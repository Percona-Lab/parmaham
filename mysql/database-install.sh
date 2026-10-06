#!/usr/bin/env bash
# Install Percona Server for MySQL and tune it for this node's size.
#
# Usage: database-install.sh [--repo ps-97-lts] [--buffer-pool-pct 60]
#                            [--binlog 0|1] [--flush-log-at-trx-commit 1|2]
#
# Safe to re-run: an existing installation is kept and only the tuning file
# is regenerated (and the server restarted).
source "$(dirname "$0")/../common/lib.sh"
source "$(dirname "$0")/lib/mysql.sh"

usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

require_root
load_config
while (($#)); do
    case $1 in
        --repo)                    conf_set PS_REPO "$2"; shift 2 ;;
        --buffer-pool-pct)         conf_set MYSQL_BUFFER_POOL_PCT "$2"; shift 2 ;;
        --binlog)                  conf_set MYSQL_BINLOG "$2"; shift 2 ;;
        --flush-log-at-trx-commit) conf_set MYSQL_FLUSH_LOG_AT_TRX_COMMIT "$2"; shift 2 ;;
        -h|--help)                 usage ;;
        *) warn "unknown option $1"; usage 1 ;;
    esac
done

FAMILY=$(os_family)
SERVICE=$(mysql_service)
install_payload

# ---------------------------------------------------------------------------
# 1. Packages
# ---------------------------------------------------------------------------
install_percona_release() {
    command -v percona-release &>/dev/null && return
    log "installing percona-release"
    case $FAMILY in
        debian)
            apt-get update -q
            pkg_install curl gnupg2 lsb-release ca-certificates
            curl -fsSL -o /tmp/percona-release.deb https://repo.percona.com/apt/percona-release_latest.generic_all.deb
            pkg_install /tmp/percona-release.deb
            rm -f /tmp/percona-release.deb
            ;;
        rhel)
            dnf install -y -q https://repo.percona.com/yum/percona-release-latest.noarch.rpm
            ;;
    esac
}

base_packages() {
    case $FAMILY in
        debian) apt-get update -q; pkg_install curl python3 xz-utils tar util-linux pciutils procps ;;
        rhel)   pkg_install curl python3 xz tar util-linux pciutils procps-ng ;;
    esac
}

base_packages
install_percona_release

FRESH_INSTALL=0
if ! command -v mysqld &>/dev/null; then
    FRESH_INSTALL=1
    log "enabling Percona repository $PS_REPO"
    percona-release enable-only "$PS_REPO" release
    ROOT_PASS=$(random_password)
    case $FAMILY in
        debian)
            apt-get update -q
            debconf-set-selections <<EOF
percona-server-server percona-server-server/root-pass password $ROOT_PASS
percona-server-server percona-server-server/re-root-pass password $ROOT_PASS
EOF
            log "installing percona-server-server"
            pkg_install percona-server-server percona-server-client
            ;;
        rhel)
            dnf module disable -y -q mysql 2>/dev/null || true
            log "installing percona-server-server"
            pkg_install percona-server-server percona-server-client
            systemctl enable --now "$SERVICE"
            TEMP_PASS=$(grep 'temporary password' /var/log/mysqld.log | tail -1 | awk '{print $NF}')
            [[ -n $TEMP_PASS ]] || die "could not find the temporary root password in /var/log/mysqld.log"
            mysql --connect-expired-password -uroot -p"$TEMP_PASS" \
                -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$ROOT_PASS'"
            ;;
    esac
    MYSQL_SOCKET=""
    write_client_cnf "$MYSQL_ADMIN_CNF" root "$ROOT_PASS" root 0600
    [[ -e /root/.my.cnf ]] || ln -s "$MYSQL_ADMIN_CNF" /root/.my.cnf
else
    log "MySQL is already installed: $(mysqld --version)"
    [[ -r $MYSQL_ADMIN_CNF ]] || die "MySQL is installed but $MYSQL_ADMIN_CNF is missing. Create it with root credentials ([client] user=, password=) and re-run."
fi

systemctl enable "$SERVICE" &>/dev/null
systemctl start "$SERVICE"
wait_for_mysql
MYSQL_SOCKET=$(mysql_admin -NBe 'SELECT @@socket')
DATADIR=$(mysql_admin -NBe 'SELECT @@datadir')
conf_set MYSQL_SOCKET "$MYSQL_SOCKET"
# rewrite admin cnf with the socket path
write_client_cnf "$MYSQL_ADMIN_CNF" "$(cnf_value "$MYSQL_ADMIN_CNF" user)" "$(cnf_value "$MYSQL_ADMIN_CNF" password)" root 0600

# ---------------------------------------------------------------------------
# 2. Tuning for this node
# ---------------------------------------------------------------------------
MEM_MB=$(mem_total_mb)
CPUS=$(cpu_count)
BP_MB=$(( MEM_MB * MYSQL_BUFFER_POOL_PCT / 100 / 128 * 128 ))
(( BP_MB >= 256 )) || BP_MB=256
REDO_MB=$(( BP_MB / 4 ))
(( REDO_MB < 1024 )) && REDO_MB=1024
(( REDO_MB > 32768 )) && REDO_MB=32768
IO_THREADS=$(( CPUS / 2 ))
(( IO_THREADS < 4 )) && IO_THREADS=4
(( IO_THREADS > 32 )) && IO_THREADS=32

# Storage class of the datadir device decides the I/O capacity
DATA_DEV=$(df --output=source "$DATADIR" | tail -1)
DISK_NAME=$(lsblk -no PKNAME "$DATA_DEV" 2>/dev/null | tail -1)
[[ -n $DISK_NAME ]] || DISK_NAME=$(basename "$DATA_DEV")
ROTA=$(cat "/sys/block/$DISK_NAME/queue/rotational" 2>/dev/null || echo 0)
if [[ $ROTA == 1 ]]; then
    IO_CAP=200;   IO_CAP_MAX=400;   DISK_CLASS=hdd
