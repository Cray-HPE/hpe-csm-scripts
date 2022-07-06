#!/bin/bash -l

# MIT License
#
# (C) Copyright [2021-2022] Hewlett Packard Enterprise Development LP
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

# HMS test metrics test cases: 3
# 1. GET /Inventory/RedfishEndpoints API response code
# 2. GET /Inventory/RedfishEndpoints API response body
# 3. Verify Redfish endpoint discovery statuses

# get_auth_access_token
#
#   Retrieve a Keycloak authentication token for the test session which requires the
#   client secret to be supplied. Once the token is obtained, extract the "access_token"
#   field of the JSON dictionary since that is the token string that will need to be
#   supplied in the authorization headers of the curl HTTP requests being tested.
#
function get_auth_access_token()
{
    # get client secret
    CLIENT_SECRET=$(get_client_secret)
    CLIENT_SECRET_RET=$?
    if [[ ${CLIENT_SECRET_RET} -ne 0 ]] ; then
        return 1
    fi

    # get authentication token
    AUTH_TOKEN=$(get_auth_token "${CLIENT_SECRET}")
    AUTH_TOKEN_RET=$?
    if [[ ${AUTH_TOKEN_RET} -ne 0 ]] ; then
        return 1
    fi

    # extract access_token field from authentication token
    ACCESS_TOKEN=$(extract_access_token "${AUTH_TOKEN}")
    ACCESS_TOKEN_RET=$?
    if [[ ${ACCESS_TOKEN_RET} -ne 0 ]] ; then
        return 1
    fi

    # return the access_token
    echo "${ACCESS_TOKEN}"
}

# get_client_secret
#
#   Return the admin client authentication secret from Kubernetes.
#
#   Example:
#      ncn # kubectl get secrets admin-client-auth -o jsonpath='{.data.client-secret}' | base64 -d
#      <admin_client_secret>
#
function get_client_secret()
{
    # get client secret from Kubernetes
    KUBECTL_GET_SECRET_CMD="kubectl get secrets admin-client-auth -o jsonpath='{.data.client-secret}'"
    >&2 echo $(timestamp_print "Running '${KUBECTL_GET_SECRET_CMD}'...")
    KUBECTL_GET_SECRET_OUT=$(eval ${KUBECTL_GET_SECRET_CMD})
    KUBECTL_GET_SECRET_RET=$?
    if [[ ${KUBECTL_GET_SECRET_RET} -ne 0 ]] ; then
        >&2 echo -e "${KUBECTL_GET_SECRET_OUT}\n"
        >&2 echo -e "ERROR: '${KUBECTL_GET_SECRET_CMD}' failed with error code: ${KUBECTL_GET_SECRET_RET}\n"
        return 1
    elif [[ -z "${KUBECTL_GET_SECRET_OUT}" ]] ; then
        >&2 echo -e "ERROR: '${KUBECTL_GET_SECRET_CMD}' failed to return client secret\n"
        return 1
    fi
    CLIENT_SECRET=$(echo "${KUBECTL_GET_SECRET_OUT}" | base64 -d)
    echo "${CLIENT_SECRET}"
}

