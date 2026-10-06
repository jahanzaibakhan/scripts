#!/usr/bin/env bash
#
# debian12-upgrade-check.sh
#
# Read-only health check for servers upgraded from Debian 11 (bullseye) to
# Debian 12 (bookworm). Reports what the upgrade left unfinished: broken or
# leftover packages, MariaDB system tables not upgraded, Varnish down,
# PHP-FPM / core services down, failed units, missing Python modules
# (boto, boto3) and resource problems, each with date and time span.
#
# It makes no changes to the server. The only thing it writes is a temporary
# directory under /tmp for the Varnish VCL compile test, removed on exit.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/jahanzaibakhan/scripts/main/debian12-upgrade-check.sh | sudo bash
#   curl -fsSL https://raw.githubusercontent.com/jahanzaibakhan/scripts/main/debian12-upgrade-check.sh | sudo bash -s -- --summary
#   sudo bash debian12-upgrade-check.sh [--summary] [--no-color] [--help]
#
# Options:
#   --summary    print only the final summary
#   --no-color   disable colors (also honoured: NO_COLOR=1)
#
# Environment overrides:
#   PY_MODULES="boto boto3 botocore"    Python modules that must import
#   SERVICES="nginx apache2 ..."        services that must be active, if installed
#
# Exit code: 0 = all good, 1 = warnings only, 2 = failures found, 3 = not root

VERSION="1.0.0"

PY_MODULES=${PY_MODULES:-"boto boto3 botocore"}
SERVICES=${SERVICES:-"nginx apache2 mariadb redis-server memcached monit imunify360-agent"}

USE_COLOR=1
QUIET=0
[ -n "${NO_COLOR:-}" ] && USE_COLOR=0
for arg in "$@"; do
  case "$arg" in
    --no-color) USE_COLOR=0 ;;
    --summary)  QUIET=1 ;;
    -h|--help)
      cat <<'EOF'
debian12-upgrade-check.sh - read-only Debian 11 -> 12 upgrade health check

Usage: sudo bash debian12-upgrade-check.sh [--summary] [--no-color]

  --summary    print only the final summary
  --no-color   disable colors (or set NO_COLOR=1)

Env: PY_MODULES="boto boto3 botocore"  SERVICES="nginx apache2 mariadb ..."
Exit: 0 all good, 1 warnings, 2 failures, 3 not root
EOF
      exit 0 ;;
    *) echo "Unknown option: $arg (see --help)" >&2; exit 3 ;;
  esac
done

if [ "$USE_COLOR" = 1 ]; then
  RED=$'\e[1;31m'; GREEN=$'\e[1;32m'; YELLOW=$'\e[1;33m'; BLUE=$'\e[1;36m'
  BOLD=$'\e[1m'; DIM=$'\e[2m'; RESET=$'\e[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; DIM=""; RESET=""
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "${RED}This check needs root to read logs and the database. Run it with sudo.${RESET}" >&2
  exit 3
fi

export PATH="$PATH:/usr/sbin:/sbin:/usr/local/sbin:/usr/local/bin"
export LC_ALL=C
NOW=$(date +%s)
TMPDIR_VCL=""
trap '[ -n "$TMPDIR_VCL" ] && rm -rf "$TMPDIR_VCL"' EXIT

# ---------------------------------------------------------------- helpers

declare -a I_LVL I_AREA I_MSG I_TS
declare -a MISSING
declare -A REPORTED

ago() {
  local s=$(( NOW - $1 ))
  [ "$s" -lt 0 ] && s=0
  local d=$(( s / 86400 )) h=$(( s % 86400 / 3600 )) m=$(( s % 3600 / 60 ))
  if   [ "$d" -gt 0 ]; then printf '%dd %dh ago' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh %dm ago' "$h" "$m"
  else                      printf '%dm ago' "$m"
  fi
}

fmt_ts() {
  [ -z "$1" ] && return
  printf '%s (%s)' "$(date -d "@$1" '+%Y-%m-%d %H:%M %Z')" "$(ago "$1")"
}

to_epoch() { [ -n "$1" ] && date -d "$1" +%s 2>/dev/null; }

