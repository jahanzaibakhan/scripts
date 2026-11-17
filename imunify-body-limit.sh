#!/usr/bin/env bash
#
# imunify-body-limit.sh
# Shows the Imunify360 WAF (ModSecurity) request body limit and lowers it
# to 128MB when it is higher.
#
# An oversized SecRequestBodyLimit (e.g. 1342177280 = 1280MB) lets
# ModSecurity buffer huge request bodies in memory/disk and inspect them,
# which shows up as high CPU load on the server.
#
# The directive lives in /etc/imunify360-wafd/modsecurity.d/body_limit.conf.
# Only the SecRequestBodyLimit line is changed; any other lines are kept.
# The original file is backed up first, and the web server config is
# tested before anything is reloaded. If the config test fails, or the
# service does not come back, the backup is restored automatically.
#
# Services reloaded/restarted (only those that exist, are active, and
# reference the imunify360-wafd config):
#   - imunify360-wafd*   (restart, if a wafd unit exists and is active)
#   - apache2 / httpd    (configtest, then graceful reload)
#   - nginx              (configtest, then reload)
#
# Usage (as root):
#   bash imunify-body-limit.sh              # report, confirm, apply 128MB
#   bash imunify-body-limit.sh --check      # report only, no changes
#   bash imunify-body-limit.sh --yes        # apply without prompting
#   bash imunify-body-limit.sh --limit 256  # use a different target (MB)
#   bash imunify-body-limit.sh --revert     # restore the most recent backup
#   curl -fsSL <raw-url> | sudo bash -s -- [option]

set -uo pipefail

TARGET_MB=128
CONF="/etc/imunify360-wafd/modsecurity.d/body_limit.conf"
BACKUP_DIR="/etc/imunify-body-limit"
WAIT_SECS=30

if [[ -t 1 ]]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'
else
  R=""; G=""; Y=""; B=""; N=""
fi
die()  { echo "${R}ERROR:${N} $*" >&2; exit 1; }
info() { echo "${B}==${N} $*"; }
ok()   { echo "${G}OK:${N} $*"; }
warn() { echo "${Y}WARN:${N} $*"; }

MODE="apply"; ASSUME_YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)  MODE="check" ;;
    --revert) MODE="revert" ;;
    --yes|-y) ASSUME_YES=1 ;;
    --limit)  shift; [[ "${1:-}" =~ ^[0-9]+$ && "$1" -gt 0 ]] || die "--limit needs a size in MB"; TARGET_MB="$1" ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || die "run as root"
[[ -f "$CONF" ]] || die "$CONF not found (is Imunify360 WAF installed?)"

TARGET_BYTES=$((TARGET_MB * 1024 * 1024))

# Print the effective SecRequestBodyLimit value (bytes), empty if absent.
read_limit() {
  awk 'tolower($1)=="secrequestbodylimit" {print $2; exit}' "$CONF" 2>/dev/null
}

human() {  # bytes -> "NNN MB"
  [[ "$1" =~ ^[0-9]+$ ]] && echo "$(( $1 / 1024 / 1024 )) MB ($1 bytes)" || echo "n/a"
}

limit_c() {
  local v="$1"
  if [[ ! "$v" =~ ^[0-9]+$ ]]; then echo "${Y}not set${N}"
  elif (( v <= TARGET_BYTES )); then echo "${G}$(human "$v")${N}"
  else echo "${R}$(human "$v")${N}"
  fi
}

# ---- discover which services matter ------------------------------------
WAFD_UNITS=()
while read -r u; do
  [[ -n "$u" ]] && systemctl is-active --quiet "$u" 2>/dev/null && WAFD_UNITS+=("$u")
done < <(systemctl list-unit-files --no-legend --type=service 2>/dev/null \
          | awk '$1 ~ /^imunify360-wafd/ {print $1}')

WEB_UNITS=()     # entries: "<unit>:<kind>"
conf_refs() { grep -rqs "imunify360-wafd" "$@" 2>/dev/null; }
for u in apache2 httpd; do
  if systemctl is-active --quiet "$u" 2>/dev/null; then
    if conf_refs /etc/apache2 /etc/httpd; then WEB_UNITS+=("$u:apache")
    else warn "$u is active but no imunify360-wafd include found in its config; skipping"; fi
  fi
done
if systemctl is-active --quiet nginx 2>/dev/null; then
  if conf_refs /etc/nginx; then WEB_UNITS+=("nginx:nginx"); fi
fi

