# Changelog

## [0.0.11] - 2021-06-01
### Changed
 - Added script to set static NTP and DNS servers on NCN BMCs (does not support Intel BMCs)
 - Added management switch port data to hsm_discovery_verify.sh to help determine if mismatches are benign

## [0.0.10] - 2021-05-07
### Changed
 - Aruba_BGP_Peers.py
   - Limit TFTP failover routes to 3
   - Update iBGP distance to avoid routing loops
