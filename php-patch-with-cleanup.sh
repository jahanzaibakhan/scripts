#!/usr/bin/env bash
#
# php-patch-with-cleanup.sh
# Frees disk space, applies the PHP vulnerability fix (patching_php.sh), then
# verifies the patched php*-fpm packages (version 20261021).
#
# In the terminal: pre-checks (root, no patch already running, Debian 11+, not
# already patched), then steps 1-2 and the free-space check, so any reason the
# patch cannot run is shown right there. Only steps 3-4 (patch, verify) run in a
# detached screen session named "php" (setsid if screen is missing), which
# closes by itself when done. The full result is written to /var/log/php-patch-summary.log,
# ending with one "RESULT: ..." line.
#
#  1. Clearing disk space  runs opsgenie/disk-cleanup.sh. If no space is
#                          freed, warns "Nothing to clear" and still patches,
#                          unless less than 1.2 GiB is free on / (df "Avail").
#  2. Sury signing key     replaces expired copies of the DEB.SURY.ORG key
#                          (php, apache2, nginx repos) with the renewed key from
#                          packages.sury.org, or apt-get update fails EXPKEYSIG.
#  3. Patching             runs patching_php.sh (embedded below, unchanged) in
#                          its own session, so it keeps going if SSH drops.
#  4. Verify               every installed php*-fpm must be on 20261021.
#
# Usage (as root on the server):
#   curl -fsSL https://raw.githubusercontent.com/jahanzaibakhan/scripts/main/php-patch-with-cleanup.sh | bash
#   ... | bash -s -- --foreground      # old behaviour: run everything in this terminal
#
# Dashboard reporting (RUNNING / COMPLETED / NO_ACTION / FAILED, with the log):
#   PATCH_REPORT_TOKEN='<token>' bash -c "$(curl -fsSL https://raw.githubusercontent.com/jahanzaibakhan/scripts/main/php-patch-with-cleanup.sh)"
# Without PATCH_REPORT_TOKEN nothing is reported. PATCH_REPORT_URL overrides the endpoint.
#
# Logs:
#   /var/log/php-patch-summary.log      result of the last run (what you saw on screen)
#   /var/log/patching_php_cleanup.log   disk cleanup output
#   /var/log/patching_php.log           patch output (timestamped)

set -o pipefail

