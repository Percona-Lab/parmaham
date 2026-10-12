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

# HammerDB's MySQL driver counts transactions with SHOW GLOBAL STATUS
# (Com_commit + Com_rollback). seekdb returns neither, the monitor virtual
# user then fails on an unset variable and the run has no result. Ask seekdb's
# plan cache instead, in the same two-row shape: every HammerDB transaction is
# one stored procedure call. (\$ keeps the view name literal inside the
# driver's double-quoted string.)
proc pmh_patch_driver {} {
    upvar #0 _ED ed
    set query {show global status where Variable_name = 'Com_commit' or Variable_name =  'Com_rollback'}
    set seekdb {select 'Com_commit', cast(coalesce(sum(executions), 0) as signed) from oceanbase.V\$OB_PLAN_CACHE_PLAN_STAT where object_type = 'PROCEDURE' union all select 'Com_rollback', 0}
    if { [string first $query $ed(package)] < 0 } {
        puts "PARMAHAM_ERROR: the transaction count query was not found in the HammerDB driver"
        exit 1
    }
    set ed(package) [string map [list $query $seekdb] $ed(package)]
    puts "PARMAHAM: transaction count from seekdb's plan cache (procedure calls)"
}

proc pmh_build_settings {} {
    diset tpcc mysql_storage_engine innodb
    # No history_pk: HammerDB adds the key only for MySQL 8.0.30 and later
    # (seekdb reports 5.7.25), and its version check fails on seekdb's version
    # string, which contains spaces (Tcl list quoting adds braces before the
    # comparison). seekdb/lib/db.sh db_after_build adds the key instead.
    diset tpcc mysql_history_pk false
}
