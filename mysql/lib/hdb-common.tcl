# Shared HammerDB CLI setup for Percona Server for MySQL.
# All settings come from PMH_* environment variables exported by the
# calling shell script (see common/lib.sh: hdb_env).

proc pmh_env { name {default ""} } {
    if { [info exists ::env($name)] && $::env($name) ne "" } { return $::env($name) }
    return $default
}

dbset db mysql
dbset bm TPC-C

diset connection mysql_host   [pmh_env PMH_DB_HOST localhost]
diset connection mysql_port   [pmh_env PMH_DB_PORT 3306]
diset connection mysql_socket [pmh_env PMH_DB_SOCKET /var/run/mysqld/mysqld.sock]

diset tpcc mysql_user  [pmh_env PMH_DB_USER hammerdb]
diset tpcc mysql_pass  [pmh_env PMH_DB_PASS]
diset tpcc mysql_dbase [pmh_env PMH_DB_NAME tpcc]
