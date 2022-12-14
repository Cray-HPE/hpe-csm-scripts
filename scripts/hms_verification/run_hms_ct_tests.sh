#!/bin/bash

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


ctSmokeLog="/tmp/ct_smoke_log.txt"
ctFuncLog="/tmp/ct_func_log.txt"
HELP_URL="https://github.com/Cray-HPE/docs-csm/blob/release/1.2/troubleshooting/hms_ct_manual_run.md"

echo "================================================================="
echo "============  Running HMS CT Smoke Tests... ====================="
echo "================================================================="
echo " "

if [ ! -e /opt/cray/tests/ncn-resources/hms/hms-test/hms_run_ct_smoke_tests_ncn-resources.sh ]; then
	echo " "
	echo "===> CT Smoke test not found -- not installed?"
	echo " "
	echo "For troubleshooting and manual steps, see ${HELP_URL}."
	echo " "
	exit 1
fi

/opt/cray/tests/ncn-resources/hms/hms-test/hms_run_ct_smoke_tests_ncn-resources.sh > $ctSmokeLog 2>&1
rval=$?

if [[ $rval != 0 ]]; then
	echo "CT Smoke Test Failed.  See output in ${ctSmokeLog}."
	echo " "
	echo "For troubleshooting and manual steps, see ${HELP_URL}."
	echo " "
	exit 1
fi


echo " "
echo "================================================================="
echo "===========  Running HMS CT Functional Tests... ================="
echo "================================================================="
echo " "

if [ ! -e /opt/cray/tests/ncn-resources/hms/hms-test/hms_run_ct_functional_tests_ncn-resources.sh ]; then
	echo " "
	echo "===> CT Functional Test not found -- not installed?"
	echo " "
	echo "For troubleshooting and manual steps, see ${HELP_URL}."
	echo " "
	exit 1
fi

/opt/cray/tests/ncn-resources/hms/hms-test/hms_run_ct_functional_tests_ncn-resources.sh > $ctFuncLog 2>&1
rval=$?

if [[ $rval != 0 ]]; then
	echo " "
	echo "===> CT Functional Test Failed.  See output in ${ctFuncLog}."
	echo " "
	echo "For troubleshooting and manual steps, see ${HELP_URL}."
	echo " "
	exit 1
fi

exit 0

