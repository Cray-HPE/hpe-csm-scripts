#!/bin/bash

# MIT License
# 
# (C) Copyright [2022-2023] Hewlett Packard Enterprise Development LP
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

# This script runs one or more sets of CT tests for HMS services via 'helm test'.
# When all HMS tests are invoked, they are executed in parallel and thus should
# not include tests that would interfere with one another. By default, The Helm
# charts for HMS services are configured to only run non-disruptive tests since
# they are executed during installs and upgrades in the CSM health validation steps.

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

# service name, helm deployment, smoke tests bool, functional tests bool
BSS_ARR=("bss" "cray-hms-bss" 1 1)
CAPMC_ARR=("capmc" "cray-hms-capmc" 1 1)
FAS_ARR=("fas" "cray-hms-firmware-action" 1 1)
HBTD_ARR=("hbtd" "cray-hms-hbtd" 1 0)
HMNFD_ARR=("hmnfd" "cray-hms-hmnfd" 1 0)
HSM_ARR=("hsm" "cray-hms-smd" 1 1)
PCS_ARR=("pcs" "cray-power-control" 1 1)
REDS_ARR=("reds" "cray-hms-reds" 1 0)
SCSD_ARR=("scsd" "cray-hms-scsd" 1 0)
SLS_ARR=("sls" "cray-hms-sls" 1 1)

ALL_ARR=("${BSS_ARR[@]}" \
"${CAPMC_ARR[@]}" \
"${FAS_ARR[@]}" \
"${HBTD_ARR[@]}" \
"${HMNFD_ARR[@]}" \
"${HSM_ARR[@]}" \
"${PCS_ARR[@]}" \
"${REDS_ARR[@]}" \
"${SCSD_ARR[@]}" \
"${SLS_ARR[@]}")

ALL_SERVICES="${BSS_ARR[0]} \
${CAPMC_ARR[0]} \
${FAS_ARR[0]} \
${HBTD_ARR[0]} \
${HMNFD_ARR[0]} \
${HSM_ARR[0]} \
${PCS_ARR[0]} \
${REDS_ARR[0]} \
${SCSD_ARR[0]} \
${SLS_ARR[0]}"

# default behavior is to run all hms tests
TEST_SERVICE="all"
DATE_TIME=$(date +"%Y%m%dT%H%M%S")
LOG_PATH="/opt/cray/tests/hms_ct_test-${DATE_TIME}.log"
HELP_URL="https://github.com/Cray-HPE/docs-csm/blob/main/troubleshooting/hms_ct_manual_run.md"

# parse command-line options
while getopts "hlt:" opt; do
    case ${opt} in
        h) echo "run_hms_ct_tests.sh is a test utility for HMS services"
           echo
           echo "Usage: run_hms_ct_tests.sh [-h] [-l] [-t <service>]"
           echo
           echo "Arguments:"
           echo "    -h        display this help message"
           echo "    -l        list the HMS services that can be tested"
           echo "    -t        test the specified service, must be one of:"
           echo "                  all ${ALL_SERVICES}"
           exit 0
           ;;
        l) echo "${ALL_SERVICES}"
           exit 0
           ;;
        t) case ${OPTARG} in
               "all" | \
               "${BSS_ARR[0]}" | \
               "${CAPMC_ARR[0]}" | \
               "${FAS_ARR[0]}" | \
               "${HBTD_ARR[0]}" | \
               "${HMNFD_ARR[0]}" | \
               "${HSM_ARR[0]}" | \
               "${PCS_ARR[0]}" | \
               "${REDS_ARR[0]}" | \
               "${SCSD_ARR[0]}" | \
               "${SLS_ARR[0]}")
                   TEST_SERVICE=${OPTARG}
                   ;;
               *)
                   echo "ERROR: bad argument supplied to -t <service>, must be one of:"
                   echo "    all ${ALL_SERVICES}"
                   exit 1
                   ;;
           esac
           ;;
        ?) exit 1
           ;;
    esac
done

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

