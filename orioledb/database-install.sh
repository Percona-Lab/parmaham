#!/usr/bin/env bash
# Install OrioleDB (PostgreSQL with OrioleDB's patches plus the orioledb
# extension, built from source) and tune it for this node's size.
#
# Usage: database-install.sh [--version beta19] [--pg-major 18]
#                            [--shared-buffers-pct 25] [--synchronous-commit on|off]
#
#   --version             OrioleDB release, a tag of github.com/orioledb/orioledb
#                         (default beta19)
#   --pg-major            PostgreSQL major version to build with it (default 18;
#                         the release's .pgtags lists the supported ones)
#   --shared-buffers-pct  memory share for OrioleDB's buffer pool (default 25)
#   --synchronous-commit  on = durable commits (default), off = no WAL flush wait
#
# Builds into /opt/orioledb/<major> (about 15 minutes on 2 vCPUs), creates a
# cluster in /var/lib/orioledb/<major>/data with the C locale (OrioleDB tables
# need ICU, C, POSIX or builtin collations) and runs it as orioledb.service.
# Every new table uses OrioleDB (default_table_access_method).
#
# Safe to re-run: the build is reused while the version is unchanged, and the
# tuning file is regenerated (and the server restarted).
source "$(dirname "$0")/../common/lib.sh"

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

require_root
load_config
while (($#)); do
    case $1 in
        --version)            conf_set ORIOLEDB_VERSION "$2"; shift 2 ;;
        --pg-major)           conf_set ORIOLEDB_PG_MAJOR "$2"; shift 2 ;;
        --shared-buffers-pct) conf_set PG_SHARED_BUFFERS_PCT "$2"; shift 2 ;;
        --synchronous-commit) conf_set PG_SYNCHRONOUS_COMMIT "$2"; shift 2 ;;
        -h|--help)            usage ;;
        *) warn "unknown option $1"; usage 1 ;;
    esac
done
# the version and major version decide the paths
load_db
[[ $(os_family) == debian ]] || die "the OrioleDB installer supports Debian and Ubuntu only for now"

SERVICE=$(db_service)
claim_database orioledb
install_payload
base_packages

# ---------------------------------------------------------------------------
# 1. Build
# ---------------------------------------------------------------------------
STAMP=$ORIOLEDB_PREFIX/PARMAHAM_ORIOLEDB_VERSION
if [[ $(cat "$STAMP" 2>/dev/null) != "$ORIOLEDB_VERSION" ]]; then
    log "installing build dependencies"
    pkg_install build-essential git bison flex pkg-config libreadline-dev zlib1g-dev \
        libzstd-dev liblz4-dev libicu-dev libssl-dev libxml2-dev libsystemd-dev libcurl4-openssl-dev
    SRC=/opt/orioledb/src
    rm -rf "$SRC"; install -d "$SRC"
    log "fetching OrioleDB $ORIOLEDB_VERSION"
    git clone -q --depth 1 --branch "$ORIOLEDB_VERSION" https://github.com/orioledb/orioledb "$SRC/orioledb"
    # .pgtags pins the patched PostgreSQL each OrioleDB release builds against
    PGTAG=$(awk -F': *' -v m="$ORIOLEDB_PG_MAJOR" '$1 == m {print $2}' "$SRC/orioledb/.pgtags")
    [[ -n $PGTAG ]] || die "OrioleDB $ORIOLEDB_VERSION does not support PostgreSQL $ORIOLEDB_PG_MAJOR ($(tr '\n' ' ' < "$SRC/orioledb/.pgtags"))"
    log "building PostgreSQL with OrioleDB patches ($PGTAG) into $ORIOLEDB_PREFIX"
    git clone -q --depth 1 --branch "$PGTAG" https://github.com/orioledb/postgres "$SRC/postgres"
    (
        cd "$SRC/postgres"
        ./configure -q --prefix="$ORIOLEDB_PREFIX" --with-icu --with-lz4 --with-zstd \
            --with-openssl --with-libxml --with-systemd
        make -s -j"$(cpu_count)"
        make -s install
        make -s -C contrib -j"$(cpu_count)" install
    ) > "$PMH_LOG/orioledb-build.log" 2>&1 || die "PostgreSQL build failed (see $PMH_LOG/orioledb-build.log)"
    log "building the orioledb extension"
    (
        cd "$SRC/orioledb"
        make -s USE_PGXS=1 PG_CONFIG="$ORIOLEDB_PREFIX/bin/pg_config" -j"$(cpu_count)"
        make -s USE_PGXS=1 PG_CONFIG="$ORIOLEDB_PREFIX/bin/pg_config" install
    ) >> "$PMH_LOG/orioledb-build.log" 2>&1 || die "orioledb build failed (see $PMH_LOG/orioledb-build.log)"
    echo "$ORIOLEDB_VERSION" > "$STAMP"
    rm -rf "$SRC"
    log "OrioleDB $ORIOLEDB_VERSION built: $("$ORIOLEDB_PREFIX/bin/postgres" --version)"
