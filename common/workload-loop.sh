#!/usr/bin/env bash
# Permanent workload loop, run by parmaham-workload.service.
#
# Each iteration: re-read the configuration, run HammerDB for
# WORKLOAD_RAMPUP + WORKLOAD_DURATION minutes paced to the target (WORKLOAD_NOPM,
# or WORKLOAD_PERCENT of the measured capacity), record the result, sleep WORKLOAD_SLEEP seconds, repeat.
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
    if ! workload_target; then
        write_status error note "$TARGET_ERROR"; sleep 300; continue
    fi
    CORRECTION=$(cat "$CORRECTION_FILE" 2>/dev/null || echo 1)

    # NOPM counts new-order transactions, which are 10 of every 23 transactions
    # in the HammerDB mix; each virtual user loop iteration is one transaction.
    # --percent 100 runs unthrottled.
    UNTHROTTLED=0
    [[ $TARGET_MODE == percent && $WORKLOAD_PERCENT -ge 100 ]] && UNTHROTTLED=1
    PACE_MS=$(awk -v target="$TARGET_NOPM" -v free="$UNTHROTTLED" -v vu="$VU" -v c="$CORRECTION" 'BEGIN {
        if (free) { print 0; exit }
        per_vu_per_min = target * 23 / 10 / vu * c
        printf "%.3f\n", 60000 / per_vu_per_min }')

    iteration=$(( iteration + 1 ))
    STARTED=$(date -u +%FT%TZ)
    LOGFILE=$RUN_LOGS/run-$(date +%Y%m%d-%H%M%S).log
    write_status running iteration "$iteration" started_at "$STARTED" vu "$VU" \
        rampup_min "$WORKLOAD_RAMPUP" duration_min "$WORKLOAD_DURATION" sleep_sec "$WORKLOAD_SLEEP" \
        target_mode "$TARGET_MODE" percent "$TARGET_PCT" target_nopm "$TARGET_NOPM" capacity_nopm "$CAP_NOPM" \
        pace_ms "$PACE_MS" correction "$CORRECTION" log "runs/$(basename "$LOGFILE")"
    log "iteration $iteration: $VU VU, target $(target_text), pace ${PACE_MS}ms, ${WORKLOAD_RAMPUP}+${WORKLOAD_DURATION} min"

    export PMH_VU=$VU PMH_RAMPUP=$WORKLOAD_RAMPUP PMH_DURATION=$WORKLOAD_DURATION PMH_PACE_MS=$PACE_MS \
           PMH_TIMEPROFILE=$HAMMERDB_TIMEPROFILE
    if RESULT=$(hammerdb_timed_run hdb-run.tcl "$LOGFILE"); then
        read -r NOPM TPM <<< "$RESULT"
        failures=0
        json_kv iteration "$iteration" started_at "$STARTED" finished_at "$(date -u +%FT%TZ)" \
            nopm "$NOPM" tpm "$TPM" target_nopm "$TARGET_NOPM" target_mode "$TARGET_MODE" percent "$TARGET_PCT" \
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
            target_nopm "$TARGET_NOPM" target_mode "$TARGET_MODE" percent "$TARGET_PCT" vu "$VU" ok false \
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
