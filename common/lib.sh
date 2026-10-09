# shellcheck shell=bash
# Shared helpers for Parma Ham scripts. Source this file, do not execute it.

set -euo pipefail

PMH_ETC=${PMH_ETC:-/etc/parmaham}
PMH_CONF=${PMH_CONF:-$PMH_ETC/parmaham.conf}
PMH_HOME=${PMH_HOME:-/opt/parmaham}
PMH_STATE=${PMH_STATE:-/var/lib/parmaham}
PMH_LOG=${PMH_LOG:-/var/log/parmaham}
PMH_USER=${PMH_USER:-parmaham}
PMH_SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# Supported databases: one directory each, with lib/db.sh (shell plug-in),
# lib/hdb-db.tcl (HammerDB settings) and dashboard_collector.py
PMH_DATABASES="mysql mariadb postgresql orioledb pgrust"

log()  { printf '%s [parmaham] %s\n' "$(date '+%F %T')" "$*" >&2; }
warn() { log "WARNING: $*"; }
die()  { log "ERROR: $*"; exit 1; }

require_root() {
    [[ $(id -u) -eq 0 ]] || die "this script must be run as root (try: sudo $0 $*)"
}

# ---------------------------------------------------------------------------
# Configuration: /etc/parmaham/parmaham.conf holds KEY=value lines. Defaults
# live in config/parmaham.conf.defaults; command line flags override both and
# are written back so other scripts and the dashboard see the same values.
# ---------------------------------------------------------------------------
load_config() {
    # shellcheck disable=SC1091
    source "$PMH_SRC/config/parmaham.conf.defaults"
    if [[ -r $PMH_CONF ]]; then
        # shellcheck disable=SC1090
        source "$PMH_CONF"
    fi
}

# Load the database plug-in. The scripts that work the same for every database
# live in common/ and are linked from each database directory: when started
# as postgresql/compute-capacity.sh the database is the directory's, otherwise
# (systemd units, common/...) it is PMH_DB from the configuration.
load_db() {
    local dir
    dir=$(basename "$(cd "$(dirname "$0")" && pwd)")
    if [[ " $PMH_DATABASES " == *" $dir "* ]]; then
        if [[ $dir != "$PMH_DB" ]] && grep -qs '^PMH_DB=' "$PMH_CONF"; then
            die "this node is set up for $PMH_DB (PMH_DB in $PMH_CONF); use $PMH_DB/$(basename "$0")"
        fi
        PMH_DB=$dir
    fi
    [[ " $PMH_DATABASES " == *" $PMH_DB "* ]] || die "unknown database type PMH_DB=$PMH_DB"
    # shellcheck disable=SC1090
    source "$PMH_SRC/$PMH_DB/lib/db.sh"
}

# Path of the running script that keeps the database directory it was
# started from (realpath would resolve the link into common/)
script_path() { echo "$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"; }

conf_set() {
    local key=$1 value=$2
    install -d -m 0755 "$PMH_ETC"
    touch "$PMH_CONF"
    if grep -q "^${key}=" "$PMH_CONF"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$PMH_CONF"
    else
        echo "${key}=${value}" >> "$PMH_CONF"
    fi
    printf -v "$key" '%s' "$value"
}

# Copy the project to $PMH_HOME so systemd units do not depend on where the
# repository was cloned, and create the service account and directories.
install_payload() {
    if ! id "$PMH_USER" &>/dev/null; then
        useradd --system --home-dir "$PMH_STATE" --shell /usr/sbin/nologin "$PMH_USER"
    fi
    install -d -m 0755 "$PMH_HOME" "$PMH_ETC"
    install -d -m 0755 -o "$PMH_USER" -g "$PMH_USER" "$PMH_STATE" "$PMH_STATE/runs" "$PMH_LOG"
    if [[ $PMH_SRC != "$PMH_HOME" ]]; then
        local d
        # every database directory: plug-ins may share code (mariadb uses mysql/lib)
        for d in common config dashboard compare $PMH_DATABASES; do
            rm -rf "${PMH_HOME:?}/$d"
            # no -a: do not carry over the clone's owner or SELinux label
            # (files under /root are admin_home_t, which systemd may not execute)
            # -r keeps the links to common/ as links
            cp -r --preserve=mode,timestamps "$PMH_SRC/$d" "$PMH_HOME/$d"
            chown -R root:root "$PMH_HOME/$d"
            chmod -R go-w "$PMH_HOME/$d"
        done
    fi
    if command -v restorecon &>/dev/null; then
        restorecon -R "$PMH_HOME" "$PMH_ETC" "$PMH_STATE" "$PMH_LOG" 2>/dev/null || true
    fi
    [[ -f $PMH_CONF ]] || install -m 0644 "$PMH_SRC/config/parmaham.conf.example" "$PMH_CONF"
}

