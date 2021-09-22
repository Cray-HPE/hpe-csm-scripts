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
    Attempt to lock any management nodes that are not already locked in HSM.
"""

import json
from base64 import b64decode
import sys
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

def doRest(uri, authToken, op, payload=None):
    """
        Func to get a JSON payload from a URL. It's assumed to be a full URL.
        Also note that we'll only ever be contacting HMS services.
    """
    getHeaders = {'Authorization': 'Bearer %s' % authToken,}
    if op == "get":
        r = requests.get(url=uri, headers=getHeaders)
    elif op == "post" and not payload is None:
        r = requests.post(url=uri, headers=getHeaders, data=json.dumps(payload))
    else:
        return 1

    retJSON = r.text

    if r.status_code >= 300:
        stat = 1
    else:
        stat = 0

    return retJSON, stat

def doRestGet(uri, authToken):
    """Wrapper for doRest() for GET operations"""
    return doRest(uri, authToken, "get")

def doRestPost(uri, authToken, payload):
    """Wrapper for doRest() for POST operations"""
    return doRest(uri, authToken, "post", payload)

def getHSMComps(authToken, fltr):
    """Get HSM RFEP data"""
    url = "https://api-gw-service-nmn.local/apis/smd/hsm/v2/State/Components" + fltr
    rfepJSON, rstat = doRestGet(url, authToken)
    rfepData = json.loads(rfepJSON)
    return rfepData, rstat

def doHSMLock(authToken, compIDList):
    """Lock specified components. compIDStr is a comma separated list of components to lock"""
    url = "https://api-gw-service-nmn.local/apis/smd/hsm/v2/locks/lock"
    payload = {"ComponentIDs": compIDList, "ProcessingModel": "flexible"}
    respJSON, rstat = doRestPost(url, authToken, payload)
    respData = json.loads(respJSON)
    return respData, rstat

def genIDStr(compList):
    """Turn a list of components into a list of xnames."""
    compStr = ""
    for comp in compList:
        if len(compStr) > 0:
            compStr += "," + comp['ID']
        else:
            compStr += comp['ID']
    return compStr

def genSummary(compList, compLockList, lockRet):
    """Generate a summary of management nodes locked and any errors that occurred."""
    print("Operation Summary")
    print("=================")

    print("Found %d management nodes:" % (len(compList)))
    compStr = genIDStr(compList)
    print("    " + compStr)

    print("Found %d management nodes to lock:" % (len(compLockList)))
    print("    " + ','.join(compLockList))

    if lockRet['Counts']['Success'] > 0:
        print("Successfully locked %d management nodes:" % (lockRet['Counts']['Success']))
        compStr = ','.join(lockRet['Success']['ComponentIDs'])
        print("    " + compStr)

    if lockRet['Counts']['Failure'] > 0:
        print("Failed to lock %d management nodes:" % (lockRet['Counts']['Failure']))
        for comp in lockRet['Failure']:
            print("    " + comp['ID'] + " - " + comp['Reason'])

    print("")
    return lockRet['Counts']['Failure']

def main():
    """Entry point"""
    numErrs = 0
    compList = []
    authToken = getAuthenticationToken()
    if authToken == "":
        print("ERROR: No/empty auth token, can't continue.")
        return 1

    compData, stat = getHSMComps(authToken, "?type=node&role=management")
    if stat != 0:
        print("HSM Components returned non-zero.")
        return 1
    for comp in compData['Components']:
        if "Locked" in comp and comp['Locked'] is True:
            continue
        compList.append(comp['ID'])
    if len(compList) == 0:
        print("No Management Nodes to Lock")
        return 0
    retData, stat = doHSMLock(authToken, compList)
    if stat != 0:
        if "detail" in retData:
            print("Failed to lock Management Nodes: " + retData['detail'])
        else:
            print("Failed to lock Management Nodes.")
        return 1

    numErrs = genSummary(compData['Components'], compList, retData)

    if numErrs > 0:
        return 1

    return 0

if __name__ == "__main__":
    ret = main()
    sys.exit(ret)