out()     { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
section() { out ""; out "${BOLD}== $1 ==${RESET}"; }
ok()      { out "  ${GREEN}[ OK ]${RESET} $1"; }
note()    { out "  ${BLUE}[INFO]${RESET} $1"; }
detail()  { out "         ${DIM}$1${RESET}"; }

record()  { I_LVL+=("$1"); I_AREA+=("$2"); I_MSG+=("$3"); I_TS+=("${4:-}"); }
bad() {
  out "  ${RED}[FAIL]${RESET} ${RED}$2${RESET}"
  [ -n "${3:-}" ] && detail "since $(fmt_ts "$3")"
  record FAIL "$1" "$2" "${3:-}"
}
warn() {
  out "  ${YELLOW}[WARN]${RESET} $2"
  [ -n "${3:-}" ] && detail "since $(fmt_ts "$3")"
  record WARN "$1" "$2" "${3:-}"
}

# all rotated copies of a log, oldest first, decompressed
logcat() {
  local base=$1 f
  for f in $(ls -1 "$base".*.gz 2>/dev/null | sort -t. -k3,3nr) "$base".1 "$base"; do
    [ -f "$f" ] && zcat -f "$f" 2>/dev/null
  done
}

unit_load()  { systemctl show -p LoadState --value "$1" 2>/dev/null; }
unit_since() {
  local t
  t=$(systemctl show -p StateChangeTimestamp --value "$1" 2>/dev/null)
  [ -n "$t" ] && [ "$t" != "n/a" ] && to_epoch "$t"
}
last_log() {   # last journal line for a unit, without the prefix
  journalctl -u "$1" -b --no-pager -o cat -n 50 2>/dev/null \
    | grep -iE 'error|fail|denied|cannot|could not' | tail -1 | cut -c1-160
}

# ---------------------------------------------------------------- header

HOST=$(hostname -f 2>/dev/null || hostname)
OS=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")
DEB_VER=$(cat /etc/debian_version 2>/dev/null)
KERNEL=$(uname -r)
BOOT_TS=$(to_epoch "$(uptime -s 2>/dev/null)")
IP=$(hostname -I 2>/dev/null | awk '{print $1}')

# migration start: first time base-files moved from 11.x to 12.x
MIG_TS=""
mig_line=$(logcat /var/log/dpkg.log | grep -E ' upgrade base-files:[^ ]+ 11[^ ]* 12' | head -1)
[ -n "$mig_line" ] && MIG_TS=$(to_epoch "$(echo "$mig_line" | awk '{print $1" "$2}')")
# migration end: last dpkg action within 6 hours of the start
MIG_END=""
if [ -n "$MIG_TS" ]; then
  w_from=$(date -d "@$MIG_TS" '+%Y-%m-%d %H:%M:%S')
  w_to=$(date -d "@$(( MIG_TS + 21600 ))" '+%Y-%m-%d %H:%M:%S')
  last=$(logcat /var/log/dpkg.log | awk -v a="$w_from" -v b="$w_to" '{t = $1 " " $2} t >= a && t <= b {l = t} END {print l}')
  MIG_END=$(to_epoch "$last")
fi
MIG_SINCE=$( [ -n "$MIG_TS" ] && date -d "@$MIG_TS" '+%Y-%m-%d %H:%M:%S' || echo "1970-01-01 00:00:00")

out "${BOLD}Debian 11 -> 12 upgrade check v$VERSION${RESET}"
out "  Host       : $HOST ${IP:+($IP)}"
out "  OS         : $OS (debian_version $DEB_VER)"
out "  Kernel     : $KERNEL"
out "  Booted     : $(fmt_ts "$BOOT_TS")"
if [ -n "$MIG_TS" ]; then
  out "  Upgrade    : started $(fmt_ts "$MIG_TS")"
  [ -n "$MIG_END" ] && out "               last package change $(date -d "@$MIG_END" '+%Y-%m-%d %H:%M %Z') ($(( (MIG_END - MIG_TS) / 60 )) min)"
else
  out "  Upgrade    : no 11 -> 12 base-files upgrade found in dpkg logs (rotated away or never upgraded)"
fi
out "  Checked at : $(date '+%Y-%m-%d %H:%M:%S %Z')"

# ---------------------------------------------------------------- 1. system

section "1. Operating system"

case "$DEB_VER" in
  12*) ok "Debian $DEB_VER (bookworm)" ;;
  11*) bad OS "Still Debian $DEB_VER (bullseye): upgrade not applied" ;;
  *)   warn OS "Unexpected Debian version: ${DEB_VER:-unknown}" ;;
