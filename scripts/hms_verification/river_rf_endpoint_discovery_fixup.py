#!/usr/bin/python3

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

"""
    Attempt to fixup river redfish endpoint discovery issues for BMCs that have
    an EthernetInterfaces entry in HSM and are pingable but do not have a
    RedfishEndpoints entry in HSM.
"""

import json
from base64 import b64decode
import sys
import os
import time
import requests
from kubernetes import client, config

def getK8sClient():
    """Create a k8s client object for use in getting auth tokens."""
    config.load_kube_config()
    k8sClient = client.CoreV1Api()
    return k8sClient

def getAuthenticationToken():
    """Fetch auth token for HMS REST API calls."""
    URL = "https://api-gw-service-nmn.local/keycloak/realms/shasta/protocol/openid-connect/token"

    kSecret = getK8sClient().read_namespaced_secret("admin-client-auth", "default")
    secret = b64decode(kSecret.data['client-secret']).decode("utf-8")

    DATA = {
        "grant_type": "client_credentials",
        "client_id": "admin-client",
        "client_secret": secret
    }

    try:
        r = requests.post(url=URL, data=DATA)
    except OSError:
        return ""

    result = json.loads(r.text)
    return result['access_token']

def doRest(uri, authToken):
    """
        Func to get a JSON payload from a URL. It's assumed to be a full URL.
        Also note that we'll only ever be contacting HMS services.
    """
    getHeaders = {'Authorization': 'Bearer %s' % authToken,}
    r = requests.get(url=uri, headers=getHeaders)
    retJSON = r.text

    if r.status_code >= 300:
        stat = 1
    else:
        stat = 0

    return retJSON, stat

def getHSMRFEP(authToken, fltr):
    """Get HSM RFEP data"""
    url = "https://api-gw-service-nmn.local/apis/smd/hsm/v2/Inventory/RedfishEndpoints" + fltr
    rfepJSON, rstat = doRest(url, authToken)
    rfepData = json.loads(rfepJSON)
    return rfepData, rstat

def getHSMEthData(authToken, fltr):
    """Get HSM EthernetInterfaces data"""
    url = "https://api-gw-service-nmn.local/apis/smd/hsm/v2/Inventory/EthernetInterfaces" + fltr
    ethJSON, rstat = doRest(url, authToken)
    ethData = json.loads(ethJSON)
    return ethData, rstat

def getSLSData(authToken, fltr):
    """Get HSM RFEP data"""
    url = "https://api-gw-service-nmn.local/apis/sls/v1/search/hardware" + fltr
    rfepJSON, rstat = doRest(url, authToken)
    rfepData = json.loads(rfepJSON)
    return rfepData, rstat

def doHSMEthDelete(authToken, ethID):
    """Delete a EthernetInterfaces entry from HSM by ethernet ID"""
    uri = "https://api-gw-service-nmn.local/apis/smd/hsm/v2/Inventory/EthernetInterfaces/" + ethID
    getHeaders = {'Authorization': 'Bearer %s' % authToken,}
    r = requests.delete(url=uri, headers=getHeaders)
    if r.status_code >= 300:
        stat = 1
    else:
        stat = 0

    return stat

def doPing(host):
    """Ping the specified host"""
    stat = os.system("ping -c 1 " + host + " > /dev/null 2>&1")
    if stat == 0:
        return True
    return False

def genBMCList(rfepData, ethData, slsData):
    """
        Generate a list of BMCs that have EthernetInterface entries but not
        RedfishEndpoint entries in HSM and are pingable.
    """
    bmcList = []

    for eth in ethData:
        if len(eth['IPAddresses']) > 0 and len(eth['IPAddresses'][0]) > 0:
            pass
        else:
            continue

        # Check RF Endpoints presence. Only care about when the
        # BMC doesn't have a redfishEndpoint entry.
        rfeps = rfepData['RedfishEndpoints']
        filtered = list(filter(lambda rfep, e=eth: (rfep['ID'] == e['ComponentID']), rfeps))
        if len(filtered) > 0:
            continue

        # Filter out non-river components
        filtered = list(filter(lambda c, e=eth: (c['Parent'] == e['ComponentID']), slsData))
        if not filtered:
            continue

        isPingable = doPing(eth['ComponentID'])
        if not isPingable:
            continue

        bmcList.append(eth)

    return bmcList

def deleteHSMEthEntries(authToken, bmcList):
    """Delete all the EthernetInterfaces entries for the specified BMCs"""
    failList = []
    passList = []

    for bmc in bmcList:
        stat = doHSMEthDelete(authToken, bmc['ID'])
        if stat != 0:
            failList.append(bmc)
        else:
            passList.append(bmc)
    return passList, failList

def waitForHSMEthEntries(authToken, bmcList):
    """Waits for the EthernetInterfaces entries for the specified BMCs to be repopulated."""
    failList = []
    passList = []
    fltr = ""
    ethData = []
    for bmc in bmcList:
        if len(fltr) == 0:
            fltr += "?MACAddress=" + bmc['MACAddress']
        else:
            fltr += "&MACAddress=" + bmc['MACAddress']

    for retry in range(5):
        print("%d: Waiting for EthernetInterfaces to be repopulated..." % retry)
        time.sleep(60)
        ethData, stat = getHSMEthData(authToken, fltr)
        if stat != 0:
            continue

        if len(ethData) == len(bmcList):
            passList = bmcList
            break
    else:
        for bmc in bmcList:
            filtered = list(filter(lambda e, b=bmc: (e['ID'] == b['ID']), ethData))
            if not filtered:
                failList.append(bmc)
            else:
                passList.append(bmc)
    return passList, failList

