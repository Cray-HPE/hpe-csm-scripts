#!/usr/bin/env python3

# required commands to be run on switch prior to running this script.
# ssh server vrf default
# ssh server vrf mgmt
# https-server vrf default
# https-server vrf mgmt
# https-server rest access-mode read-write

import getpass
import logging
import os
import sys
import requests
import urllib3
import yaml
import pprint
from kubernetes import client, config
from netaddr import IPNetwork, IPAddress
import base64
import getopt
import json

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

usage_message = """This script updates the BGP neighbors on the management switches to match the IPs of what CSI generated.
       - It Queries SLS for network and NCN data. 

USAGE: - <IP of switch 1> <IP of Switch 2> 

       - The IPs used should be Node Management Network IPs (NMN), these IPs will be what's used for the BGP Router-ID.

Example: ./aruba_set_bgp_peers.py 10.252.0.2 10.252.0.3
"""
debug = False


def on_debug(debug=False, message=None):
    if debug:
        print("DEBUG: {}".format(message))


#
# Convenience wrapper around remote calls
#
def remote_request(
    remote_type, remote_url, headers=None, data=None, verify=True, debug=False
):
    remote_response = None
    while True:
        try:
            response = requests.request(
                remote_type, url=remote_url, headers=headers, data=data, verify=verify
            )
            on_debug(debug, "Request response: {}".format(response.text))
            response.raise_for_status()
            remote_response = json.dumps({})
            if response.text:
                remote_response = response.json()
            break
        except Exception as err:
            message = "Error calling {}: {}".format(remote_url, err)
            raise SystemExit(message)
    return remote_response


# take in switch IP and path as arguments
try:
    switch1 = sys.argv[1]
    switch2 = sys.argv[2]
except IndexError:
    print(usage_message)
    raise (SystemExit)
    sys.exit()

switch_ips = [switch1, switch2]

username = "admin"
password = getpass.getpass("Switch Password: ")


def _response_ok(response, call_type):
    """
    Checks whether API HTTP response contains the associated OK code.
    :param response: Response object
    :param call_type: String containing the HTTP request type
    :return: True if response was OK, False otherwise
    """
    ok_codes = {"GET": [200], "PUT": [200, 204], "POST": [201, 268], "DELETE": [204]}

    return response.status_code in ok_codes[call_type]


def remote_delete(remote_url, data=None, verify=False):
    response = session.delete(remote_url)
    if not _response_ok(response, "DELETE"):
        logging.warning("FAIL")
        return False
    else:
        logging.info("SUCCESS")
        return True


def remote_get(remote_url, data=None, verify=False):
    response = session.get(remote_url)
    if not _response_ok(response, "GET"):
        logging.warning("FAIL")
        return False
    else:
        logging.info("SUCCESS")
    return response


def remote_post(remote_url, data=None):
    response = session.post(remote_url, json=data, verify=False)
    if not _response_ok(response, "POST"):
        logging.warning("FAIL")
        return False
    else:
        logging.info("SUCCESS")
    return response


def remote_put(remote_url, data=None):
    response = session.put(remote_url, json=data, verify=False)
    if not _response_ok(response, "PUT"):
        logging.warning("FAIL")
        return False
    else:
        logging.info("SUCCESS")
    return response


#
# Get the admin client secret from Kubernetes
#
secret = None
try:
    config.load_kube_config()
    v1 = client.CoreV1Api()
    secret_obj = v1.list_namespaced_secret(
        "default", field_selector="metadata.name=admin-client-auth"
    )
    secret_dict = secret_obj.to_dict()
    secret_base64_str = secret_dict["items"][0]["data"]["client-secret"]
    on_debug(debug, "base64 secret from Kubernetes is {}".format(secret_base64_str))
    secret = base64.b64decode(secret_base64_str.encode("utf-8"))
    on_debug(debug, "secret from Kubernetes is {}".format(secret))
except Exception as err:
    print("Error collecting secret from Kubernetes: {}".format(err))
    sys.exit(1)

#
# Get an auth token by using the secret
#
token = None
try:
    token_url = "https://api-gw-service-nmn.local/keycloak/realms/shasta/protocol/openid-connect/token"
    token_data = {
        "grant_type": "client_credentials",
        "client_id": "admin-client",
        "client_secret": secret,
    }
    token_request = remote_request("POST", token_url, data=token_data, debug=debug)
    token = token_request["access_token"]
    on_debug(
        debug=debug,
        message="Auth Token from keycloak (first 50 char): {}".format(token[:50]),
    )
