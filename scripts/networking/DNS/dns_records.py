#!/usr/bin/env python3
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

import sys
import getopt
import json
import base64
import urllib3
import requests
# Note, version on v1.3 systems throws a warning in stderr
from kubernetes import client, config
from netaddr import IPNetwork, IPAddress

# Get rid of cert warning messages
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)


#
# Parse input args
#
argv = sys.argv[1:]
action = ''
debug = False
filename = ''

help_message = """Add or delete or print DNS records / IP Reservations from SLS.

USAGE:  -i  - record in /etc/hosts format (see below)
       [-p] - pretty prints out existing reservations for viewing 
       [-x] - deletes records in the csv file if they exist
       [-f] - force record replacement.  If a record currently exists
              in SLS it will be replaced with the file record. Default
              behavior is to leave the original record.
       [-v] - verbose debug

NOTE:  Record format - requires quotes:  "IPAddress Name/A Alias/CNAME[]"
       Example:        "10.92.100.71 api_gateway api-gw api_gw api-gw.local"

NOTE:  This program is idempotent - can safely try to add/del multiple times.
       This program will cowardly refuse to update an existing record without -f.
""".format(sys.argv[0])

try:
    opts, args = getopt.getopt(argv, "i:hpxfv")
    if not opts:
        print(help_message)
        sys.exit(2)
except getopt.GetoptError:
    print(help_message)
    sys.exit(2)

input_reservation = None
prettyprint = False
debug = False
force = False
action = 'add'
for opt, arg in opts:
    if opt == '-h':
        print(help_message)
        sys.exit()
    elif opt in ("-i"):
        input_reservation = arg
    elif opt in ("-p"):
        prettyprint = True
    elif opt in ("-v"):
        debug = True
    elif opt in ("-f"):
        force = True
    elif opt in ("-x"):
        action = 'delete'


#
# Debug convenience function
#
def on_debug(debug=False, message=None):
    if debug:
        print('DEBUG: {}'.format(message))


#
# Convenience wrapper around remote calls
#
def remote_request(remote_type, remote_url, headers=None, data=None, verify=True, debug=False):
    remote_response = None
    while True:
        try:
            response = requests.request(remote_type,
                                        url=remote_url,
                                        headers=headers,
                                        data=data,
                                        verify=verify)
            on_debug(debug, 'Request response: {}'.format(response.text))
            response.raise_for_status()
            remote_response = json.dumps({})
            if response.text:
                remote_response = response.json()
            break
        except Exception as err:
            message = 'Error calling {}: {}'.format(remote_url, err)
            raise SystemExit(message)
    return remote_response


#
# Get the admin client secret from Kubernetes
#
secret = None
try:
    config.load_kube_config()
    v1 = client.CoreV1Api()
    secret_obj = v1.list_namespaced_secret(
        'default', field_selector='metadata.name=admin-client-auth')
    secret_dict = secret_obj.to_dict()
    secret_base64_str = secret_dict['items'][0]['data']['client-secret']
    on_debug(debug, 'base64 secret from Kubernetes is {}'.format(secret_base64_str))
    secret = base64.b64decode(secret_base64_str.encode('utf-8'))
    on_debug(debug, 'secret from Kubernetes is {}'.format(secret))
except Exception as err:
    print('Error collecting secret from Kubernetes: {}'.format(err))
    sys.exit(1)


#
# Get an auth token by using the secret
#
token = None
try:
    token_url = 'https://api-gw-service-nmn.local/keycloak/realms/shasta/protocol/openid-connect/token'
    token_data = {'grant_type': 'client_credentials',
                  'client_id': 'admin-client', 'client_secret': secret}
    token_request = remote_request(
        'POST', token_url, data=token_data, debug=debug)
    token = token_request['access_token']
    on_debug(debug=debug, message='Auth Token from keycloak (first 50 char): {}'.format(
        token[:50]))
except Exception as err:
    print('Error obtaining keycloak token: {}'.format(err))
    sys.exit(1)


