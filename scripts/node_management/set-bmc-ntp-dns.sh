#!/bin/bash
# Copyright (C) 2021 Hewlett Packard Enterprise Development LP
# Sets static NTP, timezone, and DNS entries on an iLO BMC
# Author: Jacob Salmela <jacob.salmela@hpe.com>
set -eo pipefail

BMC="$HOSTNAME-mgmt"
VENDOR="$(ipmitool fru | awk '/Board Mfg/ && !/Date/ {print $4}')"
if [[ "$VENDOR" = *Marvell* ]] || [[ "$VENDOR" = HP* ]] || [[ "$VENDOR" = Hewlett* ]]; then
  manager=1
  interface=1
  # Time to wait before checking if the BMC is back after a reset
  secs=30
elif [[ "$VENDOR" = *GIGA*BYTE* ]]; then
  manager=Self
  interface=bond0
  # GBs are slow and need more time to reset
  #FIXME: Do a real check here instead of a static sleep
  secs=360
elif [[ "$VENDOR" = *Intel* ]]; then
  echo "Not yet developed."
  exit 1
fi

if [[ -z ${USERNAME} ]] || [[ -z ${IPMI_PASSWORD} ]]; then
  echo "\$USERNAME \$IPMI_PASSWORD must be set"
  exit 1
fi

usage() {
  # Generates a usage line
  # Any line startng with with a #/ will show up in the usage line
  grep '^#/' "$0" | cut -c4-
}

#/ Usage: set-bmc-ntp-dns.sh [-h] ilo|gb|intel [-N NTP_SERVERS]|[-D DNS_SERVERS] [-options]
#/
#/    Sets static NTP and DNS servers on BMCs using data defined in cloud-init (or by providing manual overrides)
#/
#/    $USERNAME and $IPMI_PASSWORD must be set prior to running this script.
#/
#/
#/    options common to 'ilo', 'gb', and 'intel' commands:
#/
#/       [-A]               configure a BMC, running all the necessary tasks (fresh installs only)
#/       [-s]               shows the current configuration of NTP and DNS
#/       [-t]               show the current date/time for the BMC
#/       [-N NTP_SERVERS]   a comma seperated list of NTP servers (manual override when no 1.5 metadata exists)
#/       [-D DNS_SERVERS]   a comma seperated list of DNS servers (manual override when no 1.5 metadata exists)
#/       [-d]               sets static DNS servers using cloud-init data or overrides
#/       [-n]               sets static NTP servers using cloud-init data or overrides (see -S for iLO)
#/       [-r]               gracefully resets the BMC
#/       [-f]               forcefully resets the BMC
#/
#/    options specific to the the 'ilo' command:
#/       [-S]               disables DHCP so static entries can be set
#/       [-z]               show current timezone
#/       [-Z INDEX]         set a new timezone
#/
#/    options specific to the 'gb' command:
#/       [-]                yet to be developed
#/
#/    options specific to the 'intel' command:
#/       [-]                yet to be developed
#/
#/    EXAMPLES:
#/
#/       Upgrading 1.4 to 1.5 passing in NTP and DNS entries that don't exist in 1.4 metadata:
#/           set-bmc-ntp-dns.sh ilo -s
#/           set-bmc-ntp-dns.sh ilo -S #(iLO only)
#/           set-bmc-ntp-dns.sh ilo -N time-hmn,time.nist.gov -n
#/           set-bmc-ntp-dns.sh ilo -D 10.92.100.225,172.30.48.1 -d
#/           set-bmc-ntp-dns.sh -r
#/
#/       Fresh install of 1.5 with new metadata already in place:
#/           set-bmc-ntp-dns.sh ilo -A
#/                     or
#/           set-bmc-ntp-dns.sh ilo -s
#/           set-bmc-ntp-dns.sh ilo -S #(iLO only)
#/           set-bmc-ntp-dns.sh ilo -n
#/           set-bmc-ntp-dns.sh ilo -d
#/           set-bmc-ntp-dns.sh -r
#/
#/       Disabling DHCP (iLO only):
#/           set-bmc-ntp-dns.sh ilo -S
#/
#/       Setting just NTP servers (DHCP must have been previously disabled):
#/           set-bmc-ntp-dns.sh gb -n
#/
#/       Setting just DNS servers (DHCP must have been previously disabled):
#/           set-bmc-ntp-dns.sh gb -d
#/
#/       Gracefully resetting the BMC:
#/           set-bmc-ntp-dns.sh ilo -r
#/
#/       Checking the datetime on all NCN BMCs:
#/          for i in ncn-m00{2..3} ncn-{w,s}00{1..3}; do echo "------$i--------"; ssh $i 'export USERNAME=root; export IPMI_PASSWORD=password; /set-bmc-ntp-dns.sh gb -t'; done
#/
#/       Check the current timezone on a NCN BMC (iLO only):
#/          set-bmc-ntp-dns.sh ilo -z
#/
#/       Set the timezone on a NCN BMC (iLO only):
#/          curl https://$HOSTNAME-mgmt/redfish/v1/managers/1/DateTime --insecure -u $USERNAME:$IPMI_PASSWORD -L | jq .TimeZoneList
#/          # Pick a desired timezone index number
#/          set-bmc-ntp-dns.sh ilo -Z 7
#/