# ---------------------------------------------------------------------------
# Hardware sizing
# ---------------------------------------------------------------------------
mem_total_mb() { awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo; }
cpu_count()    { nproc; }
numa_nodes()   { ls -d /sys/devices/system/node/node* 2>/dev/null | wc -l; }

# Storage class of the device holding a directory: sets DISK_NAME and
# DISK_CLASS (nvme, ssd or hdd)
disk_class() {
    local dev
    dev=$(df --output=source "$1" | tail -1)
    DISK_NAME=$(lsblk -no PKNAME "$dev" 2>/dev/null | tail -1)
    [[ -n $DISK_NAME ]] || DISK_NAME=$(basename "$dev")
    if [[ $(cat "/sys/block/$DISK_NAME/queue/rotational" 2>/dev/null || echo 0) == 1 ]]; then
        DISK_CLASS=hdd
    elif [[ $DISK_NAME == nvme* ]]; then
        DISK_CLASS=nvme
    else
        DISK_CLASS=ssd
    fi
}

# OS settings recommended for database servers, shared by every
# database-install.sh: low swappiness, transparent huge pages off, pressure
# stall information on, and a drop-in for the database service unit.
install_os_tuning() {
    local service=$1
    echo "vm.swappiness = 1" > /etc/sysctl.d/90-parmaham.conf
    sysctl -q -p /etc/sysctl.d/90-parmaham.conf || true

    # Pressure stall information is shown on the dashboard; some kernels
    # (RHEL 9 and derivatives) build it in but disable it unless booted with psi=1.
    if [[ ! -e /proc/pressure/cpu ]]; then
        if command -v grubby &>/dev/null; then
            grubby --update-kernel=ALL --args=psi=1
            warn "pressure stall information enabled with the psi=1 kernel argument; reboot for it to take effect"
        else
            warn "this kernel does not provide pressure stall information (/proc/pressure); add psi=1 to the kernel command line"
        fi
    fi

    cat > /etc/systemd/system/parmaham-thp.service <<EOF
[Unit]
Description=Parma Ham: disable transparent huge pages (recommended for databases)
Before=$service.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled; echo never > /sys/kernel/mm/transparent_hugepage/defrag'

[Install]
WantedBy=multi-user.target
EOF
    install -d "/etc/systemd/system/$service.service.d"
    cat > "/etc/systemd/system/$service.service.d/parmaham.conf" <<EOF
[Service]
LimitNOFILE=1048576
Restart=on-failure
EOF
    systemctl daemon-reload
    systemctl enable --now parmaham-thp.service &>/dev/null || warn "could not disable transparent huge pages"
}

# Packages every database-install.sh needs (dashboard, HammerDB download)
base_packages() {
    case $(os_family) in
        debian) apt-get update -q; pkg_install curl python3 xz-utils tar util-linux pciutils procps gnupg2 ca-certificates lsb-release ;;
        rhel)   pkg_install curl python3 xz tar util-linux pciutils procps-ng ;;
    esac
}

# Record which database this node runs. Parma Ham runs one database per
# node, so refuse to switch a node that is already set up for another one.
claim_database() {
    if grep -qs '^PMH_DB=' "$PMH_CONF" && [[ $PMH_DB != "$1" ]]; then
        die "this node is already set up for $PMH_DB (PMH_DB in $PMH_CONF); Parma Ham runs one database per node"
    fi
    conf_set PMH_DB "$1"
}

random_password() {
    # satisfies MySQL's default password policy: mixed case + digits + symbol
    printf '%s-Pm1' "$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)"
}

