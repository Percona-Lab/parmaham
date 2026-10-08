#!/usr/bin/env bash
# Install MySQL (Percona Server by default) and tune it for this node's size.
#
# Usage: database-install.sh [--flavor percona|community] [--repo REPO]
#                            [--buffer-pool-pct 60] [--binlog 0|1]
#                            [--flush-log-at-trx-commit 1|2]
#
#   --flavor  percona   Percona Server for MySQL (default)
#             community Oracle MySQL Community Server from repo.mysql.com
#   --repo    percona:   percona-release repository (default ps-97-lts)
#             community: repo.mysql.com series, mysql-9.7-lts (default) or
#                        mysql-innovation for the newest release
#
# Safe to re-run: an existing installation is kept and only the tuning file
# is regenerated (and the server restarted).
source "$(dirname "$0")/../common/lib.sh"

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

require_root
load_config
load_db
REPO_ARG=""
while (($#)); do
    case $1 in
        --flavor)                  conf_set MYSQL_FLAVOR "$2"; shift 2 ;;
        --repo)                    REPO_ARG=$2; shift 2 ;;
        --buffer-pool-pct)         conf_set MYSQL_BUFFER_POOL_PCT "$2"; shift 2 ;;
        --binlog)                  conf_set MYSQL_BINLOG "$2"; shift 2 ;;
        --flush-log-at-trx-commit) conf_set MYSQL_FLUSH_LOG_AT_TRX_COMMIT "$2"; shift 2 ;;
        -h|--help)                 usage ;;
        *) warn "unknown option $1"; usage 1 ;;
    esac
done
case $MYSQL_FLAVOR in
    percona)   [[ -z $REPO_ARG ]] || conf_set PS_REPO "$REPO_ARG" ;;
    community) [[ -z $REPO_ARG ]] || conf_set MYSQL_COMMUNITY_REPO "$REPO_ARG" ;;
    *) die "--flavor must be percona or community" ;;
esac

FAMILY=$(os_family)
SERVICE=$(db_service)
claim_database mysql
install_payload

# ---------------------------------------------------------------------------
# 1. Packages
# ---------------------------------------------------------------------------
install_percona_release() {
    command -v percona-release &>/dev/null && return
    log "installing percona-release"
    case $FAMILY in
        debian)
            curl -fsSL -o /tmp/percona-release.deb https://repo.percona.com/apt/percona-release_latest.generic_all.deb
            pkg_install /tmp/percona-release.deb
            rm -f /tmp/percona-release.deb
            ;;
        rhel)
            dnf install -y -q https://repo.percona.com/yum/percona-release-latest.noarch.rpm
            ;;
    esac
}

# Oracle's repository for one release series (mysql-9.7-lts, mysql-innovation)
install_mysql_community_repo() {
    local series=$MYSQL_COMMUNITY_REPO key=/usr/share/keyrings/mysql-community.gpg
    log "enabling the repo.mysql.com repository $series"
    case $FAMILY in
        debian)
            # shellcheck disable=SC1091
            . /etc/os-release
            curl -fsSL https://repo.mysql.com/RPM-GPG-KEY-mysql-2025 | gpg --dearmor --yes -o "$key"
            echo "deb [signed-by=$key] http://repo.mysql.com/apt/$ID $VERSION_CODENAME $series mysql-tools" \
                > /etc/apt/sources.list.d/mysql-community.list
            apt-get update -q
            ;;
        rhel)
            # mysqlNN-community-release-el9.rpm: NN is any current series; it
            # defines every series, and only the requested one is enabled
            rpm -q mysql97-community-release &>/dev/null \
                || dnf install -y -q https://repo.mysql.com/mysql97-community-release-el9.rpm
            dnf config-manager --disable 'mysql*-community' 'mysql-innovation-community' &>/dev/null || true
            case $series in
                mysql-innovation) dnf config-manager --enable mysql-innovation-community ;;
                mysql-*-lts)      dnf config-manager --enable "mysql$(tr -dc 0-9 <<< "$series")-lts-community" ;;
                *) die "unknown repo.mysql.com series $series" ;;
            esac
            dnf config-manager --enable mysql-tools-community &>/dev/null || true
            ;;
    esac
}

base_packages

FRESH_INSTALL=0
if ! command -v mysqld &>/dev/null; then
    FRESH_INSTALL=1
    ROOT_PASS=$(random_password)
    if [[ $MYSQL_FLAVOR == percona ]]; then
        install_percona_release
        log "enabling Percona repository $PS_REPO"
        percona-release enable-only "$PS_REPO" release
        PKGS=(percona-server-server percona-server-client) DEBCONF=percona-server-server
    else
        install_mysql_community_repo
        PKGS=(mysql-community-server mysql-community-client) DEBCONF=mysql-community-server
    fi
    case $FAMILY in
        debian)
            apt-get update -q
            debconf-set-selections <<EOF
$DEBCONF $DEBCONF/root-pass password $ROOT_PASS
$DEBCONF $DEBCONF/re-root-pass password $ROOT_PASS
EOF
            log "installing ${PKGS[*]}"
            pkg_install "${PKGS[@]}"
            ;;
        rhel)
            dnf module disable -y -q mysql 2>/dev/null || true
            log "installing ${PKGS[*]}"
            pkg_install "${PKGS[@]}"
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
db_wait
MYSQL_SOCKET=$(db_admin 'SELECT @@socket')
DATADIR=$(db_admin 'SELECT @@datadir')
conf_set MYSQL_SOCKET "$MYSQL_SOCKET"
# rewrite admin cnf with the socket path
write_client_cnf "$MYSQL_ADMIN_CNF" "$(cnf_value "$MYSQL_ADMIN_CNF" user)" "$(cnf_value "$MYSQL_ADMIN_CNF" password)" root 0600

# ---------------------------------------------------------------------------
# 2. Tuning for this node
# ---------------------------------------------------------------------------
mysql_sizing "$DATADIR"

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
innodb_numa_interleave = $([[ $(numa_nodes) -gt 1 ]] && echo ON || echo OFF)

$BINLOG_CFG
EOF

install_os_tuning "$SERVICE"
log "restarting $SERVICE"
systemctl restart "$SERVICE"
db_wait

# ---------------------------------------------------------------------------
# 3. Accounts for HammerDB and the dashboard
# ---------------------------------------------------------------------------
mysql_create_accounts "GRANT PROCESS, REPLICATION CLIENT ON *.* TO '$MYSQL_MONITOR_USER'@'localhost';
GRANT SELECT ON performance_schema.* TO '$MYSQL_MONITOR_USER'@'localhost';"

log "$(db_admin 'SELECT CONCAT(@@version_comment, " ", VERSION())') is running (buffer pool ${BP_MB}MB, redo ${REDO_MB}MB, io_capacity $IO_CAP)"
[[ $FRESH_INSTALL == 1 ]] && log "root credentials are in $MYSQL_ADMIN_CNF (linked from /root/.my.cnf)"
log "next step: $(dirname "$0")/database-generate.sh"