# make_api_call() uses curl to contact an API endpoint
function make_api_call() {
  local endpoint="$1"
  local method="$2"
  local payload="$3"
  local filter="$4"
  if [[ "$method" == GET ]]; then
    # A simple GET request is mostly the same
    curl "https://${BMC}/${endpoint}" --insecure -L -s -u ${USERNAME}:${IPMI_PASSWORD} | jq ${filter}

  elif [[ "$method" == PATCH ]]; then

    if [[ "$VENDOR" = *GIGA*BYTE* ]]; then

      # GIGABYTE seems to need If-Match headers.  For now, just accept * all since we don't know yet what they are looking for
      curl -X PATCH "https://${BMC}/${endpoint}" --insecure -L -u ${USERNAME}:${IPMI_PASSWORD} \
        -H "Content-Type: application/json" -H "Accept: application/json" \
        -H "If-Match: *" \
        -d "${payload}"
      echo -e "\n"

    else

      curl -X PATCH "https://${BMC}/${endpoint}" --insecure -L -u ${USERNAME}:${IPMI_PASSWORD} \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "${payload}"
      echo -e "\n"

    fi

  elif [[ "$method" == POST ]]; then

    if [[ "$VENDOR" = *GIGA*BYTE* ]]; then

      curl -X POST "https://${BMC}/${endpoint}" --insecure -L -u ${USERNAME}:${IPMI_PASSWORD} \
        -H "Content-Type: application/json" -H "Accept: application/json" \
        -H "If-Match: *" \
        -d "${payload}"
      echo -e "\n"

    else

      curl -X POST "https://${BMC}/${endpoint}" --insecure -L -u ${USERNAME}:${IPMI_PASSWORD} \
        -H "Content-Type: application/json" -H "Accept: application/json" \
        -d "${payload}"
      echo -e "\n"

    fi
  fi
}

# show_current_bmc_datetime() shows the current datetime on the BMC
function show_current_bmc_datetime() {
  if [[ "$VENDOR" = *Marvell* ]] || [[ "$VENDOR" = HP* ]] || [[ "$VENDOR" = Hewlett* ]]; then
    make_api_call "redfish/v1/managers/${manager}/DateTime" \
      "GET" null \
      ".DateTime"

  elif [[ "$VENDOR" = *GIGA*BYTE* ]]; then
    make_api_call "redfish/v1/Managers/${manager}" \
      "GET" null \
      ".DateTime"

  elif [[ "$VENDOR" = *Intel* ]]; then

    echo "$VENDOR not yet developed."
    exit 1

  fi
}

