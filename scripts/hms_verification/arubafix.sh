#!/bin/bash


# MIT License
# 
# (C) Copyright [2021] Hewlett Packard Enterprise Development LP
# 
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation
# the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included
# in all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
# THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR
# OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
# ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.


# The bug: SNMP doesn't always report all MAC addr entries, so HMS discovery
# job reports it as not found.  So no idea which leaf switch should have it.
# Thus: the SNMP reset has to be applied to all leaf switches, to be sure.
# One way to figger out the switch that needs the fix -- use the mgmt interface
# to look for the MAC, using e.g. 'ssh sw-leaf-001 show mac-address-table'.
# If MAC is found in that table, that is the one that needs to be reset.
# This may be a future enhancement.


SWPW=""
DISCOVERY_LOG=/tmp/hmsdisc.log
HELP_URL="https://github.com/Cray-HPE/docs-csm/blob/main/troubleshooting/aruba_snmp_manual_fixup.md"

debugLevel=0
testMode=0

resetSNMP() {
	swname=$1

	echo "Performing SNMP Reset on Aruba leaf switch: ${swname}"
	echo " "
	expLog=/tmp/swreset_exp_${swname}.out

 	expect -c "
spawn ssh admin@${swname}
expect \"password: \"
send \"${SWPW}\n\"
expect \"# \"
send \"configure terminal\n\"
expect \"config)# \"
send \"no snmp-server vrf default\n\"
expect \"config)# \"
send \"snmp-server vrf default\n\"
expect \"config)# \"
send \"exit\n\"
expect \"# \"
send \"write memory\n\"
expect \"# \"
send \"exit\n\"
" > $expLog 2>&1

	if [ $? -ne 0 ]; then
		echo "Communication with $swname failed."
		echo " "
		echo "Communication log:"
		echo " "
		cat $expLog
		echo " "
		return 1
	else
		echo "Aruba switch $swname SNMP reset succeeded."
	fi

	if (( debugLevel > 0 )); then
		cat $expLog
	fi

	return 0
}

usage() {
	echo "Usage: `basename $0` [-h] [-d] [-t]"
	echo " "
	echo "   -h    Help text"
	echo "   -d    Print debug info during execution."
	echo "   -t    Test mode, don't touch Aruba switches."
	echo " "
}


### ENTRY POINT

while getopts "hdt" opt; do
	case "${opt}" in
		h)
			usage
			exit 0
			;;
		d)
			(( debugLevel = debugLevel + 1 ))
			;;
		t)
			testMode=1
			;;
		*)
			usage
			exit 0
			;;
	esac
done

## Get a list of Aruba leaf switches.  If there are none, nothing to do.

echo " "
echo "==> Getting Aruba leaf switch info from SLS..."

swJSON="/tmp/sw.JSON"
cray sls search hardware list --type comptype_mgmt_switch --format json > $swJSON

if [ $? -ne 0 ]; then
	echo " "
	echo "ERROR executing SLS switch HW search:"
	cat $swJSON
	echo " "
	echo "For troubleshooting and manual steps, see ${HELP_URL}."
	echo " "
	echo "Exiting..."
	exit 1
fi

echo " "
echo "==> Fetching switch hostnames..."

swNames=$(cat $swJSON | jq '.[] | select((.Class == "River") and (.ExtraProperties.Brand == "Aruba"))' | jq '.ExtraProperties.Aliases[0]' | sed 's/"//g')

if (( debugLevel > 0 )); then
	echo "Switches found:"
	echo $swNames
	echo " "
fi

if [[ "${swNames}" == "" ]]; then
	echo " "
	echo "No Aruba switches found, nothing to do, exiting."
	exit 0
fi


## Check if the aruba switch problem exists.


# 1. Determine the name of the last HSM discovery job that ran
#    NOTE: be sure the job is in the Completed state!  If not, loop
#    until it is.

for (( iter = 1; iter <= 30; iter = iter + 1 )); do
	if (( iter == 1 )); then
		echo "==> Looking for completed HMS discovery pod..."
	else
		echo "==> Looking for completed HMS discovery pod, attempt #${iter}..."
	fi

	HMS_DISCOVERY_POD=$(kubectl -n services get pods -l app=hms-discovery | tail -n 1 | grep Completed | awk '{ print $1 }')
	if [[ "${HMS_DISCOVERY_POD}" != "" ]]; then
		break
	fi
	sleep 5
done

if [[ "${HMS_DISCOVERY_POD}" == "" ]]; then
	echo "ERROR: No valid HMS discovery pod found; discovery in progress? Exiting."
	echo " "
	echo "For troubleshooting and manual steps, see ${HELP_URL}."
	echo " "
	exit 1
fi

if (( debugLevel > 0 )); then
	echo "Most recent HMS discover pod: $HMS_DISCOVERY_POD"
fi

kubectl -n services logs $HMS_DISCOVERY_POD -c hms-discovery > $DISCOVERY_LOG 2>&1

