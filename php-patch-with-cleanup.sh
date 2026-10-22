#!/usr/bin/env bash
#
# php-patch-with-cleanup.sh
# Frees disk space, applies the PHP vulnerability fix (patching_php.sh), then
# verifies the patched php*-fpm packages (version 20261021).
#
#  1. Clearing disk space  runs opsgenie/disk-cleanup.sh. If no space is
#                          freed, warns "Nothing to clear" and still patches,
#                          unless less than 500 MiB is available on /.
#  2. Patching             runs patching_php.sh (embedded below, unchanged) in
#                          its own session, so it keeps going if SSH drops.
#  3. Verify               every installed php*-fpm must be on 20261021.
#
# Usage (as root on the server):
#   curl -fsSL https://raw.githubusercontent.com/jahanzaibakhan/scripts/main/php-patch-with-cleanup.sh | bash
#
# Logs:
#   /var/log/patching_php_cleanup.log   disk cleanup output
#   /var/log/patching_php.log           patch output (timestamped)

set -o pipefail

CLEANUP_URL="https://raw.githubusercontent.com/jahanzaibakhan/opsgenie/main/disk-cleanup.sh"
CLEANUP_LOG="/var/log/patching_php_cleanup.log"
PATCH_SCRIPT="/root/patching_php.sh"
PATCH_LOG="/var/log/patching_php.log"
PATCH_VERSION="20261021"
MIN_FREED_BYTES=$((1024 * 1024))          # under 1 MiB freed counts as nothing cleared
MIN_FREE_BYTES=$((500 * 1024 * 1024))     # apt needs room to unpack the packages

