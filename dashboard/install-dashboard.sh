#!/usr/bin/env bash
# Install the Parma Ham dashboard as a systemd service.
#
# Usage: install-dashboard.sh [--port 80] [--bind 0.0.0.0] [--uninstall]
#
# The dashboard is public by design: it has no authentication and shows only
# benchmark, hardware and performance information. It runs as an
# unprivileged dynamic user and reads database metrics with a monitoring
# account that has no access to anything but statistics and the benchmark
# schema.
source "$(dirname "$0")/../common/lib.sh"

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

UNIT=parmaham-dashboard.service
require_root
load_config
while (($#)); do
    case $1 in
        --port)      conf_set DASHBOARD_PORT "$2"; shift 2 ;;
        --bind)      conf_set DASHBOARD_BIND "$2"; shift 2 ;;
        --uninstall) systemctl disable --now "$UNIT" 2>/dev/null || true
                     rm -f "/etc/systemd/system/$UNIT"; systemctl daemon-reload
                     log "dashboard removed"; exit 0 ;;
        -h|--help)   usage ;;
        *) warn "unknown option $1"; usage 1 ;;
    esac
done
[[ $DASHBOARD_PORT =~ ^[0-9]+$ ]] || die "invalid port $DASHBOARD_PORT"
command -v python3 &>/dev/null || pkg_install python3

MONITOR_CNF=$PMH_ETC/$PMH_DB-monitor.cnf
[[ -r $MONITOR_CNF ]] || warn "$MONITOR_CNF not found - database metrics will be unavailable until database-install.sh has run"

install_payload

cat > "/etc/systemd/system/$UNIT" <<EOF
[Unit]
Description=Parma Ham dashboard
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/python3 $PMH_HOME/dashboard/parmaham_dashboard.py
Environment=PMH_HOME=$PMH_HOME PMH_ETC=$PMH_ETC PMH_STATE=$PMH_STATE PYTHONUNBUFFERED=1
LoadCredential=db.cnf:$MONITOR_CNF
DynamicUser=yes
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "$UNIT" &>/dev/null
systemctl restart "$UNIT"

# open the port in an active host firewall
if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow "$DASHBOARD_PORT/tcp" >/dev/null && log "opened port $DASHBOARD_PORT/tcp in ufw"
elif command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
    firewall-cmd -q --permanent --add-port="$DASHBOARD_PORT/tcp" && firewall-cmd -q --reload \
        && log "opened port $DASHBOARD_PORT/tcp in firewalld"
fi

sleep 2
systemctl is-active -q "$UNIT" || die "dashboard failed to start: journalctl -u $UNIT"
ADDR=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<NF;i++) if ($i=="src") print $(i+1)}')
PORT_SUFFIX=$([[ $DASHBOARD_PORT == 80 ]] || echo ":$DASHBOARD_PORT")
log "dashboard running at http://${ADDR:-<this-host>}$PORT_SUFFIX/"