CLEANUP_URL="https://raw.githubusercontent.com/jahanzaibakhan/opsgenie/main/disk-cleanup.sh"
CLEANUP_LOG="/var/log/patching_php_cleanup.log"
PATCH_SCRIPT="/root/patching_php.sh"
PATCH_LOG="/var/log/patching_php.log"
PATCH_LOCK="/var/run/patching_php.lock"
PATCH_VERSION="20261021"
SUMMARY_LOG="/var/log/php-patch-summary.log"
RUN_SCRIPT="/root/php-patch-run.sh"
RUN_LOCK="/var/run/php-patch-with-cleanup.lock"
SCREEN_NAME="php"
PATCH_REPORT_URL="${PATCH_REPORT_URL:-https://phpstack-1503702-6743017.cloudwaysapps.com/api/report.php}"
PATCH_REPORT_TOKEN="${PATCH_REPORT_TOKEN:-}"
RUN_ID=""
SERVER_IP=""
RUN_STARTED_AT=""
# The dashboard's *.cloudwaysapps.com certificate chains to this root, which
# Debian 11's ca-certificates (20230311) lacks, so curl there fails with
# "self signed certificate in certificate chain". Added to the system bundle
# for dashboard requests only. From Debian 12 ca-certificates 20250419,
# SHA256 C3:2F:FD:9F:46:F9:36:D1:6C:36:73:99:09:59:43:4B:9A:D6:0A:AF:BB:9E:7C:F3:36:54:F1:44:CC:1B:A1:43
SSLCOM_TLS_ECC_ROOT_2022="-----BEGIN CERTIFICATE-----
MIICOjCCAcCgAwIBAgIQFAP1q/s3ixdAW+JDsqXRxDAKBggqhkjOPQQDAzBOMQsw
CQYDVQQGEwJVUzEYMBYGA1UECgwPU1NMIENvcnBvcmF0aW9uMSUwIwYDVQQDDBxT
U0wuY29tIFRMUyBFQ0MgUm9vdCBDQSAyMDIyMB4XDTIyMDgyNTE2MzM0OFoXDTQ2
MDgxOTE2MzM0N1owTjELMAkGA1UEBhMCVVMxGDAWBgNVBAoMD1NTTCBDb3Jwb3Jh
dGlvbjElMCMGA1UEAwwcU1NMLmNvbSBUTFMgRUNDIFJvb3QgQ0EgMjAyMjB2MBAG
ByqGSM49AgEGBSuBBAAiA2IABEUpNXP6wrgjzhR9qLFNoFs27iosU8NgCTWyJGYm
acCzldZdkkAZDsalE3D07xJRKF3nzL35PIXBz5SQySvOkkJYWWf9lCcQZIxPBLFN
SeR7T5v15wj4A4j3p8OSSxlUgaNjMGEwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSME
GDAWgBSJjy+j6CugFFR781a4Jl9nOAuc0DAdBgNVHQ4EFgQUiY8vo+groBRUe/NW
uCZfZzgLnNAwDgYDVR0PAQH/BAQDAgGGMAoGCCqGSM49BAMDA2gAMGUCMFXjIlbp
15IkWE8elDIPDAI2wv2sdDJO4fscgIijzPvX6yv/N33w7deedWo1dlJF4AIxAMeN
b0Igj762TVntd00pxCAgRWSGOlDGxK0tk/UYfXLtqc/ErFc2KAhl3zx5Zn6g6g==
-----END CERTIFICATE-----"
MIN_FREED_BYTES=$((1024 * 1024))          # under 1 MiB freed counts as nothing cleared
MIN_FREE_BYTES=1288490188                 # 1.2 GiB df "Avail" needed after cleanup
SURY_KEY_URL="https://packages.sury.org/php/apt.gpg"
SURY_FPR="15058500A0235D97F5D10063B188E2B695BD4743"

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

# df's "Avail" for / (what df -h shows; excludes blocks reserved for root).
free_bytes() { df -PB1 / 2>/dev/null | awk 'NR == 2 { print $4 }'; }

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
    status "[1/4] Clearing disk space..."
    before=$(free_bytes)
    echo "Free space on / before: $(human_size "$before")"

    if ! curl -fsSL "$CLEANUP_URL" | bash > "$CLEANUP_LOG" 2>&1; then
        fail "Disk cleanup script failed, see $CLEANUP_LOG"
        tail -n 20 "$CLEANUP_LOG" >&2
        exit 1
    fi

    after=$(free_bytes)
    freed=$((after - before))
    echo "Free space on / after:  $(human_size "$after")"

    if (( freed < MIN_FREED_BYTES )); then
        warn "Nothing to clear: no disk space was freed (details: $CLEANUP_LOG)."
    else
        ok "Disk space cleared: $(human_size "$freed") freed."
    fi
}

# Prints the Sury key's validity (e=expired) and expiry epoch if the keyring has it.
sury_key_state() {
    gpg --no-default-keyring --keyring "$1" --list-keys --with-colons 2>/dev/null |
        awk -F: -v fpr="$SURY_FPR" '
            /^pub:/ { v = $2; x = $7 }
            /^fpr:/ && $10 == fpr { print v, x; exit }
        '
}

# Keys in a keyring file (more than one: merge with --import instead of overwriting).
key_count() {
    gpg --no-default-keyring --keyring "$1" --list-keys --with-colons 2>/dev/null | grep -c '^pub:'
}

