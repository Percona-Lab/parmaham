#!/usr/bin/env bash
# Permanent workload loop, run by parmaham-workload.service.
#
# Each iteration: re-read the configuration, run HammerDB for
# WORKLOAD_RAMPUP + WORKLOAD_DURATION minutes paced to WORKLOAD_PERCENT of the
# measured capacity, record the result, sleep WORKLOAD_SLEEP seconds, repeat.
source "$(dirname "$0")/lib.sh"

RESULTS=$PMH_STATE/results.jsonl
RUN_LOGS=$PMH_LOG/runs
KEEP_RUN_LOGS=200
# Pacing correction learned from previous iterations (achieved vs target)
CORRECTION_FILE=$PMH_STATE/pace-correction

install -d "$RUN_LOGS"
trap 'write_status stopped note "workload service stopped"; exit 0' TERM INT

iteration=0
[[ -f $RESULTS ]] && iteration=$(wc -l < "$RESULTS")
failures=0

while true; do
    load_config
    load_db
    hdb_env
    [[ -r $PMH_STATE/capacity.json ]] || { write_status error note "no capacity.json - run compute-capacity.sh"; sleep 300; continue; }

    CAP_NOPM=$(json_get "$PMH_STATE/capacity.json" nopm)
    CAP_VU=$(json_get "$PMH_STATE/capacity.json" vu)
    VU=$WORKLOAD_VU
    (( VU > 0 )) || VU=$CAP_VU
    CORRECTION=$(cat "$CORRECTION_FILE" 2>/dev/null || echo 1)

    # NOPM counts new-order transactions, which are 10 of every 23 transactions
    # in the HammerDB mix; each virtual user loop iteration is one transaction.
    read -r TARGET_NOPM PACE_MS < <(awk -v cap="$CAP_NOPM" -v pct="$WORKLOAD_PERCENT" -v vu="$VU" -v c="$CORRECTION" 'BEGIN {
        target = cap * pct / 100
        if (pct >= 100) { print int(target), 0; exit }        # 100% = unthrottled
        per_vu_per_min = target * 23 / 10 / vu * c
        printf "%d %.3f\n", target, 60000 / per_vu_per_min }')

    iteration=$(( iteration + 1 ))
    STARTED=$(date -u +%FT%TZ)
    LOGFILE=$RUN_LOGS/run-$(date +%Y%m%d-%H%M%S).log
    write_status running iteration "$iteration" started_at "$STARTED" vu "$VU" \
        rampup_min "$WORKLOAD_RAMPUP" duration_min "$WORKLOAD_DURATION" sleep_sec "$WORKLOAD_SLEEP" \
        percent "$WORKLOAD_PERCENT" target_nopm "$TARGET_NOPM" capacity_nopm "$CAP_NOPM" \
        pace_ms "$PACE_MS" correction "$CORRECTION" log "runs/$(basename "$LOGFILE")"
    log "iteration $iteration: $VU VU, target $TARGET_NOPM NOPM ($WORKLOAD_PERCENT% of $CAP_NOPM), pace ${PACE_MS}ms, ${WORKLOAD_RAMPUP}+${WORKLOAD_DURATION} min"

    export PMH_VU=$VU PMH_RAMPUP=$WORKLOAD_RAMPUP PMH_DURATION=$WORKLOAD_DURATION PMH_PACE_MS=$PACE_MS \
           PMH_TIMEPROFILE=$HAMMERDB_TIMEPROFILE
    if RESULT=$(hammerdb_timed_run hdb-run.tcl "$LOGFILE"); then
        read -r NOPM TPM <<< "$RESULT"
        failures=0
        json_kv iteration "$iteration" started_at "$STARTED" finished_at "$(date -u +%FT%TZ)" \
            nopm "$NOPM" tpm "$TPM" target_nopm "$TARGET_NOPM" percent "$WORKLOAD_PERCENT" \
            vu "$VU" duration_min "$WORKLOAD_DURATION" ok true log "runs/$(basename "$LOGFILE")" >> "$RESULTS"
        log "iteration $iteration: $NOPM NOPM, $TPM TPM (target $TARGET_NOPM)"

        # Adjust pacing so the long-term average converges on the target.
        # Only learn from runs that were not limited by the database itself
        # (achieved >= 90% of target) and keep the factor within sane bounds.
        if [[ $PACE_MS != 0 ]]; then
            awk -v c="$CORRECTION" -v t="$TARGET_NOPM" -v a="$NOPM" 'BEGIN {
                if (a <= 0 || a < 0.9 * t) { print c; exit }
                n = c * t / a; if (n < 0.8) n = 0.8; if (n > 1.25) n = 1.25
                printf "%.4f\n", n }' > "$CORRECTION_FILE.tmp" && mv "$CORRECTION_FILE.tmp" "$CORRECTION_FILE"
        fi
    else
        failures=$(( failures + 1 ))
        json_kv iteration "$iteration" started_at "$STARTED" finished_at "$(date -u +%FT%TZ)" \
            target_nopm "$TARGET_NOPM" percent "$WORKLOAD_PERCENT" vu "$VU" ok false \
            error "no result, see $(basename "$LOGFILE")" log "runs/$(basename "$LOGFILE")" >> "$RESULTS"
        warn "iteration $iteration produced no result (see $LOGFILE)"
        tail -5 "$LOGFILE" >&2 || true
    fi

    # keep the newest run logs only
    ls -1t "$RUN_LOGS"/run-*.log 2>/dev/null | tail -n +$(( KEEP_RUN_LOGS + 1 )) | xargs -r rm -f

    if (( failures > 0 )); then
        # back off on repeated failures (database down, ...) up to 10 minutes
        PAUSE=$(( failures * 60 )); (( PAUSE > 600 )) && PAUSE=600
        write_status error iteration "$iteration" note "last run failed, retrying" \
            sleep_until "$(date -u -d "+$PAUSE sec" +%FT%TZ)"
        sleep "$PAUSE"
    elif (( WORKLOAD_SLEEP > 0 )); then
        write_status sleeping iteration "$iteration" sleep_until "$(date -u -d "+$WORKLOAD_SLEEP sec" +%FT%TZ)"
        sleep "$WORKLOAD_SLEEP"
    fi
done
