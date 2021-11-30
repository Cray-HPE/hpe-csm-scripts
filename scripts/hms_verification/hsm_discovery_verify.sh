#
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
#
#!/bin/bash -e

echo "=========================================================="
echo "             HSM Discovery Verification                   "
echo "=========================================================="

SLSJSON="/tmp/sls.json"
SLSRAW="/tmp/slsraw.json"
COMPSJSON="/tmp/comps.json"
RFEPSJSON="/tmp/rfeps.json"

# Wrapper for grep, since if grep finds no match it returns 1 and breaks stuff.
grepme () {
	tok=$1
	shift
	grep $tok $*
	return 0
}

echo " "
echo "Fetching SLS Components..."

cray sls hardware list --format json > ${SLSRAW}
if [ `cat ${SLSRAW} | wc -l` -eq 0 ]; then
	echo " "
	echo "==> ERROR: Failed to get SLS Components."
	exit 1
fi

cray sls hardware list --format json | jq '.[] | select ((.TypeString == "Node") or (.TypeString == "ChassisBMC") or (.TypeString == "RouterBMC") or (.TypeString == "CabinetPDUController")) | if .TypeString == "Node" then .Parent else .Xname end' | sort | uniq | sed 's/"//g' | sed 's/\(x.*c[0-9]$\)/\1b0/' > ${SLSJSON}

if [ `cat ${SLSJSON} | wc -l` -eq 0 ]; then
	echo " "
	echo "==> ERROR: Failed to get SLS Components."
	exit 1
fi

echo " "
echo "Fetching HSM Components..."
cray hsm state components list --format json | jq '.Components[] | select((.Type == "NodeBMC") or (.Type == "ChassisBMC") or (.Type == "RouterBMC") or (.Type == "CabinetPDUController")) .ID' | sort | uniq | sed 's/"//g' > ${COMPSJSON}

if [ `cat ${COMPSJSON} | wc -l` -eq 0 ]; then
	echo " "
	echo "==> ERROR: Failed to get HSM Components."
	exit 1
fi

echo " "
echo "Fetching HSM Redfish endpoints..."
cray hsm inventory redfishEndpoints list --format json | jq '.RedfishEndpoints[] | select((.Type == "NodeBMC") or (.Type == "ChassisBMC") or (.Type == "RouterBMC") or (.Type == "CabinetPDUController")) .ID' | sort | uniq | sed 's/"//g' > ${RFEPSJSON}

if [ `cat ${RFEPSJSON} | wc -l` -eq 0 ]; then
	echo " "
	echo "==> ERROR: Failed to get HSM Redfish endpoints."
	exit 1
fi

rslt=0

echo " "
echo "=============== BMCs in SLS not in HSM components ==============="
wcl=`comm -23 ${SLSJSON} ${COMPSJSON} | wc -l`
if [ $wcl -eq 0 ]; then
	echo "ALL OK"
else
	rslt=1
	IFS=$'\r\n' GLOBIGNORE='*' command eval 'BCOMPS=($(comm -23 ${SLSJSON} ${COMPSJSON}))'
	nbcmps=${#BCOMPS[@]}

	for (( ix = 0; ix < nbcmps; ix ++ )); do
		hasport=$(cat $SLSRAW | jq '.[] | .ExtraProperties | .NodeNics' | sed 's/"//g' | sed 's/ //g' | grepme ${BCOMPS[$ix]})

		if [ "${hasport}" == "" ]; then
			echo "${BCOMPS[$ix]}  # No mgmt port association"
		else
			echo "${BCOMPS[$ix]}"
		fi
	done
fi

echo " "
echo "=============== BMCs in SLS not in HSM Redfish Endpoints =============== "
wcl=`comm -23 ${SLSJSON} ${RFEPSJSON} | wc -l`
if [ $wcl -eq 0 ]; then
	echo "ALL OK"
else
	rslt=1
	IFS=$'\r\n' GLOBIGNORE='*' command eval 'BRFEPS=($(comm -23 ${SLSJSON} ${RFEPSJSON}))'
	nbrfeps=${#BRFEPS[@]}
	for (( ix = 0; ix < nbrfeps; ix ++ )); do
		hasport=$(cat $SLSRAW | jq '.[] | .ExtraProperties | .NodeNics' | sed 's/"//g' | sed 's/ //g' | grepme ${BRFEPS[$ix]})
		if [ "${hasport}" == "" ]; then
			echo "${BRFEPS[$ix]}  # No mgmt port association"
		else
			echo "${BRFEPS[$ix]}"
		fi
	done
fi

exit $rslt