elif [[ $DISK_NAME == nvme* ]]; then
    IO_CAP=10000; IO_CAP_MAX=20000; DISK_CLASS=nvme
else
    IO_CAP=2000;  IO_CAP_MAX=4000;  DISK_CLASS=ssd
fi
NUMA_NODES=$(ls -d /sys/devices/system/node/node* 2>/dev/null | wc -l)

if [[ $MYSQL_BINLOG == 1 ]]; then
    BINLOG_CFG="log_bin = binlog
binlog_expire_logs_seconds = $MYSQL_BINLOG_EXPIRE_SECONDS
sync_binlog = 1"
else
    BINLOG_CFG="skip_log_bin"
fi

CNF="$(mysql_conf_dir)/zz-parmaham.cnf"
log "writing $CNF (RAM ${MEM_MB}MB, ${CPUS} CPUs, $DISK_CLASS storage)"
cat > "$CNF" <<EOF
# Generated by Parma Ham database-install.sh on $(date -u '+%F %T') UTC.
# Node: ${MEM_MB} MB RAM, ${CPUS} CPUs, datadir on $DISK_NAME ($DISK_CLASS).
# Re-run database-install.sh to regenerate; local changes will be lost.
[mysqld]
skip_name_resolve = ON
max_connections = 1000
table_open_cache = 4000
performance_schema = ON

innodb_buffer_pool_size = ${BP_MB}M
innodb_redo_log_capacity = ${REDO_MB}M
innodb_log_buffer_size = 64M
innodb_flush_log_at_trx_commit = $MYSQL_FLUSH_LOG_AT_TRX_COMMIT
innodb_flush_method = O_DIRECT
innodb_io_capacity = $IO_CAP
innodb_io_capacity_max = $IO_CAP_MAX
innodb_read_io_threads = $IO_THREADS
innodb_write_io_threads = $IO_THREADS
innodb_open_files = 4000
innodb_numa_interleave = $([[ $NUMA_NODES -gt 1 ]] && echo ON || echo OFF)

$BINLOG_CFG
EOF

# OS settings recommended for database servers
cat > /etc/sysctl.d/90-parmaham.conf <<EOF
vm.swappiness = 1
EOF
sysctl -q -p /etc/sysctl.d/90-parmaham.conf || true

cat > /etc/systemd/system/parmaham-thp.service <<EOF
[Unit]
Description=Parma Ham: disable transparent huge pages (recommended for MySQL)
Before=$SERVICE.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled; echo never > /sys/kernel/mm/transparent_hugepage/defrag'

[Install]
WantedBy=multi-user.target
EOF
install -d "/etc/systemd/system/$SERVICE.service.d"
cat > "/etc/systemd/system/$SERVICE.service.d/parmaham.conf" <<EOF
[Service]
LimitNOFILE=1048576
Restart=on-failure
EOF
systemctl daemon-reload
systemctl enable --now parmaham-thp.service &>/dev/null || warn "could not disable transparent huge pages"

log "restarting $SERVICE"
systemctl restart "$SERVICE"
wait_for_mysql

# ---------------------------------------------------------------------------
# 3. Accounts for HammerDB and the dashboard
# ---------------------------------------------------------------------------
if [[ -r $MYSQL_BENCH_CNF ]]; then
    BENCH_PASS=$(cnf_value "$MYSQL_BENCH_CNF" password)
else
    BENCH_PASS=$(random_password)
fi
if [[ -r $MYSQL_MONITOR_CNF ]]; then
    MON_PASS=$(cnf_value "$MYSQL_MONITOR_CNF" password)
else
    MON_PASS=$(random_password)
fi
mysql_admin <<EOF
CREATE USER IF NOT EXISTS '$MYSQL_BENCH_USER'@'localhost' IDENTIFIED BY '$BENCH_PASS';
ALTER USER '$MYSQL_BENCH_USER'@'localhost' IDENTIFIED BY '$BENCH_PASS';
GRANT ALL ON \`$MYSQL_BENCH_DB\`.* TO '$MYSQL_BENCH_USER'@'localhost';
GRANT PROCESS ON *.* TO '$MYSQL_BENCH_USER'@'localhost';
CREATE USER IF NOT EXISTS '$MYSQL_MONITOR_USER'@'localhost' IDENTIFIED BY '$MON_PASS';
ALTER USER '$MYSQL_MONITOR_USER'@'localhost' IDENTIFIED BY '$MON_PASS';
GRANT PROCESS, REPLICATION CLIENT ON *.* TO '$MYSQL_MONITOR_USER'@'localhost';
GRANT SELECT ON performance_schema.* TO '$MYSQL_MONITOR_USER'@'localhost';
GRANT SELECT ON \`$MYSQL_BENCH_DB\`.* TO '$MYSQL_MONITOR_USER'@'localhost';
EOF
write_client_cnf "$MYSQL_BENCH_CNF" "$MYSQL_BENCH_USER" "$BENCH_PASS" "$PMH_USER" 0640
write_client_cnf "$MYSQL_MONITOR_CNF" "$MYSQL_MONITOR_USER" "$MON_PASS" root 0600

VERSION=$(mysql_admin -NBe 'SELECT VERSION()')
log "Percona Server $VERSION is running (buffer pool ${BP_MB}MB, redo ${REDO_MB}MB, io_capacity $IO_CAP)"
[[ $FRESH_INSTALL == 1 ]] && log "root credentials are in $MYSQL_ADMIN_CNF (linked from /root/.my.cnf)"
log "next step: $(dirname "$0")/database-generate.sh"