refresh_sury_key() {
    local new_key backup_dir f state exp now fixed=0 failed=0
    status "[2/4] Checking Sury signing key..."

    if ! command -v gpg >/dev/null 2>&1; then
        warn "gpg is not installed, skipped Sury key check."
        return
    fi

    # Throwaway gpg home so nothing lands in /root/.gnupg.
    export GNUPGHOME
    GNUPGHOME=$(mktemp -d)
    new_key="$GNUPGHOME/sury.gpg"
    now=$(date +%s)

    local -a expired=()
    for f in /etc/apt/trusted.gpg /etc/apt/trusted.gpg.d/*.gpg /usr/share/keyrings/*.gpg; do
        [[ -f "$f" ]] || continue
        state=$(sury_key_state "$f")
        [[ -n "$state" ]] || continue
        exp=${state#* }
        if [[ "${state%% *}" == e ]] || [[ -n "$exp" && "$exp" -le "$now" ]]; then
            expired+=("$f")
        fi
    done

    if (( ${#expired[@]} == 0 )); then
        ok "Sury key is valid, nothing to refresh."
        rm -rf "$GNUPGHOME"; unset GNUPGHOME
        return
    fi
    warn "Expired Sury key in ${#expired[@]} keyring(s), fetching renewed key from $SURY_KEY_URL"

    if ! curl -fsSL --max-time 30 "$SURY_KEY_URL" -o "$new_key"; then
        fail "Could not download $SURY_KEY_URL, apt-get update will likely fail with EXPKEYSIG."
        rm -rf "$GNUPGHOME"; unset GNUPGHOME
        return
    fi
    exp=$(gpg --show-keys --with-colons "$new_key" 2>/dev/null |
        awk -F: -v fpr="$SURY_FPR" '/^pub:/ { e = $7 } /^fpr:/ && $10 == fpr { print e; exit }')
    if [[ -z "$exp" || "$exp" -le "$now" ]]; then
        fail "Downloaded key is not the Sury key or is still expired, left keyrings unchanged."
        rm -rf "$GNUPGHOME"; unset GNUPGHOME
        return
    fi

    backup_dir="/root/sury-key-backup-$(date +%Y%m%d%H%M%S)"
    mkdir -p "$backup_dir"
    for f in "${expired[@]}"; do
        cp -a "$f" "$backup_dir/$(echo "${f#/}" | tr / _)"
        if (( $(key_count "$f") > 1 )); then
            gpg --no-default-keyring --keyring "$f" --import "$new_key" >/dev/null 2>&1
        else
            cp "$new_key" "$f" && chmod 644 "$f"
        fi
        state=$(sury_key_state "$f")
        if [[ -n "$state" && "${state%% *}" != e && "${state#* }" -gt "$now" ]]; then
            echo "  refreshed $f"
            fixed=$((fixed + 1))
        else
            fail "Could not refresh $f"
            failed=$((failed + 1))
        fi
    done
    rm -rf "$GNUPGHOME"; unset GNUPGHOME

    if (( failed == 0 )); then
        ok "Sury key refreshed in ${fixed} keyring(s), valid until $(date -d "@$exp" +%Y-%m-%d). Backups: $backup_dir"
    else
        warn "Sury key refreshed in ${fixed}, failed in ${failed} keyring(s). Backups: $backup_dir"
    fi
}

# Uses df "Avail", the free space df -h shows, not the root-reserved blocks.
check_disk_space() {
    local free
    free=$(free_bytes)
    if (( free < MIN_FREE_BYTES )); then
        fail "Not enough disk space: only $(human_size "$free") free on / after cleanup (df Avail), need at least $(human_size "$MIN_FREE_BYTES"). Patching not started - free up space and rerun."
        write_result FAILED "low_disk free=$(human_size "$free")"
        exit 1
    fi
    ok "Disk space OK for apt: $(human_size "$free") free on /."
}

run_patch() {
    local pid rc last line elapsed=0
    status "[3/4] Now running patching..."

    check_disk_space

    write_patch_script
    : >> "$PATCH_LOG"
    last=$(wc -l < "$PATCH_LOG")
    echo "Patch log: $PATCH_LOG"

    # Own session: an SSH disconnect kills this wrapper but not the patch.
    setsid -w bash "$PATCH_SCRIPT" < /dev/null > /dev/null 2>&1 3>&- &
    pid=$!

    # Terminal: one line redrawn in place on fd 3 (kept out of the summary log),
    # dots every second, status every 10s. No terminal: one line per 10s.
    local cols dots
    cols=$(tput cols 2>/dev/null || echo 120)
    while kill -0 "$pid" 2>/dev/null; do
        if (( elapsed % 10 == 0 )); then
            line=$(tail -n +"$((last + 1))" "$PATCH_LOG" | grep -E '\[(INFO|WARN|ERROR)\]' | tail -n 1 | cut -c 21-)
        fi
        # Keep the dashboard's RUNNING row current, without holding up the loop.
        if (( elapsed > 0 && elapsed % 60 == 0 )); then
            report_status RUNNING "${line:-Patching}" 1 < /dev/null > /dev/null 2>&1 3>&- &
        fi
        if [[ -n "$SPIN" ]]; then
            dots=$(printf '%*s' $((elapsed % 3 + 1)) '' | tr ' ' .)
            printf '\r\033[K  Running%-3s %4ss  %s' "$dots" "$elapsed" "$(cut -c 1-$((cols - 22)) <<< "${line:-working}")" >&3
        elif (( elapsed > 0 && elapsed % 10 == 0 )); then
            printf '  ... %3ss  %s\n' "$elapsed" "${line:-working}"
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    [[ -n "$SPIN" ]] && printf '\r\033[K' >&3
    wait "$pid"
    rc=$?

    # Show this run's status lines from the patch log.
    tail -n +"$((last + 1))" "$PATCH_LOG" | grep -E '\[(INFO|WARN|ERROR)\]' | cut -c 21- | sed 's/^/  /'

    # Another run took the lock between our check and this start.
    if tail -n +"$((last + 1))" "$PATCH_LOG" | grep -q 'Another patching_php.sh is already running'; then
        show_running_patch
        exit 1
    fi

    if (( rc == 0 )); then
        ok "Patch completed."
    else
        fail "Patch finished with rc=${rc}, see $PATCH_LOG. Verifying anyway..."
    fi
    return "$rc"
}

verify_patch() {
    local installed unpatched
    status "[4/4] Patch completed, now verifying..."

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

# PIDs of a patching_php.sh run in progress (holder of its lock), if any.
# Only "bash [path/]patching_php.sh": under bash -c "$(curl ...)" this script's
# own text (which mentions patching_php.sh) is on the command line of this shell
# and of every subshell, so a looser pattern would find itself.
running_patch_pids() {
    local pids pid alive=""
    pids=$(pgrep -f '^(/usr)?(/bin/)?bash +([^ ]*/)?patching_php\.sh( |$)')
    if [[ -z "$pids" && -e "$PATCH_LOCK" ]] && ! flock -n "$PATCH_LOCK" true 2>/dev/null; then
        pids=$(fuser "$PATCH_LOCK" 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$')
    fi
    for pid in $pids; do
        [[ "$pid" != "$$" && "$pid" != "$BASHPID" ]] && kill -0 "$pid" 2>/dev/null && alive+="$pid "
    done
    echo $alive
}

