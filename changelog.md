# Changelog

## [0.2.1] - 2022-12-15
### Changed
- Fixed a variable that was not being set properly.

## [0.2.0] - 2022-10-12
### Changed
- Modify leaf_switch_snmp_creds.sh to not require a user to delete

## [0.0.35] - 2022-06-08
### Changed
 - Add workaround for dns_records.py for hostnames that contain underscores.

## [0.0.34] - 2022-06-08
### Changed
 - Update make_node_groups to handle K8s output change

## [0.0.33] - 2022-05-09
### Changed
 - Change dns_records.py to use the NMN API gateway for the calls to SLS.

## [0.0.32] - 2022-02-03
### Changed
 - Change lock_management_nodes.py to lock nodeBMCs of management nodes as well.

## [0.0.31] - 2022-01-14
### Changed
 - Removed duplicate CabinetPDUController output from verify_hsm_discovery.

## [0.0.30] - 2021-11-18
### Changed
 - Added script to set SNMP creds on mgmt network leaf switches.

## [0.0.17] - 2021-06-21
### Changed
 - Created Python helper script to make API calls for NTP/DNS script, to avoid security issues
   around writing passwords to files or passing them on the command line.

## [0.0.11] - 2021-06-01
### Changed
 - Added script to set static NTP and DNS servers on NCN BMCs (does not support Intel BMCs)
 - Added management switch port data to hsm_discovery_verify.sh to help determine if mismatches are benign

## [0.0.10] - 2021-05-07
### Changed
 - Aruba_BGP_Peers.py
   - Limit TFTP failover routes to 3
   - Update iBGP distance to avoid routing loops
