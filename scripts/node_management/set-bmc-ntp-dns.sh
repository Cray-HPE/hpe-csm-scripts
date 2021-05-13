#!/bin/bash
# Copyright (C) 2021 Hewlett Packard Enterprise Development LP
# Sets static NTP, timezone, and DNS entries on an iLO BMC
# Author: Jacob Salmela <jacob.salmela@hpe.com>
set -eo pipefail

# We have a BMC per NCN, so these will likely stay 1, but adding them in for flexibility in the future.
manager=1
interface=1
BMC="$HOSTNAME-mgmt"

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

# show_current_bmc_datetime() shows the current datetime on the BMC
function show_current_bmc_datetime() {
  curl "https://${BMC}/redfish/v1/managers/${manager}/DateTime" \
    --insecure \
    -u ${USERNAME}:${IPMI_PASSWORD} \
    -L \
    -s \
    | jq .DateTime
}

# show_current_bmc_datetime() shows the current datetime on the BMC
function show_current_bmc_timezone() {
  curl "https://${BMC}/redfish/v1/managers/${manager}/DateTime" \
    --insecure \
    -u ${USERNAME}:${IPMI_PASSWORD} \
    -L \
    -s \
    | jq .TimeZone.Name
}

# set_bmc_timezone() manually sets the timezone on the BMC using an index number from .TimeZoneList
function set_bmc_timezone() {
  if [[ -z $TIMEZONE ]]; then
    echo "No timezone index provided"
  else
    curl -X PATCH "https://${BMC}/redfish/v1/managers/${manager}/DateTime" \
      --insecure \
      -u ${USERNAME}:${IPMI_PASSWORD} \
      -L \
      -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      -d "{\"TimeZone\": {\"Index\": $TIMEZONE} }"
    echo -e "\n"
    reset_ilo_manager
  fi
}

# show_current_bmc_settings() shows the current iLo settings for DNS and NTP
function show_current_bmc_settings() {
  echo "redfish/v1/managers/${manager}/DateTime .StaticNTPServers:"
  curl "https://${BMC}/redfish/v1/managers/${manager}/DateTime" \
    --insecure \
    -u ${USERNAME}:${IPMI_PASSWORD} \
    -L \
    -s \
    | jq .StaticNTPServers

  echo "redfish/v1/managers/${manager}/ethernetinterfaces/${interface} .Oem.Hpe.IPv4.DNSServers:"
  curl "https://${BMC}/redfish/v1/managers/${manager}/ethernetinterfaces/${interface}" \
    --insecure \
    -u ${USERNAME}:${IPMI_PASSWORD} \
    -L \
    -s \
    | jq .Oem.Hpe.IPv4.DNSServers

  echo "redfish/v1/managers/${manager}/ethernetinterfaces/${interface} .Oem.Hpe.DHCPv4 status:"
  curl "https://${BMC}/redfish/v1/managers/${manager}/ethernetinterfaces/${interface}" \
    --insecure \
    -u ${USERNAME}:${IPMI_PASSWORD} \
    -L \
    -s \
    | jq .Oem.Hpe.DHCPv4

  echo "redfish/v1/managers/${manager}/ethernetinterfaces/${interface} .Oem.Hpe.DHCPv6 status:"
  curl "https://${BMC}/redfish/v1/managers/${manager}/ethernetinterfaces/${interface}" \
    --insecure \
    -u ${USERNAME}:${IPMI_PASSWORD} \
    -L \
    -s \
    | jq .Oem.Hpe.DHCPv6
}

# reset_ilo_manager() gracefully restarts the BMC and waits a bit for it to come back
function reset_ilo_manager() {
  if [[ "$1" == all-force ]]; then
    reset_type='{"ResetType": "ForceRestart"}'
  else
    reset_type='{"ResetType": "GracefulRestart"}'
  fi

  curl -X POST "https://${BMC}/redfish/v1/managers/${manager}/Actions/Manager.Reset" \
    --insecure \
    -u ${USERNAME}:${IPMI_PASSWORD} \
    -L \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "$reset_type"

  secs=45
  while [ $secs -gt 0 ]; do
    echo -ne "$secs waiting a bit for the BMC to reset...\033[0K\r"
    sleep 1
    : $((secs--))
  done
  echo -e "\n"
}