if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[1;31m'
    C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_CYAN=$'\033[1;36m'
else
    C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
fi

status() { printf '\n%s>>> %s%s\n' "$C_CYAN$C_BOLD" "$1" "$C_RESET"; }
ok()     { printf '%s[OK]    %s%s\n' "$C_GREEN" "$1" "$C_RESET"; }
warn()   { printf '%s[WARN]  %s%s\n' "$C_YELLOW" "$1" "$C_RESET"; }
fail()   { printf '%s[ERROR] %s%s\n' "$C_RED" "$1" "$C_RESET" >&2; }

human_size() { numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || echo "$1 bytes"; }

# Size - Used: all unallocated blocks on /, root reservation included.
physical_free_bytes() { df -PB1 / 2>/dev/null | awk 'NR == 2 { print $2 - $3 }'; }
available_bytes()     { df -PB1 / 2>/dev/null | awk 'NR == 2 { print $4 }'; }

# patching_php.sh exactly as provided; it logs to /var/log/patching_php.log.
write_patch_script() {
cat > "$PATCH_SCRIPT" <<'PATCH_EOF'
#!/bin/bash
# PHP vulnerability fix: upgrade PHP packages, keep FPM pid/UMask, mask extra FPM on single PHP.
# Run in background: nohup setsid bash patching_php.sh > /dev/null 2>&1 &
set -o pipefail

LOG_FILE="/var/log/patching_php.log"
LOCKFILE="/var/run/patching_php.lock"
FACT_FILE="/etc/ansible/facts.d/server_settings.fact"

PHP_FIX_PACKAGES=(
    dh-php libphp7.4-embed libphp8.0-embed libphp8.1-embed libphp8.2-embed libphp8.3-embed libphp8.4-embed
    newrelic-php5 newrelic-php5-common php-common php-pear
    php7.4 php7.4-bcmath php7.4-bz2 php7.4-cgi php7.4-cli php7.4-common php7.4-curl php7.4-dba php7.4-dev
    php7.4-enchant php7.4-fpm php7.4-gd php7.4-gmp php7.4-igbinary php7.4-imagick php7.4-imap php7.4-interbase
    php7.4-intl php7.4-json php7.4-mbstring php7.4-memcached php7.4-mongodb php7.4-msgpack php7.4-mysql
    php7.4-odbc php7.4-opcache php7.4-pgsql php7.4-phpdbg php7.4-readline php7.4-redis php7.4-soap php7.4-sqlite3
    php7.4-sybase php7.4-tidy php7.4-xdebug php7.4-xml php7.4-xmlrpc php7.4-xsl php7.4-zip
    php8.0 php8.0-bcmath php8.0-bz2 php8.0-cgi php8.0-cli php8.0-common php8.0-curl php8.0-dba php8.0-dev
    php8.0-enchant php8.0-fpm php8.0-gd php8.0-gmp php8.0-igbinary php8.0-imagick php8.0-imap php8.0-interbase
    php8.0-intl php8.0-mbstring php8.0-memcached php8.0-mongodb php8.0-msgpack php8.0-mysql php8.0-odbc
    php8.0-opcache php8.0-pgsql php8.0-phpdbg php8.0-readline php8.0-redis php8.0-soap php8.0-sqlite3
    php8.0-sybase php8.0-tidy php8.0-xdebug php8.0-xml php8.0-xmlrpc php8.0-xsl php8.0-zip
    php8.1 php8.1-bcmath php8.1-bz2 php8.1-cgi php8.1-cli php8.1-common php8.1-curl php8.1-dba php8.1-dev
    php8.1-enchant php8.1-fpm php8.1-gd php8.1-gmp php8.1-igbinary php8.1-imagick php8.1-imap php8.1-interbase
    php8.1-intl php8.1-mbstring php8.1-memcached php8.1-mongodb php8.1-msgpack php8.1-mysql php8.1-odbc
    php8.1-opcache php8.1-pgsql php8.1-phpdbg php8.1-readline php8.1-redis php8.1-soap php8.1-sqlite3
    php8.1-sybase php8.1-tidy php8.1-xdebug php8.1-xml php8.1-xmlrpc php8.1-xsl php8.1-zip
    php8.2 php8.2-bcmath php8.2-bz2 php8.2-cgi php8.2-cli php8.2-common php8.2-curl php8.2-dba php8.2-dev
    php8.2-enchant php8.2-fpm php8.2-gd php8.2-gmp php8.2-igbinary php8.2-imagick php8.2-imap php8.2-interbase
    php8.2-intl php8.2-mbstring php8.2-memcached php8.2-mongodb php8.2-msgpack php8.2-mysql php8.2-odbc
    php8.2-opcache php8.2-pgsql php8.2-phpdbg php8.2-readline php8.2-redis php8.2-soap php8.2-sqlite3
    php8.2-sybase php8.2-tidy php8.2-xdebug php8.2-xml php8.2-xmlrpc php8.2-xsl php8.2-zip
    php8.3 php8.3-bcmath php8.3-bz2 php8.3-cgi php8.3-cli php8.3-common php8.3-curl php8.3-dba php8.3-dev
    php8.3-enchant php8.3-fpm php8.3-gd php8.3-gmp php8.3-igbinary php8.3-imagick php8.3-imap php8.3-interbase
    php8.3-intl php8.3-mbstring php8.3-memcached php8.3-mongodb php8.3-msgpack php8.3-mysql php8.3-odbc
    php8.3-opcache php8.3-pgsql php8.3-phpdbg php8.3-readline php8.3-redis php8.3-soap php8.3-sqlite3
    php8.3-sybase php8.3-tidy php8.3-xdebug php8.3-xml php8.3-xmlrpc php8.3-xsl php8.3-zip
    php8.4 php8.4-bcmath php8.4-bz2 php8.4-cgi php8.4-cli php8.4-common php8.4-curl php8.4-dba php8.4-dev
    php8.4-enchant php8.4-fpm php8.4-gd php8.4-gmp php8.4-igbinary php8.4-imagick php8.4-imap php8.4-interbase
    php8.4-intl php8.4-mbstring php8.4-memcached php8.4-mongodb php8.4-msgpack php8.4-mysql php8.4-odbc
    php8.4-opcache php8.4-pgsql php8.4-phpdbg php8.4-readline php8.4-redis php8.4-soap php8.4-sqlite3
    php8.4-sybase php8.4-tidy php8.4-xdebug php8.4-xml php8.4-xmlrpc php8.4-xsl php8.4-zip
    pkg-php-tools
)

# Ignore HUP before starting the logger so it survives SSH disconnect too.
trap '' HUP

# Timestamp every line (ours + apt/dpkg output) into the log file.
exec > >(while IFS= read -r line || [ -n "$line" ]; do printf '%(%Y-%m-%d %H:%M:%S)T %s\n' -1 "$line"; done >> "$LOG_FILE") 2>&1

log_info()  { echo "[INFO] $1"; }
log_warn()  { echo "[WARN] $1"; }
log_error() { echo "[ERROR] $1"; }
die()       { log_error "$1"; log_info "===== patching_php.sh finished rc=1 ====="; exit 1; }

# Read key from a [section] of server_settings.fact.
fact_get() {
    awk -v s="[$1]" -v k="$2" '
        $0 == s { f = 1; next }
        /^\[/   { f = 0 }
        f && index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }
    ' "$FACT_FILE" 2>/dev/null | tr -d '[:space:]'
}

get_fpm_pid() {
    sed -nE 's/^[[:space:]]*pid[[:space:]]*=[[:space:]]*([^[:space:];#]+).*/\1/p' \
        "/etc/php/$1/fpm/php-fpm.conf" 2>/dev/null | tail -n 1
}

log_info "===== patching_php.sh started ====="

[ "$(id -u)" -eq 0 ] || die "Must run as root"

exec 9>"$LOCKFILE"
flock -n 9 || die "Another patching_php.sh is already running"

# Missing or empty server_type means a PHP server.
SERVER_TYPE=$(fact_get basic server_type | tr '[:upper:]' '[:lower:]')
case "$SERVER_TYPE" in
    ''|php) log_info "server_type='${SERVER_TYPE}' -> PHP server, continuing" ;;
    *)      log_info "server_type='${SERVER_TYPE}' -> not PHP, nothing to do"
            log_info "===== patching_php.sh finished rc=0 ====="
            exit 0 ;;
