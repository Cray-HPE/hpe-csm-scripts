# Changelog

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
