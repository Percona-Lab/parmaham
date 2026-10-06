# shellcheck shell=bash
# Percona Server for MySQL helpers. Sourced after common/lib.sh.

MYSQL_ADMIN_CNF=$PMH_ETC/mysql-admin.cnf      # root, 0600 root
MYSQL_BENCH_CNF=$PMH_ETC/mysql-bench.cnf      # hammerdb user, 0640 root:parmaham
MYSQL_MONITOR_CNF=$PMH_ETC/mysql-monitor.cnf  # dashboard user, 0600 root
MYSQL_BENCH_USER=hammerdb
MYSQL_MONITOR_USER=parmaham_mon
MYSQL_BENCH_DB=tpcc

mysql_service() {
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

mysql_admin() { mysql --defaults-extra-file="$MYSQL_ADMIN_CNF" "$@"; }
mysql_bench() { mysql --defaults-extra-file="$MYSQL_BENCH_CNF" "$MYSQL_BENCH_DB" "$@"; }

random_password() {
    # MySQL's default password policy is satisfied by mixed case + digits + symbol
    printf '%s-Pm1' "$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)"
}

# write_client_cnf file user password owner_group mode
write_client_cnf() {
    local file=$1 user=$2 pass=$3 group=$4 mode=$5
    install -d -m 0755 "$PMH_ETC"
    umask 077
    {
        echo "[client]"
        echo "user=$user"
        echo "password=$pass"
        # an empty socket= would make the client use an empty path
        [[ -n ${MYSQL_SOCKET:-} ]] && echo "socket=$MYSQL_SOCKET"
    } > "$file"
    umask 022
    chown "root:$group" "$file"
    chmod "$mode" "$file"
}

cnf_value() {
    # cnf_value file key
    sed -n "s/^$2=//p" "$1" | head -1
}

wait_for_mysql() {
    local i
    for i in $(seq 1 120); do
        if mysqladmin --defaults-extra-file="$MYSQL_ADMIN_CNF" ping &>/dev/null; then return 0; fi
        sleep 2
    done
    die "MySQL did not become available"
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

# Fail early when the benchmark schema is missing
require_schema() {
    local n
    n=$(mysql_bench -NBe "SELECT COUNT(*) FROM warehouse" 2>/dev/null) \
        || die "TPROC-C schema not found - run database-generate.sh first"
    [[ $n -gt 0 ]] || die "TPROC-C schema is empty - run database-generate.sh first"
}
