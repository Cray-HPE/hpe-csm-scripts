#!/usr/bin/python3

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



import json
from base64 import b64decode
import requests
from kubernetes import client, config
import re
import string
from itertools import groupby
from operator import itemgetter

##############################################################################
# Generate per-cabinet details containing info on nodes, NodeBMCs, RouterBMCs,
# CabinetPDUControllers.   A Higher level func will do these by type -- river,
# and hill/mountain.   This func will print FAIL/PASS/WARNING as needed along
# with relevant data, and of: "Not present in HSM State Components"
#                             "Not Present in HSM RedfishEndpoints"
#                             "No mgmt port association"

# Each mountain cabinet has 8 ChassisBMC. It is expected that all 8 are
# discovered. (pass/fail)
# Each hill cabinet has 2 ChassisBMCs (c1 and c3), It is expected that both are
# discovered. (pass/fail)

# For each River Cabinet provide a summary of the number of Management NCNs,
# Application, and Compute nodes in each cabinet

# For each River BMC/Component in SLS verify that it exists under
# RedfishEndpoints and State Components in HSM

# For RouterBMCs/NodeBMCs/Nodes this can be made PASS/FAIL

# For the Master Management NCNs it is acceptable to that 1 of them has a BMC
# not connected to the HMN. Provide an information message for the master NCN
# BMCs that are not connected to the HMN, also provide the alias of the nodes.

# For CMCs if they are missing should be a warning
# Intel CMCs are not expected to be discovered

# For CabinetPDUControllers this should be made a Warning
# HPE PDUs are not expected to be discovered
##############################################################################

# Node topology constants
expected_node_topology = [
	{
		# Windom
		"Models": ["WindomNodeCard", "WNC"],
		"ExpectedBMCs": ["b0", "b1"],
		"ExpectedNodes": ["b0n0", "b0n1", "b1n0", "b1n1"]
	},
	{
		# Castle
		"Models": ["CNC"],
		"ExpectedBMCs": ["b0", "b1"],
		"ExpectedNodes": ["b0n0", "b0n1", "b1n0", "b1n1"]
	},
	{
		# Grizzly Peak
		"Models": ["GrizzlyPkNodeCard"],
		"ExpectedBMCs": ["b0"],
		"ExpectedNodes": ["b0n0", "b0n1"]
	},
	{
		# Bard Peak
		"Models": ["BardPeakNC"],
		"ExpectedBMCs": ["b0", "b1"],
		"ExpectedNodes": ["b1n0", "b1n0"]
	},
	{
		# Antero
		"Models": ["ANTERO"],
		"ExpectedBMCs": ["b0"],
		"ExpectedNodes": ["b0n0", "b0n1", "b0n2", "b0n3"]

	}
]

# Build a lookup table by model
expected_node_topology_by_model = {}
for node_topology in expected_node_topology:
	for model in node_topology["Models"]:
		expected_node_topology_by_model[model] = node_topology

# Retrieve the corresponding node topology object for the given slot if it exists.
def getExpectedNodeTopologyForSlot(slot_xname, nodeEnclosureInventoryData):
	node_enclosure_xname = slot_xname + "e0"
	
	# Determine the current model for this slot. Need to check that each key exists, as its not guaranteed
	# to exist
	if node_enclosure_xname not in nodeEnclosureInventoryData:
		return None
	node_enclosure_data = nodeEnclosureInventoryData[node_enclosure_xname]
	
	if "PopulatedFRU" not in node_enclosure_data:
		return None
	
	if "NodeEnclosureFRUInfo" not in node_enclosure_data["PopulatedFRU"]:
		return None

	if "Model" not in  node_enclosure_data["PopulatedFRU"]["NodeEnclosureFRUInfo"]:
		return None
		
	# Check to see if know about this node model
	model = node_enclosure_data["PopulatedFRU"]["NodeEnclosureFRUInfo"]["Model"]
	if model not in expected_node_topology_by_model:
		# print(f"{slot_xname} Model: {model} not found!")
		return None
	
	return expected_node_topology_by_model[model]

