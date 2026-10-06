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
        for d in common config dashboard "$PMH_DB"; do
            rm -rf "${PMH_HOME:?}/$d"
            # no -a: do not carry over the clone's owner or SELinux label
            # (files under /root are admin_home_t, which systemd may not execute)
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

    # HammerDB's MySQL interface (mysqltcl) links against Oracle's
    # libmysqlclient.so.24 and requires its versioned symbols, so Percona's
    # libperconaserverclient cannot be substituted. Take the library from the
    # MySQL minimal tarball and keep it private to HammerDB.
    if [[ ! -e $libdir/libmysqlclient.so.24 ]]; then
        local v=$MYSQL_CLIENT_LIB_VERSION
        case $arch in
            x86_64)  tarball="mysql-$v-linux-glibc2.17-x86_64-minimal.tar.xz" ;;
            aarch64) tarball="mysql-$v-linux-glibc2.28-aarch64.tar.xz" ;;  # no minimal build for ARM
        esac
        url="https://cdn.mysql.com/archives/mysql-${v%.*}/$tarball"
        log "downloading libmysqlclient.so.24 from $url"
        install -d "$libdir"
        curl -fsSL "$url" | tar xJ -C "$libdir" --strip-components=2 --wildcards \
            '*/lib/libmysqlclient.so*' '*/lib/private/*'
        [[ -e $libdir/libmysqlclient.so.24 ]] || die "libmysqlclient.so.24 not found after extraction"
    fi
    log "HammerDB $HAMMERDB_VERSION installed in $dir"
}

# Run a HammerDB CLI Tcl script. PMH_* variables must already be exported.
# Each invocation gets a clean TMP directory: HammerDB keeps its settings
# and job history in SQLite files there and we want neither to carry over.
# HammerDB echoes every setting it changes, including the database password
# ("Changed tpcc:mysql_pass from x to y"), so its output is masked before it
# reaches any log.
hammerdb_cli() {
    local script=$1 tmp rc=0
    tmp="$PMH_STATE/hammerdb-tmp.$$"
    rm -rf "$tmp"
    install -d -m 0700 "$tmp"
    (
        cd "$(hammerdb_dir)"
        export TMP="$tmp" LD_LIBRARY_PATH="$PMH_HOME/hammerdb/lib"
        ./hammerdbcli auto "$script" 2>&1 | mask_passwords
    ) || rc=$?
    rm -rf "$tmp"
    return $rc
}

mask_passwords() {
    sed -u -E -e 's/(_pass(word)? from ).* to .* for /\1*** to *** for /' \
              -e 's/^Value .* for ([a-z_:]*_pass(word)?) is the same as existing value .*, no change/Value *** for \1 is the same as existing value ***, no change/'
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
