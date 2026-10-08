#!/usr/bin/env bash
# Install the Parma Ham compare page: a side-by-side view of any two Parma Ham
# workloads, read from their dashboards. It needs no database and can run on
# a small separate machine or next to a dashboard (use another --port).
#
# Usage: install-compare.sh [--add URL [--name NAME]] [--remove URL] [--list]
#                           [--port 80] [--bind 0.0.0.0] [--uninstall]
#
#   --add URL     add a Parma Ham dashboard, e.g. http://192.0.2.10/
#   --name NAME   name shown for the host added with --add (default: its hostname)
#   --remove URL  remove a host
#   --list        show the configured hosts and exit
#
# Hosts are kept in /etc/parmaham/compare-hosts (one "URL [name]" per line);
# changes apply without a restart. Like the dashboard, the page is public.
source "$(dirname "$0")/../common/lib.sh"

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

UNIT=parmaham-compare.service
HOSTS=$PMH_ETC/compare-hosts
require_root
load_config
ADD=() REMOVE=() NAME="" LIST=0
while (($#)); do
    case $1 in
        --add)       ADD+=("$2"); shift 2 ;;
        --name)      NAME=$2; shift 2 ;;
        --remove)    REMOVE+=("$2"); shift 2 ;;
        --list)      LIST=1; shift ;;
        --port)      conf_set COMPARE_PORT "$2"; shift 2 ;;
        --bind)      conf_set COMPARE_BIND "$2"; shift 2 ;;
        --uninstall) systemctl disable --now "$UNIT" 2>/dev/null || true
                     rm -f "/etc/systemd/system/$UNIT"; systemctl daemon-reload
                     log "compare page removed ($HOSTS kept)"; exit 0 ;;
        -h|--help)   usage ;;
        *) warn "unknown option $1"; usage 1 ;;
    esac
done
[[ $COMPARE_PORT =~ ^[0-9]+$ ]] || die "invalid port $COMPARE_PORT"
(( ${#ADD[@]} <= 1 )) || [[ -z $NAME ]] || die "--name applies to a single --add"

install -d -m 0755 "$PMH_ETC"
[[ -f $HOSTS ]] || printf '# Parma Ham dashboards to compare: URL [name]\n' > "$HOSTS"
norm() { local u=$1; [[ $u =~ ^https?:// ]] || u="http://$u"; echo "${u%/}"; }
for u in "${REMOVE[@]}"; do
    u=$(norm "$u")
    grep -v -F -e "$u " -e "$u/" "$HOSTS" | grep -v -x -F "$u" > "$HOSTS.tmp" || true
    mv "$HOSTS.tmp" "$HOSTS"; log "removed $u"
done
for u in "${ADD[@]}"; do
    u=$(norm "$u")
    [[ $u =~ ^https?://[^/[:space:]]+(/[^[:space:]]*)?$ ]] || die "not a URL: $u"
    if curl -fsS -m 10 "$u/api/info" -o /dev/null; then
        log "$u: Parma Ham dashboard found"
    else
        warn "$u/api/info is not reachable from this machine now; adding it anyway"
    fi
    grep -v -F -e "$u " "$HOSTS" | grep -v -x -F "$u" > "$HOSTS.tmp" || true
    echo "$u${NAME:+ $NAME}" >> "$HOSTS.tmp"; mv "$HOSTS.tmp" "$HOSTS"
    log "added $u${NAME:+ ($NAME)}"
done
chmod 0644 "$HOSTS"
if [[ $LIST == 1 ]]; then grep -v '^#' "$HOSTS" || log "no hosts configured"; exit 0; fi

command -v python3 &>/dev/null || pkg_install python3
install_payload
WEB_USER=parmaham-web
id "$WEB_USER" &>/dev/null || useradd --system --no-create-home --home-dir / --shell /usr/sbin/nologin "$WEB_USER"

cat > "/etc/systemd/system/$UNIT" <<EOF
[Unit]
Description=Parma Ham compare page
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/python3 $PMH_HOME/compare/parmaham_compare.py
Environment=PMH_HOME=$PMH_HOME PMH_ETC=$PMH_ETC PYTHONUNBUFFERED=1
User=$WEB_USER
Group=$WEB_USER
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

if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow "$COMPARE_PORT/tcp" >/dev/null && log "opened port $COMPARE_PORT/tcp in ufw"
elif command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
    firewall-cmd -q --permanent --add-port="$COMPARE_PORT/tcp" && firewall-cmd -q --reload \
        && log "opened port $COMPARE_PORT/tcp in firewalld"
fi

sleep 2
systemctl is-active -q "$UNIT" || die "compare page failed to start: journalctl -u $UNIT"
ADDR=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<NF;i++) if ($i=="src") print $(i+1)}')
PORT_SUFFIX=$([[ $COMPARE_PORT == 80 ]] || echo ":$COMPARE_PORT")
log "compare page running at http://${ADDR:-<this-host>}$PORT_SUFFIX/ with $(grep -cv '^#' "$HOSTS") hosts"
