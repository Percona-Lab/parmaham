# Build the TPROC-C schema.
source [file join [file dirname [info script]] hdb-common.tcl]

diset tpcc ${P}_count_ware [pmh_env PMH_WAREHOUSES 200]
diset tpcc ${P}_num_vu     [pmh_env PMH_BUILD_VU 8]
diset tpcc ${P}_partition  [pmh_env PMH_PARTITION false]
if { [llength [info procs pmh_build_settings]] } { pmh_build_settings }

puts "PARMAHAM: building [pmh_env PMH_WAREHOUSES 200] warehouses with [pmh_env PMH_BUILD_VU 8] virtual users"
buildschema
vudestroy
puts "PARMAHAM: build complete"
exit
