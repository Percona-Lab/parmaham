#!/usr/bin/env bash
# Measure the sustainable throughput of this node and store it as the
# capacity the permanent workload is scaled against.
#
# Usage: compute-capacity.sh [--vu 64] [--rampup 15] [--duration 30] [--background]
#
#   --vu          virtual users (default 64)
#   --rampup      warm-up minutes (default 15)
#   --duration    measured minutes (default 30)
#   --background  run as the transient systemd unit parmaham-capacity, so the
#                 measurement survives a closed SSH session
#                 (follow with: journalctl -fu parmaham-capacity)
#
# A running permanent workload is stopped for the measurement and started
# again afterwards (it then uses the new capacity).
source "$(dirname "$0")/../common/lib.sh"

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

require_root
load_config
load_db
BACKGROUND=0
ARGS=()
while (($#)); do
    case $1 in
        --background) BACKGROUND=1; shift; continue ;;
        --vu)       conf_set CAPACITY_VU "$2"; ARGS+=("$1" "$2"); shift 2 ;;
        --rampup)   conf_set CAPACITY_RAMPUP "$2"; ARGS+=("$1" "$2"); shift 2 ;;
        --duration) conf_set CAPACITY_DURATION "$2"; ARGS+=("$1" "$2"); shift 2 ;;
        -h|--help)  usage ;;
        *) warn "unknown option $1"; usage 1 ;;
    esac
done

if [[ $BACKGROUND == 1 ]]; then
    systemctl reset-failed parmaham-capacity.service &>/dev/null || true
    systemd-run --unit=parmaham-capacity --description="Parma Ham capacity measurement" \
        "$(script_path)" "${ARGS[@]}"
    log "capacity measurement started in the background; follow it with: journalctl -fu parmaham-capacity"
    exit 0
fi

install_payload
install_hammerdb
hdb_env
require_schema

WORKLOAD_WAS_ACTIVE=0
if systemctl is-active -q parmaham-workload.service; then
    WORKLOAD_WAS_ACTIVE=1
    log "stopping parmaham-workload.service for the measurement"
    systemctl stop parmaham-workload.service
fi
restore_workload() {
    if [[ $WORKLOAD_WAS_ACTIVE == 1 ]]; then
        log "starting parmaham-workload.service again"
        systemctl start parmaham-workload.service
    fi
}
trap restore_workload EXIT
trap 'write_status idle note "capacity measurement interrupted"; exit 130' INT TERM

export PMH_VU=$CAPACITY_VU PMH_RAMPUP=$CAPACITY_RAMPUP PMH_DURATION=$CAPACITY_DURATION PMH_PACE_MS=0 \
       PMH_TIMEPROFILE=$HAMMERDB_TIMEPROFILE
STARTED=$(date -u +%FT%TZ)
LOGFILE=$PMH_LOG/capacity.log
write_status capacity started_at "$STARTED" vu "$CAPACITY_VU" \
    rampup_min "$CAPACITY_RAMPUP" duration_min "$CAPACITY_DURATION" log capacity.log
log "measuring capacity: $CAPACITY_VU virtual users, ${CAPACITY_RAMPUP}min warm-up + ${CAPACITY_DURATION}min measurement (log: $LOGFILE)"
log "expected to finish at $(date -d "+$(( CAPACITY_RAMPUP + CAPACITY_DURATION + 1 )) min" '+%F %T')"

if ! RESULT=$(hammerdb_timed_run hdb-run.tcl "$LOGFILE"); then
    write_status idle note "capacity measurement failed"
    die "capacity measurement failed, no result found (see $LOGFILE)"
fi
read -r NOPM TPM <<< "$RESULT"

WAREHOUSES_DB=$(db_bench "SELECT COUNT(*) FROM warehouse")
json_kv nopm "$NOPM" tpm "$TPM" vu "$CAPACITY_VU" rampup_min "$CAPACITY_RAMPUP" \
        duration_min "$CAPACITY_DURATION" warehouses "$WAREHOUSES_DB" \
        started_at "$STARTED" measured_at "$(date -u +%FT%TZ)" \
        db "$PMH_DB" db_version "$(db_version)" \
    | write_atomic "$PMH_STATE/capacity.json"
cp "$LOGFILE" "$PMH_LOG/capacity-$(date +%Y%m%d-%H%M%S).log"
write_status idle note "capacity measured: $NOPM NOPM"

log "capacity: $NOPM NOPM, $TPM TPM with $CAPACITY_VU virtual users"
log "next step: $(dirname "$0")/install-workload.sh"
