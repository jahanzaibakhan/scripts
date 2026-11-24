#!/usr/bin/env bash
#
# imunify-upgrade-fix.sh
# Fixes Imunify360 being down after an interrupted/failed Imunify package
# upgrade (Cloudways "apt-get install --only-upgrade imunify360-firewall ..."):
#   - /var/lib/rpm-state/imunify360-transaction-in-progress left behind:
#     imunify360.service has ConditionPathExists=! on it, so systemd skips
#     every start ("Condition check resulted in Imunify360 resident being
#     skipped") and monit cannot bring it back
#   - packages left unpacked / half-configured (dpkg --audit)
#   - the failed run's cause is shown from /var/log/apt/term.log, e.g.
#     "trying to overwrite '...', which is also in package imunify-..."
# Fix: dpkg --configure -a, apt-get -f install (retried once with
# --force-overwrite ONLY when every conflict is between Imunify packages),
# remove the stale marker, start imunify360 / agent socket / aibolit-resident
# (webshield and antivirus are never started or unmasked by this script - the
# Imunify agent manages them), re-enable monit, then show the status.
#
# Usage (as root):
#   bash imunify-upgrade-fix.sh            # check, confirm, fix
#   bash imunify-upgrade-fix.sh --check    # check only (includes an apt dry run), no changes
#   bash imunify-upgrade-fix.sh --yes      # fix without the confirmation prompt
#   curl -fsSL <raw-url> | sudo bash -s -- [--check|--yes]

set -uo pipefail

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  RED=$'\e[1;31m'; GREEN=$'\e[1;32m'; YELLOW=$'\e[1;33m'; RST=$'\e[0m'
else
  RED=""; GREEN=""; YELLOW=""; RST=""
fi
red()    { echo "${RED}$*${RST}"; }
green()  { echo "${GREEN}$*${RST}"; }
yellow() { echo "${YELLOW}$*${RST}"; }
die()    { echo "${RED}ERROR: $*${RST}" >&2; exit 1; }
hr()     { echo "------------------------------------------------------------"; }

MODE=fix; ASSUME_YES=0
for a in "$@"; do
  case "$a" in
    --check|-c) MODE=check ;;
    --yes|-y)   ASSUME_YES=1 ;;
    -h|--help)  awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0" 2>/dev/null; exit 0 ;;
    *) die "Unknown option: $a (use --check, --yes or no option)" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Run this script as root (sudo -i first)."
command -v dpkg >/dev/null && command -v apt-get >/dev/null || die "This script is for Debian/Ubuntu (dpkg/apt) servers."

confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  local ok; read -r -p "$1 [y/N]: " ok </dev/tty || return 1
  [[ "$ok" =~ ^[Yy]$ ]]
}

MARKER=/var/lib/rpm-state/imunify360-transaction-in-progress
UNITS=(imunify360 imunify360-agent.socket aibolit-resident imunify360-webshield imunify360-pam imunify-antivirus imunify-auditd-log-reader)
# Units this script starts. webshield/antivirus are left to the Imunify agent
# (it starts webshield itself when enabled in its config; the webshield-bundle
# upgrade can also remove an old mask on its own).
START_UNITS=(imunify360 imunify360-agent.socket aibolit-resident)
# Packages whose file conflicts with each other are safe to --force-overwrite.
IMUNIFY_PKG_RE='^(imunify|ai-bolit|rustbolit|alt-|cloudlinux-backup-utils|app-version-detector)'
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

unit_load()  { systemctl show -p LoadState --value "$1" 2>/dev/null; }      # loaded / masked / not-found
unit_state() { systemctl is-active "$1" 2>/dev/null; }
audit_pkgs() { dpkg --audit 2>/dev/null | awk '/^ [a-z0-9]/{print $1}' | sed 's/:.*//'; }
apt_busy()   { pgrep -x 'apt|apt-get|aptitude|dpkg|unattended-upgr' >/dev/null 2>&1; }

