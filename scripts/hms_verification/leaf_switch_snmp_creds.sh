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


## This script can be run with no special ENV vars, in which case
## all SNMP user and password info will be asked interactively.
## If ENV vars are used, the script will require no interaction.
##
## Example:
##
##    # SNMPDELUSER=badID SNMPNEWUSER=newID SNMPAUTHPW=authpw SNMPPRIVPW=privpw mgmt_switch_snmp_creds.sh
##
## Obviously, 'badID', 'newID', 'authPW' and 'privPW' are just example
## place holders.

MGMTPW=""
SNMPDelUser=""
SNMPNewUser=""
SNMPAuthPW=""
SNMPPrivPW=""
DODELL=1
swNamesAruba=""
swNamesDell=""

debugLevel=0
testMode=0


setSwitchSNMPCredsDell() {
	swname=$1

	echo "Setting SNMP default creds on Dell leaf switch: ${swname}"
	echo " "
	if (( testMode != 0 )); then
		echo "[Test mode, not interacting with switches.]"
		return 0
	fi

	# NOTE: Undesireable creds can NOT be removed.
 	outtext=$(expect -c "
spawn ssh admin@${swname}
while 1 {
  expect {
    \"*yes/no*\" {send \"yes\n\"}
    \"password: \" {send \"${MGMTPW}\n\"}
    \"*# \" {break}
  }
}
send \"configure terminal\n\"
expect \"config)# \"
send \"snmp-server user ${SNMPNewUser} cray-reds-group 3 auth md5 ${SNMPAuthPW} priv des ${SNMPPrivPW}\n\"
expect \"config)# \"
send \"exit\n\"
expect \"# \"
send \"write memory\n\"
expect \"# \"
send \"exit\n\"
")

	if [ $? -ne 0 ]; then
		echo "Communication with $swname failed."
		echo " "
		echo "Communication log:"
		echo " "
    #shellcheck disable=SC2154
		cat $expLog
		echo " "
		return 1
	else
		echo "Dell switch $swname SNMP cred reset succeeded."
	fi

	if (( debugLevel > 1 )); then
		echo $outtext
	fi

	return 0
}

setSwitchSNMPCredsAruba() {
	swname=$1

	echo "Setting SNMP default creds on Aruba leaf switch: ${swname}"
	echo " "
	if (( testMode != 0 )); then
		echo "[Test mode, not interacting with switches.]"
		return 0
	fi


# no snmpv3 user <NAME> [auth <AUTH-PROTOCOL> auth-pass <AUTH-PWORD> [priv <PRIV-PROTOCOL> priv-pass <PRIV-PWORD>] ]

 	outtext=$(expect -c "
spawn ssh admin@${swname}
while 1 {
  expect {
    \"*yes/no*\" {send \"yes\n\"}
    \"password: \" {send \"${MGMTPW}\n\"}
    \"*# \" {break}
  }
}
send \"configure terminal\n\"
expect \"config)# \"
send \"snmpv3 user ${SNMPNewUser} auth md5 auth-pass plaintext ${SNMPAuthPW} priv des priv-pass plaintext ${SNMPPrivPW}\n\"
expect \"config)# \"
send \"exit\n\"
expect \"# \"
send \"write memory\n\"
expect \"# \"
send \"exit\n\"
")

	if [ $? -ne 0 ]; then
		echo "Communication with $swname failed."
		echo " "
		echo "Communication log:"
		echo " "
		echo $outtext
		echo " "
		return 1
	fi

	# fail checks:
	# Check for "must be in range of" "nvalid input"

	fails=`echo $outtext | grep -e "must be in range of" -e "nvalid input"`
	if [[ "${fails}" != "" ]]; then
		echo "Failed to set new user and/or creds."
		if (( debugLevel > 1 )); then
			echo $outtext
		fi
		return 1
	fi

 	outtext2=$(expect -c "
spawn ssh admin@${swname}
expect \"password: \"
send \"${MGMTPW}\n\"
expect \"# \"
send \"configure terminal\n\"
expect \"config)# \"
send \"no snmpv3 user ${SNMPDelUser}\n\"
expect \"config)# \"
send \"exit\n\"
expect \"# \"
send \"write memory\n\"
expect \"# \"
send \"exit\n\"
")

	if [ $? -ne 0 ]; then
		echo "Communication with $swname failed."
		echo " "
		echo "Communication log:"
		echo " "
		echo $outtext2
		echo " "
		return 1
	fi

	echo "Aruba switch $swname SNMP cred reset succeeded."

	if (( debugLevel > 1 )); then
		echo $outtext
		echo " "
		echo $outtext2
	fi

	return 0
}


usage() {
	echo "Usage: `basename $0` [-h] [-a] [-d] [-t]"
	echo " "
	echo "   -h    Help text"
	echo "   -d    Print debug info during execution."
	echo "   -a    Fix up Aruba switches only.  Default"
	echo "         is all leaf switches."
	echo "   -t    Test mode, don't touch any switches."
	echo " "
	echo "This script will prompt for all needed information."
	echo "Alternatively, environment variables can be specified"
	echo "to avoid prompting:"
	echo " "
	echo "  SNMPDELUSER     SNMP user ID to delete"
	echo "  SNMPNEWUSER     SNMP new user ID to add"
	echo "  SNMPAUTHPW      SNMP auth password"
	echo "  SNMPPRIVPW      SNMP priv password"
	echo "  MGMTPW          Switch admin password"
	echo " "
}


### ENTRY POINT

while getopts "hadt" opt; do
	case "${opt}" in
		h)
			usage
			exit 0
			;;
		d)
			(( debugLevel = debugLevel + 1 ))
			;;
		a)
			DODELL=0
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
echo "==> Getting management network leaf switch info from SLS..."

