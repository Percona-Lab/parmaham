#!/usr/bin/env bash
# Generate the HammerDB TPROC-C database.
#
# Usage: database-generate.sh [--warehouses 200] [--vu N] [--partition true|false] [--force]
#
#   --warehouses  number of warehouses (default 200)
#   --vu          virtual users used to load data (default: number of CPUs)
#   --partition   partition order_line (HammerDB option, useful above ~200 warehouses)
#   --force       drop an existing schema first (stops the workload service)
source "$(dirname "$0")/../common/lib.sh"
source "$(dirname "$0")/lib/mysql.sh"

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

require_root
load_config
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

if mysql_admin -NBe "SHOW DATABASES LIKE '$MYSQL_BENCH_DB'" | grep -q .; then
    if [[ $FORCE == 1 ]]; then
        if systemctl is-active -q parmaham-workload.service; then
            log "stopping parmaham-workload.service"
            systemctl stop parmaham-workload.service
        fi
        log "dropping existing database $MYSQL_BENCH_DB"
        mysql_admin -e "DROP DATABASE \`$MYSQL_BENCH_DB\`"
    else
        die "database $MYSQL_BENCH_DB already exists; use --force to drop and regenerate it"
    fi
fi

BUILD_VU_EFF=$BUILD_VU
(( BUILD_VU_EFF > 0 )) || BUILD_VU_EFF=$(cpu_count)
(( BUILD_VU_EFF <= WAREHOUSES )) || BUILD_VU_EFF=$WAREHOUSES

export PMH_WAREHOUSES=$WAREHOUSES PMH_BUILD_VU=$BUILD_VU_EFF PMH_PARTITION=$PARTITION
LOGFILE=$PMH_LOG/generate.log
log "building $WAREHOUSES warehouses with $BUILD_VU_EFF virtual users (log: $LOGFILE)"
START=$(date +%s)
hammerdb_cli "$PMH_HOME/mysql/lib/hdb-build.tcl" 2>&1 | tee "$LOGFILE" | grep -E --line-buffered 'PARMAHAM|FINISHED|Error|error' || true

BUILT=$(mysql_bench -NBe "SELECT COUNT(*) FROM warehouse" 2>/dev/null || echo 0)
[[ $BUILT == "$WAREHOUSES" ]] || die "schema build failed: expected $WAREHOUSES warehouses, found $BUILT (see $LOGFILE)"
grep -q 'TPCC SCHEMA COMPLETE' "$LOGFILE" || die "schema build did not complete (see $LOGFILE)"

# HammerDB creates history.id as INT; a permanent run would exhaust it, so
# widen it to BIGINT. The purge job deletes history rows by this key.
log "widening history.id to BIGINT"
mysql_bench -e "ALTER TABLE history MODIFY id BIGINT NOT NULL AUTO_INCREMENT INVISIBLE"

SIZE_MB=$(mysql_admin -NBe "SELECT ROUND(SUM(data_length+index_length)/1048576) FROM information_schema.tables WHERE table_schema='$MYSQL_BENCH_DB'")
json_kv warehouses "$WAREHOUSES" build_vu "$BUILD_VU_EFF" partition "$PARTITION" \
        created_at "$(date -u +%FT%TZ)" build_seconds "$(( $(date +%s) - START ))" size_mb "$SIZE_MB" \
    | write_atomic "$PMH_STATE/schema.json"

if [[ -f $PMH_STATE/capacity.json ]]; then
    mv "$PMH_STATE/capacity.json" "$PMH_STATE/capacity.json.old"
    warn "previous capacity measurement no longer applies and was moved to capacity.json.old"
fi
log "schema ready: $WAREHOUSES warehouses, ${SIZE_MB} MB in $(( $(date +%s) - START ))s"
log "next step: $(dirname "$0")/compute-capacity.sh"