show_running_patch() {
    local pids line
    pids=$(running_patch_pids)
    fail "patching_php.sh is already running on this server, not starting another run."
    if [[ -n "$pids" ]]; then
        echo "Running process(es):"
        ps -o pid=,etime=,cmd= -p "${pids// /,}" 2>/dev/null | sed 's/^/  PID /'
    fi
    line=$(grep -E '\[(INFO|WARN|ERROR)\]' "$PATCH_LOG" 2>/dev/null | tail -n 1 | cut -c 21-)
    [[ -n "$line" ]] && echo "Its latest step: $line"
    echo "Wait for it to finish, then rerun this script. Follow it with:"
    echo "  tail -f $PATCH_LOG"
}

init_reporting() {
    if [[ -z "$PATCH_REPORT_TOKEN" ]]; then
        warn "Dashboard reporting off (no PATCH_REPORT_TOKEN)."
        return
    fi
    SERVER_IP=$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
    RUN_ID="$(hostname -s)-$(date +%s)"
    RUN_STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # The endpoint answers 405 to GET; anything else means reports would not arrive.
    local ca code
    ca=$(report_ca_bundle)
    code=$(curl -sS -o /dev/null -w '%{http_code}' --cacert "$ca" --connect-timeout 10 --max-time 20 "$PATCH_REPORT_URL" 2>&1)
    rm -f "$ca"
    if [[ "$code" == 405 ]]; then
        ok "Dashboard reporting on (${SERVER_IP})."
    else
        warn "Dashboard not reachable (${code}); the patch still runs, but this server will not show on the dashboard."
    fi
}

