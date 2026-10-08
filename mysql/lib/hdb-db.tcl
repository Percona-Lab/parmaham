# HammerDB settings for MySQL (sourced by common/hdb-common.tcl)
set P mysql
dbset db mysql
dbset bm TPC-C

diset connection mysql_host   [pmh_env PMH_DB_HOST localhost]
diset connection mysql_port   [pmh_env PMH_DB_PORT 3306]
diset connection mysql_socket [pmh_env PMH_DB_SOCKET /var/run/mysqld/mysqld.sock]

diset tpcc mysql_user  [pmh_env PMH_DB_USER hammerdb]
diset tpcc mysql_pass  [pmh_env PMH_DB_PASS]
diset tpcc mysql_dbase [pmh_env PMH_DB_NAME tpcc]

proc pmh_build_settings {} {
    diset tpcc mysql_storage_engine innodb
    # Invisible auto-increment PK on history: lets the purge job delete old
    # history rows by primary-key range instead of scanning the table.
    diset tpcc mysql_history_pk true
}