except Exception as err:
    print("Error obtaining keycloak token: {}".format(err))
    sys.exit(1)


#
# Get existing SLS data for comparison (used as a cache)
#
sls_cache = None
sls_url = "https://api_gw_service.local/apis/sls/v1/networks"
auth_headers = {"Authorization": "Bearer {}".format(token)}
try:
    sls_cache = remote_request("GET", sls_url, headers=auth_headers, verify=False)
    on_debug(debug=debug, message="SLS data has {} records".format(len(sls_cache)))
except Exception as err:
    print("Error requesting EthernetInterfaces from SLS: {}".format(err))
    sys.exit(1)
on_debug(debug=debug, message="SLS records {}".format(sls_cache))

# get CAN prefix
for i in range(len(sls_cache)):
    if "ExtraProperties" in sls_cache[i]:
        for z in range(len(sls_cache[i]["ExtraProperties"]["Subnets"])):
            if (
                "CAN Bootstrap DHCP Subnet"
                in sls_cache[i]["ExtraProperties"]["Subnets"][z]["FullName"]
            ):
                CAN_prefix = sls_cache[i]["ExtraProperties"]["Subnets"][z]["CIDR"]
                pprint.pprint("CAN Prefix " + CAN_prefix)

# get HMN prefix
for i in range(len(sls_cache)):
    if "ExtraProperties" in sls_cache[i]:
        for z in range(len(sls_cache[i]["ExtraProperties"]["Subnets"])):
            if (
                "HMN MetalLB"
                in sls_cache[i]["ExtraProperties"]["Subnets"][z]["FullName"]
            ):
                HMN_prefix = sls_cache[i]["ExtraProperties"]["Subnets"][z]["CIDR"]
                pprint.pprint("HMN Prefix " + HMN_prefix)

# get NMN prefix
for i in range(len(sls_cache)):
    if "ExtraProperties" in sls_cache[i]:
        for z in range(len(sls_cache[i]["ExtraProperties"]["Subnets"])):
            if (
                "NMN MetalLB"
                in sls_cache[i]["ExtraProperties"]["Subnets"][z]["FullName"]
            ):
                NMN_prefix = sls_cache[i]["ExtraProperties"]["Subnets"][z]["CIDR"]
                pprint.pprint("NMN Prefix " + NMN_prefix)

# get TFTP prefix
for i in range(len(sls_cache)):
    if "ExtraProperties" in sls_cache[i]:
        for z in range(len(sls_cache[i]["ExtraProperties"]["Subnets"])):
            if (
                "NMN MetalLB"
                in sls_cache[i]["ExtraProperties"]["Subnets"][z]["FullName"]
            ):
                for x in range(
                    len(sls_cache[i]["ExtraProperties"]["Subnets"][z]["IPReservations"])
                ):
                    if (
                        "cray-tftp"
                        in sls_cache[i]["ExtraProperties"]["Subnets"][z][
                            "IPReservations"
                        ][x]["Name"]
                    ):
                        TFTP_prefix = (
                            sls_cache[i]["ExtraProperties"]["Subnets"][z][
                                "IPReservations"
                            ][x]["IPAddress"]
                            + "/32"
                        )
                        pprint.pprint("TFTP Prefix " + TFTP_prefix)

asn = 65533

ncn_nmn_ips = []
ncn_names = []
ncn_can_ips = []
ncn_hmn_ips = []

all_prefix = [CAN_prefix, HMN_prefix, NMN_prefix, TFTP_prefix]

# NCN Names
for i in range(len(sls_cache)):
    if "ExtraProperties" in sls_cache[i]:
        for z in range(len(sls_cache[i]["ExtraProperties"]["Subnets"])):
            if (
                "NMN Bootstrap DHCP Subnet"
                in sls_cache[i]["ExtraProperties"]["Subnets"][z]["FullName"]
            ):
                for x in range(
                    len(sls_cache[i]["ExtraProperties"]["Subnets"][z]["IPReservations"])
                ):
                    NCN = sls_cache[i]["ExtraProperties"]["Subnets"][z][
                        "IPReservations"
                    ][x]["Name"]
                    if "ncn-w" in NCN:
                        name = sls_cache[i]["ExtraProperties"]["Subnets"][z][
                            "IPReservations"
                        ][x]["Name"]
                        ncn_names.append(name)
