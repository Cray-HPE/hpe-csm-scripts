#!/bin/bash -e

echo "=========================================================="
echo "             HSM Discovery Verification                   "
echo "=========================================================="

SLSJSON="/tmp/sls.json"
COMPSJSON="/tmp/comps.json"
RFEPSJSON="/tmp/rfeps.json"


echo " "
echo "Fetching SLS Components..."
cray sls hardware list --format json | jq '.[] | select ((.TypeString == "Node") or (.TypeString == "ChassisBMC") or (.TypeString == "RouterBMC") or (.TypeString == "CabinetPDUController")) | if .TypeString == "Node" then .Parent else .Xname end' | sort | uniq | sed 's/"//g' | sed 's/\(x.*c[0-9]$\)/\1b0/' > ${SLSJSON}

if [ `cat ${SLSJSON} | wc -l` -eq 0 ]; then
	echo " "
	echo "==> ERROR: Failed to get SLS Components."
	cat ${RSPOUT}
	exit 1
fi

echo " "
echo "Fetching HSM Components..."
cray hsm state components list --format json | jq '.Components[] | select((.Type == "NodeBMC") or (.Type == "ChassisBMC") or (.Type == "RouterBMC")) .ID' | sort | uniq | sed 's/"//g' > ${COMPSJSON}

if [ `cat ${COMPSJSON} | wc -l` -eq 0 ]; then
	echo " "
	echo "==> ERROR: Failed to get HSM Components."
	cat ${RSPOUT}
	exit 1
fi

echo " "
echo "Fetching HSM Redfish endpoints..."
cray hsm inventory redfishEndpoints list --format json | jq '.RedfishEndpoints[] | select((.Type == "NodeBMC") or (.Type == "ChassisBMC") or (.Type == "RouterBMC")) .ID' | sort | uniq | sed 's/"//g' > ${RFEPSJSON}

if [ `cat ${RFEPSJSON} | wc -l` -eq 0 ]; then
	echo " "
	echo "==> ERROR: Failed to get HSM Redfish endpoints."
	cat ${RSPOUT}
	exit 1
fi

rslt=0

echo " "
echo "=============== BMCs in SLS not in HSM components ==============="
wcl=`comm -23 ${SLSJSON} ${COMPSJSON} | wc -l`
if [ $wcl -eq 0 ]; then
	echo "ALL OK"
else
	comm -23 ${SLSJSON} ${COMPSJSON}
	rslt=1
fi

echo " "
echo "=============== BMCs in SLS not in HSM Redfish Endpoints =============== "
wcl=`comm -23 ${SLSJSON} ${RFEPSJSON} | wc -l`
if [ $wcl -eq 0 ]; then
	echo "ALL OK"
else
	comm -23 ${SLSJSON} ${RFEPSJSON}
	rslt=1
fi

exit $rslt

