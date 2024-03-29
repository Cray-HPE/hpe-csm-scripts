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


# is_vshasta_node
function is_vshasta_node {
    # This is the best check for an image specifically booted to vshasta
    [[ -f /etc/google_system ]] && return 0

    # metal images can still be booted on GCP, so check if there are any disks vendored by Google
    # if not, we conclude that this is not GCP
    lsblk --noheadings -o vendor | grep -q Google
    return $?
}

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

# print_failed_pod_logs <pod_filter_arg>
function print_failed_pod_logs()
{
    if [[ -z "${1}" ]] || [[ "${1}" == "all" ]]; then
        POD_FILTER="test-smoke|test-functional"
    else
        POD_FILTER="${1}-test-smoke|${1}-test-functional"
    fi

    # gather list of failed HMS test pods
    FAILED_PODS=$(kubectl -n services get pods | grep -E "${POD_FILTER}" | awk '{print $1}')

    # print the failed pod logs
    for POD in ${FAILED_PODS}; do
        echo
        echo "Printing pod logs for ${POD}..."
        kubectl -n services logs ${POD}
        echo
    done
}

# set up signal handling
trap 'if [[ -f ${LOG_PATH} ]]; then \
          echo Received kill signal, exiting with status code: 1 | tee -a ${LOG_PATH}; \
      else \
          echo Received kill signal, exiting with status code: 1; \
      fi; \
      exit 1' SIGHUP SIGINT SIGTERM

# service name, helm deployment, smoke tests bool, functional tests bool, helm filter args
BSS_ARR=("bss" "cray-hms-bss" 1 1 "none")
CAPMC_ARR=("capmc" "cray-hms-capmc" 1 1 "name=cray-hms-capmc-test-smoke,name=cray-hms-capmc-test-functional")
FAS_ARR=("fas" "cray-hms-firmware-action" 1 1 "none")
HBTD_ARR=("hbtd" "cray-hms-hbtd" 1 0 "none")
HMNFD_ARR=("hmnfd" "cray-hms-hmnfd" 1 1 "none")
HSM_ARR=("hsm" "cray-hms-smd" 1 1 "name=cray-hms-smd-test-smoke,name=cray-hms-smd-test-functional")
PCS_ARR=("pcs" "cray-power-control" 1 1 "none")
SCSD_ARR=("scsd" "cray-hms-scsd" 1 0 "none")
SLS_ARR=("sls" "cray-hms-sls" 1 1 "none")

ALL_ARR=("${BSS_ARR[@]}" \
"${CAPMC_ARR[@]}" \
"${FAS_ARR[@]}" \
"${HBTD_ARR[@]}" \
"${HMNFD_ARR[@]}" \
"${HSM_ARR[@]}" \
"${PCS_ARR[@]}" \
"${SCSD_ARR[@]}" \
"${SLS_ARR[@]}")

ALL_SERVICES="${BSS_ARR[0]} \
${CAPMC_ARR[0]} \
${FAS_ARR[0]} \
${HBTD_ARR[0]} \
${HMNFD_ARR[0]} \
${HSM_ARR[0]} \
${PCS_ARR[0]} \
${SCSD_ARR[0]} \
${SLS_ARR[0]}"

# default behavior is to run all hms tests
TEST_SERVICE="all"
PRINT_POD_LOGS=false
DATE_TIME=$(date +"%Y%m%dT%H%M%S")
LOG_PATH="/opt/cray/tests/hms_ct_test-${DATE_TIME}.log"
HELP_URL="https://github.com/Cray-HPE/docs-csm/blob/main/troubleshooting/hms_ct_manual_run.md"

# parse command-line options
while getopts "hlt:p" opt; do
    case ${opt} in
        h) echo "run_hms_ct_tests.sh is a test utility for HMS services"
           echo
           echo "Usage: run_hms_ct_tests.sh [-h] [-l] [-t <service>] [-p]"
           echo
           echo "Arguments:"
           echo "    -h        display this help message"
           echo "    -l        list the HMS services that can be tested"
           echo "    -t        test the specified service, must be one of:"
           echo "                  all ${ALL_SERVICES}"
           echo "    -p        print pod logs of failed tests to stdout"
           echo "                  Warning: output is verbose"
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
        p) PRINT_POD_LOGS=true
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

if ${PRINT_POD_LOGS}; then
    which kubectl &> /dev/null
    if [[ $? -ne 0 ]]; then
        echo "ERROR: kubectl command missing, can't print pod logs"
        PRINT_POD_LOGS=false
    fi
fi

echo "Log file for run is: ${LOG_PATH}"