# disable_ilo_dhcp() disables dhcp on the iLO since ipmitool cannot fully disable it.  This requres a restart.
function disable_ilo_dhcp() {
  # Check if it's already disabled
  dhcpv4_dns_enabled=$(curl "https://${BMC}/redfish/v1/managers/${manager}/ethernetinterfaces/${interface}" --insecure -u ${USERNAME}:${IPMI_PASSWORD} -L -s | jq .Oem.Hpe.DHCPv4.UseDNSServers)
  dhcpv4_ntp_enabled=$(curl "https://${BMC}/redfish/v1/managers/${manager}/ethernetinterfaces/${interface}" --insecure -u ${USERNAME}:${IPMI_PASSWORD} -L -s | jq .Oem.Hpe.DHCPv4.UseNTPServers)
  dhcpv6_dns_enabled=$(curl "https://${BMC}/redfish/v1/managers/${manager}/ethernetinterfaces/${interface}" --insecure -u ${USERNAME}:${IPMI_PASSWORD} -L -s | jq .Oem.Hpe.DHCPv6.UseDNSServers)
  dhcpv6_ntp_enabled=$(curl "https://${BMC}/redfish/v1/managers/${manager}/ethernetinterfaces/${interface}" --insecure -u ${USERNAME}:${IPMI_PASSWORD} -L -s | jq .Oem.Hpe.DHCPv6.UseNTPServers)

  # Disable DHCPv4
  echo -e "Disabling DHCPv4 on iLO..."
  if [[ "${dhcpv4_dns_enabled}" == true ]] || [[ "${dhcpv4_ntp_enabled}" == true ]] ; then
    curl -X PATCH "https://${BMC}/redfish/v1/managers/${manager}/ethernetinterfaces/${interface}" \
      --insecure \
      -u ${USERNAME}:${IPMI_PASSWORD} \
      -L \
      -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      -d "{\"DHCPv4\":{
            \"UseDNSServers\": false,
            \"UseNTPServers\": false
          }}"
    echo -e "\n"
  elif [[ "${dhcpv4_dns_enabled}" == false ]] && [[ "${dhcpv4_ntp_enabled}" == false ]] ; then
    echo "Already disabled"
  fi

  # Disable DHCPv6
  echo -e "Disabling DHCPv6 on iLO..."
  if [[ "${dhcpv6_dns_enabled}" == true ]] || [[ "${dhcpv6_ntp_enabled}" == true ]] ; then
    curl -X PATCH "https://${BMC}/redfish/v1/managers/${manager}/ethernetinterfaces/${interface}" \
      --insecure \
      -u ${USERNAME}:${IPMI_PASSWORD} \
      -L \
      -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      -d "{\"DHCPv6\":{
            \"UseDNSServers\": false,
            \"UseNTPServers\": false
          }}"
      echo -e "\n"
  elif [[ "${dhcpv6_dns_enabled}" == false ]] && [[ "${dhcpv6_ntp_enabled}" == false ]] ; then
    echo "Already disabled"
  fi

  # if any values were true, we need to reset to apply the changes
  if [[ "${dhcpv6_dns_enabled}" == true ]] || [[ "${dhcpv6_ntp_enabled}" == true ]] || [[ "${dhcpv4_dns_enabled}" == true ]] || [[ "${dhcpv4_ntp_enabled}" == true ]]; then
    echo -e "\nThe BMC will gracefully restart to apply these changes."
    reset_ilo_manager
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
  # Static NTP servers cannot be set unless DHCP is completely disabled. See disable_ilo_dhcp()
  echo "Setting static NTP servers on ${BMC}..."

  # if the user provided an override, use that
  # {"StaticNTPServers": ["<NTP server 1>", "<NTP server 2>"]}
  if [[ -n $NTP_SERVERS ]]; then
    local ntp_servers="$NTP_SERVERS"
    ntp_array=(${ntp_servers/,/ })
    ntp_json=$(echo "{\"StaticNTPServers\": ["
      cnt=${#ntp_array[@]}
      if [[ $cnt -eq 1 ]]; then
        echo "\"${ntp_array[0]}\""
      else
        for ((i=0 ; i<cnt ; i++)); do
          if [[ i -eq 1 ]]; then
            # no comma for last element
            ntp_array[i]=\"${ntp_array[i]}\"
          else
            ntp_array[i]=\"${ntp_array[i]}\",
          fi
          echo "${ntp_array[i]}"
        done
      fi
      echo "]}\""
    )
    ntp_servers=$ntp_json
  else
    # othwerwise, get it from cloud-init
    local ntp_servers=""
    ntp_servers="$(get_ci_ntp_servers)"
  fi

  curl -X PATCH "https://${BMC}/redfish/v1/managers/${manager}/DateTime" \
    --insecure \
    -u ${USERNAME}:${IPMI_PASSWORD} \
    -L \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "$ntp_servers"
  echo -e "\n"

  configuration_settings=$(curl "https://$HOSTNAME-mgmt/redfish/v1/managers/1/DateTime" --insecure -u ${USERNAME}:${IPMI_PASSWORD} -L -s | jq .ConfigurationSettings)
  if [[ "${configuration_settings}" == "\"SomePendingReset\"" ]]; then
    echo -e "The BMC will gracefully restart to apply these changes."
    reset_ilo_manager
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
  local dns="{\"Oem\" :{\"Hpe\": {\"IPv4\": {\"DNSServers\": [\"${dnslist[0]//'"'}\", \"${dnslist[1]//'"'}\"]} }}}"
  echo "${dns}"
}