# Retrieve the expected nodes BMCs that should be present in the slot if node topology data exists.
def getExpectedNodeBMCsForSlot(slot_xname, nodeEnclosureInventoryData):
	expected_node_topology = getExpectedNodeTopologyForSlot(slot_xname, nodeEnclosureInventoryData)
	if expected_node_topology is None:
		return None

	bmc_xnames = []
	for bmc in expected_node_topology["ExpectedBMCs"]:
		bmc_xnames.append(slot_xname+bmc)

	return bmc_xnames

# Retrieve the expected nodes that should be present in the slot if node topology data exists.
def getExpectedNodesForSlot(slot_xname, nodeEnclosureInventoryData):
	expected_node_topology = getExpectedNodeTopologyForSlot(slot_xname, nodeEnclosureInventoryData)
	if expected_node_topology is None:
		return None

	node_xnames = []
	for nodes in expected_node_topology["ExpectedNodes"]:
		node_xnames.append(slot_xname+nodes)

	return node_xnames

# Data structure to contain cabinet info.

class CabInfo():
	def __init__(self, xn, xc, model):
		self.xname = xn
		self.xclass = xc
		self.model = model

# Create a k8s client object for use in getting auth tokena.

def getK8sClient():
	config.load_kube_config()
	k8sClient = client.CoreV1Api()
	return k8sClient

# Fetch auth token for HMS REST API calls.

def getAuthenticationToken():
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

# Func to get a JSON payload from a URL.  It's assumed to be a full URL.
# Also note that we'll only ever be contacting HMS services.

def doRest(uri, authToken):
	getHeaders = {'Authorization': 'Bearer %s' % authToken,}
	r = requests.get(url=uri, headers=getHeaders)
	retJSON = r.text

	if r.status_code >= 300:
		ret = 1
	else:
		ret = 0

	return retJSON, ret


# Get HSM component data

def getHSMComponents(authToken):
	url = "https://api-gw-service-nmn.local/apis/smd/hsm/v2/State/Components"
	compsJSON, rstat = doRest(url, authToken)
	return compsJSON, rstat



# Get HSM RFEP data

def getHSMRFEP(authToken):
	url = "https://api-gw-service-nmn.local/apis/smd/hsm/v2/Inventory/RedfishEndpoints"
	rfepJSON, rstat = doRest(url, authToken)
	return rfepJSON, rstat

# Get HSM Hardware Inventory data for nodes

def getHSMInventoryHardwareForNodeEnclosures(authTokens):
	url = "https://api-gw-service-nmn.local/apis/smd/hsm/v2/Inventory/Hardware?Type=NodeEnclosure"
	rfepJSON, rstat = doRest(url, authTokens)
	return rfepJSON, rstat

# Get SLS HW data

def getSLSHWData(authToken):
	url = "https://api-gw-service-nmn.local/apis/sls/v1/hardware"
	slsJSON, rstat = doRest(url, authToken)
	return slsJSON, rstat


# Returns a list of cabinets and their type (RV,MT,HILL).
# This is taken from the SLS data.

def getCabList(sls_hardware):
	cabList = []

	for comp in sls_hardware:
		if comp['TypeString'] == "Cabinet":
			model = None
			if "Model" in comp['ExtraProperties']:
				model = comp['ExtraProperties']['Model']
			cabList.append(CabInfo(comp['Xname'], comp['Class'], model))

	return cabList


# Given a BMC, return a list of connected mgmt port NICs.

def findNodeNics(bmc, sls_hardware):
	nics = []
	for comp in sls_hardware:
		if not "ExtraProperties" in comp:
			continue

		if not "NodeNics" in comp['ExtraProperties']:
			continue

		for nic in comp['ExtraProperties']['NodeNics']:
			if nic == bmc:
				nics.append(comp['Xname'])

	return nics

# Xname helpers
def get_component_parent(xname:str):
    regex_cdu = "^d([0-9]+)$"
    regex_cabinet = "^x([0-9]{1,4})$"
    if re.match(regex_cdu, xname) is not None or re.match(regex_cabinet, xname) is not None:
		# Parent of Cabinets and CDUs is the System s0
        return "s0"

    # Trim all trailing numbers, then in the result, trim all trailing
	# letters.
    return xname.rstrip(string.digits).rstrip(string.ascii_letters)