# 2. Examine the discovery logs to get MAC addrs associated with undiscovered
#    MACs.
 
echo " "
echo "==> Looking for undiscovered MAC addrs in discovery log..."
echo " "
UNKNOWN_MACS=$(cat $DISCOVERY_LOG | jq 'select(.msg == "MAC address in HSM not found in any switch!").unknownComponent.ID' -r -c)

if (( debugLevel > 0 )); then
	echo "Unknown MACs:"
	echo "$UNKNOWN_MACS"
fi

if [[ "${UNKNOWN_MACS}" == "" ]]; then
	echo "No unknown/undiscovered MACs found;"
	echo "no Aruba issue on this system, exiting."
	exit 0
else
	echo "Found unknown/undiscovered MACs in discovery log."
fi

# 3. Use the logs to get MAC addrs of ones found on the switches (but not 
#    in HSM).

echo " "
echo "==> Looking for unknown/undiscovered MAC addrs in discovery log..."
FOUND_IN_SWITCH_MACS=$(cat $DISCOVERY_LOG | jq 'select(.msg == "Found MAC address in switch.").macWithoutPunctuation' -r)

if (( debugLevel > 0 )); then
	echo "MACS in switches:"
	echo "$FOUND_IN_SWITCH_MACS"
fi

# 4. Do a diff to match the 2 sets.  Any MACs not found in both indicate
#    the aruba problem exists.

echo " "
echo "==> Identifying undiscovered MAC mismatches..."
echo " "
if (( debugLevel > 1 )); then
	diff -y <(echo "$UNKNOWN_MACS" | sort -u) <(echo "$FOUND_IN_SWITCH_MACS" \
        | sort -u)
fi

diff -y <(echo "$UNKNOWN_MACS" | sort -u) <(echo "$FOUND_IN_SWITCH_MACS" \
        | sort -u) | awk 'BEGIN{bad=0}{if (($2 == "<") || ($2 == "|")) { bad = 1 }}END{exit bad}'
hasbadmac=$?
rslt=0

if [ $hasbadmac -ne 0 ]; then
	# We need another check if there are mismatches.  It's possible some of them
	# are from another network that we don't care  about.

	suspectMACs=$(diff -y <(echo "$UNKNOWN_MACS" | sort -u) <(echo "$FOUND_IN_SWITCH_MACS" \
        | sort -u) | grep -e '<' -e '|' | awk '{printf("%s\n",$1)}')


	for mac in ${suspectMACs}; do
		if (( debugLevel > 1 )); then
			echo "Unknown MAC: .${mac}."
		fi

		# Get IP
		ip=$(cat $DISCOVERY_LOG | jq "select(.unknownComponent.ID == \"${mac}\") | .unknownComponent.IPAddress" | sed 's/"//g')

		NW=$(cray sls search networks list --ip-address $ip --format json | jq .[].Name | sed 's/"//g')

		if (( debugLevel > 1 )); then
			echo "Unknown MAC's IP: ${ip}, network: ${NW}."
		fi

		#Ignore networks that are not one of "HMN", "HMN_RVR", or "HMN_MTN"
    #shellcheck disable=SC2166
		if [ "${NW}" == "HMN" -o "${NW}" == "HMN_RVR" -o "${NW}" == "HMN_MTN" ]; then
			rslt=1
			break
		else
			echo "INFO: Unknown MAC: ${mac} is on non-relevant network: ${NW}, ignoring."
		fi
	done
fi

if [[ $rslt == 0 ]]; then
	echo "============================"
	echo "= No Aruba MAC mismatches. ="
	echo "============================"
	exit 0
fi

## If we got here, we have a discovery problem.  We need to delete the SNMP
## configuration from the affected switch(es?) and reconfigure the SNMP
## server.  NOTE: it is possible that the MAC will never show up in some cases.

# Use SLS to get a list of River Aruba switches.
#
# cray sls search hardware list --type comptype_mgmt_switch --format json
#
# Look for Class (River)
#          ExtraProperties.Aliases[0] (hostname)
#          Brand (Aruba)

echo "============================================"
echo "= Aruba undiscovered MAC mismatches found! ="
echo "= Performing switch SNMP resets.           ="
echo "============================================"

if (( testMode != 0 )); then
	echo " "
	echo "[Test mode, not acting on Aruba switches.]"
	exit 0
fi


# For each Aruba switch, perform the SNMP reset

echo " "
echo "==> Applying SNMP reset to Aruba switches..."
echo " "
echo -n " ==> PASSWORD REQUIRED for Aruba access.  Enter Password: "
stty -echo
read SWPW
stty echo
echo " "

ok=1
for mswitch in ${swNames}; do
	resetSNMP $mswitch
	if [ $? -ne 0 ]; then
		ok=0
	fi
	
done

if (( ok != 1 )); then
	echo " "
	echo "Some Aruba switches did not get SNMP reset, Exiting..."
	echo " "
	echo "For troubleshooting and manual steps, see ${HELP_URL}."
	echo " "
	exit 1
fi

echo " "
exit 0