swJSON="/tmp/sw.JSON"
cray sls search hardware list --type comptype_mgmt_switch --format json > $swJSON

if [ $? -ne 0 ]; then
	echo " "
	echo "ERROR executing SLS switch HW search:"
	cat $swJSON
	echo " "
	echo "Exiting..."
	exit 1
fi

echo " "
echo "==> Fetching switch hostnames..."

swNamesAruba=$(cat $swJSON | jq '.[] | select((.Class == "River") and (.ExtraProperties.Brand == "Aruba"))' | jq '.ExtraProperties.Aliases[0]' | grep -i leaf | sed 's/"//g')

if [ $DODELL -ne 0 ]; then
	swNamesDell=$(cat $swJSON | jq '.[] | select((.Class == "River") and (.ExtraProperties.Brand == "Dell"))' | jq '.ExtraProperties.Aliases[0]' | grep -i leaf | sed 's/"//g')
fi

if (( debugLevel > 0 )); then
	echo "Aruba Switches found:"
	echo $swNamesAruba
	echo " "
	if [ $DODELL -ne 0 ]; then
		echo "Dell Switches found:"
		echo $swNamesDell
		echo " "
	fi
fi

if [[ "${swNamesAruba}" == "" && "${swNamesDell}" == "" ]]; then
	echo " "
	echo "No management switches found! Nothing to do, exiting."
	exit 0
fi


## Obtain SNMP mgmt interface password, SNMP auth and priv passwords
## either from env vars or by asking.

if [[ -z "${SNMPDELUSER}" ]]; then
	echo " "
	echo -n "==> Enter 'bad' default SNMP user ID to remove: "
	read SNMPDelUser
else
	SNMPDelUser=${SNMPDELUSER}
fi

if [[ -z "${SNMPNEWUSER}" ]]; then
	echo " "
	echo -n "==> Enter new default SNMP user ID to add: "
	read SNMPNewUser
else
	SNMPNewUser=${SNMPNEWUSER}
fi

if [[ -z "${SNMPAUTHPW}" ]]; then
	echo " "
	echo -n "==> Enter new default SNMP auth password: "
	read SNMPAuthPW
else
	SNMPAuthPW=${SNMPAUTHPW}
fi

if [[ ${#SNMPAuthPW} -lt 8 || ${#SNMPAuthPW} -gt 32 ]]; then
	echo "Auth password length must be 8-32 characters long."
	echo " "
	exit 1
fi

if [[ -z "${SNMPPRIVPW}" ]]; then
	echo " "
	echo -n "==> Enter new default SNMP private password: "
	read SNMPPrivPW
else
	SNMPPrivPW=${SNMPPRIVPW}
fi

if [[ ${#SNMPPrivPW} -lt 8 || ${#SNMPPrivPW} -gt 32 ]]; then
	echo "Private password length must be 8-32 characters long."
	echo " "
	exit 1
fi

if [[ -z "${SNMPMGMTPW}" ]]; then
	echo " "
	echo -n "==> Enter switch management interface password: "
	read MGMTPW
else
	MGMTPW=${SNMPMGMTPW}
fi

if (( debugLevel > 0 )); then
	echo "Removing SNMP user ID: ${SNMPDelUser}"
	echo "Adding new SNMP user ID: ${SNMPNewUser}"
	echo "SNMP auth password: ${SNMPAuthPW}"
	echo "SNMP priv password: ${SNMPPrivPW}"
fi

badSwitches=""
ok=1

for mswitch in ${swNamesAruba}; do
	echo "==============================="
	setSwitchSNMPCredsAruba $mswitch
	if [ $? -ne 0 ]; then
		ok=0
		badSwitches="${badSwitches} ${mswitch}"
	fi
done
for mswitch in ${swNamesDell}; do
	echo "==============================="
	setSwitchSNMPCredsDell $mswitch
	if [ $? -ne 0 ]; then
		ok=0
		badSwitches="${badSwitches} ${mswitch}"
	fi
done

if (( ok != 1 )); then
	echo " "
	echo "The following switches failed to set new default SNMP credentials:"
	echo " "
	echo "   ${badSwitches}"
	echo " "
	exit 1
fi

echo " "
exit 0

