# HammerDB settings for seekdb: HammerDB's MySQL driver over TCP (seekdb has
# no Unix socket). Sourced by common/hdb-common.tcl.
set P mysql
dbset db mysql
dbset bm TPC-C

diset connection mysql_host   [pmh_env PMH_DB_HOST 127.0.0.1]
diset connection mysql_port   [pmh_env PMH_DB_PORT 2881]
diset connection mysql_socket null

diset tpcc mysql_user  [pmh_env PMH_DB_USER hammerdb]
diset tpcc mysql_pass  [pmh_env PMH_DB_PASS]
diset tpcc mysql_dbase [pmh_env PMH_DB_NAME tpcc]

proc pmh_build_settings {} {
    diset tpcc mysql_storage_engine innodb
    # No history_pk: HammerDB adds the key only for MySQL 8.0.30 and later
    # (seekdb reports 5.7.25), and its version check fails on seekdb's version
    # string, which contains spaces (Tcl list quoting adds braces before the
    # comparison). seekdb/lib/db.sh db_after_build adds the key instead.
    diset tpcc mysql_history_pk false
}