# Convenience function, checks SLS components to see if they are present in
# HSM component data, HSM RedfishEndpoint data, and if there is a mgmt port
# associated with it in SLS.  Returns a message with relevant info.

def doChecks(xclass, comp, bname, ctype, hsm_state_components, hsm_redfish_endpoints, sls_hardware):
	noc = ""

	# Check state components presence
	filtered = list(filter(lambda f: (f['ID'] == bname), hsm_state_components.values()))
	if not filtered:
		noc = "Not found in HSM Components"

	# Check RF Endpoints presence
	filtered = list(filter(lambda f: (f['ID'] == bname), hsm_redfish_endpoints.values()))
	if not filtered:
		if len(noc) > 0:
			noc += "; "
		noc += "Not found in HSM Redfish Endpoints"

	if xclass == "River":
		# Check mgmt port connection
		filtered = findNodeNics(bname, sls_hardware)
		if not filtered:
			if len(noc) > 0:
				noc += "; "
			noc += "No mgmt port connection"
			if ctype == "NodeBMC":
				# Check if this is a mgmt NCN, if so, print alias.  This is
				# determined by looking at the Role -- look for Management.
				# Then, grab the ExtraProperties/Aliases.
				if comp['ExtraProperties']['Role'] == "Management":
					noc += "; BMC of mgmt node " + comp['ExtraProperties']['Aliases'][0]

	return noc

# Generate a per-cabinet summary containing numbers of nodes, BMCs, etc.
# This needs to be gotten from HSM component data.  TODO: should we be using
# the RF endpoints instead?

def genSummary(sls_hardware, hsm_state_components):
	cabList = getCabList(sls_hardware)
	# Sort by cab num
	clSorted = sorted(cabList, key=lambda cab: cab.xname)

	print("HSM Cabinet Summary")
	print("===================")

	for cab in clSorted:
		nodes = 0
		nodebmcs = 0
		cmcs = 0
		rtrbmcs = 0
		chassisbmcs = 0
		cabpducontrollers = 0
		appNodes = 0
		mgmtNodes = 0
		compNodes = 0

		computeModuleSlotsPopulated = 0
		computeModuleSlotsEmpty = 0
		routerModuleSlotsPopulated = 0
		routerModuleSlotsEmpty = 0

		for comp in hsm_state_components.values():
			if not comp['ID'].startswith(cab.xname):
				continue

			ctype = comp['Type']
			if ctype == "Node":
				nodes += 1
				if comp['Role'] == "Compute":
					compNodes += 1
				elif comp['Role'] == "Management":
					mgmtNodes += 1
				elif comp['Role'] == "Application":
					appNodes += 1
			elif ctype == "NodeBMC" and comp['ID'].endswith("b999"):
				cmcs += 1
			elif ctype == "NodeBMC":
				nodebmcs += 1
			elif ctype == "RouterBMC":
				rtrbmcs += 1
			elif ctype == "ChassisBMC":
				chassisbmcs += 1
			elif ctype == "CabinetPDUController":
				cabpducontrollers += 1
			elif ctype == "ComputeModule":
				if comp["State"] == "Empty":
					computeModuleSlotsEmpty += 1
				else:
					computeModuleSlotsPopulated += 1
			elif ctype == "RouterModule":
				if comp["State"] == "Empty":
					routerModuleSlotsEmpty  += 1
				else:
					routerModuleSlotsPopulated += 1

		cabinet_description = cab.xclass
		if cab.model is not None:
			cabinet_description += " - " + cab.model
		print("%s (%s)" % (cab.xname, cabinet_description))
		if cab.xclass == "River":
			print("  Discovered Nodes:         %3d (%d Mgmt, %d Application, %d Compute)" %
				(nodes, mgmtNodes, appNodes, compNodes))
		else:
			print("  Discovered Nodes:         %3d" % (nodes))

		print("  Discovered Node BMCs:     %3d" % (nodebmcs))
		print("  Discovered Router BMCs:   %3d" % (rtrbmcs))
		print("  Discovered Chassis BMCs:  %3d" % (chassisbmcs))
		if cab.xclass == "River" or cab.model == "EX2500":
			print("  Discovered Cab PDU Ctlrs: %3d" % (cabpducontrollers))
			print("  Discovered CMCs:          %3d" % (cmcs))
		if cab.xclass in ["Hill", "Mountain"]:
			print("  Compute Module slots")
			print("    Populated: %3d" % (computeModuleSlotsPopulated))
			print("    Empty:     %3d" % (computeModuleSlotsEmpty))
			print("  Router Module slots")
			print("    Populated: %3d" % (routerModuleSlotsPopulated))
			print("    Empty:     %3d" % (routerModuleSlotsEmpty))

	print("")


