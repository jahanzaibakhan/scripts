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
#   - CORRUPTED (zero-filled) files in Imunify packages or its bundled Python
#     (alt-python-internal*), e.g. subprocess.py full of null bytes ->
#     "SyntaxError: source code string cannot contain null bytes" crash loop.
#     Found with dpkg --verify (md5 mismatch AND file starts with 4K of zeros,
#     so normal config edits are never flagged).
#   - zero-filled files in dpkg's own database (/var/lib/dpkg/info/<pkg>.*)
#     that make every apt run fail ("fgets gave an empty string from ...")
#     -> moved to a backup folder and the package reinstalled
#   - disk full on /var: shows what uses the space and offers a safe cleanup
#     (apt cache, journal above 100 MB, already-rotated logs) before the fix
#   - apt package lists for the Imunify repo missing (wiped by an
#     "apt-get update" on a full disk): apt then only knows the installed
#     versions, so the newer imunify-core can never be installed and
#     "apt-get -f install" would REMOVE imunify360-firewall/antivirus/ui
#     -> apt-get update first; this script never lets apt remove Imunify
#   - Imunify packages out of step ("ImportError: cannot import name
#     'MalwareTune'": imunify-core older than firewall/antivirus) and new
#     dependencies apt does not pull in by itself on a broken system
#     (imunify-agent-proxy, a newer imunify360-webshield-bundle) -> the whole
#     installed Imunify set is installed together, plus every dependency the
#     apt dry run names, checked by simulation before anything runs
#   - stale bytecode ("ValueError: bad marshal data") -> __pycache__ cleared
#   - Imunify packages on hold (apt-mark hold): apt cannot upgrade them, so
#     e.g. imunify-core stays old while antivirus/firewall are newer
#     ("ImportError: cannot import name 'is_cluster'") -> the holds on the
#     Imunify-related packages only are lifted before the install (other
#     holds are untouched); the re-hold command is printed at the end
# Fix: dpkg --configure -a, apt-get update, install the Imunify package set
# (retried once with --force-overwrite ONLY when every conflict is between
# Imunify packages), reinstall packages with corrupted files at their
# INSTALLED version, remove the stale marker, start imunify360 / agent socket
# / aibolit-resident (webshield and antivirus are never started or unmasked by
# this script - the Imunify agent manages them), re-enable monit, then show
# the status. Each issue is printed in red and each fix in green.
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

# Files of Imunify-related packages that are corrupted: md5 differs from the
# package AND the file starts with 4 KiB of NUL bytes (zero-filled by a crash /
# disk problem). Prints "pkg<TAB>path" lines.
find_corrupt() {
  local pkgs f n
  pkgs="$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 2>/dev/null | awk '$1 ~ /^ii/{print $2}' \
          | grep -E "$IMUNIFY_PKG_RE|^alt-python-internal")"
  [[ -n "$pkgs" ]] || return 0
  # shellcheck disable=SC2086
  timeout 180 dpkg --verify $pkgs 2>/dev/null | awk '$1 ~ /^..5/ && $2 != "c" {print $NF}' | while IFS= read -r f; do
    [[ -f "$f" && -s "$f" ]] || continue
    n="$(head -c 4096 "$f" | tr -d '\000' | wc -c)"
    (( n == 0 )) || continue
    printf '%s\t%s\n' "$(dpkg -S "$f" 2>/dev/null | head -n1 | cut -d: -f1)" "$f"
  done
}

# Packages installed together as one set (same as Cloudways' own upgrade).
IMUNIFY_SET_RE='^(imunify|ai-bolit|rustbolit)'
imunify_lists() { ls /var/lib/apt/lists/ 2>/dev/null | grep -cE 'imunify.*_Packages'; }