show_status() {
  hr
  echo "== Imunify status"
  for u in "${UNITS[@]}"; do
    local l s; l="$(unit_load "$u")"; s="$(unit_state "$u")"
    [[ "$l" == not-found ]] && continue
    if [[ "$l" == masked ]]; then printf '  %-28s %s\n' "$u" "masked (left as is)"
    elif [[ "$s" == active ]]; then printf '  %-28s %s\n' "$u" "${GREEN}active${RST}"
    else printf '  %-28s %s\n' "$u" "${RED}${s}${RST}"; fi
  done
  printf '  %-28s %s\n' "marker file" "$([[ -e $MARKER ]] && echo "${RED}present${RST}" || echo "${GREEN}absent${RST}")"
  printf '  %-28s %s\n' "dpkg --audit" "$(n=$(audit_pkgs | wc -l); (( n )) && echo "${RED}$n package(s) not configured${RST}" || echo "${GREEN}clean${RST}")"
  command -v monit >/dev/null && monit summary 2>/dev/null | grep -iE '^\s*imunify' | sed 's/^ */  monit: /'
  command -v imunify360-agent >/dev/null && [[ "$(unit_state imunify360)" == active ]] && \
    printf '  %-28s %s\n' "agent version" "$(timeout 20 imunify360-agent version 2>/dev/null | tail -n1)"
  hr
  if [[ "$(unit_state imunify360)" == active ]]; then green "IMUNIFY STATUS: RUNNING"; else red "IMUNIFY STATUS: NOT RUNNING"; fi
}

# The newest apt run that failed, from term.log (newest file first, rotated logs too).
last_failed_run() {
  local f blk
  for f in $(ls -t /var/log/apt/term.log* 2>/dev/null); do
    blk="$(zcat -f "$f" 2>/dev/null | tr -d '\r' | awk '
      /^Log started:/ {blk=$0 "\n"; next}
      {blk=blk $0 "\n"}
      /^Log ended:/ { if (blk ~ /dpkg: error|Errors were encountered|returned an error code/) last=blk }
      END { printf "%s", last }')"
    [[ -n "$blk" ]] && { printf '%s' "$blk"; return 0; }
  done
}

echo "== Check: $(hostname)"
echo "imunify360 : $(unit_state imunify360) ($(unit_load imunify360)), ConditionResult=$(systemctl show -p ConditionResult --value imunify360 2>/dev/null)"
echo "Packages   : $(dpkg-query -W -f='${Version}' imunify360-firewall 2>/dev/null || echo '?') imunify360-firewall, $(dpkg-query -W -f='${Version}' imunify-core 2>/dev/null || echo '?') imunify-core"
echo

echo "== Findings"
ISSUES=(); BLOCKERS=()

if [[ -e "$MARKER" ]]; then
  AGE_H=$(( ( $(date +%s) - $(stat -c %Y "$MARKER") ) / 3600 ))
  if apt_busy && (( AGE_H < 2 )); then
    BLOCKERS+=("BUSY: an apt/dpkg run is active and the marker is only ${AGE_H}h old - an upgrade is in progress right now. Wait for it.")
  else
    ISSUES+=("MARKER: $MARKER exists since $(date -r "$MARKER" '+%F %T') (${AGE_H}h) - systemd skips every imunify360 start.")
  fi
fi
if apt_busy && [[ ! -e "$MARKER" ]]; then
  BLOCKERS+=("BUSY: an apt/dpkg process is running: $(pgrep -ax 'apt|apt-get|dpkg|unattended-upgr' | head -n2 | tr '\n' ' ')")
fi

