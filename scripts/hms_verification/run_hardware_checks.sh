#!/bin/bash

# MIT License
# 
# (C) Copyright [2023] Hewlett Packard Enterprise Development LP
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

# print_and_log <string>
function print_and_log()
{
    if [[ -z "${LOG_PATH}" ]]; then
        echo "ERROR: log path is not set"
        exit 1
    fi

    MESSAGE="${1}"
    if [[ -z "${MESSAGE}" ]]; then
        echo "ERROR: no message to print and log"
        exit 1
    else
        echo "${MESSAGE}" | tee -a ${LOG_PATH}
    fi
}

# set up signal handling
trap 'if [[ -f ${LOG_PATH} ]]; then \
          echo Received kill signal, exiting with status code: 1 | tee -a ${LOG_PATH}; \
      else \
          echo Received kill signal, exiting with status code: 1; \
      fi; \
      exit 1' SIGHUP SIGINT SIGTERM

DATE_TIME=$(date +"%Y%m%dT%H%M%S")
LOG_PATH="/opt/cray/tests/hardware_checks-${DATE_TIME}.log"
#TODO
HELP_URL="https://github.com/Cray-HPE/docs-csm/blob/main/troubleshooting/hms_ct_manual_run.md"

# sanity checks
which helm &> /dev/null
if [[ $? -ne 0 ]]; then
    echo "ERROR: helm command missing"
    exit 1
fi

touch ${LOG_PATH} &> /dev/null
if [[ $? -ne 0 ]]; then
    echo "ERROR: log file path is not writable: ${LOG_PATH}"
    exit 1
fi

echo "Log file for run is: ${LOG_PATH}"

echo "Running hardware checks..."
helm test -n services cray-hms-smd --filter name=cray-hms-smd-check-hardware > ${LOG_PATH} 2>&1
echo "DONE."

if [[ -r "${LOG_PATH}" ]]; then
    echo "" >> "${LOG_PATH}"
    TEST_OUTPUT=$(cat "${LOG_PATH}")
else
    echo "ERROR: missing readable test output file: ${LOG_PATH}"
    exit 1
fi

# parse hardware check output
TEST_SUITE_HW_CHECK_OUTPUT=$(echo "${TEST_OUTPUT}" | sed -n '/TEST SUITE:.*cray-hms-smd-check-hardware/,/Phase:/p')
if [[ -z "${TEST_SUITE_HW_CHECK_OUTPUT}" ]]; then
    print_and_log "ERROR: cray-hms-smd-check-hardware checks didn't appear to run"
else
    TEST_SUITE_HW_CHECK_PARSE_CHECK=$(echo "${TEST_SUITE_HW_CHECK_OUTPUT}" | grep -E "TEST SUITE:" | wc -l | tr -d " ")
    if [[ ${TEST_SUITE_HW_CHECK_PARSE_CHECK} -ne 1 ]]; then
        print_and_log "ERROR: failed to parse Helm output for cray-hms-smd-check-hardware data"
        # ensure invalid data is not processed
        TEST_SUITE_HW_CHECK_OUTPUT=""
    fi
fi
TEST_SUITE_HW_CHECK_PASS_CHECK=$(echo "${TEST_SUITE_HW_CHECK_OUTPUT}" | grep -E "Phase:.*Succeeded" | wc -l | tr -d " ")

# print results
if [[ ${TEST_SUITE_HW_CHECK_PASS_CHECK} -eq 1 ]]; then
    print_and_log "SUCCESS: Hardware checks passed"
    exit 0
else
    print_and_log "FAILURE: Hardware checks FAILED"
    #TODO
    echo "For troubleshooting and manual steps, see: ${HELP_URL}"
    exit 1
fi
