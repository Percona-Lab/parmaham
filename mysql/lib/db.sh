# shellcheck shell=bash
# Database plug-in for MySQL (Percona Server or Oracle MySQL Community).
# Sourced by common/lib.sh load_db; mariadb/lib/db.sh builds on it.
#
# Every <db>/lib/db.sh provides:
#   DB_LABEL                 display name
#   db_service               systemd unit of the server (without .service)
#   db_wait                  wait until the server accepts connections
#   db_admin [SQL]           run SQL (or stdin) as the administrator
#   db_bench [SQL]           run SQL (or stdin) as the benchmark user in the
#                            benchmark database; tab-separated rows, no header
#   hdb_env                  export the PMH_DB_* settings for <db>/lib/hdb-db.tcl
#   db_schema_exists         true when the benchmark database exists
#   db_drop_schema           drop it
#   db_after_build           fix-ups after HammerDB built the schema
#   db_schema_size_mb        size of the benchmark database
#   db_version               server version string
#   db_purge_install         install the purge procedures, record a watermark
#   db_purge_run HOURS BATCH delete data older than HOURS
#   db_procmem_spec          procmem.py SPEC of the server processes
#   db_hammerdb_libs DIR     (optional) client library HammerDB needs
# and writes $PMH_ETC/$PMH_DB-monitor.cnf for the dashboard collector.

DB_LABEL=${DB_LABEL:-MySQL}
MYSQL_ADMIN_CNF=$PMH_ETC/$PMH_DB-admin.cnf      # root, 0600 root
MYSQL_BENCH_CNF=$PMH_ETC/$PMH_DB-bench.cnf      # hammerdb user, 0640 root:parmaham
MYSQL_MONITOR_CNF=$PMH_ETC/$PMH_DB-monitor.cnf  # dashboard user, 0600 root
MYSQL_BENCH_USER=hammerdb
MYSQL_MONITOR_USER=parmaham_mon
MYSQL_BENCH_DB=tpcc
# client program (mariadb/lib/db.sh: mariadb)
MYSQL_CLIENT=${MYSQL_CLIENT:-mysql}

db_service() {
    case $(os_family) in
        debian) echo mysql ;;
        rhel)   echo mysqld ;;
    esac
}

mysql_conf_dir() {
    case $(os_family) in
        debian) echo /etc/mysql/mysql.conf.d ;;
        rhel)   echo /etc/my.cnf.d ;;
    esac
}

mysql_admin() { "$MYSQL_CLIENT" --defaults-extra-file="$MYSQL_ADMIN_CNF" "$@"; }
mysql_bench() { "$MYSQL_CLIENT" --defaults-extra-file="$MYSQL_BENCH_CNF" "$MYSQL_BENCH_DB" "$@"; }

