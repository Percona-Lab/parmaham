#!/usr/bin/env bash
# Install and start the permanent HammerDB workload as a systemd service.
#
# Usage: install-workload.sh [--percent 50 | --nopm N] [--vu N] [--rampup 1]
#                            [--duration 60] [--sleep 0] [--stop] [--uninstall]
#
#   --percent    share of measured capacity (NOPM) to run, 1-100 (default 50;
#                100 runs unthrottled)
#   --nopm       run at a fixed target of N new orders per minute instead; no
#                capacity measurement is needed (--percent switches back)
#   --vu         virtual users (default: the count compute-capacity.sh used,
#                or CAPACITY_VU without a measurement)
#   --rampup     warm-up minutes per iteration (default 1)
#   --duration   measured minutes per iteration (default 60)
#   --sleep      pause between iterations in seconds (default 0)
#   --stop       stop the service, keep it installed (start again by re-running)
#   --uninstall  stop and remove the service
#
# Settings are re-read at the start of every iteration; re-running this
# script restarts the service so they apply immediately.
source "$(dirname "$0")/../common/lib.sh"

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

UNIT=parmaham-workload.service
require_root
load_config
load_db
# Options are checked before they are saved: the running workload re-reads
# the configuration at every iteration and must not pick up a setting this
# script then rejects.
PENDING=()
opt() { printf -v "$1" '%s' "$2"; PENDING+=("$1"); }
while (($#)); do
    case $1 in
        --percent)   opt WORKLOAD_PERCENT "$2"; opt WORKLOAD_NOPM 0; shift 2 ;;
        --nopm)      opt WORKLOAD_NOPM "$2"; shift 2 ;;
        --vu)        opt WORKLOAD_VU "$2"; shift 2 ;;
        --rampup)    opt WORKLOAD_RAMPUP "$2"; shift 2 ;;
        --duration)  opt WORKLOAD_DURATION "$2"; shift 2 ;;
        --sleep)     opt WORKLOAD_SLEEP "$2"; shift 2 ;;
        --stop)      systemctl stop "$UNIT"; log "workload stopped"; exit 0 ;;
        --uninstall) systemctl disable --now "$UNIT" 2>/dev/null || true
                     rm -f "/etc/systemd/system/$UNIT"; systemctl daemon-reload
                     log "workload service removed"; exit 0 ;;
        -h|--help)   usage ;;
        *) warn "unknown option $1"; usage 1 ;;
    esac
done
[[ $WORKLOAD_PERCENT =~ ^[0-9]+$ && $WORKLOAD_PERCENT -ge 1 && $WORKLOAD_PERCENT -le 100 ]] \
    || die "--percent must be between 1 and 100"
for v in WORKLOAD_RAMPUP WORKLOAD_DURATION WORKLOAD_SLEEP WORKLOAD_VU WORKLOAD_NOPM; do
    [[ ${!v} =~ ^[0-9]+$ ]] || die "$v must be a whole number"
done
(( WORKLOAD_DURATION >= 1 )) || die "--duration must be at least 1 minute"

install_payload
install_hammerdb
hdb_env
require_schema

workload_target || die "$TARGET_ERROR (nothing was changed)"
if [[ $TARGET_MODE == nopm && $CAP_NOPM != null ]] && (( TARGET_NOPM > CAP_NOPM )); then
    warn "the target ($TARGET_NOPM NOPM) is above the measured capacity ($CAP_NOPM NOPM): runs will fall short of it"
fi
for v in "${PENDING[@]}"; do conf_set "$v" "${!v}"; done

cat > "/etc/systemd/system/$UNIT" <<EOF
[Unit]
Description=Parma Ham permanent HammerDB workload
After=network.target $(db_service).service
Wants=$(db_service).service

[Service]
User=$PMH_USER
Group=$PMH_USER
ExecStart=$PMH_HOME/common/workload-loop.sh
Restart=always
RestartSec=30
KillMode=control-group
TimeoutStopSec=60
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "$UNIT" &>/dev/null
# a pacing correction learned for other settings does not apply any more
rm -f "$PMH_STATE/pace-correction"
systemctl restart "$UNIT"

log "workload started: $VU virtual users, target $(target_text)"
log "iterations: ${WORKLOAD_RAMPUP} min warm-up + ${WORKLOAD_DURATION} min run, ${WORKLOAD_SLEEP}s pause"
log "follow with: journalctl -fu $UNIT"
