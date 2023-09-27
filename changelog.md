# Changelog

## [0.7.0] - 2023-09-25

### Changed
- Removed REDS from run_hms_ct_tests.sh

## [0.6.1] - 2023-07-28
### Changed
- Added check for vShasta to run_hms_ct_tests.sh

## [0.6.0] - 2023-07-05
### Changed
- Added HMNFD Tavern tests to HMS CT test wrapper.

## [0.5.5] - 2023-05-03
### Changed
- Removed BGP script.
- Removed Aruba SNMP scripts.

## [0.5.4] - 2023-03-20
### Changed
- Added option to print failed pod logs to HMS CT test wrapper.

## [0.5.3] - 2023-03-02
### Changed
- Moved CAPMC get_power_cap_capabilities test into hardware checks stage.

## [0.5.2] - 2023-02-22
### Changed
- Linting of minor language and formatting errors.

## [0.5.1] - 2023-02-10
### Changed
- Improved argument parsing for set-bmc-ntp-dns.sh.

## [0.5.0] - 2023-02-03
### Changed
- Moved hardware-sensitive CT tests into separate stage.

## [0.4.5]
### Changed
- The verify_hsm_discovery.py script now properly supports EX2500 cabinets.

## [0.4.4] - 2023-01-24
### Changed
- Added PCS to run_hms_ct_tests.sh script.

## [0.4.3] - 2022-12-15
### Changed
- Fixed a variable that was not being set properly.

## [0.4.1] - 2022-10-27
### Changed
- Fixed broken HSM CLI call in make_node_groups script.

## [0.4.0] - 2022-10-26
### Changed
- verify_hsm_discovery.py now references troubleshooting documentation upon failure.

## [0.0.40] - 2022-10-12
### Changed
- Modify leaf_switch_snmp_creds.sh to not require a user to delete

## [0.0.39] - 2022-09-09
### Changed
 - Update hsm_discovery_status_test.sh to fix token leaks.
 - Clean up run_hms_ct_tests.sh for shellcheck.

## [0.0.38] - 2022-07-25
### Changed
 - Add workaround to dns_records.py to allow for hostnames with _

## [0.0.37] - 2022-07-20
### Changed
 - Update run_hms_ct_tests.sh for improved log output formatting.

## [0.0.36] - 2022-07-14
### Changed
 - Remove WAR for bad SLS chassis data generation from verify_hsm_discovery.py.

## [0.0.35] - 2022-07-12
### Changed
 - Updates to run_hms_ct_tests.sh to run Helm versions of CT tests.
 - Update make_node_groups to handle K8s output change.
 - Update verify_hsm_discovery.py to use HSM v2 instead of v1 which is deprecated.

## [0.0.34] - 2022-06-08
### Changed
 - Add workaround for dns_records.py for hostnames that contain underscores.

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
