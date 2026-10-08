#!/usr/bin/env bash
# Delete HammerDB data older than PURGE_RETENTION_HOURS.
# Run by parmaham-purge.timer (see install-hammerdb-purge.sh).
source "$(dirname "$0")/lib.sh"

load_config
load_db
LOCK=$PMH_STATE/purge.lock
exec 9> "$LOCK"
flock -n 9 || { log "previous purge still running, skipping"; exit 0; }

log "purging data older than ${PURGE_RETENTION_HOURS}h"
db_purge_run "$PURGE_RETENTION_HOURS" "$PURGE_BATCH"