# System CA bundle plus the SSL.com root above, in a temp file (caller removes it).
report_ca_bundle() {
    local ca
    ca=$(mktemp)
    { cat /etc/ssl/certs/ca-certificates.crt 2>/dev/null; printf '%s\n' "$SSLCOM_TLS_ECC_ROOT_2022"; } > "$ca"
    echo "$ca"
}

# JSON string body: escape \ and ", turn newlines into \n, drop other control
# characters and invalid UTF-8.
json_str() {
    printf '%s' "$1" | { if command -v iconv >/dev/null 2>&1; then iconv -f UTF-8 -t UTF-8 -c; else cat; fi; } |
        sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' | tr -d '\000-\010\013-\037' |
        awk 'BEGIN { ORS = "" } NR > 1 { print "\\n" } { print }'
}

# $1 status (RUNNING/COMPLETED/NO_ACTION/FAILED), $2 current step, $3 attempts.
report_status() {
    [[ -n "$PATCH_REPORT_TOKEN" && -n "$RUN_ID" ]] || return 0
    local payload attempt packages ca
    packages=$(dpkg -l 'php[0-9]*-fpm' 2>/dev/null | awk '/^ii/ {print $2 "=" $3}' | paste -sd, -)
    payload=$(mktemp)
    printf '{"runId":"%s","serverIp":"%s","hostname":"%s","status":"%s","result":"%s","detail":"%s","step":"%s","packages":"%s","startedAt":"%s","log":"%s"}' \
        "$RUN_ID" "$SERVER_IP" "$(json_str "$(hostname -f 2>/dev/null || hostname)")" "$1" \
        "$(json_str "$RESULT")" "$(json_str "$RESULT_DETAIL")" "$(json_str "$2")" "$(json_str "$packages")" \
        "$RUN_STARTED_AT" "$(json_str "$(tail -n 600 "$SUMMARY_LOG" 2>/dev/null)")" > "$payload"
    ca=$(report_ca_bundle)
    for ((attempt = 1; attempt <= ${3:-1}; attempt++)); do
        if curl -fsS --cacert "$ca" --connect-timeout 10 --max-time 30 -X POST "$PATCH_REPORT_URL" \
            -H "Authorization: Bearer ${PATCH_REPORT_TOKEN}" -H "Content-Type: application/json" \
            --data-binary @"$payload" >/dev/null 2>&1; then
            rm -f "$payload" "$ca"
            return 0
        fi
        (( attempt < ${3:-1} )) && sleep 10
    done
    rm -f "$payload" "$ca"
    return 1
}

# Dashboard status for a RESULT state.
result_status() {
    case "$1" in
        PATCHED) echo COMPLETED ;;
        ALREADY_PATCHED) echo NO_ACTION ;;
        *) echo FAILED ;;
    esac
}

report_final() {
    [[ -n "$PATCH_REPORT_TOKEN" && -n "$RUN_ID" ]] || return 0
    if report_status "$(result_status "$RESULT")" "" 3; then
        ok "Result sent to the dashboard."
    else
        warn "Could not send the result to the dashboard."
    fi
}

# Last line of the summary log, read by fleet tooling: RESULT: <STATE> <detail>
RESULT=""
RESULT_DETAIL=""
IN_RUN=""
write_result() {
    RESULT="$1"
    RESULT_DETAIL="$2"
    if [[ -n "$IN_RUN" ]]; then
        printf 'RESULT: %s %s\n' "$1" "$2"     # stdout already copies to the summary
    else
        printf 'RESULT: %s %s\n' "$1" "$2" | tee -a "$SUMMARY_LOG"
        report_final
    fi
}