def genCabinetDetails(sls_hardware, hsm_state_components, hsm_redfish_endpoints, hsm_inventory_node_enclosures, cabinet_selector, check_river_specific_hardware=False, check_mountain_specific_hardware=False):
	numErrs = 0

	cabList = getCabList(sls_hardware)
	# Sort by cab num
	clSorted = sorted(cabList, key=lambda cab: cab.xname)

	numCabs = 0
	for cab in clSorted:
		# Check to see if this cabinet should be checked
		if not cabinet_selector(cab):
			continue

		numCabs += 1

		cabinet_description = cab.xclass
		if cab.model is not None:
			cabinet_description += " - " + cab.model
		print("%s (%s)" % (cab.xname, cabinet_description))

		if check_mountain_specific_hardware:
			#
			# Chassis BMCs
			#

			# Check ChassisBMCs.  All 8 must be present in each cabinet for
			# Mountain (EX3000/EX4000), c1 and c3 must be present for Hill 
			# EX2000, and EX2500 cabinets can have 1, 2 or 3.
			# NOTE!!!  
			# It is assumed that the SLS data contains all requisite ChassisBMCs 
			# and this app does not have to verify the counts or e.g. that c1 
			# and c3 are both present in SLS for Hill (EX2000).

			errs = []
			chassis_bmcs = list(filter(lambda f: (f['TypeString'] == "ChassisBMC"), sls_hardware))
			for chassis_bmc in chassis_bmcs:
				chassis_bmc_xname = chassis_bmc["Xname"]

				error_msgs = []

				# Check state components presence
				if chassis_bmc_xname not in hsm_state_components:
					error_msgs.append("Not found in HSM Components")

				# Check RF Endpoints presence
				if chassis_bmc_xname not in hsm_redfish_endpoints:
					error_msgs.append("Not found in HSM Redfish Endpoints")

				if len(error_msgs) > 0:
					errs.append("- %s - %s." % (chassis_bmc_xname, '; '.join(error_msgs)))

			# Print out the Chassis BMC info.
			if not errs:
				print("  ChassisBMCs: PASS")
			else:
				numErrs += 1
				print("  ChassisBMCs: FAIL")
				for emsg in errs:
					print("    %s" % (emsg))

		#
		# Nodes
		#

		# Check Nodes.  Missing == WARNING.

		# Iterate all nodes in SLS.  Check for not present in comps/rfeps,
		# mgmt ports.  Any missing/mismatch is a FAIL.
		errs = []
		nodes = list(filter(lambda f: (f['TypeString'] == "Node"), sls_hardware))
		for node in nodes:
			node_xname = node['Xname']
			if not node_xname.startswith(cab.xname):
				continue

			if node_xname not in hsm_state_components:
				# Check to see if the slot is populated
				bmc_xname = get_component_parent(node_xname)
				slot_xname = get_component_parent(bmc_xname)

				# Ignore empty slots
				if slot_xname in hsm_state_components and hsm_state_components[slot_xname]["State"] == "Empty":
					continue

				# Check to see if this node is expected to be present based on the node enclosure
				expected_bmcs = getExpectedNodesForSlot(slot_xname, hsm_inventory_node_enclosures)
				if expected_bmcs is not None:
					if bmc_xname not in expected_bmcs:
						continue

				# Not all nodes have NIDs, so check for that.
				nidStr = "N/A"
				if "NID" in node['ExtraProperties']:
					nidStr = "%d" % (node['ExtraProperties']['NID'])
				aliasString = "N/A"
				if "Aliases" in node['ExtraProperties']:
					aliasString = ", ".join(node['ExtraProperties']["Aliases"])

				errs.append("- %s (%s, NID %s, Alias %s) - Not found in HSM Components." %
					(node_xname, node['ExtraProperties']['Role'], nidStr, aliasString))

		# Print out the node info.
		if not errs:
			print("  Nodes: PASS")
		else:
			print("  Nodes: FAIL")
			for emsg in errs:
				print("    %s" % (emsg))

		# Check NodeBMCs.  Missing == WARNING.  This is tricky, the SLS data
		# doesn't have node BMCs, need to infer them from the nodes using the
		# Parent field.  Check for presence in comps/RFEPs and mgmt ports,
		# mismatches == WARNING.
		# if so, report it as info.
		errs = []
		mappedComps = {}
		for node in nodes:
			node_xname = node['Xname']
			if not node_xname.startswith(cab.xname):
				continue
			
			# Determine xnames
			bmc_xname = node['Parent']
			slot_xname = get_component_parent(bmc_xname)

			# Check to see if we have already processes this BMC before
			if bmc_xname in mappedComps:
				continue
			mappedComps[bmc_xname] = True

			# Check to see if this is ncn-m001's BMC. If so than ignore it if its BMC is not connected to the HMN
			if "ncn-m001" in node["ExtraProperties"]["Aliases"] and len(findNodeNics(bmc_xname, sls_hardware)) == 0:
				continue

			# Ignore empty slots. If a slot is empty then there is no blade present.
			# print(f"Node BMC Slot: {slot_xname}")
			if slot_xname in hsm_state_components and hsm_state_components[slot_xname]["State"] == "Empty":
				continue

			# Check to see if this node is expected to be present based on the node enclosure
			expected_bmcs = getExpectedNodeBMCsForSlot(slot_xname, hsm_inventory_node_enclosures)
			# print(f"Expected Node BMCs for {slot_xname}: {expected_bmcs}")
			if expected_bmcs is not None:
				if bmc_xname not in expected_bmcs:
					# print("Ignoring NodeBMC as its not expected to be present")
					continue

			noc = doChecks(cab.xclass, node, bmc_xname, "NodeBMC", hsm_state_components, hsm_redfish_endpoints, sls_hardware)

			if len(noc) > 0:
				errs.append("- %s - %s." % (bmc_xname, noc))

		# Print out the Node BMC info.
		if not errs:
			print("  NodeBMCs: PASS")
		else:
			print("  NodeBMCs: FAIL")
			for emsg in errs:
				print("    %s" % (emsg))

		# Check RouterBMCs.  Missing == WARNING.
		errs = []
		router_bmcs = list(filter(lambda f: (f['TypeString'] == "RouterBMC"), sls_hardware))
		for router_bmc in router_bmcs:
			bname = router_bmc['Xname']
			if not bname.startswith(cab.xname):
				continue

			noc = doChecks(cab.xclass, router_bmc, bname, "RouterBMC", hsm_state_components, hsm_redfish_endpoints, sls_hardware)
			if len(noc) > 0:
				errs.append("- %s - %s." % (bname, noc))

		# Print out the Chassis BMC info.
		if not errs:
			print("  RouterBMCs: PASS")
		else:
			numErrs += 1
			print("  RouterBMCs: FAIL")
			for emsg in errs:
				print("    %s" % (emsg))

		if check_river_specific_hardware:
			# Check Gigabyte CMCs
			errs = []
			gigabyte_cmcs = list(filter(lambda f: (f['Xname'].endswith("b999")), sls_hardware))
			for gigabyte_cmc in gigabyte_cmcs:
				gigabyte_cmc_xname = gigabyte_cmc['Xname']
				if not gigabyte_cmc_xname.startswith(cab.xname):
					continue

				noc = doChecks(cab.xclass, gigabyte_cmc, bname, "ChassisBMC", hsm_state_components, hsm_redfish_endpoints, sls_hardware)

				# Check to see if this is a "phantom Intel CMC", which shows up for intel compute nodes but is
				# not a real device.
				if len(findNodeNics(gigabyte_cmc_xname, sls_hardware)) == 0:
					continue

				if len(noc) > 0:
					errs.append("- %s - %s." % (bname, noc))

			# Print out CMC info
			if not errs:
				print("  CMCs: PASS")
			else:
				numErrs += 1
				print("  CMCs: FAIL")
				for emsg in errs:
					print("    %s" % (emsg))

			# Check CabPDUControllers in SLS.  Check comps/RFEP.  Mgmt port?
			# Mismatches are FAIL.
			pdus = list(filter(lambda f: (f['TypeString'] == "CabinetPDUController"), sls_hardware))
			for pdu in pdus:
				bname = pdu['Xname']
				if not bname.startswith(cab.xname):
					continue

				noc = doChecks(cab.xclass, pdu, bname, "CabinetPDUController",  hsm_state_components, hsm_redfish_endpoints, sls_hardware)
				if len(noc) > 0:
					errs.append("- %s - %s." % (bname, noc))

			# Print out the Cabomet PDU Controller info.
			if not errs:
				print("  CabinetPDUControllers: PASS")
			else:
				print("  CabinetPDUControllers: FAIL")
				for emsg in errs:
					print("    %s" % (emsg))

	if numCabs == 0:
		print("None Found.")

	print("")
	return numErrs