# show_current_bmc_datetime() shows the current datetime on the BMC
function show_current_bmc_timezone() {
  make_api_call "redfish/v1/managers/${manager}/DateTime" \
    "GET" null \
    ".TimeZone.Name"
}

# set_bmc_timezone() manually sets the timezone on the BMC using an index number from .TimeZoneList
function set_bmc_timezone() {
  if [[ -z $TIMEZONE ]]; then

    echo "No timezone index provided."
    echo "View available indicies at redfish/v1/managers/1/DateTime | jq .TimeZoneList"
    exit 1

  else

    make_api_call "redfish/v1/managers/${manager}/DateTime" \
      "PATCH" \
      "{\"TimeZone\": {\"Index\": $TIMEZONE} }" null

    reset_bmc_manager

  fi
}

# show_current_bmc_settings() shows the current iLo settings for DNS and NTP
function show_current_bmc_settings() {
  if [[ "$VENDOR" = *Marvell* ]] || [[ "$VENDOR" = HP* ]] || [[ "$VENDOR" = Hewlett* ]]; then
    echo ".StaticNTPServers:"
    make_api_call "redfish/v1/managers/${manager}/DateTime" \
      "GET" null \
      ".StaticNTPServers"

    echo ".Oem.Hpe.IPv4.DNSServers:"
    make_api_call "redfish/v1/managers/${manager}/ethernetinterfaces/${interface}" \
      "GET" null \
      ".Oem.Hpe.IPv4.DNSServers"

    echo ".Oem.Hpe.DHCPv4s:"
    make_api_call "redfish/v1/managers/${manager}/ethernetinterfaces/${interface}" \
      "GET" null \
      ".Oem.Hpe.DHCPv4"

    echo ".Oem.Hpe.DHCPv6 status:"
    make_api_call "redfish/v1/managers/${manager}/ethernetinterfaces/${interface}" \
      "GET" null \
      ".Oem.Hpe.DHCPv6"

  elif [[ "$VENDOR" = *GIGA*BYTE* ]]; then

    echo ".NTP:"
    make_api_call "redfish/v1/Managers/${manager}/NetworkProtocol" \
      "GET" null \
      ".NTP"

    echo ".NameServers:"
    make_api_call "redfish/v1/Managers/${manager}/EthernetInterfaces/${interface}" \
      "GET" null \
      .NameServers

    echo ".DHCPv4.DHCPEnabled:"
    make_api_call "redfish/v1/Managers/${manager}/EthernetInterfaces/${interface}" \
      "GET" null \
      ".DHCPv4.DHCPEnabled"

  elif [[ "$VENDOR" = *Intel* ]]; then

    echo "$VENDOR not yet developed."
    exit 1

  fi
}

# reset_bmc_manager() gracefully restarts the BMC and waits a bit for it to come back
function reset_bmc_manager() {
  if [[ "$1" == all-force ]]; then

    if [[ "$VENDOR" = *Marvell* ]] || [[ "$VENDOR" = HP* ]] || [[ "$VENDOR" = Hewlett* ]] \
       || [[ "$VENDOR" = GIGA*BYTE ]]; then

      reset_type='{"ResetType": "ForceRestart"}'

    elif [[ "$VENDOR" = *Intel* ]]; then

      echo "$VENDOR not yet developed."
      exit 1

    fi

  else

    if [[ "$VENDOR" = *Marvell* ]] || [[ "$VENDOR" = HP* ]] || [[ "$VENDOR" = Hewlett* ]]; then

      reset_type='{"ResetType": "GracefulRestart"}'

    elif [[ "$VENDOR" = *GIGA*BYTE* ]]; then

      # GB only have a force restart option
      reset_type='{"ResetType": "ForceRestart"}'

    elif [[ "$VENDOR" = *Intel* ]]; then

      echo "$VENDOR not yet developed."
      exit 1

    fi

  fi

  if [[ "$VENDOR" = *Marvell* ]] || [[ "$VENDOR" = HP* ]] || [[ "$VENDOR" = Hewlett* ]]; then

    make_api_call "redfish/v1/managers/${manager}/Actions/Manager.Reset" \
        "POST" \
        "$reset_type" null

  elif [[ "$VENDOR" = *GIGA*BYTE* ]]; then

    make_api_call "redfish/v1/Managers/${manager}/Actions/Manager.Reset" \
      "POST" \
      "$reset_type" null

  elif [[ "$VENDOR" = *Intel* ]]; then

    echo "$VENDOR not yet developed."
    exit 1

  fi

  while [ $secs -gt 0 ]; do

    echo -ne "$secs waiting a bit for the BMC to reset...\033[0K\r"
    sleep 1
    : $((secs--))

  done

  echo -e "\n"
}