# SET = installed Imunify packages + the extra packages given as arguments
# (half-configured ones, ones with damaged dpkg info) + every package the dry
# run names in an unmet dependency: both the one that is missing/too old
# ("Depends: X ... but it is not going to be installed" / "but <old> is to be
# installed") and the one that needs it (" pkg : Depends: ..."), found by
# repeated dry runs. SIM_SET = the final dry-run output.
SET=(); SIM_SET=""
# While Imunify packages are still on hold (check mode, before the fix lifts
# them) the dry run simulates as if they were not.
SIM_HOLD=()
plan_set() {
  local i n add new
  mapfile -t SET < <( { dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 2>/dev/null | awk '$1 ~ /^[ih]/ && substr($1,2,1) != "n" {print $2}' | grep -E "$IMUNIFY_SET_RE"
                        printf '%s\n' "$@"; } | grep -v '^$' | sed 's/:.*//' | awk '!seen[$0]++')
  (( ${#SET[@]} )) || return 0
  for i in 1 2 3 4 5 6; do
    SIM_SET="$(apt-get -s -o Debug::NoLocking=1 "${SIM_HOLD[@]}" install "${SET[@]}" 2>&1)"
    add="$( { grep -E 'Depends: .* but ' <<<"$SIM_SET" | grep -oP 'Depends: \K[a-z0-9][a-z0-9.+-]*'
              grep -oP '^\s+\K[a-z0-9][a-z0-9.+-]*(?=(:[a-z0-9]+)? : (Pre)?Depends:)' <<<"$SIM_SET"; } | sort -u)"
    new=()
    for n in $add; do printf '%s\n' "${SET[@]}" | grep -qxF "$n" || new+=("$n"); done
    (( ${#new[@]} )) || break
    SET+=("${new[@]}")
  done
}
removes_imunify() { awk '/^Remv/{print $2}' <<<"$1" | grep -E "$IMUNIFY_PKG_RE" | tr '\n' ' '; }

FIXED=()
fixed() { FIXED+=("$1"); green "      FIXED: $1"; }
summary() {
  hr
  echo "== Summary"
  for i in "${ISSUES[@]}"; do red   "  ISSUE : $i"; done
  for f in "${FIXED[@]}";  do green "  FIXED : $f"; done
}

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
    printf '  %-28s %s\n' "agent version" "$(timeout 20 imunify360-agent version 2>/dev/null | grep -E '[0-9]+\.[0-9]+' | tail -n1)"
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

echo "Scanning Imunify package files for corruption (dpkg --verify) ..."
CORRUPT="$(find_corrupt)"
CORRUPT_PKGS=()
if [[ -n "$CORRUPT" ]]; then
  mapfile -t CORRUPT_PKGS < <(cut -f1 <<<"$CORRUPT" | grep -v '^$' | sort -u)
  ISSUES+=("CORRUPT: $(wc -l <<<"$CORRUPT") file(s) are zero-filled (null bytes) in: ${CORRUPT_PKGS[*]} - will reinstall at the installed version.")
fi

# Zero-filled files in dpkg's own database (/var/lib/dpkg/info/<pkg>.triggers,
# .md5sums, ...) make every apt run fail ("fgets gave an empty string from
# .../<pkg>.triggers"). They are moved aside and the package reinstalled, which
# writes them again. Any package, not just Imunify - apt cannot work otherwise.
ZINFO=()
for f in /var/lib/dpkg/info/*; do
  [[ -f "$f" && -s "$f" ]] || continue
  [[ "$(head -c 4096 "$f" | tr -d '\000' | wc -c)" -eq 0 ]] && ZINFO+=("$f")
done
ZINFO_PKGS=()
if (( ${#ZINFO[@]} )); then
  mapfile -t ZINFO_PKGS < <(for f in "${ZINFO[@]}"; do b="${f##*/}"; b="${b%.*}"; echo "${b%%:*}"; done | sort -u)
  ISSUES+=("DPKG-DB: ${#ZINFO[@]} zero-filled file(s) in /var/lib/dpkg/info for: ${ZINFO_PKGS[*]} - apt fails on them; will move them aside and reinstall those packages.")
fi

# apt lists for the Imunify repo wiped -> apt only sees installed versions.
LISTS_MISSING=0
if (( $(imunify_lists) == 0 )); then
  LISTS_MISSING=1
  ISSUES+=("APT-LISTS: no package lists for the Imunify repo in /var/lib/apt/lists - apt only knows the installed versions, cannot upgrade imunify-core, and 'apt-get -f install' would REMOVE Imunify; will run apt-get update first.")
fi

# Imunify packages out of step / stale bytecode (only while imunify360 is down).
MISMATCH=0; PYC=0
if [[ "$(unit_state imunify360)" != active ]]; then
  JRN="$(journalctl -u imunify360 -n 80 -o cat --no-pager 2>/dev/null)"
  IMPERR="$(grep -m1 -oE "ImportError: cannot import name '[^']+'" <<<"$JRN")"
  if [[ -z "$IMPERR" ]] && command -v imunify360-agent >/dev/null; then
    IMPERR="$(timeout 20 imunify360-agent version 2>&1 | grep -m1 -oE "ImportError: cannot import name '[^']+'")"
  fi
  if [[ -n "$IMPERR" ]]; then
    MISMATCH=1
    ISSUES+=("MISMATCH: $IMPERR - Imunify packages are out of step (imunify-core $(dpkg-query -W -f='${Version}' imunify-core 2>/dev/null), imunify360-firewall $(dpkg-query -W -f='${Version}' imunify360-firewall 2>/dev/null)); will install the whole Imunify set together.")
  fi
  if grep -q 'bad marshal data' <<<"$JRN"; then
    PYC=1
    ISSUES+=("PYC: 'ValueError: bad marshal data' - corrupt compiled Python cache; will clear __pycache__ in /opt/imunify360/venv and /opt/alt/python-internal.")
  fi
fi

# Imunify-related packages on hold: apt will not upgrade them, so the set
# cannot be brought in step. Only an issue while something is wrong.
mapfile -t HELD < <(apt-mark showhold 2>/dev/null | grep -E "$IMUNIFY_PKG_RE")
HOLD_FIX=0
if (( ${#HELD[@]} )); then
  if [[ "$(unit_state imunify360)" != active ]] || (( ${#ISSUES[@]} )); then
    HOLD_FIX=1; SIM_HOLD=(--allow-change-held-packages)
    ISSUES+=("HELD: ${#HELD[@]} Imunify-related package(s) on hold (apt-mark hold): $(printf '%s ' "${HELD[@]:0:8}")$( (( ${#HELD[@]} > 8 )) && echo "...")- apt cannot upgrade them, so the Imunify set stays out of step; will lift the holds on these packages only.")
    NONIMU="$(apt-mark showhold 2>/dev/null | grep -vE "$IMUNIFY_PKG_RE" | tr '\n' ' ')"
    [[ -n "$NONIMU" ]] && echo "Other holds: $NONIMU(not Imunify - left as is)"
  else
    echo "Held       : ${#HELD[@]} Imunify package(s) on hold, but imunify360 is running - left as is."
  fi
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

NEED_MB=600
disk_free_mb() { df -Pm /var | awk 'NR==2{print $4}'; }
AVAIL_MB="$(disk_free_mb)"
echo "Disk /var  : ${AVAIL_MB} MB free"
DISK_LOW=0
# Only relevant when there is something for apt to do.
if (( AVAIL_MB < NEED_MB && ${#ISSUES[@]} > 0 )); then
  DISK_LOW=1
  ISSUES+=("DISK: only ${AVAIL_MB} MB free on /var - apt needs at least ${NEED_MB} MB to unpack the Imunify packages.")
fi

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

red "RESULT: IMUNIFY ISSUE FOUND:"
for i in "${ISSUES[@]}"; do red "  - $i"; done
if [[ -n "$CORRUPT" ]]; then
  cut -f2 <<<"$CORRUPT" | head -n 10 | while IFS= read -r f; do red "      zero-filled: $f"; done
  CRASH="$(journalctl -u imunify360 -n 30 -o cat --no-pager 2>/dev/null | grep -E 'Error:|null bytes' | tail -n1)"
  [[ -n "$CRASH" ]] && red "      imunify360 crash: $CRASH"
fi
if [[ -n "$FAIL_LINES" && ( -e "$MARKER" || ${#AUDIT[@]} -gt 0 ) ]]; then
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

# --- Disk full: show what uses the space, offer safe cleanup ----------------------
if (( DISK_LOW )); then
  echo
  echo "== Disk usage (largest first)"
  timeout 90 du -xm --max-depth=1 / 2>/dev/null | sort -rn | sed -n '2,8p' | awk '{printf "  %7d MB  %s\n",$1,$2}'
  echo "  -- inside /var:"
  timeout 60 du -xm --max-depth=2 /var 2>/dev/null | sort -rn | sed -n '2,7p' | awk '{printf "  %7d MB  %s\n",$1,$2}'
  echo "  -- largest files over 200 MB:"
  timeout 90 find / -xdev -type f -size +200M -printf '%s\t%TY-%Tm-%Td\t%p\n' 2>/dev/null | sort -rn | head -n 8 \
    | awk -F'\t' '{printf "  %7.0f MB  %s  %s\n",$1/1048576,$2,$3}'

  # Safe cleanup: only caches and already-rotated logs - nothing an app or DB uses.
  APT_MB="$(du -sm /var/cache/apt/archives 2>/dev/null | cut -f1)"; APT_MB="${APT_MB:-0}"
  JRN_MB="$(du -sm /var/log/journal 2>/dev/null | cut -f1)"; JRN_MB="${JRN_MB:-0}"
  JRN_FREE=$(( JRN_MB > 100 ? JRN_MB - 100 : 0 ))
  ROT_MB="$(find /var/log -xdev -type f \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.[0-9].log' -o -name '*.old' \) -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{printf "%d", s/1048576}')"
  CLEAN_MB=$(( APT_MB + JRN_FREE + ROT_MB ))
  echo
  echo "== Safe cleanup available (caches and rotated logs only)"
  printf '  %6d MB  apt package cache (/var/cache/apt/archives)  -> apt-get clean\n' "$APT_MB"
  printf '  %6d MB  systemd journal above 100 MB                 -> journalctl --vacuum-size=100M\n' "$JRN_FREE"
  printf '  %6d MB  rotated logs in /var/log (*.gz, *.1, *.old)   -> deleted\n' "$ROT_MB"
  printf '  %6d MB  total; would leave about %d MB free (need %d)\n' "$CLEAN_MB" $(( AVAIL_MB + CLEAN_MB )) "$NEED_MB"

  if [[ $MODE == check ]]; then
    echo
    if (( AVAIL_MB + CLEAN_MB >= NEED_MB )); then
      yellow "Without --check the script offers this cleanup first, then the Imunify fix."
    else
      red "Safe cleanup alone is not enough - free more space by hand (largest items above), then re-run."
    fi
    echo "Check only (--check) - no changes made."
    show_status; exit 2
  fi

  echo
  if (( CLEAN_MB > 0 )) && confirm "Run the safe cleanup now?"; then
    apt-get clean 2>/dev/null
    journalctl --vacuum-size=100M >/dev/null 2>&1
    find /var/log -xdev -type f \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.[0-9].log' -o -name '*.old' \) -delete 2>/dev/null
    AVAIL_MB="$(disk_free_mb)"
    echo "Disk /var  : ${AVAIL_MB} MB free after cleanup"
  fi
  if (( AVAIL_MB < NEED_MB )); then
    red "Still only ${AVAIL_MB} MB free on /var - free more space by hand (largest items above), then re-run this script."
    echo "Imunify packages not touched."
    show_status; exit 2
  fi
  green "Enough space now (${AVAIL_MB} MB) - continuing with the Imunify fix."
fi

# Dry run: would apt be able to finish the job?
echo
echo "== apt dry run"
SIM="$(apt-get -s -o Debug::NoLocking=1 -f install 2>&1)"
FREM="$(removes_imunify "$SIM")"
[[ -n "$FREM" ]] && red "  'apt-get -f install' alone would REMOVE: $FREM- this script never runs it that way."
if (( LISTS_MISSING )); then
  yellow "  Imunify repo lists are missing, so this dry run only sees installed versions."
  yellow "  The fix runs apt-get update first and re-plans; run --check again after an apt-get update for an exact plan."
fi
plan_set "${AUDIT[@]}" "${ZINFO_PKGS[@]}"
if (( ${#SET[@]} )); then
  echo "  Imunify set: apt-get install ${SET[*]}"
  if grep -q '^E:' <<<"$SIM_SET"; then
    grep -E '^E:|Depends: .* but ' <<<"$SIM_SET" | head -n 6 | while IFS= read -r l; do red "  $l"; done
    (( LISTS_MISSING )) || yellow "  The dry run reports errors; the fix may need manual work."
  else
    SREM="$(removes_imunify "$SIM_SET")"
    echo "  OK: $(grep -c '^Inst' <<<"$SIM_SET") to install/upgrade, $(grep -c '^Conf' <<<"$SIM_SET") to configure, $(grep -c '^Remv' <<<"$SIM_SET") to remove."
    grep '^Inst' <<<"$SIM_SET" | grep -E "^Inst (imunify-core|imunify360-firewall|imunify-antivirus|imunify-agent-proxy|imunify360-webshield-bundle) " \
      | awk '{ if ($3 ~ /^\[/) {o=$3; gsub(/[][]/,"",o); n=$4} else {o="new"; n=$3}; gsub(/[(]/,"",n); print "    " $2 ": " o " -> " n }'
    [[ -n "$SREM" ]] && red "  Would REMOVE Imunify packages: $SREM- the fix will refuse this."
  fi
fi
for p in "${CORRUPT_PKGS[@]}"; do
  v="$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null)"
  if apt-cache madison "$p" 2>/dev/null | awk -F'|' '{gsub(/ /,"",$2); print $2}' | grep -qxF "$v"; then
    echo "  reinstall $p=$v: available in the repo"
  else
    yellow "  reinstall $p: installed version $v is no longer in the repo - the current candidate will be installed instead"
  fi
done

if [[ $MODE == check ]]; then
  echo
  echo "Check only (--check) - no changes made."
  show_status; exit 0
fi

echo
echo "The fix will:"
(( ${#ZINFO[@]} )) && echo "  0. move ${#ZINFO[@]} zero-filled /var/lib/dpkg/info file(s) to a backup folder (reinstalled in step 3)"
(( HOLD_FIX )) && echo "  0. apt-mark unhold ${#HELD[@]} Imunify-related package(s) (other holds untouched)"
echo "  1. dpkg --configure -a"
echo "  2. apt-get update (refresh the Imunify repo lists)"
echo "  3. re-plan and install the Imunify package set with its new dependencies (never removing Imunify;"
echo "     retry once with --force-overwrite only if every conflict is Imunify-vs-Imunify)"
(( ${#CORRUPT_PKGS[@]} )) && echo "     + apt-get install --reinstall ${CORRUPT_PKGS[*]} (installed versions) to replace the zero-filled files"
echo "  4. remove $MARKER once dpkg --audit is clean"
echo "  5. clear stale __pycache__ (if needed), daemon-reload and start ${START_UNITS[*]} (webshield is left to the Imunify agent)"
echo "  6. re-enable monit for imunify-resident"
confirm "Apply the fix?" || die "Aborted. No changes made."
echo

LOGF="/root/imunify-upgrade-fix-$(date +%Y%m%d-%H%M%S).log"
echo "Full apt/dpkg output: $LOGF"

fail_stop() { red "      $1 Last lines:"; tail -n 8 "$LOGF" | cut -c1-220
              echo "Marker left in place. Fix the apt error above, then re-run this script."; summary; show_status; exit 1; }

# apt-get with one retry using --force-overwrite, only when every
# "trying to overwrite" conflict involves Imunify packages on both sides.
apt_retry() {
  apt-get "${APT_OPTS[@]}" "$@" >>"$LOGF" 2>&1 && return 0
  local confl newp oldp
  confl="$(tail -n 400 "$LOGF" | tr -d '\r' | grep -E "trying to overwrite .* which is also in package")"
  newp="$(tail -n 400 "$LOGF" | tr -d '\r' | grep -oP "error processing archive \S*/\d+-\K[a-z0-9.+-]+(?=_)" | sort -u)"
  oldp="$(grep -oP "also in package \K[a-z0-9.+-]+" <<<"$confl" | sort -u)"
  if [[ -n "$confl" ]] && ! printf '%s\n%s\n' "$newp" "$oldp" | grep -v '^$' | grep -vqE "$IMUNIFY_PKG_RE"; then
    yellow "      file conflict between Imunify packages ($(tr '\n' ' ' <<<"$oldp")) - retrying with --force-overwrite"
    apt-get "${APT_OPTS[@]}" -o Dpkg::Options::=--force-overwrite "$@" >>"$LOGF" 2>&1 && return 0
  fi
  return 1
}

if (( ${#ZINFO[@]} )); then
  ZBK="${LOGF%.log}-dpkg-info"
  if mkdir -p "$ZBK" && mv "${ZINFO[@]}" "$ZBK"/; then
    fixed "moved ${#ZINFO[@]} zero-filled dpkg info file(s) to $ZBK"
  else red "Could not move the zero-filled dpkg info files - stopping."; summary; show_status; exit 1; fi
fi

if (( HOLD_FIX )); then
  echo "held before fix: ${HELD[*]}" >>"$LOGF"
  if apt-mark unhold "${HELD[@]}" >>"$LOGF" 2>&1; then
    SIM_HOLD=()
    fixed "lifted the hold on ${#HELD[@]} Imunify-related package(s): ${HELD[*]}"
  else red "apt-mark unhold failed - stopping."; summary; show_status; exit 1; fi
fi

echo "[1/6] dpkg --configure -a"
dpkg --configure -a >>"$LOGF" 2>&1 || yellow "      dpkg --configure -a reported errors (expected if a package needs a newer dependency) - continuing."

echo "[2/6] apt-get update"
apt-get update >>"$LOGF" 2>&1 || yellow "      apt-get update reported errors (see $LOGF) - continuing if the Imunify lists are there."
if (( $(imunify_lists) == 0 )); then
  fail_stop "Imunify repo lists are still missing after apt-get update (repo unreachable or disk full?)."
fi
(( LISTS_MISSING )) && fixed "Imunify repo package lists restored ($(imunify_lists) list file(s))"

echo "[3/6] install the Imunify package set"
plan_set "${AUDIT[@]}" "${ZINFO_PKGS[@]}"
if grep -q '^E:' <<<"$SIM_SET"; then
  red "      apt still cannot resolve the Imunify set:"
  grep -E '^E:|Depends: .* but ' <<<"$SIM_SET" | head -n 6 | sed 's/^/        /'
  echo "Marker left in place - nothing installed."; summary; show_status; exit 1
fi
SREM="$(removes_imunify "$SIM_SET")"
[[ -n "$SREM" ]] && { red "      the plan would REMOVE Imunify packages ($SREM) - refusing."; echo "Marker left in place - nothing installed."; summary; show_status; exit 1; }
echo "      apt-get install ${SET[*]}"
apt_retry install "${SET[@]}" || fail_stop "installing the Imunify set failed."
dpkg --configure -a >>"$LOGF" 2>&1
fixed "Imunify set installed: $(for p in imunify-core imunify360-firewall imunify-antivirus; do v=$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null) && printf '%s %s, ' "$p" "$v"; done | sed 's/, $//')"

if (( ${#ZINFO_PKGS[@]} )); then
  echo "      reinstalling packages whose dpkg info files were zero-filled: ${ZINFO_PKGS[*]}"
  apt-get "${APT_OPTS[@]}" install --reinstall "${ZINFO_PKGS[@]}" >>"$LOGF" 2>&1 \
    || fail_stop "reinstall of ${ZINFO_PKGS[*]} failed."
  fixed "dpkg info files rewritten by reinstalling ${ZINFO_PKGS[*]}"
fi

if (( ${#CORRUPT_PKGS[@]} )); then
  echo "      reinstalling packages with zero-filled files: ${CORRUPT_PKGS[*]}"
  for p in "${CORRUPT_PKGS[@]}"; do
    v="$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null)"
    if ! apt-get "${APT_OPTS[@]}" install --reinstall "$p=$v" >>"$LOGF" 2>&1; then
      apt-get "${APT_OPTS[@]}" install --reinstall "$p" >>"$LOGF" 2>&1 || fail_stop "reinstall of $p failed."
    fi
  done
  LEFT="$(find_corrupt)"
  if [[ -n "$LEFT" ]]; then
    red "      still zero-filled after reinstall:"; cut -f2 <<<"$LEFT" | sed 's/^/        /'
    red "      This points to an ongoing disk/filesystem problem - check dmesg for I/O errors."; summary; show_status; exit 1
  fi
  fixed "zero-filled files replaced in ${CORRUPT_PKGS[*]} (dpkg --verify clean)"
fi

mapfile -t AUDIT < <(audit_pkgs)
if (( ${#AUDIT[@]} )); then
  red "      dpkg --audit still lists: ${AUDIT[*]}"
  echo "Marker left in place. Check $LOGF, then re-run this script."; summary; show_status; exit 1
fi
fixed "all packages configured, dpkg --audit is clean"

echo "[4/6] remove stale marker"
if [[ -e "$MARKER" ]]; then
  rm -f "$MARKER" && fixed "removed $MARKER - systemd no longer skips imunify360"
else echo "      already gone (removed by the package scripts)"; fi

echo "[5/6] start Imunify units"
# Bytecode can be zero-filled like the sources ("bad marshal data"); after an
# upgrade it is rebuilt anyway, so clearing it is safe.
if (( PYC || MISMATCH || ${#CORRUPT_PKGS[@]} )); then
  find /opt/imunify360/venv /opt/alt/python-internal -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null
  fixed "cleared __pycache__ in /opt/imunify360/venv and /opt/alt/python-internal (rebuilt on start)"
fi
systemctl daemon-reload
for u in "${START_UNITS[@]}"; do
  [[ "$(unit_load "$u")" == loaded ]] || continue
  [[ "$(systemctl is-enabled "$u" 2>/dev/null)" =~ ^(enabled|static|indirect)$ ]] || continue
  [[ "$(unit_state "$u")" == active ]] && continue
  systemctl reset-failed "$u" 2>/dev/null
  systemctl start --no-block "$u" && echo "      starting $u"
done
for _ in $(seq 1 45); do [[ "$(unit_state imunify360)" == active ]] && break; sleep 2; done

echo "[6/6] monit"
if command -v monit >/dev/null; then
  monit monitor imunify-resident >/dev/null 2>&1 && echo "      monit monitor imunify-resident"
fi

echo
if [[ "$(unit_state imunify360)" == active ]]; then
  fixed "imunify360 is running ($(timeout 20 imunify360-agent version 2>/dev/null | grep -E '[0-9]+\.[0-9]+' | tail -n1))"
  summary; show_status
  green "SUCCESS: Imunify360 is RUNNING again."
  (( HOLD_FIX )) && yellow "Holds were lifted. If they were set on purpose, re-hold at the new versions with: apt-mark hold ${HELD[*]}"
  exit 0
fi
summary; show_status
red "imunify360 did not come up. Last log lines:"
journalctl -u imunify360 -n 15 -o cat --no-pager 2>/dev/null | cut -c1-220
exit 1
