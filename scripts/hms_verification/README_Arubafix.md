# Automation of Aruba leaf switch SNMP bug check/fix

Aruba switches have a bug in the current FW which causes MAC address
information to be missing from SNMP while being present in the management
CLI interface.  This bug is fixed in newer versions of Aruba FW but
for various reasons HPE is not yet ready to upgrade to this newer version.
Hence the need for an automated way to check if this issue is affecting
the system and if so to fix it.

Note that this script is not 100% automated -- it does require user input.
That input is the switch management software's admin password.   Without this
the commands to fix the SNMP issue cannot be executed on the switch(es).
Since passwords cannot be coded in any way into any application source code,
this is the only way to handle this situation.

This script does the following actions:

1. Check if the system has any Aruba switches.  If not, nothing more to do.

2. Check the HMS discovery logs to see if there are any "missing" 
   MAC addresses, presumably caused by the Aruba bug.

3. If there are missing MACs, filter out any that are on irrelevant (to HMS)
   networks.

4. If there are still missing MACs, execute an SNMP "reset" on the Aruba
   switches (requires password to be input by the admin).

