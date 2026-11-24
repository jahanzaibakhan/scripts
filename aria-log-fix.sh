#!/usr/bin/env bash
#
# aria-log-fix.sh
# Diagnoses a MariaDB/MySQL service that will not start and fixes the
# Aria-related causes:
#   - corrupt/unreadable Aria logs (aria_log_control, aria_log.NNNNNNNN):
#     "Aria engine: log initialization failed", "Aria recovery failed",
#     "Unknown storage engine 'Aria'", "Could not open mysql.plugin table"
#     -> moves aria_log* to /root/aria_backup/<timestamp>/ (never deletes)
#   - a stray mariadbd/mysqld still running outside systemd, holding the
#     Aria/InnoDB locks ("Can't lock aria control file", "Unable to lock
#     ./ibdata1 error: 11") -> stops it cleanly; if the holder already
#     exited, just starts the service again (Aria logs are not touched)
# It does NOT try to fix InnoDB corruption, disk-full or memory problems:
# it shows the relevant log lines and stops without changes.
# At the end it shows the MySQL service status.
#
# Usage (as root):
#   bash aria-log-fix.sh            # check, confirm, fix
#   bash aria-log-fix.sh --check    # check only, no changes
#   bash aria-log-fix.sh --yes      # fix without the confirmation prompt
#   curl -fsSL <raw-url> | sudo bash -s -- [--check|--yes]

set -uo pipefail

die()  { echo "ERROR: $*" >&2; exit 1; }
hr()   { echo "------------------------------------------------------------"; }

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

confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  local ok
  read -r -p "$1 [y/N]: " ok </dev/tty || return 1
  [[ "$ok" =~ ^[Yy]$ ]]
}

# --- Service, datadir, error log --------------------------------------------
SVC=""
# No "| grep -q" here: with pipefail, grep exiting early makes the pipe fail.
for s in mariadb mysql; do
  if [[ "$(systemctl show -p LoadState --value "$s.service" 2>/dev/null)" == loaded ]]; then
    SVC="$(systemctl show -p Id --value "$s.service" 2>/dev/null)"; SVC="${SVC%.service}"
    break
  fi
done
[[ -n "$SVC" ]] || die "No mariadb.service or mysql.service found."