def waitForHSMRFEPs(authToken, bmcList):
    """
        Waits for the RedfishEndpoints entries for the specified
        BMCs to be repopulated by hms-discovery.
    """
    failList = []
    passList = []
    fltr = ""
    rfepData = []
    for bmc in bmcList:
        if len(fltr) == 0:
            fltr += "?id=" + bmc['ComponentID']
        else:
            fltr += "&id=" + bmc['ComponentID']

    for retry in range(5):
        print("%d: Waiting for RedfishEndpoints to be repopulated..." % retry)
        time.sleep(60)
        rfepData, stat = getHSMRFEP(authToken, fltr)
        if stat != 0:
            continue

        if len(rfepData['RedfishEndpoints']) == len(bmcList):
            passList = bmcList
            break
    else:
        for bmc in bmcList:
            filtered = list(filter(lambda r, b=bmc: (r['ID'] == b['ComponentID']),
                                              rfepData['RedfishEndpoints']))
            if not filtered:
                failList.append(bmc)
            else:
                passList.append(bmc)
    return passList, failList

def genIDStr(bmcList):
    """Turn a list of EthernetInterfaces into a list of xnames."""
    bmcStr = ""
    for bmc in bmcList:
        if len(bmcStr) > 0:
            bmcStr += "," + bmc['ComponentID']
        else:
            bmcStr += "    " + bmc['ComponentID']
    return bmcStr

def genSummary(bmcList, deleteFailList, ethTimeoutList, rfepTimeoutList):
    """Generate a summary of BMCs fixed and any errors that occurred."""
    print("Operation Summary")
    print("=================")

    if len(deleteFailList) > 0:
        print("Failed to delete EthernetInterface from HSM for %d BMCs:" %
              (len(deleteFailList)))
        bmcStr = genIDStr(deleteFailList)
        print(bmcStr)

    if len(ethTimeoutList) > 0:
        print("Timeout waiting for EthernetInterface creation for %d BMCs:" %
              (len(ethTimeoutList)))
        bmcStr = genIDStr(ethTimeoutList)
        print(bmcStr)

    if len(rfepTimeoutList) > 0:
        print("Timeout waiting for EthernetInterface creation for %d BMCs:" %
              (len(rfepTimeoutList)))
        bmcStr = genIDStr(rfepTimeoutList)
        print(bmcStr)

    if len(bmcList) > 0:
        print("Redfish endpoint discovery fixup succeeded for %d BMCs:" %
              (len(bmcList)))
        bmcStr = genIDStr(bmcList)
        print(bmcStr)
    else:
        print("Redfish endpoint discovery fixup succeeded for %d BMCs" %
              (len(bmcList)))

    print("")

def errorGuidance():
    print("\nFor troubleshooting and manual steps, see https://github.com/Cray-HPE/docs-csm/blob/main/troubleshooting/known_issues/discovery_job_not_creating_redfish_endpoints.md\n")

def main():
    """Entry point"""
    numErrs = 0
    authToken = getAuthenticationToken()
    if authToken == "":
        print("ERROR: No/empty auth token, can't continue.")
        print("\nFor troubleshooting and manual steps, see https://github.com/Cray-HPE/docs-csm/blob/main/operations/security_and_authentication/Retrieve_an_Authentication_Token.md\n")
        return 1

    rfepData, stat = getHSMRFEP(authToken, "?type=nodeBMC&type=routerBMC")
    if stat != 0:
        print("HSM RedfishEndpoints returned non-zero.")
        errorGuidance()
        return 1

    ethData, stat = getHSMEthData(authToken, "?type=nodeBMC&type=routerBMC")
    if stat != 0:
        print("HSM EthernetInterfaces returned non-zero.")
        errorGuidance()
        return 1

    slsData, stat = getSLSData(authToken, "?type=comptype_node&class=River")
    if stat != 0:
        print("HSM EthernetInterfaces returned non-zero.")
        errorGuidance()
        return 1

    bmcList = genBMCList(rfepData, ethData, slsData)
    if len(bmcList) > 0:
        deleteFailList = []
        ethTimeoutList = []
        rfepTimeoutList = []
        while True:
            print("Found %d river BMCs to fix:" % len(bmcList))
            bmcStr = genIDStr(bmcList)
            print(bmcStr)
            print("Deleting %d EthernetInterfaces entries for HSM" % len(bmcList))
            bmcList, deleteFailList = deleteHSMEthEntries(authToken, bmcList)
            if len(bmcList) == 0:
                break
            bmcList, ethTimeoutList = waitForHSMEthEntries(authToken, bmcList)
            if len(bmcList) == 0:
                break
            bmcList, rfepTimeoutList = waitForHSMRFEPs(authToken, bmcList)
            break
        genSummary(bmcList, deleteFailList, ethTimeoutList, rfepTimeoutList)
        numErrs = len(deleteFailList) + len(ethTimeoutList) + len(rfepTimeoutList)
    else:
        print("No river BMCs were found to need this RedfishEndpoint discovery fixup.")

    if numErrs > 0:
        errorGuidance()
        return 1

    return 0

if __name__ == "__main__":
    ret = main()
    sys.exit(ret)