# On exit: make sure a RESULT line exists, then let the log copier finish
# before the screen closes (it would otherwise be cut off by the hangup).
# The dashboard gets the summary only after that, so its log is complete.
finish_run() {
    [[ -n "$RESULT" ]] || write_result FAILED "see $PATCH_LOG"
    exec >&- 2>&-
    wait "$OUT_PID" 2>/dev/null
    if [[ "$RESULT" == BACKGROUND ]]; then
        RESULT=""
        report_status RUNNING "Patching in the background (screen ${SCREEN_NAME})" 3
    else
        report_status "$(result_status "$RESULT")" "" 3
    fi
}

# Another run of this wrapper (cleanup/Sury phase, before the patch starts).
wrapper_running() {
    [[ -e "$RUN_LOCK" ]] && ! flock -n "$RUN_LOCK" true 2>/dev/null
}

# Quick checks in the terminal. Exits when there is nothing to do or it cannot work.
preflight() {
    local deb major installed unpatched
    status "Pre-checks..."

    if wrapper_running || [[ -n "$(running_patch_pids)" ]]; then
        if [[ -n "$(running_patch_pids)" ]]; then
            show_running_patch
        else
            fail "php-patch-with-cleanup.sh is already running on this server (cleanup/key step), not starting another run."
            command -v screen >/dev/null 2>&1 && screen -ls 2>/dev/null | grep -q "\.${SCREEN_NAME}[[:space:]]" &&
                echo "Watch it: screen -r ${SCREEN_NAME}   (detach: Ctrl+A then D)"
            echo "Result when done: cat $SUMMARY_LOG"
        fi
        # Keep the running job's summary; this run only reports.
        exit 1
    fi
    ok "No patch is running."
    : > "$SUMMARY_LOG"

    deb=$(cat /etc/debian_version 2>/dev/null)
    major=${deb%%.*}
    if [[ "$major" =~ ^[0-9]+$ ]] && (( major < 11 )); then
        fail "Debian ${deb}: no patched PHP build (${PATCH_VERSION}) exists for this release. Upgrade the OS to Debian 11/12 first."
        write_result UNSUPPORTED "debian=${deb}"
        exit 1
    fi
    ok "Debian ${deb:-unknown}."

    installed=$(dpkg -l 'php[0-9]*-fpm' 2>/dev/null | awk '/^ii/ {print $2, $3}')
    unpatched=$(grep -v "$PATCH_VERSION" <<< "$installed")
    if [[ -n "$installed" && -z "$unpatched" ]]; then
        sed 's/^/  /' <<< "$installed"
        ok "Already patched: all installed php*-fpm packages are on ${PATCH_VERSION}. Nothing to do."
        write_result ALREADY_PATCHED "$(awk '{print $1}' <<< "$installed" | paste -sd, -)"
        exit 0
    fi
    if [[ -n "$unpatched" ]]; then
        echo "Not on ${PATCH_VERSION} yet:"
        sed 's/^/  /' <<< "$unpatched"
    fi
}

# $1: seconds to wait for the lock (the background run waits for the terminal run to let go).
hold_run_lock() {
    exec 8>"$RUN_LOCK"
    if ! flock -w "${1:-0}" 8; then
        fail "php-patch-with-cleanup.sh is already running on this server."
        exit 1
    fi
}

# From here on, everything printed also goes to the summary log (colours stripped).
start_summary_copy() {
    SPIN=""
    if [[ -t 1 ]]; then
        exec 3>&1
        SPIN=1
    fi
    # One copier process: line to the terminal as is, and to the summary without colours.
    # It must not hold the run lock (fd 8), or the background run could not take it.
    exec > >(exec 8>&-; while IFS= read -r line || [[ -n "$line" ]]; do
        printf '%s\n' "$line"
        printf '%s\n' "$line" | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' >> "$SUMMARY_LOG"
    done) 2>&1
    OUT_PID=$!
    IN_RUN=1
    trap finish_run EXIT
}