# set_bmc_dns() configures the BMC with static DNS servers on a per-interface basis
function set_bmc_dns() {
  echo -e "\nSetting ${BMC} static DNS servers..."

  # {"Oem": {"Hpe": {"IPv4": {"DNSServers": ["<NTP server 1>", "<NTP server 2>"]} }}}
  if [[ -n $DNS_SERVERS ]]; then
    local dns_servers="$DNS_SERVERS"
    dns_array=(${dns_servers/,/ })
    dns_json=$(echo "{\"Oem\" :{\"Hpe\": {\"IPv4\": {\"DNSServers\": ["
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
      echo "]} }}}\""
    )
    dns_servers=$dns_json
  else
    # othwerwise, get it from cloud-init
    local dns_servers=""
    dns_servers="$(get_ci_ntp_servers)"
  fi

  curl -X PATCH "https://${BMC}/redfish/v1/managers/${manager}/ethernetinterfaces/${interface}" \
    --insecure \
    -u ${USERNAME}:${IPMI_PASSWORD} \
    -L \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "$dns_servers"
  echo -e "\n"

  reset_ilo_manager
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
case "$subcommand" in
  # Parse options to the install sub command
  ilo)
#/    options for the 'ilo' command:
#/       [-A]               configure an HPE BMC (iLO) running all the necessary tasks (fresh installs only)
#/       [-s]               shows the current configuration of NTP and DNS
#/       [-t]               show the current date/time for the BMC
#/       [-S]               disables DHCP so static entries can be set
#/       [-N NTP_SERVERS]   a comma seperated list of NTP servers (manual override when no 1.5 metadata exists)
#/       [-D DNS_SERVERS]   a comma seperated list of DNS servers (manual override when no 1.5 metadata exists)
#/       [-d]               sets static DNS servers using cloud-init data or overrides
#/       [-n]               sets static NTP servers using cloud-init data or overrides (DHCP needs to be disabled (see -S))
#/       [-r]               gracefully resets the BMC
#/       [-f]               forcefully resets the BMC
#/
#/    EXAMPLES:
#/
#/       Upgrading 1.4 to 1.5 passing in NTP and DNS entries that don't exist in 1.4 metadata:
#/           set-bmc-ntp-dns.sh ilo -s
#/           set-bmc-ntp-dns.sh ilo -S
#/           set-bmc-ntp-dns.sh ilo -N ncn-m001,time.nist.gov -n
#/           set-bmc-ntp-dns.sh ilo -D 10.92.100.225,172.30.48.1 -d
#/           set-bmc-ntp-dns.sh -r
#/
#/       Fresh install of 1.5 with new metadata already in place:
#/           set-bmc-ntp-dns.sh ilo -A
#/                     or
#/           set-bmc-ntp-dns.sh ilo -s
#/           set-bmc-ntp-dns.sh ilo -S
#/           set-bmc-ntp-dns.sh ilo -n
#/           set-bmc-ntp-dns.sh ilo -d
#/           set-bmc-ntp-dns.sh -r
#/
#/       Disabling DHCP:
#/           set-bmc-ntp-dns.sh ilo -S
#/
#/       Setting just NTP servers (DHCP must have been previously disabled):
#/           set-bmc-ntp-dns.sh ilo -n
#/
#/       Setting just DNS servers (DHCP must have been previously disabled):
#/           set-bmc-ntp-dns.sh ilo -d
#/
#/       Gracefully resetting the BMC:
#/           set-bmc-ntp-dns.sh -r
#/
#/       Checking the datetime on all NCN BMCs:
#/          for i in ncn-m00{2..3} ncn-{w,s}00{1..3}; do echo "------$i--------"; ssh $i 'export USERNAME=root; export IPMI_PASSWORD=password; /set-bmc-ntp-dns.sh ilo -t'; done
#/
#/       Check the current timezone on a NCN BMC:
#/          set-bmc-ntp-dns.sh ilo -z
#/
#/       Set the timezone on a NCN BMC:
#/          curl https://$HOSTNAME-mgmt/redfish/v1/managers/1/DateTime --insecure -u $USERNAME:$IPMI_PASSWORD -L | jq .TimeZoneList
#/          # Pick a desired timezone index number
#/          set-bmc-ntp-dns.sh ilo -Z 7
#/
    while getopts "AsZ:tzSD:N:dnrf" opt; do
      case ${opt} in
        A) show_current_bmc_settings
           disable_ilo_dhcp
           set_bmc_dns
           set_bmc_ntp
           echo "Run 'chronyc clients' on ncn-m001 to validate NTP on the BMC is working"
           ;;
         # T) set_bmc_datetime
         #    ;;
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
        r) reset_ilo_manager ;;
        f) reset_ilo_manager all-force;;
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
  *)
    echo "intel and gb functions have yet to be developed"
    exit 1
    ;;
esac

#/
#/    options for the 'gb' command:
#/       [-]                to be developed
#/
#/    options for the 'intel' command:
#/       [-]                to be developed
#/