esac

old_src=$(grep -rhsE '^[^#]*\bbullseye\b' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null)
if [ -n "$old_src" ]; then
  bad APT "APT sources still point to bullseye ($(echo "$old_src" | wc -l) lines)"
  echo "$old_src" | head -5 | while read -r l; do detail "$l"; done
else
  ok "APT sources: no bullseye entries"
fi

if echo "$KERNEL" | grep -q 'deb11'; then
  bad Kernel "Running Debian 11 kernel $KERNEL: server not rebooted into the Debian 12 kernel" "$MIG_TS"
elif [ -n "$MIG_TS" ] && [ -n "$BOOT_TS" ] && [ "$BOOT_TS" -lt "$MIG_TS" ]; then
  warn Kernel "Not rebooted since the upgrade started" "$MIG_TS"
else
  ok "Kernel $KERNEL"
fi

if [ -f /var/run/reboot-required ]; then
  warn Kernel "Reboot required flag is set ($(sort -u /var/run/reboot-required.pkgs 2>/dev/null | paste -sd, -))" \
    "$(stat -c %Y /var/run/reboot-required 2>/dev/null)"
fi

# ---------------------------------------------------------------- 2. packages

section "2. Packages"

audit=$(dpkg --audit 2>&1)
if [ -n "$audit" ]; then
  bad Packages "dpkg --audit reports unfinished packages"
  echo "$audit" | grep -vE '^\s*$' | head -10 | while read -r l; do detail "$l"; done
else
  ok "dpkg --audit: clean"
fi

broken=$(dpkg-query -W -f='${db:Status-Abbrev}|${Package}|${Version}\n' 2>/dev/null \
  | awk -F'|' '$1 !~ /^[ih]i  *$/ && $1 !~ /^rc/ && $1 !~ /^un/ {print}')
if [ -n "$broken" ]; then
  bad Packages "$(echo "$broken" | wc -l) package(s) half-installed or not configured"
  echo "$broken" | head -15 | while IFS='|' read -r st p v; do detail "$st $p $v"; done
else
  ok "All packages fully installed and configured"
fi

if apt_chk=$(timeout 90 apt-get check -qq 2>&1); then
  ok "apt-get check: dependencies OK"
else
  bad Packages "apt-get check reports broken dependencies"
  echo "$apt_chk" | tail -5 | while read -r l; do detail "$l"; done
fi