# KEY=value credential files in /etc/parmaham: write_cnf file owner_group mode
# then "key=value" lines on stdin. MySQL-family files carry a [client] header
# so the client reads them with --defaults-extra-file.
write_cnf() {
    local file=$1 group=$2 mode=$3
    install -d -m 0755 "$PMH_ETC"
    ( umask 077; cat > "$file" )
    chown "root:$group" "$file"
    chmod "$mode" "$file"
}

cnf_value() {
    # cnf_value file key
    sed -n "s/^$2=//p" "$1" | head -1
}

# ---------------------------------------------------------------------------
# OS / package helpers
# ---------------------------------------------------------------------------
os_family() {
    # shellcheck disable=SC1091
    . /etc/os-release
    case " ${ID:-} ${ID_LIKE:-} " in
        *" debian "*|*" ubuntu "*) echo debian ;;
        *" rhel "*|*" fedora "*|*" centos "*) echo rhel ;;
        *) die "unsupported OS: ${PRETTY_NAME:-unknown}" ;;
    esac
}

pkg_install() {
    case $(os_family) in
        debian) DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$@" ;;
        rhel)   dnf install -y -q "$@" ;;
    esac
}

# ---------------------------------------------------------------------------
# HammerDB
# ---------------------------------------------------------------------------
hammerdb_dir() { echo "$PMH_HOME/hammerdb/HammerDB-$HAMMERDB_VERSION"; }

install_hammerdb() {
    local dir arch tarball url libdir
    dir=$(hammerdb_dir)
    libdir="$PMH_HOME/hammerdb/lib"
    arch=$(uname -m)
    if [[ ! -x $dir/hammerdbcli ]]; then
        case "$arch:$(os_family)" in
            x86_64:debian)  tarball="HammerDB-$HAMMERDB_VERSION-Prod-Lin-UBU24.tar.gz" ;;
            x86_64:rhel)    tarball="HammerDB-$HAMMERDB_VERSION-Prod-Lin-RHEL9.tar.gz" ;;
            aarch64:debian) tarball="HammerDB-$HAMMERDB_VERSION-Prod-Lin-UBU24-ARM64.tar.gz" ;;
            aarch64:rhel)   tarball="HammerDB-$HAMMERDB_VERSION-Prod-Lin-RHEL9-ARM64.tar.gz" ;;
            *) die "unsupported architecture $arch" ;;
        esac
        url="https://github.com/TPC-Council/HammerDB/releases/download/v$HAMMERDB_VERSION/$tarball"
        log "downloading HammerDB $HAMMERDB_VERSION from $url"
        install -d "$PMH_HOME/hammerdb"
        curl -fsSL "$url" | tar xz -C "$PMH_HOME/hammerdb"
        [[ -x $dir/hammerdbcli ]] || die "HammerDB was not found in $dir after extraction"
    fi

    # client library HammerDB's driver needs for this database (plug-in hook)
    if declare -F db_hammerdb_libs >/dev/null; then db_hammerdb_libs "$libdir"; fi
    log "HammerDB $HAMMERDB_VERSION installed in $dir"
}

# Fail early when the benchmark schema is missing
require_schema() {
    local n
    n=$(db_bench "SELECT COUNT(*) FROM warehouse" 2>/dev/null) \
        || die "TPROC-C schema not found - run database-generate.sh first"
    [[ $n -gt 0 ]] || die "TPROC-C schema is empty - run database-generate.sh first"
}

# Run a HammerDB CLI Tcl script from common/. PMH_* variables must already be
# exported (hdb_env).
# Each invocation gets a clean TMP directory: HammerDB keeps its settings
# and job history in SQLite files there and we want neither to carry over.
# HammerDB echoes every setting it changes, including the database password
# ("Changed tpcc:mysql_pass from x to y"), so its output is masked before it
# reaches any log.
hammerdb_cli() {
    local script=$PMH_HOME/common/$1 tmp rc=0
    tmp="$PMH_STATE/hammerdb-tmp.$$"
    rm -rf "$tmp"
    install -d -m 0700 "$tmp"
    (
        cd "$(hammerdb_dir)"
        export TMP="$tmp" LD_LIBRARY_PATH="$PMH_HOME/hammerdb/lib" PMH_HOME PMH_DB
        ./hammerdbcli auto "$script" 2>&1 | mask_passwords
    ) || rc=$?
    rm -rf "$tmp"
    return $rc
}