esac

case "$(fact_get php multi_app_php | tr '[:upper:]' '[:lower:]')" in
    yes|true|1|on) MULTI_PHP=true ;;
    *)             MULTI_PHP=false ;;
esac
log_info "multi_php=${MULTI_PHP}"

# Fail fast if apt/dpkg is busy or broken.
# One name per pgrep call: pgrep warns on -x patterns longer than 15 characters.
for proc in dpkg apt-get apt aptitude unattended-upgr; do
    if pgrep -x "$proc" >/dev/null; then
        ps -eo pid,etime,cmd | grep -E 'apt|dpkg|unattended' | grep -v grep | head -5
        die "Another package manager process is running: ${proc}"
    fi
done
for lock in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock; do
    if fuser "$lock" >/dev/null 2>&1; then
        fuser -v "$lock" 2>&1
        die "Lock held by another process: $lock"
    fi
done
if dpkg --audit 2>&1 | grep -q .; then
    dpkg --audit 2>&1 | head -10
    die "dpkg is in an interrupted state - run: dpkg --configure -a"
fi

# Record running PHP-FPM versions and their pid path.
declare -A FPM_PID=()
while read -r unit; do
    ver=$(echo "$unit" | sed -nE 's/^php([0-9]+\.[0-9]+)-fpm\.service$/\1/p')
    [ -n "$ver" ] || continue
    FPM_PID[$ver]=$(get_fpm_pid "$ver")
    log_info "Running before: php${ver}-fpm pid='${FPM_PID[$ver]}'"
done < <(systemctl list-units --type=service --state=running --no-legend --plain 'php*-fpm.service' | awk '{print $1}')

export DEBIAN_FRONTEND=noninteractive UCF_FORCE_CONFFOLD=1

log_info "apt-get update"
apt-get update || die "apt-get update failed"

log_info "Installing/upgrading ${#PHP_FIX_PACKAGES[@]} PHP packages"
apt-get install -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    "${PHP_FIX_PACKAGES[@]}"
INSTALL_RC=$?
if [ "$INSTALL_RC" -eq 0 ]; then
    log_info "apt-get install completed"
else
    log_error "apt-get install failed (rc=${INSTALL_RC}), still running PHP-FPM recovery steps"
