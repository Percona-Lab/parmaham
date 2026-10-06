#!/usr/bin/env bash
# Install and start the permanent HammerDB workload as a systemd service.
#
# Usage: install-workload.sh [--percent 50] [--vu N] [--rampup 1] [--duration 60]
#                            [--sleep 0] [--stop] [--uninstall]
#
#   --percent    share of measured capacity (NOPM) to run, 1-100 (default 50;
#                100 runs unthrottled)
#   --vu         virtual users (default: the count used by compute-capacity.sh)
#   --rampup     warm-up minutes per iteration (default 1)
#   --duration   measured minutes per iteration (default 60)
#   --sleep      pause between iterations in seconds (default 0)
#   --stop       stop the service, keep it installed (start again by re-running)
#   --uninstall  stop and remove the service
#
# Settings are re-read at the start of every iteration; re-running this
# script restarts the service so they apply immediately.
source "$(dirname "$0")/../common/lib.sh"
source "$(dirname "$0")/lib/mysql.sh"

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

UNIT=parmaham-workload.service
require_root
load_config
while (($#)); do
    case $1 in
        --percent)   conf_set WORKLOAD_PERCENT "$2"; shift 2 ;;
        --vu)        conf_set WORKLOAD_VU "$2"; shift 2 ;;
        --rampup)    conf_set WORKLOAD_RAMPUP "$2"; shift 2 ;;
        --duration)  conf_set WORKLOAD_DURATION "$2"; shift 2 ;;
        --sleep)     conf_set WORKLOAD_SLEEP "$2"; shift 2 ;;
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
for v in WORKLOAD_RAMPUP WORKLOAD_DURATION WORKLOAD_SLEEP WORKLOAD_VU; do
    [[ ${!v} =~ ^[0-9]+$ ]] || die "$v must be a whole number"
done
(( WORKLOAD_DURATION >= 1 )) || die "--duration must be at least 1 minute"

[[ -r $PMH_STATE/capacity.json ]] || die "no capacity measurement found - run compute-capacity.sh first"
install_payload
install_hammerdb
hdb_env
require_schema

CAP_NOPM=$(json_get "$PMH_STATE/capacity.json" nopm)
CAP_VU=$(json_get "$PMH_STATE/capacity.json" vu)
VU=$WORKLOAD_VU; (( VU > 0 )) || VU=$CAP_VU
TARGET=$(( CAP_NOPM * WORKLOAD_PERCENT / 100 ))

cat > "/etc/systemd/system/$UNIT" <<EOF
[Unit]
Description=Parma Ham permanent HammerDB workload
After=network.target $(mysql_service).service
Wants=$(mysql_service).service

[Service]
User=$PMH_USER
Group=$PMH_USER
ExecStart=$PMH_HOME/mysql/lib/workload-loop.sh
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

log "workload started: $VU virtual users, target $TARGET NOPM ($WORKLOAD_PERCENT% of $CAP_NOPM)"
log "iterations: ${WORKLOAD_RAMPUP} min warm-up + ${WORKLOAD_DURATION} min run, ${WORKLOAD_SLEEP}s pause"
log "follow with: journalctl -fu $UNIT"