# packages dpkg failed on during/after the upgrade, and whether they recovered
fails=$(logcat /var/log/apt/term.log | tr -d '\r' | awk -v since="$MIG_SINCE" '
  /^Log started:/ { ls = $3 " " $4 }
  /dpkg: error processing package/ {
    if (match($0, /package [^ ]+/) && ls >= since) {
      p = substr($0, RSTART + 8, RLENGTH - 8); sub(/:.*/, "", p); sub(/\(.*/, "", p)
      last[p] = ls
    }
  }
  END { for (p in last) print last[p] "|" p }' | sort)
if [ -n "$fails" ]; then
  while IFS='|' read -r when p; do
    st=$(dpkg-query -W -f='${db:Status-Abbrev}' "$p" 2>/dev/null)
    if echo "$st" | grep -qE '^[ih]i'; then
      note "$p failed to configure at $when, now installed OK"
    else
      bad Packages "$p failed to configure at $when and is still broken (status '${st:-missing}')" "$(to_epoch "$when")"
    fi
  done <<< "$fails"
else
  ok "No dpkg configure errors logged since the upgrade"
fi

apt_err=$(logcat /var/log/apt/history.log | awk -v since="$MIG_SINCE" '
  /^Start-Date:/  { sd = substr($0, 13); gsub(/  +/, " ", sd); cl = ""; er = "" }
  /^Commandline:/ { cl = substr($0, 14) }
  /^Error:/       { er = substr($0, 8) }
  /^End-Date:/    { if (er != "" && sd >= since) print sd "|" substr(cl, 1, 100) "|" er }')
if [ -n "$apt_err" ]; then
  n=$(echo "$apt_err" | wc -l)
  if [ -z "$audit" ] && [ -z "$broken" ]; then
    warn Packages "$n apt run(s) ended with an error since the upgrade (current package state is clean)"
  else
    bad Packages "$n apt run(s) ended with an error since the upgrade"
  fi
  echo "$apt_err" | tail -5 | while IFS='|' read -r sd cl er; do detail "$sd  $cl"; detail "   -> $er"; done
fi

left=$(dpkg-query -W -f='${db:Status-Abbrev}|${Package}|${Version}\n' 2>/dev/null \
  | awk -F'|' '$1 ~ /^[ih]i/ && $3 ~ /deb11|bullseye/ {print $2 " " $3}')
if [ -n "$left" ]; then
  warn Packages "$(echo "$left" | wc -l) Debian 11 package(s) still installed"
  echo "$left" | head -12 | while read -r l; do detail "$l"; done
else
  ok "No Debian 11 packages left"
fi

held=$(apt-mark showhold 2>/dev/null)
[ -n "$held" ] && note "$(echo "$held" | wc -l) package(s) on hold: $(echo "$held" | head -8 | tr '\n' ' ')$( [ "$(echo "$held" | wc -l)" -gt 8 ] && echo '...')"

rc=$(dpkg -l 2>/dev/null | awk '/^rc/ {n++} END {print n+0}')
[ "$rc" -gt 0 ] && note "$rc removed package(s) with leftover config files (rc)"

# ---------------------------------------------------------------- 3. database

section "3. MariaDB / MySQL"

DB_CLIENT=$(command -v mariadb || command -v mysql)
DB_UNIT=""
for u in mariadb mysql; do
  [ "$(unit_load $u)" = "loaded" ] && { DB_UNIT=$u; break; }
done

if [ -z "$DB_CLIENT" ] && [ -z "$DB_UNIT" ]; then
  note "No MariaDB/MySQL installed"
else
  REPORTED[mariadb]=1; REPORTED[mysql]=1
  pkg_ver=$($DB_CLIENT --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-MariaDB|Distrib [0-9.]+|Ver [0-9.]+' | head -1)
  srv_ver=$(timeout 10 $DB_CLIENT -NBe 'SELECT VERSION()' 2>/dev/null)
  db_active=$(systemctl is-active "$DB_UNIT" 2>/dev/null)
  if [ "$db_active" = "active" ]; then
    ok "$DB_UNIT is running (${srv_ver:-${pkg_ver:-version unknown}})"
  else
    bad MariaDB "$DB_UNIT is $db_active" "$(unit_since "$DB_UNIT")"
    detail "$(last_log "$DB_UNIT")"
  fi

  datadir=$(timeout 10 $DB_CLIENT -NBe 'SELECT @@datadir' 2>/dev/null)
  datadir=${datadir:-/var/lib/mysql/}
  [ -z "$srv_ver" ] && [ "$db_active" = "active" ] && warn MariaDB "Cannot log in as root over the socket, so some checks were skipped"

  # when the server package last changed version
  db_pkg_ts=$(logcat /var/log/dpkg.log | grep -E ' (upgrade|install) (mariadb|mysql)-server(-core)?[:-][^ ]* ' | tail -1 | awk '{print $1" "$2}')
  db_pkg_ts=$(to_epoch "$db_pkg_ts")

  info_file=""
  for f in "${datadir%/}/mariadb_upgrade_info" "${datadir%/}/mysql_upgrade_info"; do
    [ -f "$f" ] && { info_file=$f; break; }
  done
  info_ver=$( [ -n "$info_file" ] && tr -d '\0\n' < "$info_file")
  info_ts=$( [ -n "$info_file" ] && stat -c %Y "$info_file")

  if echo "$srv_ver $pkg_ver" | grep -qi mariadb; then
    UPG=$(command -v mariadb-upgrade || command -v mysql_upgrade)
    chk=$( [ -n "$UPG" ] && timeout 60 "$UPG" --check-if-upgrade-is-needed 2>&1 | head -2)
    if echo "$chk" | grep -qiE 'upgrade detected|check required|is needed'; then
      bad MariaDB "System tables NOT upgraded: data at ${info_ver:-unknown}, server ${srv_ver:-$pkg_ver}. mariadb-upgrade was never run" "${db_pkg_ts:-$MIG_TS}"
      detail "$(echo "$chk" | head -1)"
    elif [ -n "$chk" ]; then
      ok "System tables upgraded (${info_ver:-?}, recorded $(fmt_ts "$info_ts"))"
    else
      warn MariaDB "Could not run mariadb-upgrade --check-if-upgrade-is-needed"
    fi
  else
    note "MySQL (not MariaDB): system tables upgrade automatically, upgrade check skipped"
  fi

  if [ -n "$DB_UNIT" ]; then
    dbj=$(journalctl -u "$DB_UNIT" -b --no-pager -o short-unix 2>/dev/null)
    # Cloudways logs to the journal; include log_error if it is a file
    log_err=$(timeout 10 $DB_CLIENT -NBe 'SELECT @@log_error' 2>/dev/null)
    case "$log_err" in /*) [ -f "$log_err" ] && dbf=$(tail -n 20000 "$log_err" 2>/dev/null) ;; esac

    defs=$(echo "$dbj" | grep 'Incorrect definition of table')
    defs_n=$(echo -n "$defs" | grep -c . )
    if [ "$defs_n" -gt 0 ]; then
      defs_last=$(echo "$defs" | tail -1 | awk '{print int($1)}')
      defs_first=$(echo "$defs" | head -1 | awk '{print int($1)}')
      tables=$(echo "$defs" | grep -oE 'table [a-z_]+\.[a-z_]+' | sort -u | sed 's/table //' | paste -sd' ' -)
      if [ -n "$info_ts" ] && [ "$defs_last" -lt "$info_ts" ] && ! echo "$chk" | grep -qiE 'detected|required'; then
        note "$defs_n 'Incorrect definition' errors this boot ($tables), all before the upgrade fix. Last: $(fmt_ts "$defs_last")"
      else
        bad MariaDB "$defs_n 'Incorrect definition of table' errors this boot ($tables). Last: $(fmt_ts "$defs_last")" "$defs_first"
      fi
    else
      ok "No 'Incorrect definition of table' errors this boot"
    fi

    maint=$(echo "$dbj" | grep -E "debian-sys-maint|debian-start.*(ERROR|FATAL)" | tail -1)
    [ -n "$maint" ] && warn MariaDB "debian-start / debian-sys-maint errors at startup: $(echo "$maint" | cut -d' ' -f4- | cut -c1-120)" \
      "$(echo "$maint" | awk '{print int($1)}')"

    crashed=$(printf '%s\n%s\n' "$dbj" "$dbf" | grep -ciE 'marked as crashed|is corrupt')
    [ "$crashed" -gt 0 ] && bad MariaDB "$crashed crashed or corrupt table message(s) in the log"

    day=$(( NOW - 86400 ))
    other=$(echo "$dbj" | awk -v d="$day" 'int($1) >= d' | grep '\[ERROR\]' | grep -v 'Incorrect definition')
    if [ -n "$other" ]; then
      warn MariaDB "$(echo "$other" | wc -l) other [ERROR] line(s) in the last 24h"
      echo "$other" | sed -E 's/.*\[ERROR\] //' | cut -c1-110 | sort | uniq -c | sort -rn | head -3 \
        | while read -r l; do detail "$l"; done
    fi
  fi
fi

# ---------------------------------------------------------------- 4. varnish

section "4. Varnish"

v_load=$(unit_load varnish)
if [ "$v_load" = "not-found" ] || [ -z "$v_load" ]; then
  note "Varnish not installed"
else
  REPORTED[varnish]=1
  v_pkg=$(dpkg-query -W -f='${Version}' varnish 2>/dev/null)
  case "$v_pkg" in
    *deb12*) v_src="Debian package" ;;
    "")      v_src="package not installed" ;;
    *)       v_src="varnish repo" ;;
  esac
  note "Varnish ${v_pkg:-?} ($v_src)"
  [ -z "$v_pkg" ] && bad Varnish "Unit exists but the varnish package is not installed"

  v_act=$(systemctl is-active varnish 2>/dev/null)
  v_en=$(systemctl is-enabled varnish 2>/dev/null)
  if [ "$v_load" = "masked" ]; then
    m_ts=$(stat -c %Y /etc/systemd/system/varnish.service 2>/dev/null)
    bad Varnish "Varnish is MASKED (cannot start until unmasked)" "$m_ts"
    [ -n "$MIG_TS" ] && [ -n "$m_ts" ] && [ "$m_ts" -lt "$MIG_TS" ] && detail "masked before the upgrade started"
  elif [ "$v_act" = "active" ]; then
    ok "Varnish is running"
  else
    bad Varnish "Varnish is $v_act (enabled: $v_en)" "$(unit_since varnish)"
    l=$(last_log varnish); [ -n "$l" ] && detail "$l"
  fi
  [ "$v_load" != "masked" ] && [ "$v_en" = "disabled" ] && warn Varnish "Varnish is disabled at boot"

  unit_txt=$(systemctl cat varnish 2>/dev/null; cat /lib/systemd/system/varnish.service 2>/dev/null)
  store=$(echo "$unit_txt" | grep -m1 -oE -- '-s +file,[^, ]+' | sed -E 's/-s +file,//')
  vcl=$(echo "$unit_txt" | grep -m1 -oE -- ' -f +[^ ]+' | awk '{print $2}')
  if [ -n "$store" ]; then
    sdir=$(dirname "$store")
    if [ -d "$sdir" ]; then
      ok "Storage directory exists: $sdir ($(stat -c '%U:%G' "$sdir"))"
    else
      bad Varnish "Storage directory missing: $sdir (varnishd cannot create $store)"
    fi
  fi
  if [ -n "$vcl" ] && [ -f "$vcl" ] && command -v varnishd >/dev/null; then
    # varnishd drops to its own user to compile, so the work dir must be writable by it
    TMPDIR_VCL=$(mktemp -d /tmp/vclcheck.XXXXXX) && chmod 777 "$TMPDIR_VCL"
    # varnishd -C also prints harmless "Could not delete" cleanup notices
    verr=$(timeout 30 varnishd -C -n "$TMPDIR_VCL" -f "$vcl" -p vcc_allow_inline_c=on 2>&1 >/dev/null \
      | grep -vE '^\s*$|Could not delete')
    # Varnish 6.0 prints the generated C code on stderr, so only trust explicit markers
    if echo "$verr" | grep -q 'VCC-compiler'; then
      bad Varnish "VCL does not compile on Varnish ${v_pkg:-?}: $vcl"
      echo "$verr" | sed -n '2,5p' | while read -r l; do detail "$l"; done
    elif echo "$verr" | grep -qE 'VCL compilation failed|Permission denied'; then
      note "VCL compile test inconclusive: $(echo "$verr" | grep -m1 -E 'failed|denied' | cut -c1-100)"
    else
      ok "VCL compiles on Varnish ${v_pkg:-?}: $vcl"
    fi
  fi
  front=$(ss -ltnpH 'sport = :80' 2>/dev/null | grep -oE '"[^"]+"' | head -1 | tr -d '"')
  [ -n "$front" ] && note "Port 80 served by: $front"
fi

# ---------------------------------------------------------------- 5. php-fpm

section "5. PHP-FPM"

pool_names() { grep -hoE '^\s*\[[^]]+\]' /etc/php/"$1"/fpm/pool.d/*.conf 2>/dev/null | tr -d '[] \t' | grep -v '^global$'; }

fpm_units=$(systemctl list-unit-files --no-legend 'php*-fpm.service' 2>/dev/null | awk '{print $1}')
if [ -z "$fpm_units" ]; then
  note "No PHP-FPM units found"
else
  active_pools=""; inactive=""
  for u in $fpm_units; do
    ver=${u#php}; ver=${ver%-fpm.service}
    REPORTED[${u%.service}]=1
    if [ "$(systemctl is-active "$u" 2>/dev/null)" = "active" ]; then
      p=$(pool_names "$ver" | paste -sd' ' -)
      active_pools="$active_pools $p"
      ok "PHP $ver FPM running ($(echo "$p" | wc -w) pool(s))"
    else
      inactive="$inactive $u"
    fi
  done
  if [ -z "$active_pools" ]; then
    bad PHP-FPM "No PHP-FPM version is running"
  fi
  # an inactive version only matters if it holds pools no running version serves
  for u in $inactive; do
    ver=${u#php}; ver=${ver%-fpm.service}
    orphan=$(pool_names "$ver" | while read -r p; do echo " $active_pools " | grep -q " $p " || echo "$p"; done | paste -sd' ' -)
    if [ -n "$orphan" ]; then
      warn PHP-FPM "PHP $ver FPM is inactive and is the only version defining pool(s): $orphan" "$(unit_since "$u")"
    else
      out "  ${DIM}[ -- ] PHP $ver FPM inactive (not in use)${RESET}"
    fi
  done
  # Cloudways: every application needs a pool in a running PHP-FPM, with its socket present
  if [ -d /home/master/applications ]; then
    no_pool=""; no_sock=""; n_apps=0
    for d in /home/master/applications/*/; do
      app=$(basename "$d"); n_apps=$(( n_apps + 1 ))
      if ! echo " $active_pools " | grep -q " $app "; then
        no_pool="$no_pool $app"
      elif [ ! -S "/var/run/fpm-$app.sock" ] && [ ! -S "/run/php/fpm-$app.sock" ]; then
        no_sock="$no_sock $app"
      fi
    done
    [ -n "$no_pool" ] && bad PHP-FPM "$(echo $no_pool | wc -w) app(s) have no pool in a running PHP-FPM: $(echo $no_pool | cut -c1-120)"
    [ -n "$no_sock" ] && bad PHP-FPM "$(echo $no_sock | wc -w) app(s) are missing their PHP-FPM socket: $(echo $no_sock | cut -c1-120)"
    [ -z "$no_pool$no_sock" ] && [ "$n_apps" -gt 0 ] && ok "All $n_apps application(s) have a running PHP-FPM pool and socket"
  fi
fi

# ---------------------------------------------------------------- 6. services

section "6. Core services"

for s in $SERVICES; do
  [ -n "${REPORTED[$s]:-}" ] && continue
  load=$(unit_load "$s")
  [ "$load" = "not-found" ] || [ -z "$load" ] && continue
  REPORTED[$s]=1
  st=$(systemctl is-active "$s" 2>/dev/null)
  if [ "$load" = "masked" ]; then
    bad Services "$s is masked" "$(stat -c %Y /etc/systemd/system/"$s".service 2>/dev/null)"
  elif [ "$st" = "active" ]; then
    ok "$s running"
  else
    bad Services "$s is $st" "$(unit_since "$s")"
    l=$(last_log "$s"); [ -n "$l" ] && detail "$l"
  fi
done

# ---------------------------------------------------------------- 7. failed units

section "7. Failed systemd units"

transient=0
failed=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}')
if [ -z "$failed" ]; then
  ok "No failed units"
else
  for u in $failed; do
    name=${u%.service}
    [ -n "${REPORTED[$name]:-}" ] && continue
    case "$u" in
      run-*) transient=$(( transient + 1 )); continue ;;
      cloud-*|*.swap|*.mount) warn Units "$u failed" "$(unit_since "$u")" ;;
      *) bad Units "$u failed" "$(unit_since "$u")" ;;
    esac
    l=$(last_log "$u"); [ -n "$l" ] && detail "$l"
  done
  [ "$transient" -gt 0 ] && note "$transient transient run-* unit(s) failed (ignored)"