if [[ ${TEST_SERVICE} == "all" ]]; then
    #############################
    # Run all HMS service tests #
    #############################

    NUM_TEST_SERVICES=0
    echo "Running all tests..."
    for i in $(seq 0 5 $((${#ALL_ARR[@]} - 1))); do
        TEST_DEPLOYMENT=${ALL_ARR[$((${i} + 1))]}
        FILTER_ARGS=${ALL_ARR[$((${i} + 4))]}
        if [[ "${FILTER_ARGS}" == "none" ]]; then
            helm test -n services ${TEST_DEPLOYMENT} >> ${LOG_PATH} 2>&1 &
        else
            helm test -n services ${TEST_DEPLOYMENT} --filter ${FILTER_ARGS} >> ${LOG_PATH} 2>&1 &
        fi
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
    for i in $(seq 0 5 $((${#ALL_ARR[@]} - 1))); do
        # data for service being tested
        TEST_SERVICE=${ALL_ARR[${i}]}
        TEST_DEPLOYMENT=${ALL_ARR[$((${i} + 1))]}
        TEST_SMOKE=${ALL_ARR[$((${i} + 2))]}
        TEST_FUNCTIONAL=${ALL_ARR[$((${i} + 3))]}
        # some services only have smoke tests, others also have functional tests
        NUM_TESTS_EXPECTED=$((${TEST_SMOKE} + ${TEST_FUNCTIONAL}))
        NUM_TESTS_PASSED=0

        # parse smoke test output
        if [[ ${TEST_SMOKE} -eq 1 ]]; then
            TEST_SUITE_SMOKE_OUTPUT=$(echo "${ALL_OUTPUT}" | sed -n '/TEST SUITE:.*'${TEST_DEPLOYMENT}'-test-smoke/,/Phase:/p')
            if [[ -z "${TEST_SUITE_SMOKE_OUTPUT}" ]]; then
                print_and_log "ERROR: ${TEST_DEPLOYMENT}-test-smoke tests didn't appear to run"
            else
                TEST_SUITE_SMOKE_PARSE_CHECK=$(echo "${TEST_SUITE_SMOKE_OUTPUT}" | grep -E "TEST SUITE:" | wc -l | tr -d " ")
                if [[ ${TEST_SUITE_SMOKE_PARSE_CHECK} -ne 1 ]]; then
                    print_and_log "ERROR: failed to parse Helm output for ${TEST_DEPLOYMENT}-test-smoke data"
                    # ensure invalid data is not processed
                    TEST_SUITE_SMOKE_OUTPUT=""
                fi
            fi
            TEST_SUITE_SMOKE_PASS_CHECK=$(echo "${TEST_SUITE_SMOKE_OUTPUT}" | grep -E "Phase:.*Succeeded" | wc -l | tr -d " ")
            if [[ ${TEST_SUITE_SMOKE_PASS_CHECK} -eq 1 ]]; then
                ((NUM_TESTS_PASSED++))
            fi
        fi

        # parse functional test output
        if [[ ${TEST_FUNCTIONAL} -eq 1 ]]; then
            TEST_SUITE_FUNCTIONAL_OUTPUT=$(echo "${ALL_OUTPUT}" | sed -n '/TEST SUITE:.*'${TEST_DEPLOYMENT}'-test-functional/,/Phase:/p')
            if [[ -z "${TEST_SUITE_FUNCTIONAL_OUTPUT}" ]]; then
                print_and_log "ERROR: ${TEST_DEPLOYMENT}-test-functional tests didn't appear to run"
            else
                TEST_SUITE_FUNCTIONAL_PARSE_CHECK=$(echo "${TEST_SUITE_FUNCTIONAL_OUTPUT}" | grep -E "TEST SUITE:" | wc -l | tr -d " ")
                if [[ ${TEST_SUITE_FUNCTIONAL_PARSE_CHECK} -ne 1 ]]; then
                    print_and_log "ERROR: failed to parse Helm output for ${TEST_DEPLOYMENT}-test-functional data"
                    # ensure invalid data is not processed
                    TEST_SUITE_FUNCTIONAL_OUTPUT=""
                fi
            fi
            TEST_SUITE_FUNCTIONAL_PASS_CHECK=$(echo "${TEST_SUITE_FUNCTIONAL_OUTPUT}" | grep -E "Phase:.*Succeeded" | wc -l | tr -d " ")
            if [[ ${TEST_SUITE_FUNCTIONAL_PASS_CHECK} -eq 1 ]]; then
                ((NUM_TESTS_PASSED++))
            fi
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
        print_and_log "SUCCESS: All ${NUM_TEST_SERVICES} service tests passed: ${SERVICES_PASSED}"
        exit 0
    elif [[ ${NUM_SERVICES_PASSED} -eq 0 ]]; then
        print_and_log "FAILURE: All ${NUM_TEST_SERVICES} service tests FAILED: ${SERVICES_FAILED}"
        echo "For troubleshooting and manual steps, see: ${HELP_URL}"
        if ${PRINT_POD_LOGS}; then
            print_failed_pod_logs "all"
        fi
        exit 1
    else
        if [[ ${NUM_SERVICES_FAILED} -eq 1 ]]; then
            print_and_log "FAILURE: ${NUM_SERVICES_FAILED} service test FAILED (${SERVICES_FAILED}), ${NUM_SERVICES_PASSED} passed (${SERVICES_PASSED})"
        else
            print_and_log "FAILURE: ${NUM_SERVICES_FAILED} service tests FAILED (${SERVICES_FAILED}), ${NUM_SERVICES_PASSED} passed (${SERVICES_PASSED})"
        fi
        echo "For troubleshooting and manual steps, see: ${HELP_URL}"
        if ${PRINT_POD_LOGS}; then
            print_failed_pod_logs "all"
        fi
        exit 1
    fi
else
    #################################
    # Run tests for one HMS service #
    #################################

    # data for service being tested
    case ${TEST_SERVICE} in
        # services may or may not have smoke tests, functional tests, and helm filter arguments
        "${BSS_ARR[0]}") TEST_DEPLOYMENT="${BSS_ARR[1]}"
                         TEST_SMOKE="${BSS_ARR[2]}"
                         TEST_FUNCTIONAL="${BSS_ARR[3]}"
                         NUM_TESTS_EXPECTED=$((${BSS_ARR[2]} + ${BSS_ARR[3]}))
                         FILTER_ARGS="${BSS_ARR[4]}" ;;
      "${CAPMC_ARR[0]}") TEST_DEPLOYMENT="${CAPMC_ARR[1]}"
                         TEST_SMOKE="${CAPMC_ARR[2]}"
                         TEST_FUNCTIONAL="${CAPMC_ARR[3]}"
                         NUM_TESTS_EXPECTED=$((${CAPMC_ARR[2]} + ${CAPMC_ARR[3]}))
                         FILTER_ARGS="${CAPMC_ARR[4]}" ;;
        "${FAS_ARR[0]}") TEST_DEPLOYMENT="${FAS_ARR[1]}"
                         TEST_SMOKE="${FAS_ARR[2]}"
                         TEST_FUNCTIONAL="${FAS_ARR[3]}"
                         NUM_TESTS_EXPECTED=$((${FAS_ARR[2]} + ${FAS_ARR[3]}))
                         FILTER_ARGS="${FAS_ARR[4]}" ;;
       "${HBTD_ARR[0]}") TEST_DEPLOYMENT="${HBTD_ARR[1]}"
                         TEST_SMOKE="${HBTD_ARR[2]}"
                         TEST_FUNCTIONAL="${HBTD_ARR[3]}"
                         NUM_TESTS_EXPECTED=$((${HBTD_ARR[2]} + ${HBTD_ARR[3]}))
                         FILTER_ARGS="${HBTD_ARR[4]}" ;;
      "${HMNFD_ARR[0]}") TEST_DEPLOYMENT="${HMNFD_ARR[1]}"
                         TEST_SMOKE="${HMNFD_ARR[2]}"
                         TEST_FUNCTIONAL="${HMNFD_ARR[3]}"
                         NUM_TESTS_EXPECTED=$((${HMNFD_ARR[2]} + ${HMNFD_ARR[3]}))
                         FILTER_ARGS="${HMNFD_ARR[4]}" ;;
        "${HSM_ARR[0]}") TEST_DEPLOYMENT="${HSM_ARR[1]}"
                         TEST_SMOKE="${HSM_ARR[2]}"
                         TEST_FUNCTIONAL="${HSM_ARR[3]}"
                         NUM_TESTS_EXPECTED=$((${HSM_ARR[2]} + ${HSM_ARR[3]}))
                         FILTER_ARGS="${HSM_ARR[4]}" ;;
        "${PCS_ARR[0]}") TEST_DEPLOYMENT="${PCS_ARR[1]}"
                         TEST_SMOKE="${PCS_ARR[2]}"
                         TEST_FUNCTIONAL="${PCS_ARR[3]}"
                         NUM_TESTS_EXPECTED=$((${PCS_ARR[2]} + ${PCS_ARR[3]}))
                         FILTER_ARGS="${PCS_ARR[4]}" ;;
       "${SCSD_ARR[0]}") TEST_DEPLOYMENT="${SCSD_ARR[1]}"
                         TEST_SMOKE="${SCSD_ARR[2]}"
                         TEST_FUNCTIONAL="${SCSD_ARR[3]}"
                         NUM_TESTS_EXPECTED=$((${SCSD_ARR[2]} + ${SCSD_ARR[3]}))
                         FILTER_ARGS="${SCSD_ARR[4]}" ;;
        "${SLS_ARR[0]}") TEST_DEPLOYMENT="${SLS_ARR[1]}"
                         TEST_SMOKE="${SLS_ARR[2]}"
                         TEST_FUNCTIONAL="${SLS_ARR[3]}"
                         NUM_TESTS_EXPECTED=$((${SLS_ARR[2]} + ${SLS_ARR[3]}))
                         FILTER_ARGS="${SLS_ARR[4]}";;
            *) print_and_log "ERROR: invalid service: ${TEST_SERVICE}"
               exit 1 ;;
    esac

    NUM_TESTS_PASSED=0

    echo "Running ${TEST_SERVICE} tests..."
    if [[ "${FILTER_ARGS}" == "none" ]]; then
        helm test -n services ${TEST_DEPLOYMENT} > ${LOG_PATH} 2>&1
    else
        helm test -n services ${TEST_DEPLOYMENT} --filter ${FILTER_ARGS} > ${LOG_PATH} 2>&1
    fi

    echo "DONE."

    if [[ -r "${LOG_PATH}" ]]; then
        echo "" >> "${LOG_PATH}"
        TEST_OUTPUT=$(cat "${LOG_PATH}")
    else
        echo "ERROR: missing readable test output file: ${LOG_PATH}"
        exit 1
    fi

    # parse smoke test output
    if [[ ${TEST_SMOKE} -eq 1 ]]; then
        TEST_SUITE_SMOKE_OUTPUT=$(echo "${TEST_OUTPUT}" | sed -n '/TEST SUITE:.*'${TEST_DEPLOYMENT}'-test-smoke/,/Phase:/p')
        if [[ -z "${TEST_SUITE_SMOKE_OUTPUT}" ]]; then
            print_and_log "ERROR: ${TEST_DEPLOYMENT}-test-smoke tests didn't appear to run"
        else
            TEST_SUITE_SMOKE_PARSE_CHECK=$(echo "${TEST_SUITE_SMOKE_OUTPUT}" | grep -E "TEST SUITE:" | wc -l | tr -d " ")
            if [[ ${TEST_SUITE_SMOKE_PARSE_CHECK} -ne 1 ]]; then
                print_and_log "ERROR: failed to parse Helm output for ${TEST_DEPLOYMENT}-test-smoke data"
                # ensure invalid data is not processed
                TEST_SUITE_SMOKE_OUTPUT=""
            fi
        fi
        TEST_SUITE_SMOKE_PASS_CHECK=$(echo "${TEST_SUITE_SMOKE_OUTPUT}" | grep -E "Phase:.*Succeeded" | wc -l | tr -d " ")
        if [[ ${TEST_SUITE_SMOKE_PASS_CHECK} -eq 1 ]]; then
            ((NUM_TESTS_PASSED++))
        fi
    fi

    # parse functional test output
    if [[ ${TEST_FUNCTIONAL} -eq 1 ]]; then
        TEST_SUITE_FUNCTIONAL_OUTPUT=$(echo "${TEST_OUTPUT}" | sed -n '/TEST SUITE:.*'${TEST_DEPLOYMENT}'-test-functional/,/Phase:/p')
        if [[ -z "${TEST_SUITE_FUNCTIONAL_OUTPUT}" ]]; then
            print_and_log "ERROR: ${TEST_DEPLOYMENT}-test-functional tests didn't appear to run"
        else
            TEST_SUITE_FUNCTIONAL_PARSE_CHECK=$(echo "${TEST_SUITE_FUNCTIONAL_OUTPUT}" | grep -E "TEST SUITE:" | wc -l | tr -d " ")
            if [[ ${TEST_SUITE_FUNCTIONAL_PARSE_CHECK} -ne 1 ]]; then
                print_and_log "ERROR: failed to parse Helm output for ${TEST_DEPLOYMENT}-test-functional data"
                # ensure invalid data is not processed
                TEST_SUITE_FUNCTIONAL_OUTPUT=""
            fi
        fi
        TEST_SUITE_FUNCTIONAL_PASS_CHECK=$(echo "${TEST_SUITE_FUNCTIONAL_OUTPUT}" | grep -E "Phase:.*Succeeded" | wc -l | tr -d " ")
        if [[ ${TEST_SUITE_FUNCTIONAL_PASS_CHECK} -eq 1 ]]; then
            ((NUM_TESTS_PASSED++))
        fi
    fi

    # print test results
    if [[ ${NUM_TESTS_PASSED} -eq ${NUM_TESTS_EXPECTED} ]]; then
        print_and_log "SUCCESS: Service test passed: ${TEST_SERVICE}"
        exit 0
    else
        print_and_log "FAILURE: Service test FAILED: ${TEST_SERVICE}"
        echo "For troubleshooting and manual steps, see: ${HELP_URL}"
        if ${PRINT_POD_LOGS}; then
            print_failed_pod_logs "${TEST_DEPLOYMENT}"
        fi
        exit 1
    fi
fi
