# Node Management Scripts

Place scripts for working with node configurations / customizations here.

The current scripts are:

- make_node_groups: Create HSM node groups based on NCN functional categories:
  - master: a group of nodes designated as Kubernetes Master nodes
  - worker: a group of nodes designated as Kubernetes Worker nodes
  - storage: a group of nodes designated as Storage nodes
  - uai: a sub-group of Kubernetes Worker nodes allowed to run UAIs

- make_api_calls.py: Helper script for set-bmc-ntp-dns.sh

- set-bmc-ntp-dns.sh: View and change NTP and DNS settings on BMCs