print(ncn_names)

# NCN NMN IPs
for i in range(len(sls_cache)):
    if "ExtraProperties" in sls_cache[i]:
        for z in range(len(sls_cache[i]["ExtraProperties"]["Subnets"])):
            if (
                "NMN Bootstrap DHCP Subnet"
                in sls_cache[i]["ExtraProperties"]["Subnets"][z]["FullName"]
            ):
                for x in range(
                    len(sls_cache[i]["ExtraProperties"]["Subnets"][z]["IPReservations"])
                ):
                    NCN = sls_cache[i]["ExtraProperties"]["Subnets"][z][
                        "IPReservations"
                    ][x]["Name"]
                    if "ncn-w" in NCN:
                        ips = sls_cache[i]["ExtraProperties"]["Subnets"][z][
                            "IPReservations"
                        ][x]["IPAddress"]
                        ncn_nmn_ips.append(ips)
print(ncn_nmn_ips)

# NMN NCN IPs
for i in range(len(sls_cache)):
    if "ExtraProperties" in sls_cache[i]:
        for z in range(len(sls_cache[i]["ExtraProperties"]["Subnets"])):
            if (
                "HMN Bootstrap DHCP Subnet"
                in sls_cache[i]["ExtraProperties"]["Subnets"][z]["FullName"]
            ):
                for x in range(
                    len(sls_cache[i]["ExtraProperties"]["Subnets"][z]["IPReservations"])
                ):
                    NCN = sls_cache[i]["ExtraProperties"]["Subnets"][z][
                        "IPReservations"
                    ][x]["Name"]
                    if "ncn-w" in NCN:
                        ips = sls_cache[i]["ExtraProperties"]["Subnets"][z][
                            "IPReservations"
                        ][x]["IPAddress"]
                        ncn_hmn_ips.append(ips)
print(ncn_hmn_ips)

# CAN NCN IPs
for i in range(len(sls_cache)):
    if "ExtraProperties" in sls_cache[i]:
        for z in range(len(sls_cache[i]["ExtraProperties"]["Subnets"])):
            if (
                "CAN Bootstrap DHCP Subnet"
                in sls_cache[i]["ExtraProperties"]["Subnets"][z]["FullName"]
            ):
                for x in range(
                    len(sls_cache[i]["ExtraProperties"]["Subnets"][z]["IPReservations"])
                ):
                    NCN = sls_cache[i]["ExtraProperties"]["Subnets"][z][
                        "IPReservations"
                    ][x]["Name"]
                    if "ncn-w" in NCN:
                        ips = sls_cache[i]["ExtraProperties"]["Subnets"][z][
                            "IPReservations"
                        ][x]["IPAddress"]
                        ncn_can_ips.append(ips)
print(ncn_can_ips)

# json payload
bgp_data = {"asn": asn, "router_id": "", "maximum_paths": 8, "ibgp_distance": 70}

bgp_neighbor10_05 = {
    "ip_or_group_name": "",
    "remote_as": asn,
    "passive": True,
    "route_maps": {"ipv4-unicast": {"in": ""}},
    "shutdown": False,
    "activate": {"ipv4-unicast": True},
}

bgp_neighbor10_06 = {
    "ip_or_ifname_or_group_name": "",
    "remote_as": asn,
    "passive": True,
    "route_maps": {"ipv4-unicast": {"in": ""}},
    "shutdown": False,
    "activate": {"ipv4-unicast": True},
}

prefix = ["pl-can", "pl-hmn", "pl-nmn", "tftp"]

prefix_list_entry = {
    "action": "permit",
    "ge": 24,
    "le": 0,
    "preference": 10,
    "prefix": "",
}

prefix_list_tftp = {
    "action": "permit",
    "ge": 32,
    "le": 32,
    "preference": 10,
    "prefix": "",
}

prefix_list = {"address_family": "ipv4", "name": ""}

route_map = {"name": ""}

route_map_entry_nmn = {
    "action": "permit",
    "match_ipv4_prefix_list": {"pl-can": "/rest/v10.04/system/prefix_lists/pl-nmn"},
    "preference": 20,
    "set": {"ipv4_next_hop_address": ""},
}

route_map_entry_hmn = {
    "action": "permit",
    "match_ipv4_prefix_list": {"pl-hmn": "/rest/v10.04/system/prefix_lists/pl-hmn"},
    "preference": 30,
    "set": {"ipv4_next_hop_address": ""},
}