else
    log "OrioleDB $ORIOLEDB_VERSION is already built in $ORIOLEDB_PREFIX"
fi
# client tools on root's PATH
echo "export PATH=$ORIOLEDB_PREFIX/bin:\$PATH" > /etc/profile.d/orioledb.sh

# ---------------------------------------------------------------------------
# 2. Cluster and service
# ---------------------------------------------------------------------------
id postgres &>/dev/null || useradd --system --home-dir /var/lib/orioledb --shell /bin/bash postgres
install -d -o postgres -g postgres -m 0700 "$ORIOLEDB_DATADIR"
FRESH_INSTALL=0
if [[ ! -f $ORIOLEDB_DATADIR/PG_VERSION ]]; then
    FRESH_INSTALL=1
    log "creating the cluster in $ORIOLEDB_DATADIR"
    (cd / && runuser -u postgres -- "$ORIOLEDB_PREFIX/bin/initdb" -D "$ORIOLEDB_DATADIR" \
        --locale=C --encoding=UTF8 -U postgres --auth-local=peer --auth-host=scram-sha-256 >/dev/null)
fi
grep -q "^include_if_exists = 'zz-parmaham.conf'" "$ORIOLEDB_DATADIR/postgresql.conf" \
    || echo "include_if_exists = 'zz-parmaham.conf'" >> "$ORIOLEDB_DATADIR/postgresql.conf"
pg_write_tuning "$ORIOLEDB_DATADIR/zz-parmaham.conf" "$ORIOLEDB_DATADIR"

cat > "/etc/systemd/system/$SERVICE.service" <<EOF
[Unit]
Description=OrioleDB $ORIOLEDB_VERSION (PostgreSQL $ORIOLEDB_PG_MAJOR)
After=network.target

[Service]
Type=notify
User=postgres
Group=postgres
ExecStart=$ORIOLEDB_PREFIX/bin/postgres -D $ORIOLEDB_DATADIR
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

# HammerDB creates the benchmark database from template1: with the extension
# there, the database has it too
for d in template1 postgres; do
    pg_local -d "$d" -c "CREATE EXTENSION IF NOT EXISTS orioledb" >/dev/null
done

# ---------------------------------------------------------------------------
# 3. Accounts for HammerDB and the dashboard
# ---------------------------------------------------------------------------
pg_set_admin_password
pg_create_accounts

log "OrioleDB $ORIOLEDB_VERSION on PostgreSQL $(db_admin 'SHOW server_version') is running (orioledb.main_buffers ${SB_MB}MB, max_wal_size ${WAL_MB}MB)"
[[ $FRESH_INSTALL == 1 ]] && log "superuser credentials are in $PG_ADMIN_CNF"
log "next step: $(dirname "$0")/database-generate.sh"