#
# Get existing SLS data for comparison (used as a cache)
#
sls_cache = None
sls_url = 'https://api_gw_service.local/apis/sls/v1/networks'
auth_headers = {'Authorization': 'Bearer {}'.format(token)}
try:
    sls_cache = remote_request(
        'GET', sls_url, headers=auth_headers, verify=False)
    on_debug(debug=debug, message='SLS data has {} records'.format(len(sls_cache)))
except Exception as err:
    print('Error requesting EthernetInterfaces from SLS: {}'.format(err))
    sys.exit(1)
on_debug(debug=debug, message='SLS records {}'.format(sls_cache))


#
# Prints a flattened reservation record - looks like /etc/hosts entry
#
def reservation_string(reservation):
    name = reservation['Name']
    ipv4 = reservation['IPAddress']
    aliases = ''
    if 'Aliases' in reservation:
        for alias in reservation['Aliases']:
            aliases += alias + ' '
    return '{} {} {}'.format(ipv4, name, aliases).strip()


#
# Given a reservation with or without aliases, this function finds _any_ match in the
# existing /networks structure/cache for SLS.   This find may seem to find far too many
# records, but the idea here is to report absolutely any existing matches and then let
# the user decide to override on a case-by-case basis.  NOTE:  This simply finds records
# that already exist and match, but if there are multiple it does NOT sort and find
# priority.
#
# Record example:
#     {'IPAddress': '10.92.100.72', 
#      'Name': 'rsyslog_agg_service', 
#      'Aliases': [ 'rsyslog_agg_service-nmn.local', 
#                   'rsyslog_agg_service.local' ]
#    }
#
def find_reservation(new_reservation, cache, debug=False):
    matches = []
    for network in cache:
        if 'ExtraProperties' not in network or \
           'Subnets' not in network['ExtraProperties'] or \
           not network['ExtraProperties']['Subnets']:
               continue
        network_name = network['Name']
        subnets = network['ExtraProperties']['Subnets']
        for subnet in subnets:
            subnet_name = subnet['Name']
            subnet_cidr = subnet['CIDR']
            if IPAddress(new_reservation['IPAddress']) not in IPNetwork(subnet_cidr):
                continue
            if 'IPReservations' not in subnet:
                continue
            on_debug(debug, 'Finding record: {} {} {}'.format(network_name, subnet_name, new_reservation))
            reservations = subnet['IPReservations']
            for reservation in reservations:
                found = False
                if new_reservation['IPAddress'] == reservation['IPAddress']:
                    found = True
                    on_debug(debug, '  Record match by IPAddress: {}'.format(reservation))
                if new_reservation['Name'] == reservation['Name']:
                    found = True
                    on_debug(debug, '  Record match by Name: {}'.format(reservation))
                if 'Aliases' in new_reservation and 'Aliases' in reservation:
                    new_aliases = new_reservation['Aliases']
                    aliases = reservation['Aliases']
                    for alias in aliases:
                        for new_alias in new_aliases:
                            if new_alias == alias:
                                found = True
                                on_debug(debug, '  Record match by Alias: {}'.format(reservation))
                    # It's possible that the proposed A record is already a CNAME/Alias elsewhere.
                    if new_reservation['Name'] in aliases:
                        found = True
                        on_debug(debug, '  Record Name match in Alias: {}'.format(reservation))
                if found:
                    matches.append(reservation)
    return matches



#
# Update and return the network structure from cache.
#
# SLS requires that the entire network structure be modified (for just one reservation).
#
# New/Add: Finds appropriate network and subnet and adds the reservation.
# Update:  MATCHES SOLELY BY IPAddress, NOT by Name or Aliases.  This is why the -f option exists.
# Delete:  MATCHES SOLELY BY IPAddress, NOT by Name or Aliases.
#
def update_network_reservation(new_reservation, cache, delete=False, debug=False):
    for network in cache:
        if 'ExtraProperties' not in network or \
           'Subnets' not in network['ExtraProperties'] or \
           not network['ExtraProperties']['Subnets']:
               continue
        network_name = network['Name']
        subnets = network['ExtraProperties']['Subnets']
        for subnet in subnets:
            subnet_name = subnet['Name']
            subnet_cidr = subnet['CIDR']
            if IPAddress(new_reservation['IPAddress']) not in IPNetwork(subnet_cidr):
                continue
            if 'IPReservations' not in subnet:
                # Stub out a new reservations structure
                subnet['IPReservations'] = []
            on_debug(debug, 'Finding record: {} {} {}'.format(network_name, subnet_name, new_reservation))
            reservations = subnet['IPReservations']
            found_idx = -1
            for i, reservation in enumerate(reservations):
                if new_reservation['IPAddress'] == reservation['IPAddress']:
                    found_idx = i
                    on_debug(debug, '  Record match by IPAddress: {}'.format(reservation))
                    break
            if found_idx >= 0:
                if not delete:
                    reservations[i] = new_reservation
                    on_debug(debug, '  Updated record in structure.')
                    return network
                else:
                    reservations.pop(i)
                    on_debug(debug, '  Deleted record in structure.')
                    return network
            else:
                if not delete:
                    reservations.append(new_reservation)
                    on_debug(debug, '  Added record in structure.')
                    return network
    # TODO: better
    return {}



