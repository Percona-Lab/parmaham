#!/usr/bin/env bash
# Install a systemd timer that regularly deletes benchmark data older than
# the retention period, keeping the database size stable on permanent runs.
#
# Usage: install-hammerdb-purge.sh [--retention-hours 24] [--interval-min 15]
#                                  [--run-now] [--uninstall]
#
#   --retention-hours  keep data added during the last N hours (default 24)
#   --interval-min     how often the purge runs (default every 15 minutes)
#   --run-now          run one purge immediately and print what was deleted
#   --uninstall        remove the timer (stored procedures are kept)
#
# Data is removed by primary key ranges using watermarks recorded on every
# run, so the first rows are deleted one retention period after installation.
source "$(dirname "$0")/../common/lib.sh"

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

require_root
load_config
load_db
RUN_NOW=0
while (($#)); do
    case $1 in
        --retention-hours) conf_set PURGE_RETENTION_HOURS "$2"; shift 2 ;;
        --interval-min)    conf_set PURGE_INTERVAL_MIN "$2"; shift 2 ;;
        --run-now)         RUN_NOW=1; shift ;;
        --uninstall)       systemctl disable --now parmaham-purge.timer 2>/dev/null || true
                           rm -f /etc/systemd/system/parmaham-purge.{timer,service}
                           systemctl daemon-reload; log "purge timer removed"; exit 0 ;;
        -h|--help)         usage ;;
        *) warn "unknown option $1"; usage 1 ;;
    esac
done
[[ $PURGE_RETENTION_HOURS =~ ^[0-9]+$ ]] || die "--retention-hours must be a whole number"
[[ $PURGE_INTERVAL_MIN =~ ^[0-9]+$ && $PURGE_INTERVAL_MIN -ge 1 ]] || die "--interval-min must be at least 1"

install_payload
require_schema

hdb_env
log "installing purge procedures into $PMH_DB_NAME"
db_purge_install

cat > /etc/systemd/system/parmaham-purge.service <<EOF
[Unit]
Description=Parma Ham: purge HammerDB data older than the retention period
After=$(db_service).service

[Service]
Type=oneshot
User=$PMH_USER
Group=$PMH_USER
ExecStart=$PMH_HOME/common/purge.sh
EOF
cat > /etc/systemd/system/parmaham-purge.timer <<EOF
[Unit]
Description=Parma Ham: purge HammerDB data every $PURGE_INTERVAL_MIN minutes

[Timer]
OnActiveSec=1min
OnBootSec=5min
OnUnitActiveSec=${PURGE_INTERVAL_MIN}min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now parmaham-purge.timer &>/dev/null
systemctl restart parmaham-purge.timer

log "purge timer installed: every $PURGE_INTERVAL_MIN min, retention ${PURGE_RETENTION_HOURS}h"
if [[ $RUN_NOW == 1 ]]; then
    systemctl start parmaham-purge.service
    journalctl -u parmaham-purge.service -n 8 --no-pager -o cat
fi
log "check runs with: systemctl list-timers parmaham-purge.timer; journalctl -u parmaham-purge"
