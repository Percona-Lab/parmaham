#!/usr/bin/env bash
# Generate the HammerDB TPROC-C database.
# Run it as <database>/database-generate.sh (mysql/, mariadb/ or postgresql/).
#
# Usage: database-generate.sh [--warehouses 200] [--vu N] [--partition true|false] [--force]
#
#   --warehouses  number of warehouses (default 200)
#   --vu          virtual users used to load data (default: number of CPUs)
#   --partition   partition order_line (HammerDB option, useful above ~200 warehouses)
#   --force       drop an existing schema first (stops the workload service)
source "$(dirname "$0")/../common/lib.sh"

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

require_root
load_config
load_db
FORCE=0
while (($#)); do
    case $1 in
        --warehouses) conf_set WAREHOUSES "$2"; shift 2 ;;
        --vu)         conf_set BUILD_VU "$2"; shift 2 ;;
        --partition)  conf_set PARTITION "$2"; shift 2 ;;
        --force)      FORCE=1; shift ;;
        -h|--help)    usage ;;
        *) warn "unknown option $1"; usage 1 ;;
    esac
done
[[ $WAREHOUSES =~ ^[0-9]+$ && $WAREHOUSES -gt 0 ]] || die "invalid warehouse count: $WAREHOUSES"

install_payload
install_hammerdb
hdb_env

if db_schema_exists; then
    if [[ $FORCE == 1 ]]; then
        if systemctl is-active -q parmaham-workload.service; then
            log "stopping parmaham-workload.service"
            systemctl stop parmaham-workload.service
        fi
        log "dropping existing database $PMH_DB_NAME"
        db_drop_schema
    else
        die "database $PMH_DB_NAME already exists; use --force to drop and regenerate it"
    fi
fi

BUILD_VU_EFF=$BUILD_VU
(( BUILD_VU_EFF > 0 )) || BUILD_VU_EFF=$(cpu_count)
(( BUILD_VU_EFF <= WAREHOUSES )) || BUILD_VU_EFF=$WAREHOUSES

export PMH_WAREHOUSES=$WAREHOUSES PMH_BUILD_VU=$BUILD_VU_EFF PMH_PARTITION=$PARTITION
LOGFILE=$PMH_LOG/generate.log
log "building $WAREHOUSES warehouses with $BUILD_VU_EFF virtual users (log: $LOGFILE)"
START=$(date +%s)
hammerdb_cli hdb-build.tcl 2>&1 | tee "$LOGFILE" | grep -E --line-buffered 'PARMAHAM|FINISHED|Error|error' || true

BUILT=$(db_bench "SELECT COUNT(*) FROM warehouse" 2>/dev/null || echo 0)
[[ $BUILT == "$WAREHOUSES" ]] || die "schema build failed: expected $WAREHOUSES warehouses, found $BUILT (see $LOGFILE)"
grep -qE '(TPCC|HAMMERDB) SCHEMA COMPLETE' "$LOGFILE" || die "schema build did not complete (see $LOGFILE)"

db_after_build
SIZE_MB=$(db_schema_size_mb)
json_kv db "$PMH_DB" warehouses "$WAREHOUSES" build_vu "$BUILD_VU_EFF" partition "$PARTITION" \
        created_at "$(date -u +%FT%TZ)" build_seconds "$(( $(date +%s) - START ))" size_mb "$SIZE_MB" \
    | write_atomic "$PMH_STATE/schema.json"

if [[ -f $PMH_STATE/capacity.json ]]; then
    mv "$PMH_STATE/capacity.json" "$PMH_STATE/capacity.json.old"
    warn "previous capacity measurement no longer applies and was moved to capacity.json.old"
fi
log "schema ready: $WAREHOUSES warehouses, ${SIZE_MB} MB in $(( $(date +%s) - START ))s"
log "next step: $(dirname "$0")/compute-capacity.sh"
