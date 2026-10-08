# Shared HammerDB CLI setup. All settings come from PMH_* environment
# variables exported by the calling shell script (common/lib.sh, hdb_env).
#
# The database specific part is <db>/lib/hdb-db.tcl. It selects the HammerDB
# database, sets the connection and credentials, and sets P to the prefix of
# HammerDB's settings for that database (mysql_, maria_, pg_), which the
# generic build and run scripts use: diset tpcc ${P}_rampup ...
# It may define pmh_build_settings with extra settings for the schema build.

proc pmh_env { name {default ""} } {
    if { [info exists ::env($name)] && $::env($name) ne "" } { return $::env($name) }
    return $default
}

source [file join [pmh_env PMH_HOME /opt/parmaham] [pmh_env PMH_DB mysql] lib hdb-db.tcl]
