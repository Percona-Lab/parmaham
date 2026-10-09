#!/usr/bin/env bash
# Install PostgreSQL from the PostgreSQL community repository (PGDG) and tune
# it for this node's size.
#
# Usage: database-install.sh [--version 18] [--shared-buffers-pct 25]
#                            [--synchronous-commit on|off]
#
#   --version             PostgreSQL major version (default 18)
#   --shared-buffers-pct  shared_buffers as a share of RAM (default 25)
#   --synchronous-commit  on = durable commits (default), off = commits do
#                         not wait for the WAL flush
#
# Safe to re-run: an existing installation is kept and only the tuning file
# is regenerated (and the server restarted).
source "$(dirname "$0")/../common/lib.sh"

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

require_root
load_config
load_db
while (($#)); do
    case $1 in
        --version)            conf_set PG_VERSION "$2"; shift 2 ;;
        --shared-buffers-pct) conf_set PG_SHARED_BUFFERS_PCT "$2"; shift 2 ;;
        --synchronous-commit) conf_set PG_SYNCHRONOUS_COMMIT "$2"; shift 2 ;;
        -h|--help)            usage ;;
        *) warn "unknown option $1"; usage 1 ;;
    esac
done
[[ $PG_VERSION =~ ^[0-9]+$ ]] || die "--version must be a major version such as 18"

FAMILY=$(os_family)
SERVICE=$(db_service)
claim_database postgresql
install_payload

# ---------------------------------------------------------------------------
# 1. Packages
# ---------------------------------------------------------------------------
base_packages

FRESH_INSTALL=0
if [[ ! -x $(pg_bindir)/postgres ]]; then
    FRESH_INSTALL=1
    log "installing PostgreSQL $PG_VERSION from the PGDG repository"
    case $FAMILY in
        debian)
            pkg_install postgresql-common
            /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
            # creates and starts the cluster $PG_VERSION/main
            pkg_install "postgresql-$PG_VERSION" "postgresql-client-$PG_VERSION"
            ;;
        rhel)
            # shellcheck disable=SC1091
            . /etc/os-release
            rpm -q pgdg-redhat-repo &>/dev/null || dnf install -y -q \
                "https://download.postgresql.org/pub/repos/yum/reporpms/EL-${VERSION_ID%%.*}-$(uname -m)/pgdg-redhat-repo-latest.noarch.rpm"
            dnf -qy module disable postgresql 2>/dev/null || true
            pkg_install "postgresql$PG_VERSION-server" "postgresql$PG_VERSION-contrib"
            "$(pg_bindir)/postgresql-$PG_VERSION-setup" initdb
            # local TCP connections authenticate with passwords (default: ident)
            sed -i -E 's/^(host\s+all\s+all\s+\S+\s+)ident/\1scram-sha-256/' "/var/lib/pgsql/$PG_VERSION/data/pg_hba.conf"
            ;;
    esac
else
    log "PostgreSQL $PG_VERSION is already installed"
fi

systemctl enable "$SERVICE" &>/dev/null
systemctl start "$SERVICE"
db_wait
DATADIR=$(pg_local -At -c 'SHOW data_directory')
CONFFILE=$(pg_local -At -c 'SHOW config_file')

pg_set_admin_password

# ---------------------------------------------------------------------------
# 2. Tuning for this node
# ---------------------------------------------------------------------------
case $FAMILY in
    # Debian's postgresql.conf includes conf.d/
    debian) CNF="$(dirname "$CONFFILE")/conf.d/zz-parmaham.conf" ;;
    rhel)   CNF="$DATADIR/zz-parmaham.conf"
            grep -q "^include_if_exists = 'zz-parmaham.conf'" "$CONFFILE" \
                || echo "include_if_exists = 'zz-parmaham.conf'" >> "$CONFFILE" ;;
esac
pg_write_tuning "$CNF" "$DATADIR"

install_os_tuning "$SERVICE"
log "restarting $SERVICE"
systemctl restart "$SERVICE"
db_wait

# ---------------------------------------------------------------------------
# 3. Accounts for HammerDB and the dashboard
# ---------------------------------------------------------------------------
pg_create_accounts

log "PostgreSQL $(db_admin 'SHOW server_version') is running (shared_buffers ${SB_MB}MB, max_wal_size ${WAL_MB}MB)"
[[ $FRESH_INSTALL == 1 ]] && log "superuser credentials are in $PG_ADMIN_CNF"
log "next step: $(dirname "$0")/database-generate.sh"
