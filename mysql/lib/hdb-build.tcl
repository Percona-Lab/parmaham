# Build the TPROC-C schema.
source [file join [file dirname [info script]] hdb-common.tcl]

diset tpcc mysql_count_ware      [pmh_env PMH_WAREHOUSES 200]
diset tpcc mysql_num_vu          [pmh_env PMH_BUILD_VU 8]
diset tpcc mysql_storage_engine  innodb
diset tpcc mysql_partition       [pmh_env PMH_PARTITION false]
# Invisible auto-increment PK on history: lets the purge job delete old
# history rows by primary-key range instead of scanning the table.
diset tpcc mysql_history_pk      true

puts "PARMAHAM: building [pmh_env PMH_WAREHOUSES 200] warehouses with [pmh_env PMH_BUILD_VU 8] virtual users"
buildschema
vudestroy
puts "PARMAHAM: build complete"
exit