DEFAULTS="$(my_print_defaults --mysqld 2>/dev/null || true)"
DATADIR="$(grep -oP '^--datadir=\K.*' <<<"$DEFAULTS" | tail -n1)"
DATADIR="${DATADIR:-/var/lib/mysql}"; DATADIR="${DATADIR%/}"
ERRLOG="$(grep -oP '^--log[-_]error=\K.*' <<<"$DEFAULTS" | tail -n1)"
[[ -n "$ERRLOG" && "$ERRLOG" != /* ]] && ERRLOG="$DATADIR/$ERRLOG"
[[ -f "${ERRLOG:-}" ]] || ERRLOG="/var/log/mysql/error.log"
[[ -d "$DATADIR" ]] || die "Datadir $DATADIR does not exist."

is_up() { systemctl is-active --quiet "$SVC" && mysqladmin ping >/dev/null 2>&1; }

# Keep only the lines from the last start attempt, so old incidents earlier
# in the log are not mistaken for the current one.
last_attempt() { awk '/starting as process/{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}'; }

# Log lines from the most recent start attempt (journal + error log).
recent_log() {
  {
    journalctl -u "$SVC" -n 400 -o cat --no-pager 2>/dev/null | last_attempt
    [[ -f "$ERRLOG" ]] && tail -n 400 "$ERRLOG" 2>/dev/null | last_attempt
  } | grep -vE '^\s*$'
}

show_status() {
  hr
  echo "== MySQL status"
  systemctl status "$SVC" --no-pager -l 2>&1 | head -n 12
  echo
  printf 'mysqladmin ping : '; mysqladmin ping 2>&1 | head -n1
  if command -v monit >/dev/null; then
    printf 'monit           : '; monit summary 2>/dev/null | grep -iE '^\s*(mysql|mariadb)\b' | sed 's/^ *//' || echo "n/a"
  fi
  hr
}

echo "== Check: $(hostname)"
echo "Service   : $SVC ($(systemctl is-active "$SVC" 2>/dev/null))"
echo "Version   : $( (mariadbd --version 2>/dev/null || mysqld --version 2>/dev/null) | head -n1 | sed 's/^.*Ver //')"
echo "Datadir   : $DATADIR"
echo "Error log : $ERRLOG"

if is_up; then
  echo
  echo "RESULT: $SVC is running and answering ping. Nothing to fix."
  show_status
  exit 0
fi

LOG="$(recent_log)"
match() { grep -E "$1" <<<"$LOG" | tail -n "${2:-5}"; }

# --- Findings ----------------------------------------------------------------
echo
echo "== Findings"
ISSUES=()     # things this script fixes
BLOCKERS=()   # things it does not fix

# 1. Disk space / inodes on the datadir filesystem.
read -r AVAIL_KB USE_PCT < <(df -Pk "$DATADIR" | awk 'NR==2{gsub("%","",$5); print $4, $5}')
IUSE_PCT="$(df -Pi "$DATADIR" | awk 'NR==2{gsub("%","",$5); print $5}')"
echo "Disk      : ${USE_PCT}% used, $((AVAIL_KB/1024)) MB free; inodes ${IUSE_PCT:-?}% used"
if (( AVAIL_KB < 512000 )) || (( USE_PCT >= 99 )) || [[ "${IUSE_PCT:-0}" =~ ^[0-9]+$ && "${IUSE_PCT:-0}" -ge 99 ]] \
   || [[ -n "$(match 'No space left on device|errno: ?28|Disk (is )?full' 1)" ]]; then
  BLOCKERS+=("DISK: the datadir filesystem is (nearly) full - free space first; this script will not delete data.")
fi

# 2. Stray mariadbd/mysqld processes not owned by systemd.
MAINPID="$(systemctl show -p MainPID --value "$SVC" 2>/dev/null)"
STRAY=()
# Also anything else holding the lock files (e.g. aria_chk, mariabackup).
HOLDERS=""
command -v fuser >/dev/null && HOLDERS="$(fuser "$DATADIR"/aria_log_control "$DATADIR"/ibdata1 2>/dev/null)"
for p in $(pgrep -x 'mariadbd|mysqld' 2>/dev/null) $HOLDERS; do
  [[ "$p" =~ ^[0-9]+$ ]] || continue
  [[ "$p" == "$MAINPID" && "$MAINPID" != 0 ]] && continue
  [[ " ${STRAY[*]:-} " == *" $p "* ]] && continue
  STRAY+=("$p")
done
LOCKMSG="$(match "Can't lock aria control file|aria_log_control.*error: ?11|Unable to lock .*ibdata1|lock wait timeout.*aria" 3)"
if (( ${#STRAY[@]} )); then
  echo "Stray DB  : ${#STRAY[@]} process(es) outside systemd:"
  for p in "${STRAY[@]}"; do ps -o pid=,user=,etime=,cmd= -p "$p" | sed 's/^/            /'; done
  ISSUES+=("STRAY: a mariadbd/mysqld process is running outside systemd and holds the data files.")
elif [[ -n "$LOCKMSG" ]]; then
  echo "Lock msgs : file lock errors, but nothing holds the files now (the holder has exited):"
  sed 's/^/            /' <<<"$LOCKMSG" | cut -c1-220
  ISSUES+=("RETRY: the last start failed on a file lock whose holder is gone - a clean start should work.")
fi

# 3. Aria log problems.
ARIA_RE="Aria engine: (log initialization failed|.*(error|failed|corrupt))|Aria recovery failed|Plugin 'Aria' (init function returned error|registration as a STORAGE ENGINE failed)|Unknown storage engine 'Aria'|Could not open mysql\.plugin table.*Aria|aria_log(_control)?.*(Wrong|corrupt|bad|incorrect|error)|Got error [0-9]+ .*aria_log|Error in Aria"
ARIA_LINES="$(match "$ARIA_RE" 6)"
shopt -s nullglob
ARIA_FILES=("$DATADIR"/aria_log_control "$DATADIR"/aria_log.[0-9]*)
shopt -u nullglob
if (( ${#ARIA_FILES[@]} )); then
  echo "Aria files: ${#ARIA_FILES[@]} in $DATADIR ($(du -ch "${ARIA_FILES[@]}" 2>/dev/null | tail -n1 | cut -f1))"
else
  echo "Aria files: none in $DATADIR (already moved aside?)"
fi
if [[ -n "$ARIA_LINES" ]]; then
  echo "Aria msgs :"
  sed 's/^/            /' <<<"$ARIA_LINES" | cut -c1-220
  if [[ -n "$LOCKMSG" ]]; then
    echo "            (caused by the file lock above - the Aria logs themselves are not touched)"
  elif (( ${#ARIA_FILES[@]} )); then
    ISSUES+=("ARIA: Aria engine failed to initialise - aria_log* will be moved aside so MariaDB recreates them.")
  fi
fi

# 4. Ownership of the datadir and Aria files.
BAD_OWN="$(find "$DATADIR" -maxdepth 1 \( -name 'aria_log*' -o -path "$DATADIR" \) ! -user mysql 2>/dev/null)"
if [[ -n "$BAD_OWN" || -n "$(match 'Permission denied|errno: ?13' 1)" ]]; then
  echo "Ownership : not owned by mysql:"; sed 's/^/            /' <<<"${BAD_OWN:-  (see Permission denied in log)}"
  [[ -n "$BAD_OWN" ]] && ISSUES+=("OWNER: datadir/Aria files are not owned by mysql - will chown them to mysql:mysql.")
fi

# 5. InnoDB problems (reported, not fixed). Lock errors are covered by STRAY.
INNO_LINES="$(grep -E "InnoDB:|Plugin 'InnoDB'" <<<"$LOG" \
  | grep -E "\[ERROR\]|corrupt|Cannot allocate|Operating system error|Missing MLOG|log sequence number .*in the future|Upgrade after a crash|init function returned error|registration as a STORAGE ENGINE failed" \
  | grep -vE "Unable to lock|error: ?11" | tail -n 8)"
INNO_REAL="$(grep -vE "registration as a STORAGE ENGINE failed|Plugin initialization aborted|init function returned error" <<<"$INNO_LINES")"
if [[ -n "$INNO_LINES" ]]; then
  echo "InnoDB    :"
  sed 's/^/            /' <<<"$INNO_LINES" | cut -c1-220
fi
if [[ -n "$INNO_REAL" ]]; then
  BLOCKERS+=("INNODB: InnoDB has its own error (above). This script does not repair InnoDB - investigate before any innodb_force_recovery.")
elif [[ -n "$INNO_LINES" && ${#STRAY[@]} -eq 0 && -z "$LOCKMSG" ]]; then
  echo "            (InnoDB failed without a specific reason in the last 300 lines - check earlier in $ERRLOG)"
fi

# 6. Memory.
if [[ -n "$(match 'Cannot allocate memory|mmap.*failed|Out of memory|OOM' 1)" ]]; then
  BLOCKERS+=("MEMORY: allocation failures in the log - check free -m and innodb_buffer_pool_size.")
fi

# --- Verdict ------------------------------------------------------------------
echo
if (( ${#BLOCKERS[@]} )); then
  echo "RESULT: NOT an Aria-only problem. Not fixed by this script:"
  printf '  - %s\n' "${BLOCKERS[@]}"
  (( ${#ISSUES[@]} )) && { echo "Also found (fixable, but MariaDB would still fail):"; printf '  - %s\n' "${ISSUES[@]}"; }
  echo
  echo "Last 15 log lines:"; tail -n 15 <<<"$LOG" | cut -c1-220
  echo "No changes made."
  show_status
  exit 2
fi

if (( ${#ISSUES[@]} == 0 )); then
  echo "RESULT: no Aria log, lock or ownership problem found. $SVC is down for another reason."
  echo
  echo "Last 20 log lines:"; tail -n 20 <<<"$LOG" | cut -c1-220
  echo "No changes made."
  show_status
  exit 3
fi

echo "RESULT: fixable Aria-related problem(s):"
printf '  - %s\n' "${ISSUES[@]}"

if [[ $MODE == check ]]; then
  echo
  echo "Check only (--check) - no changes made."
  show_status
  exit 0
fi

echo
echo "The fix will:"
(( ${#STRAY[@]} )) && echo "  - stop the stray DB process(es) ${STRAY[*]} (SIGTERM, wait up to 120s, then SIGKILL)"
[[ " ${ISSUES[*]} " == *"ARIA:"* ]] && echo "  - move ${#ARIA_FILES[@]} aria_log* file(s) to /root/aria_backup/<timestamp>/"
[[ " ${ISSUES[*]} " == *"OWNER:"* ]] && echo "  - chown the datadir and aria_log* files to mysql:mysql"
echo "  - reset-failed and start $SVC, then show its status"
confirm "Apply the fix?" || die "Aborted. No changes made."
echo

# --- Fix ----------------------------------------------------------------------
if (( ${#STRAY[@]} )); then
  echo "Stopping stray process(es): ${STRAY[*]}"
  kill -TERM "${STRAY[@]}" 2>/dev/null
  for _ in $(seq 1 120); do
    alive=0; for p in "${STRAY[@]}"; do kill -0 "$p" 2>/dev/null && alive=1; done
    (( alive )) || break; sleep 1
  done
  for p in "${STRAY[@]}"; do
    kill -0 "$p" 2>/dev/null && { echo "  $p did not exit in 120s - SIGKILL"; kill -KILL "$p" 2>/dev/null; }
  done
  sleep 1
  echo "  done."
fi

BACKUP=""
if [[ " ${ISSUES[*]} " == *"ARIA:"* ]]; then
  BACKUP="/root/aria_backup/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP" || die "Could not create $BACKUP. No Aria files moved."
  # Recheck: files may have changed if a stray process was just stopped.
  shopt -s nullglob
  ARIA_FILES=("$DATADIR"/aria_log_control "$DATADIR"/aria_log.[0-9]*)
  shopt -u nullglob
  mv "${ARIA_FILES[@]}" "$BACKUP"/ || die "Moving aria_log* to $BACKUP failed - check what is left in $DATADIR."
  echo "Moved ${#ARIA_FILES[@]} Aria log file(s) to $BACKUP"
fi

if [[ " ${ISSUES[*]} " == *"OWNER:"* ]]; then
  chown mysql:mysql "$DATADIR" && echo "chown mysql:mysql $DATADIR"
  find "$DATADIR" -maxdepth 1 -name 'aria_log*' -exec chown mysql:mysql {} + 2>/dev/null
fi

echo "Starting $SVC ..."
systemctl reset-failed "$SVC" 2>/dev/null
systemctl start "$SVC" 2>&1 | tail -n 3
for _ in $(seq 1 60); do is_up && break; sleep 2; done

echo
if is_up; then
  echo "SUCCESS: $SVC is running and answering ping."
  # Aria tables that were open at the crash can be marked crashed.
  CRASHED="$( { journalctl -u "$SVC" --since '-5 min' -o cat --no-pager 2>/dev/null; tail -n 200 "$ERRLOG" 2>/dev/null; } \
              | grep -iE "marked as crashed|should be repaired" | sort -u | tail -n 5)"
  if [[ -n "$CRASHED" ]]; then
    echo "WARNING: tables reported as crashed - repair them (e.g. fix_crashed_tables.sh in this repo):"
    sed 's/^/  /' <<<"$CRASHED" | cut -c1-220
  fi
  command -v monit >/dev/null && monit monitor mysql >/dev/null 2>&1
  [[ -n "$BACKUP" ]] && echo "Old Aria logs kept in $BACKUP - delete once you are happy: rm -rf $BACKUP"
  show_status
  exit 0
fi

echo "FAILED: $SVC is still not running. Newest log lines:" >&2
{ journalctl -u "$SVC" --since '-3 min' -o cat --no-pager 2>/dev/null; tail -n 30 "$ERRLOG" 2>/dev/null; } \
  | grep -E "\[ERROR\]|Aria|InnoDB|Failed" | tail -n 15 | cut -c1-220 >&2
if [[ -n "$BACKUP" ]]; then
  echo "To put the old Aria logs back:" >&2
  echo "  mv $BACKUP/aria_log* $DATADIR/ && chown mysql:mysql $DATADIR/aria_log*" >&2
fi
show_status
exit 1
