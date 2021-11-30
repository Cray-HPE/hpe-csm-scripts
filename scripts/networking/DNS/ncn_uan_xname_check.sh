#!/bin/bash
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

TOKEN=$(curl -s -k -S -d grant_type=client_credentials -d client_id=admin-client -d client_secret=`kubectl get secrets admin-client-auth -o jsonpath='{.data.client-secret}' | base64 -d` https://api-gw-service-nmn.local/keycloak/realms/shasta/protocol/openid-connect/token | jq -r '.access_token')


node_list=""
uan_list=""

for node in $(kubectl get nodes| awk '{print $1}'|grep -v NAME);do
	node_list+="${node} "
done

echo "Kubernetes Nodes"
for node in $node_list;do
	xname=$(curl -s -k -H "Authorization: Bearer ${TOKEN}" "https://api-gw-service-nmn.local/apis/sls/v1/search/hardware?extra_properties.Role=Management" | jq -r '.[] | select(."ExtraProperties"."Aliases"[] | contains("'$node'")) | .Xname')
	number_of_records=$(dig $xname +short|wc -l)
	if [[ $number_of_records -gt 1 ]]
	then
		echo "$xname has more than 1 A-record - this is a problem.  This is usually related to network bond creation."
		dig dig $xname +short
		echo "This is known issue. Please remove the incorrect IP from SMD EthernetInterfaces."
		echo "If you require assistance, please open a CAST ticket and assign to CSMNET."
	fi
done

uan_list=$(curl -s -k -H "Authorization: Bearer ${TOKEN}" "https://api-gw-service-nmn.local/apis/sls/v1/search/hardware?extra_properties.Role=Application" | jq -r '.[] | select(."ExtraProperties"."Aliases"[] | contains("uan")) | .Xname')

echo "UANs"
for uan in $uan_list;do
	number_of_records=$(dig $uan +short|wc -l)
	if [[ $number_of_records -gt 1 ]]
	then
		echo "$uan has more than 1 A-record - this is a problem.  This is usually related to network bond creation."
		dig dig $uan +short
		echo "This is known issue. Please remove the incorrect IP from SMD EthernetInterfaces."
		echo "If you require assistance, please open a CAST ticket and assign to CSMNET."
	fi
done