# disable_ilo_dhcp() disables dhcp on the iLO since ipmitool cannot fully disable it.  This requres a restart.
function disable_ilo_dhcp() {
  if [[ "$VENDOR" = *Marvell* ]] || [[ "$VENDOR" = HP* ]] || [[ "$VENDOR" = Hewlett* ]]; then
    # Check if it's already disabled
    dhcpv4_dns_enabled=$(curl "https://${BMC}/redfish/v1/managers/${manager}/ethernetinterfaces/${interface}" --insecure -u ${USERNAME}:${IPMI_PASSWORD} -L -s | jq .Oem.Hpe.DHCPv4.UseDNSServers)
    dhcpv4_ntp_enabled=$(curl "https://${BMC}/redfish/v1/managers/${manager}/ethernetinterfaces/${interface}" --insecure -u ${USERNAME}:${IPMI_PASSWORD} -L -s | jq .Oem.Hpe.DHCPv4.UseNTPServers)
    dhcpv6_dns_enabled=$(curl "https://${BMC}/redfish/v1/managers/${manager}/ethernetinterfaces/${interface}" --insecure -u ${USERNAME}:${IPMI_PASSWORD} -L -s | jq .Oem.Hpe.DHCPv6.UseDNSServers)
    dhcpv6_ntp_enabled=$(curl "https://${BMC}/redfish/v1/managers/${manager}/ethernetinterfaces/${interface}" --insecure -u ${USERNAME}:${IPMI_PASSWORD} -L -s | jq .Oem.Hpe.DHCPv6.UseNTPServers)

    # Disable DHCPv4
    echo -e "Disabling DHCPv4 on iLO..."
    if [[ "${dhcpv4_dns_enabled}" == true ]] || [[ "${dhcpv4_ntp_enabled}" == true ]] ; then

      make_api_call "redfish/v1/managers/${manager}/ethernetinterfaces/${interface}" \
        "PATCH" \
        "{\"DHCPv4\":{\"UseDNSServers\": false, \"UseNTPServers\": false}}" null

    elif [[ "${dhcpv4_dns_enabled}" == false ]] && [[ "${dhcpv4_ntp_enabled}" == false ]] ; then

      echo "Already disabled"

    fi

    # Disable DHCPv6
    echo -e "Disabling DHCPv6 on iLO..."
    if [[ "${dhcpv6_dns_enabled}" == true ]] || [[ "${dhcpv6_ntp_enabled}" == true ]] ; then

      make_api_call "redfish/v1/managers/${manager}/ethernetinterfaces/${interface}" \
        "PATCH" \
        "{\"DHCPv6\":{\"UseDNSServers\": false, \"UseNTPServers\": false}}" null

    elif [[ "${dhcpv6_dns_enabled}" == false ]] && [[ "${dhcpv6_ntp_enabled}" == false ]] ; then

      echo "Already disabled"

    fi

    # if any values were true, we need to reset to apply the changes
    if [[ "${dhcpv6_dns_enabled}" == true ]] || [[ "${dhcpv6_ntp_enabled}" == true ]] || [[ "${dhcpv4_dns_enabled}" == true ]] || [[ "${dhcpv4_ntp_enabled}" == true ]]; then

      echo -e "\nThe BMC will gracefully restart to apply these changes."
      reset_bmc_manager

    fi

  elif [[ "$VENDOR" = *GIGA*BYTE* ]]; then

    #TODO: ipmitool can handle this but it would be good to implement it here as welll
    echo "$VENDOR not yet developed."
    exit 1

  elif [[ "$VENDOR" = *Intel* ]]; then

    echo "$VENDOR not yet developed."
    exit 1

  fi
}

