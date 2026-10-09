# shellcheck shell=bash
# Database plug-in for OrioleDB: PostgreSQL with OrioleDB's patches, built
# from source, and the orioledb extension as the default table access
# method. Built on the PostgreSQL plug-in (postgresql/lib/db.sh).

DB_LABEL=OrioleDB
# the dashboard's statement counts as on PostgreSQL
PG_PRELOAD="orioledb,pg_stat_statements"
# shellcheck disable=SC1091
source "$PMH_SRC/postgresql/lib/db.sh"

ORIOLEDB_PREFIX=/opt/orioledb/$ORIOLEDB_PG_MAJOR
ORIOLEDB_DATADIR=/var/lib/orioledb/$ORIOLEDB_PG_MAJOR/data

db_service()      { echo orioledb; }
pg_bindir()       { echo "$ORIOLEDB_PREFIX/bin"; }
db_procmem_spec() { echo "postgres=orioledb.service+postgres"; }

# HammerDB's PostgreSQL driver (Pgtcl) loads libpq.so.5, which the source
# build installs outside the library path: link it into HammerDB's private
# library directory
db_hammerdb_libs() {
    install -d "$1"
    ln -sfn "$ORIOLEDB_PREFIX/lib/libpq.so.5" "$1/libpq.so.5"
}

# OrioleDB tables keep their pages in OrioleDB's own buffer pool
# (orioledb.main_buffers); shared_buffers then only holds the system catalogs,
# so the memory PostgreSQL would give shared_buffers goes to main_buffers.
pg_extra_conf() {
    cat <<EOF
# OrioleDB: every new table uses the orioledb access method
default_table_access_method = 'orioledb'
orioledb.main_buffers = ${SB_MB}MB
shared_buffers = 256MB
EOF
}
