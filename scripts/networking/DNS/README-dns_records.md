# ./dns_records.py - View, add, delete or modify system DNS records
Use ./dns_records.py to view (-p), modify (requires -f) and delete (-x -f) statically defined records in DNS. 

System DNS records come either dynamically from DHCP (Kea and SMD) or may be defined statically via SLS.  Records in SLS /networks are picked up by the DNS manager every 2 minutes and added to DNS.   This utility provides a better visual reference and more safety nets than modifying SLS records via dumpstate/loadstate and JSON.

## Usage:
Help
```
./dns_records.py
./dns_records.py -h
```

View/Print Existing Records
```
./dns_records.py -p
```

Modify or Add a Record 
```
# To test
./dns_records -i <IPv4 Address> <Name/A> <Alias/CNAME list>"
# To force/accept
./dns_records -i <IPv4 Address> <Name/A> <Alias/CNAME list>" -f
```

Delete a Record (BE CAREFUL!)
```
# To test
./dns_records -i <IPv4 Address> <Name/A> <Alias/CNAME list> -x "
# To force/accept
./dns_records -i <IPv4 Address> <Name/A> <Alias/CNAME list>" -x -f
```

## Example Workflow to modify a record:
In this example we want to add an alias of "api-gateway-test" to the existing istio api gateway record at 10.92.100.71.

### Query Existing
```
# ./dns_records.py -p
<snip>
NMNLB
  nmn_metallb_address_pool 10.92.100.0/24
      10.92.100.71 istio-ingressgateway api-gw-service packages registry spire.local api_gw_service api_gw_service.local  registry.local packages packages.local spire
      10.92.100.72 rsyslog-aggregator rsyslog-agg-service
      10.92.100.60 cray-tftp tftp-service
      10.92.100.73 docker-registry docker_registry_service
      10.92.100.75 slingshot-kafka slingshot_kafka_extern_service
<snip>
```

From this output we see the existing record of `      10.92.100.71 istio-ingressgateway api-gw-service packages registry spire.local api_gw_service api_gw_service.local  registry.local packages packages.local spire`.  We use the existing line and _add_ the new "api-gateway" alias to the end.

NOTE:  Spaces don't matter in the line!

NOTE:  Quotes around the entry are REQUIRED!

### Test the Change
```
# ./dns_records.py -i "      10.92.100.71 istio-ingressgateway api-gw-service packages registry spire.local api_gw_service api_gw_service.local  registry.local packages packages.local spire api-gateway-test"
New record:       10.92.100.71 istio-ingressgateway api-gw-service packages registry spire.local api_gw_service api_gw_service.local  registry.local packages packages.local spire api-gateway-test
Existing record match.
  Existing: 10.92.100.71 istio-ingressgateway api-gw-service packages registry spire.local api_gw_service api_gw_service.local  registry.local packages packages.local spire
  New     : 10.92.100.71 istio-ingressgateway api-gw-service packages registry spire.local api_gw_service api_gw_service.local registry.local packages packages.local spire api-gateway-test
Cowardly refusing to update without -f
```

### Accept the Change
The above test showed that the record existed and presented the new record that would be added.  However, as a safety we need to "force" the change with -f (as stated in the output).
```
# ./dns_records.py -i "      10.92.100.71 istio-ingressgateway api-gw-service packages registry spire.local api_gw_service api_gw_service.local  registry.local packages packages.local spire api-gateway-test" -f
New record:       10.92.100.71 istio-ingressgateway api-gw-service packages registry spire.local api_gw_service api_gw_service.local  registry.local packages packages.local spire api-gateway-test
Existing record match.
  Existing: 10.92.100.71 istio-ingressgateway api-gw-service packages registry spire.local api_gw_service api_gw_service.local  registry.local packages packages.local spire
  New     : 10.92.100.71 istio-ingressgateway api-gw-service packages registry spire.local api_gw_service api_gw_service.local registry.local packages packages.local spire api-gateway-test
Updated reservation record in network structure (-f): NMNLB
Replaced existing reservation record in SLS
```

NOTE: DNS will pick up this new record in 2 min or less.