if [[ ${TEST_SERVICE} == "all" ]]; then
    NUM_TEST_SERVICES=0
    echo "Running all tests..."
    for i in $(seq 0 4 $((${#ALL_ARR[@]} - 1))); do
        TEST_DEPLOYMENT=${ALL_ARR[$((${i} + 1))]}
        helm test -n services ${TEST_DEPLOYMENT} >> ${LOG_PATH} 2>&1 &
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

    # initialize variables
    SERVICES_PASSED=""
    SERVICES_FAILED=""
    NUM_SERVICES_PASSED=0
    NUM_SERVICES_FAILED=0

    # evaluate which tests passed and failed
    for i in $(seq 0 4 $((${#ALL_ARR[@]} - 1))); do
        # data for service being tested
        TEST_SERVICE=${ALL_ARR[${i}]}
        TEST_DEPLOYMENT=${ALL_ARR[$((${i} + 1))]}
        TEST_SMOKE=${ALL_ARR[$((${i} + 2))]}
        TEST_FUNCTIONAL=${ALL_ARR[$((${i} + 3))]}
        # some services only have smoke tests, others also have functional tests
        NUM_TESTS_EXPECTED=$((${TEST_SMOKE} + ${TEST_FUNCTIONAL}))

        # parse test output
        TEST_OUTPUT=$(echo "${ALL_OUTPUT}" | sed -n '/^NAME: '${TEST_DEPLOYMENT}'/,/^NAME:/p')
        LAST_LINE_CHECK=$(echo "${TEST_OUTPUT}" | tail -n 1 | grep "NAME:")
        if [[ -n "${LAST_LINE_CHECK}" ]]; then
            TEST_OUTPUT=$(echo "${TEST_OUTPUT}" | sed '$d')
        fi

        # check for output from Helm test
        if [[ -z "${TEST_OUTPUT}" ]]; then
            print_and_log "ERROR: failed to parse output for ${TEST_SERVICE} test data"
        else
            COMPLETION_CHECK=$(echo "${TEST_OUTPUT}" | grep -E "Phase:")
            if [[ -z "${COMPLETION_CHECK}" ]]; then
                print_and_log "ERROR: ${TEST_SERVICE} tests didn't appear to run"
            fi
        fi

        # check for pass or fail result
        NUM_TESTS_PASSED=$(echo "${TEST_OUTPUT}" | grep -E "Phase:.*Succeeded" | wc -l | tr -d " ")

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
        print_and_log "SUCCESS: All ${NUM_TEST_SERVICES} service tests passed: ${SERVICES_PASSED}"
        exit 0
    elif [[ ${NUM_SERVICES_PASSED} -eq 0 ]]; then
        print_and_log "FAILURE: All ${NUM_TEST_SERVICES} service tests FAILED: ${SERVICES_FAILED}"
        echo "For troubleshooting and manual steps, see: ${HELP_URL}"
        exit 1
    else
        if [[ ${NUM_SERVICES_FAILED} -eq 1 ]] ; then
            print_and_log "FAILURE: ${NUM_SERVICES_FAILED} service test FAILED (${SERVICES_FAILED}), ${NUM_SERVICES_PASSED} passed (${SERVICES_PASSED})"
        else
            print_and_log "FAILURE: ${NUM_SERVICES_FAILED} service tests FAILED (${SERVICES_FAILED}), ${NUM_SERVICES_PASSED} passed (${SERVICES_PASSED})"
        fi
        echo "For troubleshooting and manual steps, see: ${HELP_URL}"
        exit 1
    fi
else
    # data for service being tested
    case ${TEST_SERVICE} in
        # some services only have smoke tests, others also have functional tests
        "${BSS_ARR[0]}") TEST_DEPLOYMENT="${BSS_ARR[1]}" ; NUM_TESTS_EXPECTED=$((${BSS_ARR[2]} + ${BSS_ARR[3]})) ;;
      "${CAPMC_ARR[0]}") TEST_DEPLOYMENT="${CAPMC_ARR[1]}" ; NUM_TESTS_EXPECTED=$((${CAPMC_ARR[2]} + ${CAPMC_ARR[3]})) ;;
        "${FAS_ARR[0]}") TEST_DEPLOYMENT="${FAS_ARR[1]}" ; NUM_TESTS_EXPECTED=$((${FAS_ARR[2]} + ${FAS_ARR[3]})) ;;
       "${HBTD_ARR[0]}") TEST_DEPLOYMENT="${HBTD_ARR[1]}" ; NUM_TESTS_EXPECTED=$((${HBTD_ARR[2]} + ${HBTD_ARR[3]})) ;;
      "${HMNFD_ARR[0]}") TEST_DEPLOYMENT="${HMNFD_ARR[1]}" ; NUM_TESTS_EXPECTED=$((${HMNFD_ARR[2]} + ${HMNFD_ARR[3]})) ;;
        "${HSM_ARR[0]}") TEST_DEPLOYMENT="${HSM_ARR[1]}" ; NUM_TESTS_EXPECTED=$((${HSM_ARR[2]} + ${HSM_ARR[3]})) ;;
        "${PCS_ARR[0]}") TEST_DEPLOYMENT="${PCS_ARR[1]}" ; NUM_TESTS_EXPECTED=$((${PCS_ARR[2]} + ${PCS_ARR[3]})) ;;
       "${REDS_ARR[0]}") TEST_DEPLOYMENT="${REDS_ARR[1]}" ; NUM_TESTS_EXPECTED=$((${REDS_ARR[2]} + ${REDS_ARR[3]})) ;;
       "${SCSD_ARR[0]}") TEST_DEPLOYMENT="${SCSD_ARR[1]}" ; NUM_TESTS_EXPECTED=$((${SCSD_ARR[2]} + ${SCSD_ARR[3]})) ;;
        "${SLS_ARR[0]}") TEST_DEPLOYMENT="${SLS_ARR[1]}" ; NUM_TESTS_EXPECTED=$((${SLS_ARR[2]} + ${SLS_ARR[3]})) ;;
            *) print_and_log "ERROR: invalid service: ${TEST_SERVICE}"
               exit 1 ;;
    esac

    echo "Running ${TEST_SERVICE} tests..."
    helm test -n services ${TEST_DEPLOYMENT} > ${LOG_PATH} 2>&1

    echo "DONE."

    if [[ -r "${LOG_PATH}" ]]; then
        echo "" >> "${LOG_PATH}"
        TEST_OUTPUT=$(cat "${LOG_PATH}")
    else
        echo "ERROR: missing readable test output file: ${LOG_PATH}"
        exit 1
    fi

    # check for output from Helm test
    COMPLETION_CHECK=$(echo "${TEST_OUTPUT}" | grep -E "Phase:")
    if [[ -z "${COMPLETION_CHECK}" ]]; then
        print_and_log "ERROR: ${TEST_SERVICE} tests didn't appear to run"
    fi

    # check for pass or fail result
    NUM_TESTS_PASSED=$(cat "${LOG_PATH}" | grep -E "Phase:.*Succeeded" | wc -l | tr -d " ")

    # print test results
    if [[ ${NUM_TESTS_PASSED} -eq ${NUM_TESTS_EXPECTED} ]]; then
        print_and_log "SUCCESS: Service test passed: ${TEST_SERVICE}"
        exit 0
    else
        print_and_log "FAILURE: Service test FAILED: ${TEST_SERVICE}"
        echo "For troubleshooting and manual steps, see: ${HELP_URL}"
        exit 1
    fi
fi
