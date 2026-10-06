#!/usr/bin/env bash
# Delete HammerDB data older than PURGE_RETENTION_HOURS.
# Run by parmaham-purge.timer (see install-hammerdb-purge.sh).
source "$(dirname "$0")/../../common/lib.sh"
source "$(dirname "$0")/mysql.sh"

load_config
LOCK=$PMH_STATE/purge.lock
exec 9> "$LOCK"
flock -n 9 || { log "previous purge still running, skipping"; exit 0; }

log "purging data older than ${PURGE_RETENTION_HOURS}h"
# READ COMMITTED avoids gap locks that could block HammerDB inserts
mysql_bench -t -e "SET SESSION transaction_isolation = 'READ-COMMITTED';
                   CALL parmaham_purge($PURGE_RETENTION_HOURS, $PURGE_BATCH);"