fi

declare -A RESTART=()

# Restore pid line in php-fpm.conf for previously running versions.
for ver in "${!FPM_PID[@]}"; do
    pid="${FPM_PID[$ver]}"
    conf="/etc/php/${ver}/fpm/php-fpm.conf"
    [ -n "$pid" ] && [ -f "$conf" ] || continue
    [ "$(get_fpm_pid "$ver")" = "$pid" ] && continue
    if grep -qE '^[[:space:]]*pid[[:space:]]*=' "$conf"; then
        sed -i -E "s|^[[:space:]]*pid[[:space:]]*=.*|pid = ${pid}|" "$conf"
    else
        sed -i "/^\[global\]/a pid = ${pid}" "$conf"
    fi
    log_info "Restored pid = ${pid} in ${conf}"
    RESTART[$ver]=1
done

UNIT_CHANGED=false
for unit_path in /lib/systemd/system/php*-fpm.service; do
    [ -f "$unit_path" ] || continue
    unit=$(basename "$unit_path")
    ver=$(echo "$unit" | sed -nE 's/^php([0-9]+\.[0-9]+)-fpm\.service$/\1/p')
    [ -n "$ver" ] || continue

    # Single PHP: stop and mask versions that were not running before install.
    if [ "$MULTI_PHP" = false ] && [ "${#FPM_PID[@]}" -gt 0 ] && [ -z "${FPM_PID[$ver]+x}" ]; then
        systemctl stop "$unit" 2>/dev/null
        if systemctl mask "$unit" >/dev/null 2>&1; then
            log_info "Stopped and masked ${unit}"
        else
            log_error "Failed to mask ${unit}"
        fi
    fi

    # Package upgrade replaces the unit file and drops the Cloudways UMask line.
    if ! grep -q '^UMask=0002$' "$unit_path"; then
        if grep -q '^UMask=' "$unit_path"; then
            sed -i 's/^UMask=.*/UMask=0002/' "$unit_path"
        else
            sed -i '/^\[Service\]/a UMask=0002' "$unit_path"
        fi
        log_info "Set UMask=0002 in ${unit_path}"
        UNIT_CHANGED=true
        if [ -n "${FPM_PID[$ver]+x}" ]; then
            RESTART[$ver]=1
        fi
    fi
done

if [ "$MULTI_PHP" = false ] && [ "${#FPM_PID[@]}" -eq 0 ]; then
    log_warn "No PHP-FPM was running before install, skipped stop/mask"
fi

if [ "$UNIT_CHANGED" = true ]; then
    systemctl daemon-reload && log_info "systemd daemon-reload done"
fi

for ver in "${!RESTART[@]}"; do
    if systemctl restart "php${ver}-fpm"; then
        log_info "Restarted php${ver}-fpm"
    else
        log_error "Restart failed: php${ver}-fpm"
    fi
done

# Verify previously running versions are up and pid file matches systemd MainPID.
FINAL_RC=$INSTALL_RC
for ver in "${!FPM_PID[@]}"; do
    unit="php${ver}-fpm"
    systemctl start "$unit" 2>/dev/null
    if ! systemctl is-active --quiet "$unit"; then
        log_error "${unit} is not running"
        FINAL_RC=1
        continue
    fi

    pid="${FPM_PID[$ver]}"
    [ -n "$pid" ] || { log_warn "${unit}: no pid line in php-fpm.conf, skipped pid check"; continue; }
    for _ in $(seq 1 30); do [ -s "$pid" ] && break; sleep 1; done

    file_pid=$(tr -d '[:space:]' < "$pid" 2>/dev/null)
    main_pid=$(systemctl show -p MainPID --value "$unit" 2>/dev/null)
    if [ -n "$file_pid" ] && [ "$file_pid" = "$main_pid" ]; then
        log_info "${unit}: pid file OK ${pid} (${file_pid})"
    else
        log_error "${unit}: pid file ${pid} has '${file_pid}', systemd MainPID is '${main_pid}'"
        FINAL_RC=1
    fi
done