fi

# ---------------------------------------------------------------- 8. python

section "8. Python modules"

if ! command -v python3 >/dev/null; then
  bad Python "python3 is not installed"
else
  note "$(python3 --version 2>&1)"
  for m in $PY_MODULES; do
    res=$(python3 -c "import $m, os; print(getattr($m, '__version__', '?'), os.path.dirname($m.__file__))" 2>&1 | tail -1)
    if echo "$res" | grep -qE 'Error|No module'; then
      bad Python "Python module '$m' is missing"
      MISSING+=("$m")
    else
      v=${res%% *}; p=${res#* }
      case "$p" in
        /usr/lib/python3*) src="apt" ;;
        /usr/local/*)      src="pip" ;;
        *)                 src="$p" ;;
      esac
      ok "$m $v ($src)"
    fi
  done
  old_py=$(ls -d /usr/local/lib/python3.[0-9]* 2>/dev/null | grep -v "python$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])')" | xargs -r -n1 basename | paste -sd' ' -)
  [ -n "$old_py" ] && note "Old Python site dirs left in /usr/local/lib (unused): $old_py"
fi

# ---------------------------------------------------------------- 9. resources

section "9. Resources"

disk=$(df -P / | awk 'NR==2 {gsub("%", "", $5); print $5}')
disk_free=$(df -Ph / | awk 'NR==2 {print $4}')
if   [ "$disk" -ge 90 ]; then bad Resources "Root disk ${disk}% used ($disk_free free)"
elif [ "$disk" -ge 80 ]; then warn Resources "Root disk ${disk}% used ($disk_free free)"
else ok "Root disk ${disk}% used ($disk_free free)"
fi

mem_t=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)
mem_a=$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo)
swap_t=$(awk '/^SwapTotal:/ {print int($2/1024)}' /proc/meminfo)
if [ "$mem_t" -gt 0 ] && [ $(( mem_a * 100 / mem_t )) -lt 10 ]; then
  warn Resources "Low memory: ${mem_a} MB available of ${mem_t} MB"
else
  ok "Memory: ${mem_a} MB available of ${mem_t} MB"
fi
if [ "$swap_t" -eq 0 ]; then
  warn Resources "No swap active"
else
  ok "Swap: ${swap_t} MB"
fi

oom_since=${MIG_TS:-$BOOT_TS}
ooms=$(journalctl _TRANSPORT=kernel --since "@$oom_since" --no-pager -o short-unix 2>/dev/null | grep -E 'Out of memory|oom-kill|Killed process')
if [ -n "$ooms" ]; then
  last=$(echo "$ooms" | grep 'Killed process' | tail -1)
  warn Resources "$(echo "$ooms" | grep -c 'Killed process') out-of-memory kill(s) since $(date -d "@$oom_since" '+%Y-%m-%d %H:%M'). Last: $(fmt_ts "$(echo "$last" | awk '{print int($1)}')")" \
    "$(echo "$ooms" | head -1 | awk '{print int($1)}')"
  echo "$last" | grep -oE 'Killed process [0-9]+ \([^)]+\)' | while read -r l; do detail "$l"; done
else
  ok "No out-of-memory kills since $(date -d "@$oom_since" '+%Y-%m-%d %H:%M')"
fi

# ---------------------------------------------------------------- summary

n_fail=0; n_warn=0
for l in "${I_LVL[@]}"; do
  [ "$l" = FAIL ] && n_fail=$(( n_fail + 1 ))
  [ "$l" = WARN ] && n_warn=$(( n_warn + 1 ))
done

echo ""
echo "${BOLD}================================ SUMMARY ================================${RESET}"
echo "  Host    : $HOST ${IP:+($IP)}"
echo "  Checked : $(date '+%Y-%m-%d %H:%M:%S %Z')"
[ -n "$MIG_TS" ] && echo "  Upgrade : started $(fmt_ts "$MIG_TS")"
echo "  Booted  : $(fmt_ts "$BOOT_TS")"
echo ""

if [ "$n_fail" -eq 0 ] && [ "$n_warn" -eq 0 ]; then
  echo "  ${GREEN}UPGRADE COMPLETE: no issues found${RESET}"
else
  if [ "$n_fail" -gt 0 ]; then
    echo "  ${RED}UPGRADE INCOMPLETE: $n_fail failure(s), $n_warn warning(s)${RESET}"
  else
    echo "  ${YELLOW}UPGRADE COMPLETE WITH WARNINGS: $n_warn warning(s)${RESET}"
  fi
  echo ""
  for lvl in FAIL WARN; do
    for i in "${!I_LVL[@]}"; do
      [ "${I_LVL[$i]}" = "$lvl" ] || continue
      c=$RED; [ "$lvl" = WARN ] && c=$YELLOW
      printf '  %s[%s]%s %-10s %s\n' "$c" "$lvl" "$RESET" "${I_AREA[$i]}" "${I_MSG[$i]}"
      [ -n "${I_TS[$i]}" ] && printf '         %-10s %ssince %s%s\n' "" "$DIM" "$(fmt_ts "${I_TS[$i]}")" "$RESET"
    done
  done
fi

echo ""
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "  ${RED}Missing packages: ${MISSING[*]}${RESET}"
else
  echo "  ${GREEN}Missing packages: none (checked: $PY_MODULES)${RESET}"
fi
echo "${BOLD}=========================================================================${RESET}"

[ "$n_fail" -gt 0 ] && exit 2
[ "$n_warn" -gt 0 ] && exit 1
exit 0