route_map_entry_can = {
    "action": "permit",
    "match_ipv4_prefix_list": {"pl-can": "/rest/v10.04/system/prefix_lists/pl-can"},
    "preference": 40,
    "set": {"ipv4_next_hop_address": ""},
}

route_map_entry_tftp = {
    "action": "permit",
    "match_ipv4_prefix_list": {"tftp": "/rest/v10.04/system/prefix_lists/tftp"},
    "preference": 10,
    "set": {"local_preference": ""},
    "match": {"ipv4_next_hop_address": ""},
}

username = "admin"
# password =
creds = {"username": username, "password": password}
version = "v10.04"

session = requests.Session()

for ips in switch_ips:
    base_url = "https://{0}/rest/{1}/".format(ips, version)
    try:
        response = session.post(base_url + "login", data=creds, verify=False, timeout=5)
    except requests.exceptions.ConnectTimeout:
        logging.warning(
            "ERROR: Error connecting to host: connection attempt timed out.  Verify the switch IPs"
        )
        exit(-1)
    # Response OK check needs to be passed "PUT" since this POST call returns 200 instead of conventional 201
    if not _response_ok(response, "PUT"):
        logging.warning(
            f"FAIL: Login failed with status code {response.status_code}: {response.text}"
        )
        exit(-1)
    else:
        logging.info("SUCCESS: Login succeeded")

    # remove bgp config
    bgp_url = base_url + "system/vrfs/default/bgp_routers/65533"
    response = remote_delete(bgp_url)

    # get prefix lists
    prefix_url = base_url + "system/prefix_lists"
    response = remote_get(prefix_url)
    pre_list = response.json()

    # remove prefix lists
    for pf in pre_list:
        print("removing prefix_list: {0} from {1}".format(pf, ips))
        response = remote_delete(prefix_url + "/" + pf)

    # remove route map config
    route_map_url = base_url + "system/route_maps"
    response = remote_get(route_map_url)
    route_map1 = response.json()

    for rm in route_map1:
        print("removing route-map: {0} from {1}".format(rm, ips))
        response = remote_delete(route_map_url + "/" + rm)

    # add prefix lists
    for p in prefix:
        prefix_list["name"] = p
        print("adding prefix lists to {0}".format(ips))
        response = remote_post(prefix_url, prefix_list)
        prefix_list_entry_url = (
            base_url + "system/prefix_lists/{0}/prefix_list_entries".format(p)
        )

        if "pl-can" in p:
            prefix_list_entry["prefix"] = CAN_prefix
            prefix_list_entry["preference"] = 10
            response = remote_post(prefix_list_entry_url, prefix_list_entry)

        if "pl-hmn" in p:
            prefix_list_entry["prefix"] = HMN_prefix
            prefix_list_entry["preference"] = 20
            response = remote_post(prefix_list_entry_url, prefix_list_entry)

        if "pl-nmn" in p:
            prefix_list_entry["prefix"] = NMN_prefix
            prefix_list_entry["preference"] = 30
            response = remote_post(prefix_list_entry_url, prefix_list_entry)

        if "tftp" in p:
            prefix_list_tftp["prefix"] = TFTP_prefix
            prefix_list_tftp["preference"] = 10
            response = remote_post(prefix_list_entry_url, prefix_list_tftp)

    # create route maps
    for name in ncn_names:
        route_map_entry_url = (
            base_url + "system/route_maps/{0}/route_map_entries".format(name)
        )
        route_map["name"] = name
        response = remote_post(route_map_url, route_map)
        print("adding route-maps to {0}".format(ips))

    for name in ncn_names:
        route_map_entry_tftp["preference"] = 10
        route_map_entry_tftp["set"]["local_preference"] = 1000
        for ip in ncn_nmn_ips:
            route_map_can_url = (
                base_url + "system/route_maps/{0}/route_map_entries".format(name)
            )
            route_map_entry_tftp["match"]["ipv4_next_hop_address"] = ip
            response = remote_post(route_map_can_url, route_map_entry_tftp)
            route_map_entry_tftp["preference"] += 10
            route_map_entry_tftp["set"]["local_preference"] += 100

    route_map_url_w001 = base_url + "system/route_maps/ncn-w001/route_map_entries"
    response = remote_get(route_map_url_w001)
    route_map1 = response.json()
    pref = int(sorted(route_map1.keys())[-1])

    for ncn, name in zip(ncn_can_ips, ncn_names):
        route_map_entry_can["set"]["ipv4_next_hop_address"] = ncn
        route_map_entry_can["preference"] = pref + 10
        route_map_can_url = base_url + "system/route_maps/{0}/route_map_entries".format(
            name
        )
        response = remote_post(route_map_can_url, route_map_entry_can)

    response = remote_get(route_map_url_w001)
    route_map1 = response.json()
    pref = int(sorted(route_map1.keys())[-1])

    for ncn, name in zip(ncn_hmn_ips, ncn_names):
        route_map_entry_hmn["set"]["ipv4_next_hop_address"] = ncn
        route_map_entry_hmn["preference"] = pref + 10
        route_map_hmn_url = base_url + "system/route_maps/{0}/route_map_entries".format(
            name
        )
        response = remote_post(route_map_hmn_url, route_map_entry_hmn)

    response = remote_get(route_map_url_w001)
    route_map1 = response.json()
    pref = int(sorted(route_map1.keys())[-1])

    for ncn, name in zip(ncn_nmn_ips, ncn_names):
        route_map_entry_nmn["set"]["ipv4_next_hop_address"] = ncn
        route_map_entry_nmn["preference"] = pref + 10
        route_map_nmn_url = base_url + "system/route_maps/{0}/route_map_entries".format(
            name
        )
        response = remote_post(route_map_nmn_url, route_map_entry_nmn)

    # add bgp asn and router id
    bgp_data["router_id"] = ips
    bgp_router_id_url = base_url + "system/vrfs/default/bgp_routers"
    response = remote_post(bgp_router_id_url, bgp_data)
    print("adding BGP configuration to {0}".format(ips))

    # get switch firmware
    firmware_url = base_url + "firmware"
    response = remote_get(firmware_url)
    firmware = response.json()

    # update BGP neighbors on firmware of 10.06
    if "10.06" in firmware["current_version"]:
        for ncn, names in zip(ncn_nmn_ips, ncn_names):
            bgp_neighbor10_06["ip_or_ifname_or_group_name"] = ncn
            bgp_neighbor_url = (
                base_url + "system/vrfs/default/bgp_routers/65533/bgp_neighbors"
            )
            bgp_neighbor10_06["route_maps"]["ipv4-unicast"]["in"] = (
                "/rest/v10.04/system/route_maps/" + names
            )
            response = remote_post(bgp_neighbor_url, bgp_neighbor10_06)
        for x in switch_ips:
            if x != ips:
                vsx_neighbor = dict(bgp_neighbor10_06)
                vsx_neighbor["ip_or_ifname_or_group_name"] = x
                del vsx_neighbor["route_maps"]
                del vsx_neighbor["passive"]
                response = remote_post(bgp_neighbor_url, vsx_neighbor)

    # update BGP neighbors on firmware of 10.06
    if "10.05" in firmware["current_version"]:
        for ncn, names in zip(ncn_nmn_ips, ncn_names):
            bgp_neighbor10_05["ip_or_group_name"] = ncn
            bgp_neighbor_url = (
                base_url + "system/vrfs/default/bgp_routers/65533/bgp_neighbors"
            )
            bgp_neighbor10_05["route_maps"]["ipv4-unicast"]["in"] = (
                "/rest/v10.04/system/route_maps/" + names
            )
            response = remote_post(bgp_neighbor_url, bgp_neighbor10_05)
        for x in switch_ips:
            if x != ips:
                vsx_neighbor = dict(bgp_neighbor10_05)
                vsx_neighbor["ip_or_group_name"] = x
                del vsx_neighbor["route_maps"]
                del vsx_neighbor["passive"]
                response = remote_post(bgp_neighbor_url, vsx_neighbor)

    write_mem_url = (
        base_url
        + "fullconfigs/startup-config?from=%2Frest%2Fv10.04%2Ffullconfigs%2Frunning-config"
    )
    response = remote_put(write_mem_url)
    if response.status_code == 200:
        print("Configuration saved on {}".format(ips))

    logout = session.post(f"https://{ips}/rest/v10.04/logout")  # logout of switch

print()
print()
print(
    "BGP configuration updated on {}, please log into the switches and verify the configuration.".format(
        ", ".join(switch_ips)
    )
)
print()
print(
    "The BGP process may need to be restarted on the switches for all of them to become ESTABLISHED."
)