# get_auth_token <client_secret>
#
#   Return an admin client authentication token from Keycloak in dictionary form.
#
#   Example:
#      ncn # curl -s \
#                         -d grant_type=client_credentials -d client_id=admin-client \
#                         -d client_secret=<client_secret> \
#                         https://api-gw-service-nmn.local/keycloak/realms/shasta/protocol/openid-connect/token \
#                         | jq
#      {
#         "access_token": "<access_token>",
#         "expires_in": 300,
#         "not-before-policy": 0,
#         "refresh_expires_in": 1800,
#         "refresh_token": "<refresh_token>",
#         "scope": "profile email",
#         "session_state": "<session_state>",
#         "token_type": "bearer"
#      }
#
function get_auth_token()
{
    CLIENT_SECRET="${1}"
    if [[ -z "${CLIENT_SECRET}" ]] ; then
        >&2 echo "ERROR: No client secret argument passed to get_auth_token() function"
        return 1
    fi
    KEYCLOAK_TOKEN_URI="https://api-gw-service-nmn.local/keycloak/realms/shasta/protocol/openid-connect/token"
    KEYCLOAK_TOKEN_CMD="curl -k -i -s -S -d grant_type=client_credentials -d client_id=admin-client -d client_secret=${CLIENT_SECRET} ${KEYCLOAK_TOKEN_URI}"
    >&2 echo $(timestamp_print "Running '${KEYCLOAK_TOKEN_CMD}'...")
    KEYCLOAK_TOKEN_OUT=$(eval ${KEYCLOAK_TOKEN_CMD})
    KEYCLOAK_TOKEN_RET=$?
    if [[ ${KEYCLOAK_TOKEN_RET} -ne 0 ]] ; then
        >&2 echo -e "${KEYCLOAK_TOKEN_OUT}\n"
        >&2 echo -e "ERROR: '${KEYCLOAK_TOKEN_CMD}' failed with error code: ${KEYCLOAK_TOKEN_RET}\n"
        return 1
    fi
    KEYCLOAK_TOKEN_HTTP_STATUS=$(echo "${KEYCLOAK_TOKEN_OUT}" | head -n 1)
    KEYCLOAK_TOKEN_HTTP_STATUS_CHECK=$(echo "${KEYCLOAK_TOKEN_HTTP_STATUS}" | grep -E -w "200")
    if [[ -z "${KEYCLOAK_TOKEN_HTTP_STATUS_CHECK}" ]] ; then
        >&2 echo -e "${KEYCLOAK_TOKEN_OUT}\n"
        >&2 echo -e "ERROR: '${KEYCLOAK_TOKEN_CMD}' did not return \"200\" status code as expected\n"
        return 1
    fi
    KEYCLOAK_TOKEN_JSON=$(echo "${KEYCLOAK_TOKEN_OUT}" | tail -n 1)
    KEYCLOAK_TOKEN_JSON_PARSED=$(echo "${KEYCLOAK_TOKEN_JSON}" | jq)
    KEYCLOAK_TOKEN_JSON_PARSED_CHECK=$?
    if [[ ${KEYCLOAK_TOKEN_JSON_PARSED_CHECK} -ne 0 ]] ; then
        >&2 echo -e "${KEYCLOAK_TOKEN_OUT}\n"
        >&2 echo -e "ERROR: '${KEYCLOAK_TOKEN_CMD}' did not return parsable JSON structure as expected\n"
        return 1
    fi
    echo "${KEYCLOAK_TOKEN_JSON_PARSED}"
}

# extract_access_token <auth_token>
#
#   Use jq to extract the "access_token" field of the supplied Keycloak authentication
#   token in JSON dictionary form. This field will need to be supplied in the authorization
#   headers of the curl HTTP requests being tested.
#
function extract_access_token()
{
    AUTH_TOKEN="${1}"
    if [[ -z "${AUTH_TOKEN}" ]] ; then
        >&2 echo "ERROR: No authentication token argument passed to extract_access_token() function"
        return 1
    fi
    ACCESS_TOKEN=$(echo "${AUTH_TOKEN}" | jq -r '.access_token')
    if [[ -z "${ACCESS_TOKEN}" ]] || [[ "${ACCESS_TOKEN}" == null ]] ; then
        >&2 echo -e "${AUTH_TOKEN}\n"
        >&2 echo -e "ERROR: failed to extract \"access_token\" field from authentication token JSON structure\n"
        return 1
    fi
    echo "${ACCESS_TOKEN}"
}

# timestamp_print <message>
function timestamp_print()
{
    echo "($(date +"%H:%M:%S")) $1"
}

################
##### Main #####
################

# initialize test variables
TARGET="api-gw-service-nmn.local"

trap ">&2 echo \"recieved kill signal, exiting with status of '1'...\" ; \
    exit 1" SIGHUP SIGINT SIGTERM

# check for jq dependency
JQ_CHECK_CMD="which jq"
JQ_CHECK_OUT=$(eval ${JQ_CHECK_CMD})
JQ_CHECK_RET=$?
if [[ ${JQ_CHECK_RET} -ne 0 ]] ; then
    echo "${JQ_CHECK_OUT}"
    >&2 echo "ERROR: '${JQ_CHECK_CMD}' failed with status code: ${JQ_CHECK_RET}"
    exit 1
fi

echo "Running hsm_discovery_status_test..."

# retrieve Keycloak authentication token for session
TOKEN=$(get_auth_access_token)
TOKEN_RET=$?
if [[ ${TOKEN_RET} -ne 0 ]] ; then
    exit 1
fi

# query HSM for the Redfish endpoint discovery statuses
CURL_CMD="curl -s -k -H \"Authorization: Bearer ${TOKEN}\" https://${TARGET}/apis/smd/hsm/v2/Inventory/RedfishEndpoints"
timestamp_print "Testing '${CURL_CMD}'..."
CURL_OUT=$(eval ${CURL_CMD})
CURL_RET=$?
if [[ ${CURL_RET} -ne 0 ]] ; then
    >&2 echo "ERROR: '${CURL_CMD}' failed with status code: ${CURL_RET}"
    exit 1
elif [[ -z "${CURL_OUT}" ]] ; then
    >&2 echo "ERROR: '${CURL_CMD}' returned an empty response."
    exit 1
fi