mask_passwords() {
    # (pg_superuserpass has no "_" before "pass")
    sed -u -E -e 's/(pass(word)? from ).* to .* for /\1*** to *** for /' \
              -e 's/^Value .* for ([a-z_:]*pass(word)?) is the same as existing value .*, no change/Value *** for \1 is the same as existing value ***, no change/' \
              -e 's/("[a-z_]*pass(word)?": *")[^"]*"/\1***"/g'
}

# Run a timed HammerDB test, logging to $2. Prints "NOPM TPM" on success.
hammerdb_timed_run() {
    local script=$1 logfile=$2 line
    hammerdb_cli "$script" > "$logfile" 2>&1 || true
    line=$(grep -m1 -oE 'TEST RESULT : System achieved [0-9]+ NOPM from [0-9]+ ' "$logfile") || return 1
    # TEST RESULT : System achieved <nopm> NOPM from <tpm>
    set -- $line
    echo "$6 $9"
}

# Target of the permanent workload. Sets TARGET_MODE (percent: a share of the
# measured capacity, nopm: the fixed WORKLOAD_NOPM), TARGET_NOPM, TARGET_PCT
# (share of the measured capacity, or null without a measurement), CAP_NOPM
# (or null) and VU. A fixed target needs no capacity measurement. Returns 1
# and sets TARGET_ERROR when there is nothing to base the target on.
workload_target() {
    local cap=$PMH_STATE/capacity.json cap_vu=""
    CAP_NOPM=null
    if [[ -r $cap ]]; then
        CAP_NOPM=$(json_get "$cap" nopm)
        cap_vu=$(json_get "$cap" vu)
    fi
    VU=$WORKLOAD_VU
    (( VU > 0 )) || VU=${cap_vu:-$CAPACITY_VU}
    if (( ${WORKLOAD_NOPM:-0} > 0 )); then
        TARGET_MODE=nopm
        TARGET_NOPM=$WORKLOAD_NOPM
        TARGET_PCT=null
        [[ $CAP_NOPM == null ]] || TARGET_PCT=$(awk -v t="$TARGET_NOPM" -v c="$CAP_NOPM" 'BEGIN { printf "%.1f", 100 * t / c }')
    else
        if [[ $CAP_NOPM == null ]]; then
            TARGET_ERROR="no capacity measurement - run compute-capacity.sh, or set a fixed target with install-workload.sh --nopm N"
            return 1
        fi
        TARGET_MODE=percent
        TARGET_NOPM=$(( CAP_NOPM * WORKLOAD_PERCENT / 100 ))
        TARGET_PCT=$WORKLOAD_PERCENT
    fi
}

# "11,437 NOPM (50% of capacity)" or "10000 NOPM (fixed target, 43.7% of capacity)"
target_text() {
    local of=""
    [[ $TARGET_PCT == null ]] || of="$TARGET_PCT% of $CAP_NOPM"
    if [[ $TARGET_MODE == nopm ]]; then
        echo "$TARGET_NOPM NOPM (fixed target${of:+, $of})"
    else
        echo "$TARGET_NOPM NOPM ($of)"
    fi
}

# Status shown by the dashboard: write_status state key value ...
write_status() {
    local state=$1; shift
    json_kv state "$state" updated_at "$(date -u +%FT%TZ)" "$@" | write_atomic "$PMH_STATE/status.json"
}

# ---------------------------------------------------------------------------
# Small JSON helpers (values must not contain double quotes)
# ---------------------------------------------------------------------------
json_kv() {
    # json_kv key value [key value ...]; numbers and true/false/null unquoted
    local out="{" sep="" k v
    while (($#)); do
        k=$1 v=$2; shift 2
        if [[ $v =~ ^-?[0-9]+(\.[0-9]+)?$ || $v == true || $v == false || $v == null ]]; then
            out+="$sep\"$k\": $v"
        else
            out+="$sep\"$k\": \"$v\""
        fi
        sep=", "
    done
    echo "$out}"
}

# Write a file atomically (readers such as the dashboard never see half a file)
write_atomic() {
    local dest=$1 tmp
    tmp=$(mktemp "$dest.XXXXXX")
    cat > "$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$dest"
}

json_get() {
    # json_get file key  -> prints the value of a top level key
    python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print("" if v is None else v)' "$1" "$2"
}