db_admin() { if (($#)); then mysql_admin -NB -e "$1"; else mysql_admin; fi; }
db_bench() { if (($#)); then mysql_bench -NB -e "$1"; else mysql_bench; fi; }

# write_client_cnf file user password owner_group mode
write_client_cnf() {
    {
        echo "[client]"
        echo "user=$2"
        echo "password=$3"
        # an empty socket= would make the client use an empty path
        if [[ -n ${MYSQL_SOCKET:-} ]]; then echo "socket=$MYSQL_SOCKET"; fi
    } | write_cnf "$1" "$4" "$5"
}

db_wait() {
    local i
    for i in $(seq 1 120); do
        if mysql_admin -e 'SELECT 1' &>/dev/null; then return 0; fi
        sleep 2
    done
    die "$DB_LABEL did not become available"
}

# Export the PMH_DB_* variables used by the HammerDB Tcl scripts
hdb_env() {
    [[ -r $MYSQL_BENCH_CNF ]] || die "$MYSQL_BENCH_CNF not found - run database-install.sh first"
    export PMH_DB_HOST=localhost
    export PMH_DB_PORT=3306
    PMH_DB_SOCKET=$(cnf_value "$MYSQL_BENCH_CNF" socket)
    PMH_DB_USER=$(cnf_value "$MYSQL_BENCH_CNF" user)
    PMH_DB_PASS=$(cnf_value "$MYSQL_BENCH_CNF" password)
    export PMH_DB_SOCKET PMH_DB_USER PMH_DB_PASS
    export PMH_DB_NAME=$MYSQL_BENCH_DB
}

db_schema_exists() { [[ -n $(db_admin "SHOW DATABASES LIKE '$MYSQL_BENCH_DB'") ]]; }
db_drop_schema()   { db_admin "DROP DATABASE \`$MYSQL_BENCH_DB\`"; }
db_version()       { db_bench 'SELECT VERSION()'; }

db_schema_size_mb() {
    db_admin "SELECT ROUND(SUM(data_length+index_length)/1048576) FROM information_schema.tables WHERE table_schema='$MYSQL_BENCH_DB'"
}

db_after_build() {
    # HammerDB creates history.id as INT; a permanent run would exhaust it, so
    # widen it to BIGINT. The purge job deletes history rows by this key.
    log "widening history.id to BIGINT"
    db_bench "ALTER TABLE history MODIFY id BIGINT NOT NULL AUTO_INCREMENT INVISIBLE"
}

db_purge_install() {
    db_bench < "$PMH_HOME/mysql/lib/purge.sql"
    # first watermark, so data from now on can be purged after the retention period
    db_bench "CALL parmaham_purge_mark()"
}

db_purge_run() {
    # READ COMMITTED avoids gap locks that could block HammerDB inserts
    mysql_bench -t -e "SET SESSION transaction_isolation = 'READ-COMMITTED';
                       CALL parmaham_purge($1, $2);"
}

db_procmem_spec() { echo mysqld; }

# Settings sized for this node, shared with MariaDB: sets MEM_MB, CPUS, BP_MB,
# REDO_MB, IO_THREADS, IO_CAP, IO_CAP_MAX, DISK_NAME and DISK_CLASS.
mysql_sizing() {
    MEM_MB=$(mem_total_mb)
    CPUS=$(cpu_count)
    # leave headroom for HammerDB, which runs on the same node
    BP_MB=$(( MEM_MB * MYSQL_BUFFER_POOL_PCT / 100 / 128 * 128 ))
    (( BP_MB >= 256 )) || BP_MB=256
    REDO_MB=$(( BP_MB / 4 ))
    (( REDO_MB < 1024 )) && REDO_MB=1024
    (( REDO_MB > 32768 )) && REDO_MB=32768
    IO_THREADS=$(( CPUS / 2 ))
    (( IO_THREADS < 4 )) && IO_THREADS=4
    (( IO_THREADS > 32 )) && IO_THREADS=32
    # the storage class of the datadir device decides the I/O capacity
    disk_class "$1"
    case $DISK_CLASS in
        hdd)  IO_CAP=200;   IO_CAP_MAX=400 ;;
        nvme) IO_CAP=10000; IO_CAP_MAX=20000 ;;
        *)    IO_CAP=2000;  IO_CAP_MAX=4000 ;;
    esac
}

# Create or update the benchmark and monitoring accounts and write their
# credential files. $1: the monitoring account's server-level grants.
mysql_create_accounts() {
    local bench_pass mon_pass
    if [[ -r $MYSQL_BENCH_CNF ]]; then bench_pass=$(cnf_value "$MYSQL_BENCH_CNF" password); else bench_pass=$(random_password); fi
    if [[ -r $MYSQL_MONITOR_CNF ]]; then mon_pass=$(cnf_value "$MYSQL_MONITOR_CNF" password); else mon_pass=$(random_password); fi
    db_admin <<EOF
CREATE USER IF NOT EXISTS '$MYSQL_BENCH_USER'@'localhost' IDENTIFIED BY '$bench_pass';
ALTER USER '$MYSQL_BENCH_USER'@'localhost' IDENTIFIED BY '$bench_pass';
GRANT ALL ON \`$MYSQL_BENCH_DB\`.* TO '$MYSQL_BENCH_USER'@'localhost';
GRANT PROCESS ON *.* TO '$MYSQL_BENCH_USER'@'localhost';
CREATE USER IF NOT EXISTS '$MYSQL_MONITOR_USER'@'localhost' IDENTIFIED BY '$mon_pass';
ALTER USER '$MYSQL_MONITOR_USER'@'localhost' IDENTIFIED BY '$mon_pass';
$1
GRANT SELECT ON \`$MYSQL_BENCH_DB\`.* TO '$MYSQL_MONITOR_USER'@'localhost';
EOF
    write_client_cnf "$MYSQL_BENCH_CNF" "$MYSQL_BENCH_USER" "$bench_pass" "$PMH_USER" 0640
    write_client_cnf "$MYSQL_MONITOR_CNF" "$MYSQL_MONITOR_USER" "$mon_pass" root 0600
}

# HammerDB's MySQL interface (mysqltcl) links against Oracle's
# libmysqlclient.so.24 and requires its versioned symbols, so Percona's
# libperconaserverclient cannot be substituted. Take the library from the
# MySQL minimal tarball and keep it private to HammerDB.
db_hammerdb_libs() {
    local libdir=$1 v=$MYSQL_CLIENT_LIB_VERSION tarball url
    [[ -e $libdir/libmysqlclient.so.24 ]] && return
    case $(uname -m) in
        x86_64)  tarball="mysql-$v-linux-glibc2.17-x86_64-minimal.tar.xz" ;;
        aarch64) tarball="mysql-$v-linux-glibc2.28-aarch64.tar.xz" ;;  # no minimal build for ARM
    esac
    url="https://cdn.mysql.com/archives/mysql-${v%.*}/$tarball"
    log "downloading libmysqlclient.so.24 from $url"
    install -d "$libdir"
    curl -fsSL "$url" | tar xJ -C "$libdir" --strip-components=2 --wildcards \
        '*/lib/libmysqlclient.so*' '*/lib/private/*'
    [[ -e $libdir/libmysqlclient.so.24 ]] || die "libmysqlclient.so.24 not found after extraction"
}