# parse the HSM response
JQ_CMD="jq '.RedfishEndpoints[] | { ID: .ID, LastDiscoveryStatus: .DiscoveryInfo.LastDiscoveryStatus}' -c | sort -V | jq -c"
timestamp_print "Processing response with: '${JQ_CMD}'..."
PARSED_OUT=$(echo "${CURL_OUT}" | eval "${JQ_CMD}" 2> /dev/null)
if [[ -z "${PARSED_OUT}" ]] ; then
    echo "${CURL_OUT}"
    >&2 echo "ERROR: '${CURL_CMD}' returned a response with missing endpoint IDs or LastDiscoveryStatus fields"
    exit 1
fi

# sanity check the response body
while read LINE ; do
    ID_CHECK=$(echo "${LINE}" | grep -E "\"ID\"")
    if [[ -z "${ID_CHECK}" ]] ; then
        echo "${LINE}"
        >&2 echo "ERROR: '${CURL_CMD}' returned a response with missing endpoint ID fields"
        exit 1
    fi
    STATUS_CHECK=$(echo "${LINE}" | grep -E "\"LastDiscoveryStatus\"")
    if [[ -z "${STATUS_CHECK}" ]] ; then
        echo "${LINE}"
        >&2 echo "ERROR: '${CURL_CMD}' returned a response with missing endpoint LastDiscoveryStatus fields"
        exit 1
    fi
done <<< "${PARSED_OUT}"

# verify that at least one endpoint was discovered successfully
PARSED_CHECK=$(echo "${PARSED_OUT}" | grep -E "ID.*LastDiscoveryStatus.*DiscoverOK")
if [[ -z "${PARSED_CHECK}" ]] ; then
    echo "${PARSED_OUT}"
    echo "FAIL: hsm_discovery_status_test found no successfully discovered endpoints"
    exit 1
fi

# count the number of endpoints with unexpected discovery statuses
timestamp_print "Verifying endpoint discovery statuses..."
PARSED_FAILED=$(echo "${PARSED_OUT}" | grep -v "DiscoverOK")
NUM_FAILS=$(echo "${PARSED_FAILED}" | grep -E "ID.*LastDiscoveryStatus" | wc -l)
# check which failed discovery statuses are present in order to print troubleshooting steps
FURTHER_PARSED_FAILED=$(echo "${PARSED_FAILED}" | grep -E "ID.*LastDiscoveryStatus")
HTTPS_GET_FAILED_CHECK_NUM=$(echo "${FURTHER_PARSED_FAILED}" | grep -E "\"HTTPsGetFailed\"" | wc -l)
CHILD_VERIFICATION_FAILED_CHECK_NUM=$(echo "${FURTHER_PARSED_FAILED}" | grep -E "\"ChildVerificationFailed\"" | wc -l)
DISCOVERY_STARTED_CHECK_NUM=$(echo "${FURTHER_PARSED_FAILED}" | grep -E "\"DiscoveryStarted\"" | wc -l)
# one endpoint on the site network is expected to be unreachable and fail discovery with a status of 'HTTPSGetFailed'
if [[ ${NUM_FAILS} -gt 1 ]] ; then
    echo "${PARSED_FAILED}"
    echo
    echo "Note: 'HTTPsGetFailed' is the expected discovery status for ncn-m001 which is not normally connected to the site network."
    echo
    # print troubleshooting steps
    if [[ ${HTTPS_GET_FAILED_CHECK_NUM} -gt 1 ]] ; then
        echo "To troubleshoot the 'HTTPsGetFailed' endpoints:"
        echo "1. Run 'nslookup <xname>'. If this fails, it may indicate a DNS issue."
        echo "2. Run 'ping -c 1 <xname>'. If this fails, it may indicate a network or hardware issue."
        echo "3. Run 'curl -s -k -u root:<password> https://<xname>/redfish/v1/Managers'. If this fails, it may indicate a credentials issue."
        echo
    fi
    if [[ ${CHILD_VERIFICATION_FAILED_CHECK_NUM} -gt 0 ]] ; then
        echo "To troubleshoot the 'ChildVerificationFailed' endpoints:"
        echo "1. Run 'kubectl -n services get pods -l app.kubernetes.io/name=cray-smd' to get the names of the HSM pods."
        echo "2. Run 'kubectl -n services logs <cray-smd-pod> cray-smd' and check the HSM logs for the cause of the bad Redfish path."
        echo
    fi
    if [[ ${DISCOVERY_STARTED_CHECK_NUM} -gt 0 ]] ; then
        echo "To troubleshoot the 'DiscoveryStarted' endpoints:"
        echo "1. Poll the LastDiscoveryStatus of the endpoint with 'cray hsm inventory redfishEndpoints describe <xname>' until the current"
        echo "discovery operation ends and results in a new state being set."
        echo
    fi
    echo "FAIL: hsm_discovery_status_test found ${NUM_FAILS} endpoints that failed discovery, maximum allowable is 1"
    exit 1
else
    echo "PASS: hsm_discovery_status_test passed!"
    exit 0
fi