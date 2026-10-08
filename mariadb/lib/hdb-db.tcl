# HammerDB settings for MariaDB (sourced by common/hdb-common.tcl)
set P maria
dbset db maria
dbset bm TPC-C

diset connection maria_host   [pmh_env PMH_DB_HOST localhost]
diset connection maria_port   [pmh_env PMH_DB_PORT 3306]
diset connection maria_socket [pmh_env PMH_DB_SOCKET /run/mysqld/mysqld.sock]

diset tpcc maria_user  [pmh_env PMH_DB_USER hammerdb]
diset tpcc maria_pass  [pmh_env PMH_DB_PASS]
diset tpcc maria_dbase [pmh_env PMH_DB_NAME tpcc]

proc pmh_build_settings {} {
    diset tpcc maria_storage_engine innodb
    # Invisible auto-increment PK on history: lets the purge job delete old
    # history rows by primary-key range instead of scanning the table.
    diset tpcc maria_history_pk true
}