# Steps 3-4, then the RESULT line.
patch_and_verify() {
    local patch_rc
    run_patch
    patch_rc=$?

    if verify_patch && (( patch_rc == 0 )); then
        status "DONE: disk cleared, PHP patched and verified."
        write_result PATCHED "$(dpkg -l 'php[0-9]*-fpm' 2>/dev/null | awk '/^ii/ {print $2}' | paste -sd, -)"
        exit 0
    fi
    status "FINISHED WITH ERRORS: check $PATCH_LOG"
    write_result FAILED "patch_rc=${patch_rc}, see $PATCH_LOG"
    exit 1
}

# Entry point of the generated background script.
run_background() {
    hold_run_lock 30
    start_summary_copy
    status "Patch started in the background $(date '+%Y-%m-%d %H:%M:%S %Z')"
    patch_and_verify
}

# Writes this script's variables and functions to a file and runs run_background
# from it in the background. Needed because under curl | bash there is no file to rerun.
start_background() {
    {
        echo '#!/usr/bin/env bash'
        echo '# Generated by php-patch-with-cleanup.sh; runs steps 3-4 (patch, verify).'
        echo 'set -o pipefail'
        declare -p CLEANUP_URL CLEANUP_LOG PATCH_SCRIPT PATCH_LOG PATCH_LOCK PATCH_VERSION \
            PATCH_REPORT_URL PATCH_REPORT_TOKEN RUN_ID SERVER_IP RUN_STARTED_AT SSLCOM_TLS_ECC_ROOT_2022 \
            SUMMARY_LOG RUN_SCRIPT RUN_LOCK SCREEN_NAME MIN_FREED_BYTES MIN_FREE_BYTES \
            SURY_KEY_URL SURY_FPR C_RESET C_BOLD C_RED C_GREEN C_YELLOW C_CYAN
        declare -f
        echo 'run_background'
    } > "$RUN_SCRIPT"
    chmod 700 "$RUN_SCRIPT"
    if ! bash -n "$RUN_SCRIPT"; then
        fail "Could not generate $RUN_SCRIPT, run with: bash -s -- --foreground"
        exit 1
    fi

    status "All checks passed, starting patch and verify in the background..."
    # The background run waits for our lock, which we hold until our last line is
    # in the summary (released on exit). Keep it and our output pipe off the child.
    if command -v screen >/dev/null 2>&1; then
        screen -dmS "$SCREEN_NAME" bash "$RUN_SCRIPT" < /dev/null > /dev/null 2>&1 3>&- 8>&-
        ok "Started in screen '${SCREEN_NAME}'. It closes by itself when done."
        echo "  Watch live:   screen -r ${SCREEN_NAME}   (detach again: Ctrl+A then D)"
    else
        setsid bash "$RUN_SCRIPT" < /dev/null > /dev/null 2>&1 3>&- 8>&- &
        ok "Started in the background (screen is not installed)."
    fi
    echo "  Progress:     tail -f $PATCH_LOG"
    echo "  Result:       cat $SUMMARY_LOG   (last line: RESULT: PATCHED / FAILED ...)"
    echo "You can close this session now."
    RESULT=BACKGROUND     # the background run writes the RESULT line
}

main() {
    local foreground=false
    [[ "${1:-}" == "--foreground" ]] && foreground=true

    if [[ $(id -u) -ne 0 ]]; then
        fail "Must run as root."
        exit 1
    fi

    init_reporting
    preflight
    hold_run_lock
    start_summary_copy
    status "Started $(date '+%Y-%m-%d %H:%M:%S %Z') on $(hostname)"
    report_status RUNNING "Pre-checks passed, clearing disk and checking Sury key" 1 < /dev/null > /dev/null 2>&1 3>&- &
    clear_disk_space
    refresh_sury_key
    check_disk_space

    if [[ "$foreground" == true ]]; then
        patch_and_verify
    fi
    start_background
}

# Wrapped in main so bash reads the whole script before running (curl | bash).
main "$@"