#
# Print out all reservations per network and per subnet.
#
def pretty_print_reservations(cache):
    for network in sls_cache:
        if 'ExtraProperties' not in network or \
           'Subnets' not in network['ExtraProperties'] or \
           not network['ExtraProperties']['Subnets']:
               continue
        print()
        print(network['Name'])
        subnets = network['ExtraProperties']['Subnets']
        for subnet in subnets:
            print('  {} {}'.format(subnet['Name'],subnet['CIDR']))
            if 'IPReservations' not in subnet:
                continue
            reservations = subnet['IPReservations']
            for reservation in reservations:
                ipv4 = reservation['IPAddress']
                name = reservation['Name']
                aliases_string = ''
                if 'Aliases' in reservation:
                    aliases = reservation['Aliases']
                    for alias in aliases:
                        aliases_string += ' ' + alias
                print('      {} {}'.format(ipv4, name+aliases_string))
    print()



#
# Pretty Print existing SLS Reservations
#
if prettyprint:
    pretty_print_reservations(sls_cache)
    sys.exit()



#
# Update the existing reservations:  add/modify/del
#
if input_reservation:
    print('New record: {}'.format(input_reservation))

    # Decompose input into a JSON record
    val = input_reservation.split()
    record = {}
    record['IPAddress'] = val.pop(0)
    record['Name'] = val.pop(0)
    if val:
        record['Aliases'] = val
    updated_network = {}

    # Find matching existing records
    matches = find_reservation(record, sls_cache, debug)

    if matches:
        print('Existing record match.')
        for match in matches:
            print('  Existing: {}'.format(reservation_string(match)))
            print('  New     : {}'.format(reservation_string(record)))
            if not force:
                print('Cowardly refusing to update without -f')
            else:
                if action == 'delete':
                    updated_network = update_network_reservation(record, sls_cache, delete=True, debug=debug)
                    print('Deleted reservation record in network structure (-x -f): {}'.format(updated_network['Name']))
                    add_record = remote_request('PUT',
                                                sls_url+'/{}'.format(updated_network['Name']),
                                                headers=auth_headers,
                                                data=json.dumps(updated_network),
                                                verify=False,
                                                debug=debug)
                    print('Deleted existing reservation record in SLS')
                else:
                    updated_network = update_network_reservation(record, sls_cache, debug=debug)
                    print('Updated reservation record in network structure (-f): {}'.format(updated_network['Name']))
                    add_record = remote_request('PUT',
                                                sls_url+'/{}'.format(updated_network['Name']),
                                                headers=auth_headers,
                                                data=json.dumps(updated_network),
                                                verify=False,
                                                debug=debug)
                    print('Replaced existing reservation record in SLS')
    else:
        print('No existing record match.')
        updated_network = update_network_reservation(record, sls_cache, debug=debug)
        if not updated_network:
            print('Error: Network or Subnet not found to add reservation.  Use -p to check available data')
            sys.exit(1)
        else:
             # NOTE:  If no new record, even a -x puts you here...
            add_record = remote_request('PUT',
                                        sls_url+'/{}'.format(updated_network['Name']),
                                        headers=auth_headers,
                                        data=json.dumps(updated_network),
                                        verify=False,
                                        debug=debug)
            print('Created new reservation record in SLS')