mapfile -t AUDIT < <(audit_pkgs)
if (( ${#AUDIT[@]} )); then
  ISSUES+=("DPKG: ${#AUDIT[@]} package(s) unpacked but not configured: $(printf '%s ' "${AUDIT[@]:0:8}")$( (( ${#AUDIT[@]} > 8 )) && echo "...")")
fi

DOWN=()
for u in "${START_UNITS[@]}"; do
  l="$(unit_load "$u")"
  [[ "$l" == loaded ]] || continue
  [[ "$(systemctl is-enabled "$u" 2>/dev/null)" =~ ^(enabled|static|indirect)$ ]] || continue
  [[ "$(unit_state "$u")" == active ]] || DOWN+=("$u")
done
(( ${#DOWN[@]} )) && echo "Down units : ${DOWN[*]}"
MASKED=(); for u in "${UNITS[@]}"; do [[ "$(unit_load "$u")" == masked ]] && MASKED+=("$u"); done
(( ${#MASKED[@]} )) && echo "Masked     : ${MASKED[*]} (left masked - not touched)"

read -r AVAIL_MB < <(df -Pm /var | awk 'NR==2{print $4}')
echo "Disk /var  : ${AVAIL_MB} MB free"
(( AVAIL_MB < 600 )) && BLOCKERS+=("DISK: only ${AVAIL_MB} MB free on /var - apt needs room to unpack; free space first.")

FAILED_RUN="$(last_failed_run)"
FAIL_LINES=""
if [[ -n "${FAILED_RUN//[[:space:]]/}" ]]; then
  FAIL_WHEN="$(head -n1 <<<"$FAILED_RUN" | sed 's/^Log started: *//')"
  FAIL_LINES="$(grep -E "dpkg: error|trying to overwrite|No space left|dpkg-deb: error|subprocess .* returned|Errors were encountered" <<<"$FAILED_RUN" | head -n 6)"
fi

if (( ${#ISSUES[@]} == 0 && ${#BLOCKERS[@]} == 0 )); then
  if [[ "$(unit_state imunify360)" == active ]]; then
    green "RESULT: no interrupted-upgrade problem found and imunify360 is running."
  else
    red "RESULT: no interrupted-upgrade problem found, but imunify360 is $(unit_state imunify360). Last log lines:"
    journalctl -u imunify360 -n 10 -o cat --no-pager 2>/dev/null | cut -c1-220
  fi
  show_status; exit 0
fi

red "RESULT: IMUNIFY ISSUE FOUND - interrupted Imunify package upgrade:"
for i in "${ISSUES[@]}"; do red "  - $i"; done
if [[ -n "$FAIL_LINES" ]]; then
  red "  Failed apt run ($FAIL_WHEN):"
  sed 's/^/      /' <<<"$FAIL_LINES" | cut -c1-220 | while IFS= read -r l; do red "$l"; done
fi
if (( ${#BLOCKERS[@]} )); then
  echo
  red "Cannot fix right now:"
  for b in "${BLOCKERS[@]}"; do red "  - $b"; done
  echo "No changes made."
  show_status; exit 2
fi

# Dry run: would apt be able to finish the job?
echo
echo "== apt dry run (apt-get -s -f install)"
SIM="$(apt-get -s -f install 2>&1)"
if grep -q '^E:' <<<"$SIM"; then
  grep '^E:' <<<"$SIM" | head -n 5 | while IFS= read -r l; do red "  $l"; done
  yellow "  The dry run reports errors; the fix may need manual work."
else
  echo "  OK: $(grep -c '^Inst' <<<"$SIM") to install/upgrade, $(grep -c '^Conf' <<<"$SIM") to configure, $(grep -c '^Remv' <<<"$SIM") to remove."
  (( $(grep -c '^Remv' <<<"$SIM") )) && yellow "  Packages would be REMOVED: $(awk '/^Remv/{print $2}' <<<"$SIM" | tr '\n' ' ')"
fi

if [[ $MODE == check ]]; then
  echo
  echo "Check only (--check) - no changes made."
  show_status; exit 0
fi

echo
echo "The fix will:"
echo "  1. dpkg --configure -a"
echo "  2. apt-get -f install (retry once with --force-overwrite only if every conflict is Imunify-vs-Imunify)"
echo "  3. remove $MARKER once dpkg --audit is clean"
echo "  4. daemon-reload and start ${START_UNITS[*]} (webshield is left to the Imunify agent)"
echo "  5. re-enable monit for imunify-resident"
confirm "Apply the fix?" || die "Aborted. No changes made."
echo

LOGF="/root/imunify-upgrade-fix-$(date +%Y%m%d-%H%M%S).log"
echo "Full apt/dpkg output: $LOGF"

echo "[1/5] dpkg --configure -a"
dpkg --configure -a >>"$LOGF" 2>&1 || yellow "      dpkg --configure -a reported errors (expected if a package needs a newer dependency) - continuing with apt."

echo "[2/5] apt-get -f install"
if ! apt-get "${APT_OPTS[@]}" -f install >>"$LOGF" 2>&1; then
  # Only retry when every "trying to overwrite" conflict involves Imunify packages on both sides.
  CONFL="$(tail -n 400 "$LOGF" | tr -d '\r' | grep -E "trying to overwrite .* which is also in package")"
  NEWP="$(tail -n 400 "$LOGF" | tr -d '\r' | grep -oP "error processing archive \S*/\d+-\K[a-z0-9.+-]+(?=_)" | sort -u)"
  OLDP="$(grep -oP "also in package \K[a-z0-9.+-]+" <<<"$CONFL" | sort -u)"
  if [[ -n "$CONFL" ]] && ! printf '%s\n%s\n' "$NEWP" "$OLDP" | grep -v '^$' | grep -vqE "$IMUNIFY_PKG_RE"; then
    yellow "      file conflict between Imunify packages ($(tr '\n' ' ' <<<"$OLDP")) - retrying with --force-overwrite"
    if ! apt-get "${APT_OPTS[@]}" -o Dpkg::Options::=--force-overwrite -f install >>"$LOGF" 2>&1; then
      red "      apt-get -f install failed again. Last lines:"; tail -n 8 "$LOGF" | cut -c1-220
      echo "Marker left in place. Fix the apt error above, then re-run this script."; show_status; exit 1
    fi
  else
    red "      apt-get -f install failed (not an Imunify-only file conflict). Last lines:"; tail -n 8 "$LOGF" | cut -c1-220
    echo "Marker left in place. Fix the apt error above, then re-run this script."; show_status; exit 1
  fi
fi
dpkg --configure -a >>"$LOGF" 2>&1

mapfile -t AUDIT < <(audit_pkgs)
if (( ${#AUDIT[@]} )); then
  red "      dpkg --audit still lists: ${AUDIT[*]}"
  echo "Marker left in place. Check $LOGF, then re-run this script."; show_status; exit 1
fi
green "      packages configured, dpkg --audit is clean."

echo "[3/5] remove stale marker"
if [[ -e "$MARKER" ]]; then rm -f "$MARKER" && echo "      removed $MARKER"; else echo "      already gone (removed by the package scripts)"; fi

echo "[4/5] start Imunify units"
systemctl daemon-reload
for u in "${START_UNITS[@]}"; do
  [[ "$(unit_load "$u")" == loaded ]] || continue
  [[ "$(systemctl is-enabled "$u" 2>/dev/null)" =~ ^(enabled|static|indirect)$ ]] || continue
  [[ "$(unit_state "$u")" == active ]] && continue
  systemctl reset-failed "$u" 2>/dev/null
  systemctl start --no-block "$u" && echo "      starting $u"
done
for _ in $(seq 1 45); do [[ "$(unit_state imunify360)" == active ]] && break; sleep 2; done

echo "[5/5] monit"
if command -v monit >/dev/null; then
  monit monitor imunify-resident >/dev/null 2>&1 && echo "      monit monitor imunify-resident"
fi

echo
show_status
if [[ "$(unit_state imunify360)" == active ]]; then
  green "SUCCESS: Imunify360 is RUNNING again."
  exit 0
fi
red "imunify360 did not come up. Last log lines:"
journalctl -u imunify360 -n 15 -o cat --no-pager 2>/dev/null | cut -c1-220
exit 1