# ---- report -------------------------------------------------------------
info "Imunify360 WAF body limit"
echo "  file:    $CONF"
CUR="$(read_limit)"
echo "  current: $(limit_c "$CUR")"
echo "  target:  ${TARGET_MB} MB ($TARGET_BYTES bytes)"
echo "  services to reload: ${WAFD_UNITS[*]:-} $(printf '%s ' "${WEB_UNITS[@]%%:*}")"
echo "  --- file contents ---"
sed 's/^/  | /' "$CONF"
echo "  ---------------------"

[[ "$MODE" == "check" ]] && exit 0

# ---- helpers ------------------------------------------------------------
web_test() {  # $1=unit:kind
  case "${1#*:}" in
    apache) if command -v apachectl >/dev/null; then apachectl configtest 2>&1
            elif command -v apache2ctl >/dev/null; then apache2ctl configtest 2>&1
            elif command -v httpd >/dev/null; then httpd -t 2>&1
            else return 0; fi ;;
    nginx)  nginx -t 2>&1 ;;
  esac
}

wait_active() {
  local u="$1" i
  for ((i = 0; i < WAIT_SECS; i++)); do
    systemctl is-active --quiet "$u" && return 0
    sleep 1
  done
  return 1
}

apply_services() {  # returns non-zero if anything failed
  local rc=0 u
  for u in "${WAFD_UNITS[@]}"; do
    info "restarting $u"
    systemctl restart "$u" && wait_active "$u" || { warn "$u failed to come back"; rc=1; }
  done
  for e in "${WEB_UNITS[@]}"; do
    u="${e%%:*}"
    info "testing config for $u"
    if ! out="$(web_test "$e")"; then
      echo "$out" | sed 's/^/  /'
      warn "$u config test failed; not reloading"; rc=1; continue
    fi
    info "reloading $u"
    systemctl reload "$u" || systemctl restart "$u"
    wait_active "$u" || { warn "$u is not active after reload"; rc=1; }
  done
  return $rc
}

restore_backup() {  # $1=backup file
  cp -p "$1" "$CONF" && ok "restored $CONF from $1"
}

# ---- revert -------------------------------------------------------------
if [[ "$MODE" == "revert" ]]; then
  BK="$(ls -1t "$BACKUP_DIR"/body_limit.conf.* 2>/dev/null | head -1)"
  [[ -n "$BK" ]] || die "no backup found in $BACKUP_DIR"
  info "reverting to $BK"
  restore_backup "$BK" || die "restore failed"
  apply_services || die "services did not all come back cleanly after revert"
  ok "reverted; limit is now $(human "$(read_limit)")"
  exit 0
fi

# ---- apply --------------------------------------------------------------
if [[ "$CUR" =~ ^[0-9]+$ ]] && (( CUR <= TARGET_BYTES )); then
  ok "current limit is already <= ${TARGET_MB} MB; nothing to do"
  exit 0
fi

if (( ! ASSUME_YES )); then
  [[ -t 0 || -r /dev/tty ]] || die "no terminal to confirm on; re-run with --yes"
  read -r -p "Set SecRequestBodyLimit to $TARGET_BYTES (${TARGET_MB} MB) and reload services? [y/N] " ans </dev/tty
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "aborted"; exit 1; }
fi

mkdir -p "$BACKUP_DIR"
BK="$BACKUP_DIR/body_limit.conf.$(date +%Y%m%d-%H%M%S)"
cp -p "$CONF" "$BK" || die "could not back up $CONF"
ok "backup: $BK"

if grep -qiE '^[[:space:]]*SecRequestBodyLimit[[:space:]]' "$CONF"; then
  sed -i -E "s|^([[:space:]]*[Ss]ec[Rr]equest[Bb]ody[Ll]imit)[[:space:]]+[0-9]+.*|\1 $TARGET_BYTES|" "$CONF"
else
  echo "SecRequestBodyLimit $TARGET_BYTES" >> "$CONF"
fi

NEW="$(read_limit)"
[[ "$NEW" == "$TARGET_BYTES" ]] || { restore_backup "$BK"; die "edit did not take effect; backup restored"; }

if ! apply_services; then
  warn "service problem after change; rolling back"
  restore_backup "$BK"
  apply_services || warn "services still unhealthy after rollback; check manually"
  die "rolled back to previous limit"
fi

# Imunify may regenerate this file; confirm the value stuck.
sleep 2
FINAL="$(read_limit)"
echo
info "result"
echo "  before: $(human "$CUR")"
echo "  after:  $(limit_c "$FINAL")"
if [[ "$FINAL" != "$TARGET_BYTES" ]]; then
  warn "file was changed back after the reload (Imunify likely regenerates it); the limit will not persist"
  exit 1
fi
ok "body limit set to ${TARGET_MB} MB"
