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

# service name, helm deployment, helm filter args
CAPMC_ARR=("capmc" "cray-hms-capmc" "name=cray-hms-capmc-check-hardware")
HSM_ARR=("hsm" "cray-hms-smd" "name=cray-hms-smd-check-hardware")

ALL_ARR=("${CAPMC_ARR[@]}" "${HSM_ARR[@]}")

DATE_TIME=$(date +"%Y%m%dT%H%M%S")
LOG_PATH="/opt/cray/tests/hardware_checks-${DATE_TIME}.log"

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

NUM_TEST_SERVICES=0
echo "Running hardware checks..."
for i in $(seq 0 3 $((${#ALL_ARR[@]} - 1))); do
    TEST_DEPLOYMENT=${ALL_ARR[$((${i} + 1))]}
    FILTER_ARGS=${ALL_ARR[$((${i} + 2))]}
    helm test -n services ${TEST_DEPLOYMENT} --filter ${FILTER_ARGS} >> ${LOG_PATH} 2>&1 &
    ((NUM_TEST_SERVICES++))
done
wait

echo "DONE."

if [[ -r "${LOG_PATH}" ]]; then
    # post-processing for log file readability
    sed -i '/NAME:/{x;p;x;}' "${LOG_PATH}"
    sed -i '/^$/{1d;}' "${LOG_PATH}"
    echo "" >> "${LOG_PATH}"
    ALL_OUTPUT=$(cat "${LOG_PATH}")
else
    echo "ERROR: missing readable test output file: ${LOG_PATH}"
    exit 1
fi

# check for output from Helm test
HELM_OUTPUT_CHECK=$(echo "${ALL_OUTPUT}" | grep -E "TEST SUITE:")
if [[ -z "${HELM_OUTPUT_CHECK}" ]]; then
    print_and_log "ERROR: failed to parse Helm output for test data"
    exit 1
fi

# initialize variables
SERVICES_PASSED=""
SERVICES_FAILED=""
NUM_SERVICES_PASSED=0
NUM_SERVICES_FAILED=0

# evaluate which tests passed and failed
for i in $(seq 0 3 $((${#ALL_ARR[@]} - 1))); do
    # data for service being tested
    TEST_SERVICE=${ALL_ARR[${i}]}
    TEST_DEPLOYMENT=${ALL_ARR[$((${i} + 1))]}
    NUM_TESTS_EXPECTED=1
    NUM_TESTS_PASSED=0

    # parse hardware check output
    TEST_SUITE_HW_CHECK_OUTPUT=$(echo "${ALL_OUTPUT}" | sed -n '/TEST SUITE:.*'${TEST_DEPLOYMENT}'-check-hardware/,/Phase:/p')
    if [[ -z "${TEST_SUITE_HW_CHECK_OUTPUT}" ]]; then
        print_and_log "ERROR: ${TEST_DEPLOYMENT}-check-hardware tests didn't appear to run"
    else
        TEST_SUITE_HW_CHECK_PARSE_CHECK=$(echo "${TEST_SUITE_HW_CHECK_OUTPUT}" | grep -E "TEST SUITE:" | wc -l | tr -d " ")
        if [[ ${TEST_SUITE_HW_CHECK_PARSE_CHECK} -ne 1 ]]; then
            print_and_log "ERROR: failed to parse Helm output for ${TEST_DEPLOYMENT}-check-hardware data"
            # ensure invalid data is not processed
            TEST_SUITE_HW_CHECK_OUTPUT=""
        fi
    fi

    TEST_SUITE_HW_CHECK_PASS_CHECK=$(echo "${TEST_SUITE_HW_CHECK_OUTPUT}" | grep -E "Phase:.*Succeeded" | wc -l | tr -d " ")
    if [[ ${TEST_SUITE_HW_CHECK_PASS_CHECK} -eq 1 ]]; then
        ((NUM_TESTS_PASSED++))
    fi

    # track the test result
    if [[ ${NUM_TESTS_PASSED} -eq ${NUM_TESTS_EXPECTED} ]]; then
        ((NUM_SERVICES_PASSED++))
        if [[ -z ${SERVICES_PASSED} ]]; then
            SERVICES_PASSED="${TEST_SERVICE}"
        else
            SERVICES_PASSED="${SERVICES_PASSED}, ${TEST_SERVICE}"
        fi
    else
        ((NUM_SERVICES_FAILED++))
        if [[ -z ${SERVICES_FAILED} ]]; then
            SERVICES_FAILED="${TEST_SERVICE}"
        else
            SERVICES_FAILED="${SERVICES_FAILED}, ${TEST_SERVICE}"
        fi
    fi
done

# print test results
if [[ ${NUM_SERVICES_FAILED} -eq 0 ]]; then
    print_and_log "SUCCESS: All ${NUM_TEST_SERVICES} hardware checks passed: ${SERVICES_PASSED}"
    exit 0
elif [[ ${NUM_SERVICES_PASSED} -eq 0 ]]; then
    print_and_log "FAILURE: All ${NUM_TEST_SERVICES} hardware checks FAILED: ${SERVICES_FAILED}"
    exit 1
else
    if [[ ${NUM_SERVICES_FAILED} -eq 1 ]] ; then
        print_and_log "FAILURE: ${NUM_SERVICES_FAILED} hardware check FAILED (${SERVICES_FAILED}), ${NUM_SERVICES_PASSED} passed (${SERVICES_PASSED})"
    else
        print_and_log "FAILURE: ${NUM_SERVICES_FAILED} hardware checks FAILED (${SERVICES_FAILED}), ${NUM_SERVICES_PASSED} passed (${SERVICES_PASSED})"
    fi
    exit 1
fi