log_info "===== patching_php.sh finished rc=${FINAL_RC} ====="
exit "$FINAL_RC"
PATCH_EOF
chmod 700 "$PATCH_SCRIPT"
}

clear_disk_space() {
    local before after freed
    status "[1/3] Clearing disk space..."
    before=$(physical_free_bytes)
    echo "Free space on / before: $(human_size "$before")"

    if ! curl -fsSL "$CLEANUP_URL" | bash > "$CLEANUP_LOG" 2>&1; then
        fail "Disk cleanup script failed, see $CLEANUP_LOG"
        tail -n 20 "$CLEANUP_LOG" >&2
        exit 1
    fi

    after=$(physical_free_bytes)
    freed=$((after - before))
    echo "Free space on / after:  $(human_size "$after")"

    if (( freed < MIN_FREED_BYTES )); then
        warn "Nothing to clear: no disk space was freed (details: $CLEANUP_LOG)."
    else
        ok "Disk space cleared: $(human_size "$freed") freed."
    fi
}

run_patch() {
    local pid rc last line elapsed=0
    status "[2/3] Now running patching..."

    # Patch even when nothing was cleared, as long as apt has room to work.
    if (( $(available_bytes) < MIN_FREE_BYTES )); then
        fail "Only $(human_size "$(available_bytes)") available on /, need $(human_size "$MIN_FREE_BYTES") for apt. Patching not started."
        exit 1
    fi

    write_patch_script
    : >> "$PATCH_LOG"
    last=$(wc -l < "$PATCH_LOG")
    echo "Patch log: $PATCH_LOG (the patch keeps running even if this SSH session drops)"

    # Own session: an SSH disconnect kills this wrapper but not the patch.
    setsid -w bash "$PATCH_SCRIPT" < /dev/null > /dev/null 2>&1 &
    pid=$!

    while kill -0 "$pid" 2>/dev/null; do
        sleep 10
        elapsed=$((elapsed + 10))
        line=$(tail -n +"$((last + 1))" "$PATCH_LOG" | grep -E '\[(INFO|WARN|ERROR)\]' | tail -n 1 | cut -c 21-)
        printf '  ... %3ss  %s\n' "$elapsed" "${line:-working}"
    done
    wait "$pid"
    rc=$?

    # Show this run's status lines from the patch log.
    tail -n +"$((last + 1))" "$PATCH_LOG" | grep -E '\[(INFO|WARN|ERROR)\]' | cut -c 21- | sed 's/^/  /'

    if (( rc == 0 )); then
        ok "Patch completed."
    else
        fail "Patch finished with rc=${rc}, see $PATCH_LOG. Verifying anyway..."
    fi
    return "$rc"
}

verify_patch() {
    local installed unpatched
    status "[3/3] Patch completed, now verifying..."

    installed=$(dpkg -l 'php[0-9]*-fpm' 2>/dev/null | awk '/^ii/ {print $2, $3}')
    if [[ -z "$installed" ]]; then
        fail "No php*-fpm packages are installed."
        return 1
    fi

    echo "dpkg -l 'php[0-9]*-fpm' | grep ${PATCH_VERSION}:"
    grep "$PATCH_VERSION" <<< "$installed" | sed 's/^/  /'

    unpatched=$(grep -v "$PATCH_VERSION" <<< "$installed")
    if [[ -n "$unpatched" ]]; then
        fail "These php*-fpm packages are NOT on ${PATCH_VERSION}:"
        sed 's/^/  /' <<< "$unpatched" >&2
        return 1
    fi
    ok "Verified: all installed php*-fpm packages are on ${PATCH_VERSION}."
}

main() {
    local patch_rc
    if [[ $(id -u) -ne 0 ]]; then
        fail "Must run as root."
        exit 1
    fi

    clear_disk_space
    run_patch
    patch_rc=$?

    if verify_patch && (( patch_rc == 0 )); then
        status "DONE: disk cleared, PHP patched and verified."
        exit 0
    fi
    status "FINISHED WITH ERRORS: check $PATCH_LOG"
    exit 1
}

# Wrapped in main so bash reads the whole script before running (curl | bash).
main "$@"
