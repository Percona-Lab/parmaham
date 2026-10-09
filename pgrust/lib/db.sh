# shellcheck shell=bash
# Database plug-in for pgrust, a PostgreSQL rewrite in Rust (one server
# process with threads). It runs on a data directory created by PostgreSQL's
# initdb, and uses PostgreSQL's client tools and share files from PGDG.
# Built on the PostgreSQL plug-in (postgresql/lib/db.sh).

DB_LABEL=pgrust
# pgrust loads no third-party PostgreSQL extensions, but bundles ports of
# contrib modules including pg_stat_statements and pg_buffercache: the same
# preload as PostgreSQL
# shellcheck disable=SC1091
source "$PMH_SRC/postgresql/lib/db.sh"

PGRUST_HOME=/opt/pgrust
PGRUST_DATADIR=/var/lib/pgrust/data

db_service()      { echo pgrust; }
db_procmem_spec() { echo "pgrust=pgrust.service+pgrust"; }
# pg_bindir: PGDG PostgreSQL's client tools (psql, initdb, pg_isready)

# settings from pgrust's quick start
pg_extra_conf() {
    cat <<EOF
# pgrust: synchronous I/O and a deep stack, as its quick start recommends
io_method = sync
max_stack_depth = 60000
unix_socket_directories = '/var/run/postgresql'
EOF
}