# Entry point

def main():
	authToken = getAuthenticationToken()
	if authToken == "":
		print("ERROR: No/empty auth token, can't continue.")
		return 1

	hsm_state_components_raw, stat = getHSMComponents(authToken)
	if stat != 0:
		print("HSM components returned non-zero.")
		return 1

	# Put HSM State components into a map
	hsm_state_components = {}
	for component in json.loads(hsm_state_components_raw)['Components']:
		hsm_state_components[component["ID"]] = component

	# Retrieve HSM Redfish information data
	hsm_redfish_endpoints_raw, stat = getHSMRFEP(authToken)
	if stat != 0:
		print("HSM RFEPs returned non-zero.")
		return 1
	
	# Put HSM RedfishEndpoints into a map
	hsm_redfish_endpoints = {}
	for redfish_endpoint in json.loads(hsm_redfish_endpoints_raw)['RedfishEndpoints']:
		hsm_redfish_endpoints[redfish_endpoint["ID"]] = redfish_endpoint


	# Retrieve HSM node enclosure inventory data
	hsm_inventory_node_enclosures_raw, stat = getHSMInventoryHardwareForNodeEnclosures(authToken)
	if stat != 0:
		print("HSM Inventory Hardware data for nodes returned non-zero.")
		return 1

	# Put HSM node enclosure inventory data into a map
	hsm_inventory_node_enclosures = {}
	for node_enclosure in json.loads(hsm_inventory_node_enclosures_raw):
		hsm_inventory_node_enclosures[node_enclosure["ID"]] = node_enclosure
	

	sls_hardware_raw, stat = getSLSHWData(authToken)
	if stat != 0:
		print("SLS hardware data returned non-zero.")
		return 1
	sls_hardware = json.loads(sls_hardware_raw)

	genSummary(sls_hardware, hsm_state_components)

	print("River Cabinet Checks")
	print("============================")
	numErrs = genCabinetDetails(sls_hardware, hsm_state_components, hsm_redfish_endpoints, hsm_inventory_node_enclosures,
		lambda cab: cab.xclass == "River",
		check_river_specific_hardware=True,
		check_mountain_specific_hardware=False
	)

	print("Mountain/Hill Cabinet Checks")
	print("============================")
	numErrs += genCabinetDetails(sls_hardware, hsm_state_components, hsm_redfish_endpoints, hsm_inventory_node_enclosures,
		lambda cab: cab.xclass == "Mountain" or (cab.xclass == "Hill" and cab.model != "EX2500"),
		check_river_specific_hardware=False,
		check_mountain_specific_hardware=True
	)

	print("EX2500 Cabinet Checks")
	print("============================")
	numErrs += genCabinetDetails(sls_hardware, hsm_state_components, hsm_redfish_endpoints, hsm_inventory_node_enclosures,
		lambda cab: cab.xclass == "Hill" and cab.model == "EX2500",
		check_river_specific_hardware=True,
		check_mountain_specific_hardware=True
	)

	if numErrs > 0:
		print("\nFor interpreting and troubleshooting results, see https://github.com/Cray-HPE/docs-csm/blob/main/operations/validate_csm_health.md#221-interpreting-hsm-discovery-results\n")
		return 1

	return 0

if __name__ == "__main__":
	ret = main()
	exit(ret)
