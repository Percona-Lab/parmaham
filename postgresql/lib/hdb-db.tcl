# HammerDB settings for PostgreSQL (sourced by common/hdb-common.tcl)
set P pg
dbset db pg
dbset bm TPC-C

diset connection pg_host    [pmh_env PMH_DB_HOST localhost]
diset connection pg_port    [pmh_env PMH_DB_PORT 5432]
diset connection pg_sslmode disable

diset tpcc pg_user  [pmh_env PMH_DB_USER hammerdb]
diset tpcc pg_pass  [pmh_env PMH_DB_PASS]
diset tpcc pg_dbase [pmh_env PMH_DB_NAME tpcc]
# Stored procedures instead of functions: HammerDB's recommendation for
# PostgreSQL 11 and later (one round trip per transaction, like MySQL).
# Used by the build (which routines to create) and by the driver.
diset tpcc pg_storedprocs true
# HammerDB's VACUUM at the end of a run would add load outside the measured
# period; autovacuum does the work during the run
diset tpcc pg_vacuum false

# HammerDB's transaction counter connects as pg_superuser to read
# pg_stat_database, which any user may read: in runs it uses the benchmark
# user (the workload service cannot read the superuser's password)
diset tpcc pg_superuser     [pmh_env PMH_DB_USER hammerdb]
diset tpcc pg_superuserpass [pmh_env PMH_DB_PASS]
diset tpcc pg_defaultdbase  postgres

proc pmh_build_settings {} {
    # the superuser creates the benchmark user and database
    diset tpcc pg_superuser     [pmh_env PMH_DB_SUPERUSER postgres]
    diset tpcc pg_superuserpass [pmh_env PMH_DB_SUPERPASS]
}