# get_ci_ntp_servers() gets ntp servers defined in cloud-init meta-data under the key 'ntp.servers'
function get_ci_ntp_servers() {
  # get ntp servers from cloud-init
  echo "{\"StaticNTPServers\": $(cat /var/lib/cloud/instance/user-data.txt \
    | yq read - -j \
    | jq .ntp.servers \
    | tr '\n' ' ')}"
}

# set_bmc_ntp() configures the BMC with static NTP servers
function set_bmc_ntp() {
  echo "Setting static NTP servers on ${BMC}..."
  if [[ -n $NTP_SERVERS ]]; then
    local ntp_servers="$NTP_SERVERS"
    ntp_array=(${ntp_servers/,/ })

    # Each vendor has a different name for the key
    if [[ "$VENDOR" = *Marvell* ]] || [[ "$VENDOR" = HP* ]] || [[ "$VENDOR" = Hewlett* ]]; then

      ntp_key=$(echo "{\"StaticNTPServers\": [")
      ntp_close="]}\""

    elif [[ "$VENDOR" = *GIGA*BYTE* ]]; then

      ntp_key=$(echo "{\"NTP\": {\"NTPServers\": [")
      ntp_close="]}}"

    elif [[ "$VENDOR" = *Intel* ]]; then

      echo "$VENDOR not yet developed."
      exit 1

    fi

    # Count how many entries are in the array
    cnt=${#ntp_array[@]}
    # If there is only one, echo the entry
    if [[ $cnt -eq 1 ]]; then
      ntp_json=$(echo "$ntp_key"
        echo "\"${ntp_array[0]}\""
        echo "$ntp_close")
    else
      # otherwise, loop through
      ntp_json=$(echo "$ntp_key"
      for ((i=0 ; i<cnt ; i++)); do
        if [[ i -eq 1 ]]; then
          # no comma for last element
          ntp_array[i]=\"${ntp_array[i]}\"
        else
          ntp_array[i]=\"${ntp_array[i]}\",
        fi
        # and echo each one so it prints as a json list
        echo "${ntp_array[i]}"
      done
      # close out the list
      echo "$ntp_close")
    fi
    ntp_servers=$ntp_json
  else
    # othwerwise, get it from cloud-init
    local ntp_servers=""
    ntp_servers="$(get_ci_ntp_servers)"
  fi

  if [[ "$VENDOR" = *Marvell* ]] || [[ "$VENDOR" = HP* ]] || [[ "$VENDOR" = Hewlett* ]]; then
    # Static NTP servers cannot be set unless DHCP is completely disabled. See disable_ilo_dhcp()
    # if the user provided an override, use that
    # {"StaticNTPServers": ["<NTP server 1>", "<NTP server 2>"]}
    make_api_call "redfish/v1/managers/${manager}/DateTime" \
      "PATCH" \
      "$ntp_servers" null

    # See if a change is needed
    configuration_settings=$(make_api_call "redfish/v1/managers/1/DateTime" "GET" null ".ConfigurationSettings")

    if [[ "${configuration_settings}" == "\"SomePendingReset\"" ]]; then

      echo -e "The BMC will gracefully restart to apply these changes."
      reset_bmc_manager

    fi

  elif [[ "$VENDOR" = *GIGA*BYTE* ]]; then

    ntp_enabled=$(make_api_call "redfish/v1/Managers/${manager}/NetworkProtocol" "GET" null ".NTP.ProtocolEnabled")

    echo "Enabling NTP..."
    if [[ "$ntp_enabled" == false ]]; then
      make_api_call "redfish/v1/Managers/${manager}/NetworkProtocol" \
        "PATCH" \
        "{\"NTP\": {\"ProtocolEnabled\": true}}" null

      # FIXME: The value doesn't seem to always update
      # reset_bmc_manager all-force

    else
      echo "Already enabled."
    fi

    echo "Setting NTP servers.."
    make_api_call "redfish/v1/Managers/${manager}/NetworkProtocol" \
      "PATCH" \
      "$ntp_servers" null

  elif [[ "$VENDOR" = *Intel* ]]; then

    echo "$VENDOR not yet developed."
    exit 1

  fi
}

# get_ci_dns_servers gets dns servers defined in cloud-init meta-data under the key 'dns-server'
function get_ci_dns_servers() {
  local dns=""

  # get dns servers from cloud-init
  if [[ -f /run/cloud-init/instance-data.json ]]; then

    dns_servers=$(jq '.ds.meta_data.Global."dns-server"' < /run/cloud-init/instance-data.json)

  else

    # Sometimes the cloud-init files aren't there
    cloud-init init
    dns_servers=$(jq '.ds.meta_data.Global."dns-server"' < /run/cloud-init/instance-data.json)

  fi

  # split dns on space and put them into an array so we can craft the JSON payload
  local dnslist=(${dns_servers// / })

  if [[ "$VENDOR" = *Marvell* ]] || [[ "$VENDOR" = HP* ]] || [[ "$VENDOR" = Hewlett* ]]; then

    local dns="{\"Oem\" :{\"Hpe\": {\"IPv4\": {\"DNSServers\": [\"${dnslist[0]//'"'}\", \"${dnslist[1]//'"'}\"]} }}}"

  elif [[ "$VENDOR" = **GIGA*BYTE** ]]; then

    local dns="{\"NameServers\": [\"${dnslist[0]//'"'}\", \"${dnslist[1]//'"'}\"]}"

  elif [[ "$VENDOR" = *Intel* ]]; then

    echo "Not yet developed."
    exit 1

  fi

  echo "${dns}"
}

# set_bmc_dns() configures the BMC with static DNS servers on a per-interface basis
function set_bmc_dns() {
  echo -e "\nSetting ${BMC} static DNS servers..."

  # If manual overrides are detected,
  if [[ -n $DNS_SERVERS ]]; then

    local dns_servers="$DNS_SERVERS"

    if [[ "$VENDOR" = *Marvell* ]] || [[ "$VENDOR" = HP* ]] || [[ "$VENDOR" = Hewlett* ]]; then

      # {"Oem": {"Hpe": {"IPv4": {"DNSServers": ["<DNS server 1>", "<DNS server 2>"]} }}}
      dns_key=$(echo "{\"Oem\" :{\"Hpe\": {\"IPv4\": {\"DNSServers\": [")
      dns_close=$(echo "]}}")

    elif [[ "$VENDOR" = **GIGA*BYTE** ]]; then

      # {"NameServers": ["<DNS server 1>", "<DNS server 2>"]}
      dns_key=$(echo "{\"NameServers\": [")
      dns_close=$(echo "]}")

    elif [[ "$VENDOR" = *Intel* ]]; then

      echo "$VENDOR not yet developed."
      exit 1

    fi
    # split them into an array as before with NTP, so we can access each element individually
    dns_array=(${dns_servers/,/ })
    dns_json=$(echo "$dns_key"
      cnt=${#dns_array[@]}
      if [[ $cnt -eq 1 ]]; then
        echo "\"${dns_array[0]}\""
      else
        for ((i=0 ; i<cnt ; i++)); do
          if [[ i -eq 1 ]]; then
            # no comma for last element
            dns_array[i]=\"${dns_array[i]}\"
          else
            dns_array[i]=\"${dns_array[i]}\",
          fi
          echo "${dns_array[i]}"
        done
      fi
      # close out the list
      echo "$dns_close"
    )
    dns_servers=$dns_json
  else
    # othwerwise, get it from cloud-init
    local dns_servers=""
    dns_servers="$(get_ci_ntp_servers)"
  fi

  if [[ "$VENDOR" = *Marvell* ]] || [[ "$VENDOR" = HP* ]] || [[ "$VENDOR" = Hewlett* ]]; then

    make_api_call "redfish/v1/Managers/${manager}/NetworkProtocol" \
      "PATCH" \
      "$dns_servers" null

    reset_bmc_manager

  # elif [[ "$VENDOR" = **GIGA*BYTE** ]]; then

    # Not possible?  This is read-only
    # make_api_call "redfish/v1/Managers/${manager}/EthernetInterfaces/${interface}" \
    #   "PATCH" \
    #   "$dns_servers" null

  elif [[ "$VENDOR" = *Intel* ]]; then

    echo "Not yet developed."
    exit 1

  fi
}

# if no arguments are passed, show usage
if [[ "$#" -eq 0 ]];then
  echo "No arguments supplied."
  usage && exit 1
fi

while getopts "h" opt; do
  case ${opt} in
    h)
      usage
      exit 0
      ;;
   \? )
     echo "Invalid option: -$OPTARG" 1>&2
     exit 1
     ;;
  esac
done
shift $((OPTIND -1))


subcommand="$1"; shift  # Remove command from the argument list
# Parse options to the install sub command
case "$subcommand" in
  ilo)
    while getopts "AsZ:tzSD:N:dnrf" opt; do
      case ${opt} in
        A) show_current_bmc_settings
           disable_ilo_dhcp
           set_bmc_dns
           set_bmc_ntp
           echo "Run 'chronyc clients' on ncn-m001 to validate NTP on the BMC is working"
           ;;
        Z) TIMEZONE="$OPTARG"
           set_bmc_timezone
           ;;
        t) show_current_bmc_datetime ;;
        z) show_current_bmc_timezone ;;
        s) show_current_bmc_settings ;;
        S) disable_ilo_dhcp ;;
        D) DNS_SERVERS="$OPTARG"
           ;;
        N) NTP_SERVERS="$OPTARG"
           ;;
        d) set_bmc_dns ;;
        n) set_bmc_ntp ; echo "Run 'chronyc clients' on ncn-m001 to validate NTP on the BMC is working" ;;
        r) reset_bmc_manager ;;
        f) reset_bmc_manager all-force;;
        \?)
          echo "Invalid Option: -$OPTARG" 1>&2
          exit 1
          ;;
        :)
          echo "Invalid Option: -$OPTARG requires an argument" 1>&2
          exit 1
          ;;
      esac
    done
    shift $((OPTIND -1))
    ;;
  # GIGABYTE-specific flags
  gb)
    while getopts "AstD:N:dnrf" opt; do
      case ${opt} in
        A) show_current_bmc_settings
           set_bmc_dns
           set_bmc_ntp
           echo "Run 'chronyc clients' on ncn-m001 to validate NTP on the BMC is working"
           ;;
        t) show_current_bmc_datetime ;;
        s) show_current_bmc_settings ;;
        D) DNS_SERVERS="$OPTARG"
           ;;
        N) NTP_SERVERS="$OPTARG"
           ;;
        d) set_bmc_dns ;;
        n) set_bmc_ntp ; echo "Run 'chronyc clients' on ncn-m001 to validate NTP on the BMC is working" ;;
        r) reset_bmc_manager ;;
        f) reset_bmc_manager all-force;;
        \?)
          echo "Invalid Option: -$OPTARG" 1>&2
          exit 1
          ;;
        :)
          echo "Invalid Option: -$OPTARG requires an argument" 1>&2
          exit 1
          ;;
      esac
    done
    shift $((OPTIND -1))
    ;;
  # Intel-specific flags
  intel) echo "Intel functions have yet to be developed"
        ;;
  *)
    echo "Unknown vendor"
    exit 1
    ;;
esac
