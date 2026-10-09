#!/usr/bin/env bash
# Install pgrust (a PostgreSQL rewrite in Rust, https://github.com/malisper/pgrust)
# and tune it for this node's size.
#
# Usage: database-install.sh [--version 0.3] [--shared-buffers-pct 25]
#                            [--synchronous-commit on|off]
#
#   --version             pgrust release to download from pgrust.com (default 0.3)
#   --shared-buffers-pct  shared_buffers as a share of RAM (default 25)
#   --synchronous-commit  on = durable commits (default), off = no WAL flush wait
#
# pgrust has no initdb or psql of its own: PostgreSQL's client tools, initdb
# and share files come from the PGDG packages (PG_VERSION, default 18; no
# PostgreSQL cluster is created). The server runs as pgrust.service on a
# cluster in /var/lib/pgrust/data. pgrust says it is not ready for production
# yet; it loads only its own ports of contrib modules, and tunes its JIT for
# AWS Graviton4.
#
# Safe to re-run: the binary is kept while the version is unchanged, and the
# tuning file is regenerated (and the server restarted).
source "$(dirname "$0")/../common/lib.sh"

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

require_root
load_config
while (($#)); do
    case $1 in
        --version)            conf_set PGRUST_VERSION "$2"; shift 2 ;;
        --shared-buffers-pct) conf_set PG_SHARED_BUFFERS_PCT "$2"; shift 2 ;;
        --synchronous-commit) conf_set PG_SYNCHRONOUS_COMMIT "$2"; shift 2 ;;
        -h|--help)            usage ;;
        *) warn "unknown option $1"; usage 1 ;;
    esac
done
load_db
[[ $(os_family) == debian ]] || die "the pgrust installer supports Debian and Ubuntu only for now"
case $(uname -m) in
    x86_64)  PLATFORM=linux-x86_64 ;;
    aarch64) PLATFORM=linux-aarch64 ;;
    *) die "pgrust has no binary for $(uname -m)" ;;
esac

SERVICE=$(db_service)
claim_database pgrust
install_payload
base_packages

# ---------------------------------------------------------------------------
# 1. PostgreSQL client tools, then pgrust
# ---------------------------------------------------------------------------
if [[ ! -x $(pg_bindir)/initdb ]]; then
    log "installing PostgreSQL $PG_VERSION client tools and initdb from PGDG (no cluster)"
    pkg_install postgresql-common
    # the server package would otherwise create and start a PostgreSQL cluster
    install -d /etc/postgresql-common/createcluster.d
    echo "create_main_cluster = false" > /etc/postgresql-common/createcluster.d/parmaham.conf
    /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
    pkg_install "postgresql-$PG_VERSION" "postgresql-client-$PG_VERSION"
fi

BIN=$PGRUST_HOME/$PGRUST_VERSION/pgrust
if [[ ! -x $BIN ]]; then
    url=https://pgrust.com/downloads/v$PGRUST_VERSION/pgrust-$PGRUST_VERSION-$PLATFORM
    log "downloading pgrust $PGRUST_VERSION from $url"
    install -d "$PGRUST_HOME/$PGRUST_VERSION"
    curl -fsSL -o "$BIN.tmp" "$url"
    want=$(curl -fsSL "$url.sha256" | awk '{print $1}')
    [[ $(sha256sum "$BIN.tmp" | awk '{print $1}') == "$want" ]] || { rm -f "$BIN.tmp"; die "checksum mismatch for $url"; }
    chmod 0755 "$BIN.tmp"; mv "$BIN.tmp" "$BIN"
fi
# the process is called pgrust (dashboard: server CPU and memory)
install -d "$PGRUST_HOME/bin"
ln -sfn "$BIN" "$PGRUST_HOME/bin/pgrust"

# ---------------------------------------------------------------------------
# 2. Cluster and service
# ---------------------------------------------------------------------------
install -d -o postgres -g postgres -m 0700 "$PGRUST_DATADIR"
FRESH_INSTALL=0
if [[ ! -f $PGRUST_DATADIR/PG_VERSION ]]; then
    FRESH_INSTALL=1
    log "creating the cluster in $PGRUST_DATADIR with PostgreSQL $PG_VERSION's initdb"
    (cd / && runuser -u postgres -- "$(pg_bindir)/initdb" -D "$PGRUST_DATADIR" \
        --no-locale --encoding=UTF8 -U postgres --auth-local=peer --auth-host=scram-sha-256 >/dev/null)
fi
grep -q "^include_if_exists = 'zz-parmaham.conf'" "$PGRUST_DATADIR/postgresql.conf" \
    || echo "include_if_exists = 'zz-parmaham.conf'" >> "$PGRUST_DATADIR/postgresql.conf"
pg_write_tuning "$PGRUST_DATADIR/zz-parmaham.conf" "$PGRUST_DATADIR"

cat > "/etc/systemd/system/$SERVICE.service" <<EOF
[Unit]
Description=pgrust $PGRUST_VERSION
After=network.target

[Service]
User=postgres
Group=postgres
# PostgreSQL's share files (time zones, ...) and the stack pgrust's quick start asks for
Environment=PGRUST_PGSHAREDIR=/usr/share/postgresql/$PG_VERSION PGRUST_TZDIR=/usr/share/zoneinfo RUST_MIN_STACK=33554432
LimitSTACK=67076096
RuntimeDirectory=postgresql
RuntimeDirectoryPreserve=yes
ExecStart=$PGRUST_HOME/bin/pgrust -D $PGRUST_DATADIR -p ${PG_PORT:-5432}
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=mixed
KillSignal=SIGINT
TimeoutSec=infinity
OOMScoreAdjust=-900

[Install]
WantedBy=multi-user.target
EOF
install_os_tuning "$SERVICE"
systemctl enable "$SERVICE" &>/dev/null
log "restarting $SERVICE"
systemctl restart "$SERVICE"
db_wait

# ---------------------------------------------------------------------------
# 3. Accounts for HammerDB and the dashboard
# ---------------------------------------------------------------------------
pg_set_admin_password
pg_create_accounts

log "pgrust $PGRUST_VERSION is running: $(db_admin 'SELECT version()') (shared_buffers ${SB_MB}MB, max_wal_size ${WAL_MB}MB)"
[[ $FRESH_INSTALL == 1 ]] && log "superuser credentials are in $PG_ADMIN_CNF"
log "next step: $(dirname "$0")/database-generate.sh"
