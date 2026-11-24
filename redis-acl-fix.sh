#!/usr/bin/env bash
#
# redis-acl-fix.sh
# Finds and fixes the common reasons redis-server will not start (or cannot
# save) on Cloudways / Debian servers. Every problem found is printed in red,
# every fix applied is printed in green.
#
# Fixes:
#   - ACL file (aclfile in redis.conf, e.g. /etc/redis/users.acl), broken
#     after the Redis 7.x upgrade (Nov 2026):
#       duplicate users ("Duplicate user 'x' found on line N") -> each user's
#       lines are merged into one, keeping ALL password hashes;
#       two entries glued on one line ("Error in applying operation
#       '+@alluser'") -> split back into separate lines;
#       CRLF line endings / blank lines -> cleaned.
#     The fixed file is test-loaded in a throw-away redis-server before it
#     replaces the real one; the original is kept as users.acl.pre-fix-<ts>.
#   - corrupt RDB snapshot ("Invalid LZF compressed string", "Short read or
#     OOM loading DB", "Wrong RDB checksum", "Terminating server after rdb
#     file reading failure", RDB from a newer Redis) -> confirmed with
#     redis-check-rdb, then moved to /root/redis-fix-backup/<ts>/ so Redis
#     starts with an empty dataset (on Cloudways Redis is a cache; the apps
#     rebuild it)
#   - corrupt / truncated AOF (appendonly yes, "Bad file format reading the
#     append only file") -> backed up, then repaired with redis-check-aof --fix
#   - log directory deleted ("Can't open the log file") -> recreated
#     redis:adm 2750 (Debian default)
#   - data directory (dir in redis.conf) missing or not writable by redis
#     -> created / chowned redis:redis
#   - RDB file not owned by redis -> chowned
#   - background saves failing (rdb_last_bgsave_status:err, MISCONF errors)
#     while vm.overcommit_memory is not 1 -> set to 1 (sysctl and
#     /etc/sysctl.d/99-redis-overcommit.conf), then a BGSAVE confirms it
# Reports only (no change): another process holding the Redis port, a full
# disk, an aclfile that is configured but missing.
# Then redis-server is started (if it was down) and its status is shown.
#
# Usage (as root):
#   bash redis-acl-fix.sh            # check, confirm, fix
#   bash redis-acl-fix.sh --check    # check only, no changes
#   bash redis-acl-fix.sh --yes      # fix without the confirmation prompt
#   curl -fsSL <raw-url> | sudo bash -s -- [--check|--yes]
#
# Exit codes: 0 OK / fixed, 1 still failing after the fix, 2 problem found
# that this script cannot fix, 3 Redis is down for a reason it does not know.

set -uo pipefail

# Colours only on a terminal (and not with NO_COLOR set).
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  RED=$'\e[1;31m'; GREEN=$'\e[1;32m'; YELLOW=$'\e[1;33m'; RST=$'\e[0m'
else
  RED=""; GREEN=""; YELLOW=""; RST=""
fi
red()    { echo "${RED}$*${RST}"; }
green()  { echo "${GREEN}$*${RST}"; }
yellow() { echo "${YELLOW}$*${RST}"; }

die() { echo "${RED}ERROR: $*${RST}" >&2; exit 1; }
hr()  { echo "------------------------------------------------------------"; }

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
command -v redis-server >/dev/null || die "redis-server not found."

confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  local ok; read -r -p "$1 [y/N]: " ok </dev/tty || return 1
  [[ "$ok" =~ ^[Yy]$ ]]
}

SVC=redis-server
CONF=/etc/redis/redis.conf
[[ -f "$CONF" ]] || die "$CONF not found."

# redis.conf plus any files it includes; for a key the last value wins.
CONF_FILES=("$CONF")
while read -r inc; do
  for f in $inc; do [[ -f "$f" ]] && CONF_FILES+=("$f"); done
done < <(awk 'tolower($1)=="include"{print $2}' "$CONF")
conf_has() { grep -qiE "^[[:space:]]*$1([[:space:]]|$)" "${CONF_FILES[@]}" 2>/dev/null; }
conf_get() {
  awk -v k="$1" 'tolower($1)==k{$1=""; sub(/^[ \t]+/,""); v=$0} END{print v}' "${CONF_FILES[@]}" 2>/dev/null | tr -d "\"'"
}

ACL="$(conf_get aclfile)"
PORT="$(conf_get port)"; PORT="${PORT:-6379}"
SOCK="$(conf_get unixsocket)"
if conf_has logfile; then LOG="$(conf_get logfile)"; else LOG=/var/log/redis/redis-server.log; fi
DATADIR="$(conf_get dir)"; DATADIR="${DATADIR:-/var/lib/redis}"; DATADIR="${DATADIR%/}"
RDBNAME="$(conf_get dbfilename)"; RDB="$DATADIR/${RDBNAME:-dump.rdb}"
AOF_ON="$(conf_get appendonly)"
AOFDIR="$DATADIR/$(conf_get appenddirname)"; [[ "$AOFDIR" == "$DATADIR/" ]] && AOFDIR="$DATADIR/appendonlydir"
AOFNAME="$(conf_get appendfilename)"; AOFNAME="${AOFNAME:-appendonly.aof}"
PASS="$(conf_get requirepass)"; [[ -n "$PASS" ]] && export REDISCLI_AUTH="$PASS"

if [[ "$PORT" == 0 && -n "$SOCK" ]]; then RCLI=(redis-cli -s "$SOCK"); else RCLI=(redis-cli -p "$PORT"); fi
rcli()       { timeout 5 "${RCLI[@]}" "$@" 2>&1; }
ping_redis() { rcli ping | head -n1; }
is_up()      { systemctl is-active --quiet "$SVC" && [[ "$(ping_redis)" =~ PONG|NOAUTH ]]; }
info_field() { rcli info "$1" | tr -d '\r' | awk -F: -v k="$2" '$1==k{print $2}'; }

show_status() {
  hr
  echo "== Redis status"
  systemctl status "$SVC" --no-pager 2>&1 | sed -n '1,6p'
  echo
  printf 'redis-cli ping : %s\n' "$(ping_redis)"
  printf 'listening      : %s\n' "$(ss -ltnp 2>/dev/null | awk -v p=":$PORT" '$4 ~ p"$"{print $4, $6}' | tr '\n' ' ')"
  command -v monit >/dev/null && printf 'monit          : %s\n' "$(monit summary 2>/dev/null | grep -iE '^\s*redis\b' | sed 's/^ *//' | head -n1)"
  hr
  if is_up; then green "REDIS STATUS: RUNNING"; else red "REDIS STATUS: NOT RUNNING"; fi
}

# Lines from the latest start attempt only (old errors outlive a fix), plus
# the recent journal (catches errors logged before the log file opens).
last_run_log() {
  if [[ -n "$LOG" && -r "$LOG" ]]; then
    tail -n 5000 "$LOG" | awk '/Redis is starting|oO0OoO0OoO0Oo/{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}'
  fi
  journalctl -u "$SVC" -n 60 -o cat --no-pager 2>/dev/null \
    | grep -vE '^(Started|Stopped|Starting|Failed to start)|Scheduled restart|repeated too quickly|Main process exited|Failed with result'
}
log_tail() {
  { [[ -n "$LOG" && -r "$LOG" ]] && cat "$LOG" || journalctl -u "$SVC" -n 40 -o cat --no-pager; } 2>/dev/null \
    | grep -vE 'overcommit|oO0Oo|Supervised|Configuration loaded|monotonic' | tail -n "${1:-5}" | cut -c1-250
}

ISSUES=(); FIXED=(); NOFIX=()
issue()  { ISSUES+=("$1"); }
nofix()  { ISSUES+=("$1"); NOFIX+=("$1"); }
fixed()  { FIXED+=("$1"); green "FIXED: $1"; }

UP=0; is_up && UP=1
echo "== Check: $(hostname)"
echo "Redis     : $(redis-server --version 2>/dev/null | grep -oP 'v=\K\S+') ($(systemctl is-active "$SVC" 2>/dev/null))"
echo "Data      : $RDB$([[ "$AOF_ON" == yes ]] && echo " + AOF ($AOFDIR)")"
echo "ACL file  : ${ACL:-none configured}"
echo "Log       : ${LOG:-journal only}"
echo
echo "== Findings"
LASTRUN="$(last_run_log)"

# --- 1. Log directory deleted (e.g. by a disk cleanup) -------------------------
LOGDIR_FIX=0
if [[ "$LOG" == /* ]]; then
  LOGDIR="$(dirname "$LOG")"
  if [[ ! -d "$LOGDIR" ]]; then
    red "Log dir   : $LOGDIR is missing (logfile $LOG)"
    LOGERR="$(grep -m1 "Can't open the log file" <<<"$LASTRUN")"
    [[ -n "$LOGERR" ]] && red "Last start error: $LOGERR"
    issue "LOGDIR: $LOGDIR does not exist - Redis cannot open its log file and aborts; it will be recreated."
    LOGDIR_FIX=1
  fi
fi

# --- 2. Data directory missing / not writable by redis --------------------------
DATADIR_FIX=""
if [[ "$DATADIR" == /* ]] && id redis >/dev/null 2>&1; then
  if [[ ! -d "$DATADIR" ]]; then
    red "Data dir  : $DATADIR is missing"
    issue "DATADIR: $DATADIR does not exist - Redis cannot chdir there and aborts; it will be created (redis:redis 750)."
    DATADIR_FIX=create
  elif ! runuser -u redis -- test -w "$DATADIR" 2>/dev/null; then
    red "Data dir  : $DATADIR is not writable by redis ($(stat -c '%U:%G %a' "$DATADIR"))"
    issue "DATADIR: redis cannot write to $DATADIR - saves fail; it will be chowned to redis:redis."
    DATADIR_FIX=chown
  fi
fi

# --- 3. RDB snapshot: corrupt, or not owned by redis ---------------------------
RDB_ERR_RE="Short read|Invalid LZF|Wrong signature|rdb file reading failure|Unexpected EOF reading RDB|Can't handle RDB format version|Unknown RDB (string )?encoding|Wrong RDB checksum|Internal error in RDB|Error trying to load the RDB"
RDB_MOVE=0; RDB_CHOWN=0
if [[ -f "$RDB" ]]; then
  if (( ! UP )); then
    RDBLOG="$(grep -E "$RDB_ERR_RE" <<<"$LASTRUN" | tail -n1 | cut -c1-250)"
    RDBCHK=""
    if command -v redis-check-rdb >/dev/null; then
      echo "Checking  : $RDB ($(du -h "$RDB" | cut -f1), saved $(date -r "$RDB" '+%F %T')) with redis-check-rdb ..."
      RDBCHK_OUT="$(timeout 300 redis-check-rdb "$RDB" 2>&1)"; rc=$?
      if (( rc == 124 )); then
        yellow "redis-check-rdb timed out after 300s - relying on the Redis log only."
      elif (( rc != 0 )) || grep -q 'RDB ERROR DETECTED' <<<"$RDBCHK_OUT"; then
        RDBCHK="$(grep -m1 -iE 'error|invalid|short read|wrong' <<<"$RDBCHK_OUT" | cut -c1-250)"
        RDBCHK="${RDBCHK:-redis-check-rdb exit code $rc}"
      else
        green "RDB file  : redis-check-rdb reports it OK"
      fi
    fi
    if [[ -n "$RDBLOG" || -n "$RDBCHK" ]]; then
      [[ -n "$RDBLOG" ]] && red "Last start error: ${RDBLOG#*# }"
      [[ -n "$RDBCHK" ]] && red "redis-check-rdb : $RDBCHK"
      issue "RDB: $RDB is corrupt or unreadable - Redis stops while loading it; it will be moved to /root/redis-fix-backup/ and Redis starts with an empty cache."
      RDB_MOVE=1
    fi
  fi
  if (( ! RDB_MOVE )) && [[ "$(stat -c %U "$RDB")" != redis ]] && id redis >/dev/null 2>&1; then
    red "RDB owner : $RDB is owned by $(stat -c '%U:%G' "$RDB")"
    issue "RDBOWNER: $RDB is not owned by redis - Redis cannot replace it; it will be chowned to redis:redis."
    RDB_CHOWN=1
  fi
fi

# --- 4. AOF corrupt / truncated (only when appendonly yes) ----------------------
AOF_ERR_RE="Bad file format reading the append only file|Unexpected end of file reading the append only file|Unrecoverable error reading the append only file|AOF.*(is truncated|corrupt)|Invalid AOF manifest|manifest.*(not found|invalid)"
AOF_FIX=0; AOFPATH=""
if [[ "$AOF_ON" == yes ]] && (( ! UP )); then
  AOFLOG="$(grep -E "$AOF_ERR_RE" <<<"$LASTRUN" | tail -n1 | cut -c1-250)"
  if [[ -n "$AOFLOG" ]]; then
    red "Last start error: ${AOFLOG#*# }"
    if [[ -d "$AOFDIR" ]]; then AOFPATH="$(ls "$AOFDIR"/*.manifest 2>/dev/null | head -n1)"; else AOFPATH="$DATADIR/$AOFNAME"; fi
    if command -v redis-check-aof >/dev/null && [[ -n "$AOFPATH" && -e "$AOFPATH" ]]; then
      issue "AOF: the append-only file is corrupt or truncated - it will be backed up, then repaired with redis-check-aof --fix ($AOFPATH)."
      AOF_FIX=1
    else
      nofix "AOF: the append-only file is corrupt, but redis-check-aof or the AOF manifest/file was not found - repair it by hand."
    fi
  fi
fi

# --- 5. ACL file ----------------------------------------------------------------
# A glued entry looks like "... +@alluser bob on ..." (newline lost between
# "+@all" and "user"), or a bare "user" token in the middle of a line.
split_acl() {
  tr -d '\r' < "$1" | awk '
    NF==0 {next}
    {
      out=""
      for (i=1; i<=NF; i++) {
        t=$i
        if (i>1 && t=="user") { print out; out="user"; continue }
        if (i>1 && t ~ /.user$/ && t!="user" && i+2<=NF && $(i+2) ~ /^(on|off)$/) {
          out=out" "substr(t,1,length(t)-4); print out; out="user"; continue
        }
        out=(out=="" ? t : out" "t)
      }
      print out
    }'
}
# Merge duplicate users, keeping every distinct rule/hash in order.
merge_acl() {
  awk '
    $1!="user" {other[++no]=$0; next}
    {
      u=$2
      if (!(u in line)) { order[++n]=u; line[u]=$0; next }
      for (i=3; i<=NF; i++) if (index(" "line[u]" ", " "$i" ")==0) line[u]=line[u]" "$i
    }
    END { for (i=1;i<=n;i++) print line[order[i]]; for (i=1;i<=no;i++) print other[i] }'
}

TMPD="$(mktemp -d /tmp/redis-acl-fix.XXXXXX)" || die "mktemp failed."
trap 'rm -rf "$TMPD"' EXIT

ACL_BAD=0
if [[ -n "$ACL" && ! -f "$ACL" ]]; then
  red "ACL file  : $ACL is configured but does not exist"
  nofix "ACLMISSING: $ACL is set as aclfile but is missing - Redis aborts; restore it from a backup (the passwords cannot be recreated here)."
elif [[ -n "$ACL" ]]; then
  split_acl "$ACL" > "$TMPD/split.acl"
  merge_acl < "$TMPD/split.acl" > "$TMPD/fixed.acl"
  LINES_ORIG="$(grep -cve '^\s*$' "$ACL")"
  GLUED="$(( $(wc -l < "$TMPD/split.acl") - LINES_ORIG ))"
  CRLF="$(grep -c $'\r' "$ACL")"
  DUPS="$(awk '$1=="user"{print $2}' "$TMPD/split.acl" | sort | uniq -d)"
  NDUPS="$(grep -c . <<<"$DUPS")"
  CONFLICT="$(awk '$1=="user"{for(i=3;i<=NF;i++) if($i=="on"||$i=="off") s[$2]=s[$2]" "$i} END{for(u in s) if(s[u] ~ /on/ && s[u] ~ /off/) print u}' "$TMPD/split.acl")"
  (( GLUED > 0 || NDUPS > 0 || CRLF > 0 )) && ACL_BAD=1
  if (( ACL_BAD )); then
    echo "ACL users : $LINES_ORIG lines -> $(wc -l < "$TMPD/fixed.acl") users after fix"
    (( GLUED > 0 )) && issue "ACL GLUED: $GLUED line(s) in $ACL hold two entries joined together (e.g. '+@alluser')."
    (( NDUPS > 0 )) && issue "ACL DUPLICATE: $NDUPS user(s) defined more than once - lines will be merged, keeping all password hashes."
    (( CRLF > 0 ))  && issue "ACL CRLF: $CRLF line(s) in $ACL have Windows line endings."
    [[ -n "$CONFLICT" ]] && yellow "WARNING: these users are both 'on' and 'off' in different lines; after merging the last one wins: $(tr '\n' ' ' <<<"$CONFLICT")"
    LASTERR="$(grep -h 'ACL errors' <<<"$LASTRUN" | tail -n1 | cut -c1-300)"
    [[ -n "$LASTERR" ]] && red "Last ACL error: ${LASTERR#*# }"
  fi
fi

# --- 6. Port held by another process -------------------------------------------
HOLDER="$(ss -ltnp 2>/dev/null | awk -v p=":$PORT" '$4 ~ p"$"{print $6}' | head -n1)"
HPID=""
if [[ -n "$HOLDER" ]] && ! systemctl is-active --quiet "$SVC"; then
  HPID="$(grep -oP 'pid=\K[0-9]+' <<<"$HOLDER" | head -n1)"
  red "Port      : $PORT is held by another process while $SVC is down:"
  ps -o pid=,user=,etime=,cmd= -p "$HPID" 2>/dev/null | sed 's/^/            /'
  echo "            ($(tail -n1 /proc/"$HPID"/cgroup 2>/dev/null)) - a rogue/manual redis-server; stop it and check crontabs."
  nofix "PORT: port $PORT is in use by PID $HPID - this script does not stop it; redis-server cannot start until it is gone."
fi

# --- 7. Disk full ---------------------------------------------------------------
DISK_FULL=0
DISKDIR="$DATADIR"; [[ -d "$DISKDIR" ]] || DISKDIR=/
read -r AVAIL_KB USE_PCT <<<"$(df -Pk "$DISKDIR" | awk 'NR==2{gsub("%","",$5); print $4, $5}')"
if (( ${AVAIL_KB:-999999} < 204800 || ${USE_PCT:-0} >= 99 )); then
  red "Disk      : $(df -Ph "$DISKDIR" | awk 'NR==2{print $6" is "$5" full, "$4" free"}')"
  DISK_FULL=1
  nofix "DISK: the disk holding $DISKDIR is (almost) full - saves fail and Redis may not start; free space first (this script deletes nothing)."
fi

# --- 8. Background saves failing (MISCONF) / overcommit -------------------------
OC="$(cat /proc/sys/vm/overcommit_memory 2>/dev/null)"
OVERCOMMIT_FIX=0
if (( UP )) && [[ "$(info_field persistence rdb_last_bgsave_status)" == err ]]; then
  FORKERR="$(grep -E "Can't save in background|Background saving error|Cannot allocate memory" <<<"$LASTRUN" | tail -n1 | cut -c1-250)"
  red "Saving    : background saves are failing (rdb_last_bgsave_status:err)${FORKERR:+ - ${FORKERR#*# }}"
  if [[ "$OC" != 1 ]]; then
    issue "BGSAVE: saves fail and vm.overcommit_memory=$OC (Redis needs 1) - it will be set to 1 (sysctl + /etc/sysctl.d/99-redis-overcommit.conf)."
    OVERCOMMIT_FIX=1
  elif [[ -z "$DATADIR_FIX" ]] && (( ! DISK_FULL )); then
    nofix "BGSAVE: saves fail for another reason - check: tail -n 50 ${LOG:-<journal>}"
  fi
elif [[ "$OC" != 1 ]]; then
  yellow "Note      : vm.overcommit_memory=$OC (Redis recommends 1); not changed because saves are not failing."
fi

# --- Result ---------------------------------------------------------------------
if (( ${#ISSUES[@]} == 0 )); then
  if (( UP )); then
    green "RESULT: no problems found."
    show_status; exit 0
  fi
  red "RESULT: $SVC is not running and none of the known causes match. Last log lines:"
  log_tail 8
  show_status; exit 3
fi

red "RESULT: ISSUE FOUND:"
for i in "${ISSUES[@]}"; do red "  - $i"; done
echo

# Validate the fixed ACL in a throw-away redis-server: no TCP port, no RDB/AOF,
# its own temp dir; if the ACL is bad it aborts at once.
validate_acl() {
  local f="$1" sock="$TMPD/test.sock" pid
  chmod 644 "$f"
  redis-server --port 0 --unixsocket "$sock" --aclfile "$f" --dir "$TMPD" \
    --save "" --appendonly no --daemonize no --logfile "$TMPD/test.log" \
    --supervised no --protected-mode yes >/dev/null 2>&1 &
  pid=$!
  for _ in 1 2 3 4 5 6; do [[ -S "$sock" ]] && break; kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
  if [[ -S "$sock" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 0
  fi
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  grep -h 'ACL' "$TMPD/test.log" | tail -n1 | cut -c1-300 >&2
  return 1
}

ACL_FIX=0
if (( ACL_BAD )); then
  if validate_acl "$TMPD/fixed.acl"; then
    green "VERIFIED: the fixed ACL file loads cleanly in a test redis-server ($(wc -l < "$TMPD/fixed.acl") users)."
    ACL_FIX=1
  else
    red "The fixed ACL file still fails to load (error above) - it will not be applied."
    NOFIX+=("ACL: automatic merge did not produce a loadable file - fix $ACL by hand.")
  fi
fi

if [[ $MODE == check ]]; then
  echo "Check only (--check) - no changes made."
  show_status; exit 0
fi

if (( ! (LOGDIR_FIX || ACL_FIX || RDB_MOVE || RDB_CHOWN || AOF_FIX || OVERCOMMIT_FIX) )) && [[ -z "$DATADIR_FIX" ]]; then
  echo "Nothing this script can change (see the issues above). No changes made."
  show_status; exit 2
fi

LOGGRP=adm; getent group adm >/dev/null || LOGGRP=redis
BKDIR="/root/redis-fix-backup/$(date +%Y%m%d-%H%M%S)"
echo "The fix will:"
(( LOGDIR_FIX )) && echo "  - create $LOGDIR (owner redis:$LOGGRP, mode 2750)"
[[ "$DATADIR_FIX" == create ]] && echo "  - create $DATADIR (owner redis:redis, mode 750)"
[[ "$DATADIR_FIX" == chown ]]  && echo "  - chown $DATADIR to redis:redis"
(( OVERCOMMIT_FIX )) && echo "  - set vm.overcommit_memory = 1 (now and in /etc/sysctl.d/99-redis-overcommit.conf)"
(( AOF_FIX )) && echo "  - copy the AOF to $BKDIR, then run redis-check-aof --fix on $AOFPATH"
(( RDB_MOVE )) && echo "  - move $RDB to $BKDIR/ (Redis starts with an empty cache)"
(( RDB_CHOWN )) && echo "  - chown $RDB to redis:redis"
(( ACL_FIX )) && echo "  - copy $ACL -> $ACL.pre-fix-<timestamp> and replace it with the fixed version"
if (( UP )); then
  echo "  - leave the running redis-server alone (ACL changes are used at its next restart)"
else
  echo "  - reset-failed and start $SVC"
fi
confirm "Apply the fix?" || die "Aborted. No changes made."
echo
echo "== Fixing"

# Stop a restart loop so files are not in use while they are moved/repaired.
if (( ! UP )) && (( RDB_MOVE || AOF_FIX )); then
  systemctl stop "$SVC" 2>/dev/null
fi

if (( LOGDIR_FIX )); then
  if install -d -o redis -g "$LOGGRP" -m 2750 "$LOGDIR"; then
    fixed "log directory $LOGDIR created ($(stat -c '%U:%G %a' "$LOGDIR"))"
  else red "Could not create $LOGDIR."; fi
fi

if [[ "$DATADIR_FIX" == create ]]; then
  if install -d -o redis -g redis -m 750 "$DATADIR"; then fixed "data directory $DATADIR created (redis:redis 750)"
  else red "Could not create $DATADIR."; fi
elif [[ "$DATADIR_FIX" == chown ]]; then
  if chown redis:redis "$DATADIR" && runuser -u redis -- test -w "$DATADIR"; then fixed "$DATADIR is writable by redis ($(stat -c '%U:%G %a' "$DATADIR"))"
  else red "$DATADIR is still not writable by redis."; fi
fi

if (( OVERCOMMIT_FIX )); then
  echo "vm.overcommit_memory = 1" > /etc/sysctl.d/99-redis-overcommit.conf
  if sysctl -q -w vm.overcommit_memory=1 && [[ "$(cat /proc/sys/vm/overcommit_memory)" == 1 ]]; then
    fixed "vm.overcommit_memory = 1 (persisted in /etc/sysctl.d/99-redis-overcommit.conf)"
  else red "Could not set vm.overcommit_memory."; fi
fi

if (( AOF_FIX )); then
  mkdir -p "$BKDIR"
  if [[ -d "$AOFDIR" ]]; then cp -a "$AOFDIR" "$BKDIR/" ; else cp -a "$DATADIR/$AOFNAME" "$BKDIR/"; fi \
    || die "AOF backup to $BKDIR failed - AOF not changed."
  echo "AOF backup: $BKDIR"
  AOFOUT="$(echo y | redis-check-aof --fix "$AOFPATH" 2>&1)"
  if grep -qiE 'Successfully truncated|AOF is valid|RDB preamble is OK|is valid' <<<"$AOFOUT"; then
    chown -R redis:redis "$AOFDIR" 2>/dev/null || chown redis:redis "$DATADIR/$AOFNAME" 2>/dev/null
    fixed "AOF repaired with redis-check-aof --fix (original in $BKDIR)"
  else
    red "redis-check-aof could not repair the AOF:"; tail -n 5 <<<"$AOFOUT"
  fi
fi

if (( RDB_MOVE )); then
  mkdir -p "$BKDIR"
  if mv "$RDB" "$BKDIR/"; then fixed "corrupt $RDB moved to $BKDIR/ (delete it once Redis is fine)"
  else red "Could not move $RDB."; fi
fi

if (( RDB_CHOWN )); then
  if chown redis:redis "$RDB"; then fixed "$RDB owned by redis:redis"; else red "Could not chown $RDB."; fi
fi

ACL_BAK=""
if (( ACL_FIX )); then
  ACL_BAK="$ACL.pre-fix-$(date +%Y%m%d-%H%M%S)"
  cp -a "$ACL" "$ACL_BAK" || die "ACL backup failed. ACL file not changed."
  OWN="$(stat -c '%U:%G' "$ACL")"; MOD="$(stat -c '%a' "$ACL")"
  if install -o "${OWN%%:*}" -g "${OWN##*:}" -m "$MOD" "$TMPD/fixed.acl" "$ACL"; then
    fixed "$ACL rewritten ($(wc -l < "$ACL") users; original kept as $ACL_BAK)"
  else
    cp -a "$ACL_BAK" "$ACL"; die "Writing $ACL failed - original restored."
  fi
fi

summary() {
  hr
  echo "== Summary"
  for i in "${ISSUES[@]}"; do red   "  ISSUE : $i"; done
  for f in "${FIXED[@]}";  do green "  FIXED : $f"; done
  for n in "${NOFIX[@]}";  do red   "  OPEN  : $n"; done
}

# Confirm a background save works (after the overcommit fix).
check_bgsave() {
  [[ "$(conf_get save)" == "" ]] && conf_has save && return 0   # saving disabled
  rcli bgsave >/dev/null
  for _ in $(seq 1 60); do [[ "$(info_field persistence rdb_bgsave_in_progress)" == 0 ]] && break; sleep 1; done
  if [[ "$(info_field persistence rdb_last_bgsave_status)" == ok ]]; then
    fixed "BGSAVE works again (rdb_last_bgsave_status:ok, $RDB written)"
  else
    red "BGSAVE still fails - check: tail -n 30 ${LOG:-<journal>}"
  fi
}

if (( UP )); then
  (( OVERCOMMIT_FIX )) && check_bgsave
  summary; show_status
  if (( ${#NOFIX[@]} )); then red "PARTLY FIXED: $SVC is running, but see OPEN above."; exit 2; fi
  green "SUCCESS: fixed. $SVC is RUNNING (it was already up and was not restarted)."
  exit 0
fi

if [[ -n "$HPID" ]] && kill -0 "$HPID" 2>/dev/null; then
  summary; show_status
  red "Port $PORT is still held by PID $HPID - stop it, then: systemctl reset-failed $SVC && systemctl start $SVC"
  exit 1
fi

echo
echo "Starting $SVC ..."
systemctl reset-failed "$SVC" 2>/dev/null
systemctl start "$SVC" 2>&1 | tail -n 3
for _ in $(seq 1 30); do is_up && break; sleep 1; done

echo
if is_up; then
  command -v monit >/dev/null && monit monitor redis >/dev/null 2>&1
  (( OVERCOMMIT_FIX )) && check_bgsave
  (( RDB_MOVE )) && yellow "Note: Redis started with an empty dataset; the apps refill the cache on their own."
  summary; show_status
  green "SUCCESS: $SVC is RUNNING (redis-cli ping: $(ping_redis))."
  exit 0
fi

summary
red "FAILED: $SVC is still not running. Newest log lines:" >&2
log_tail 6 >&2
[[ -n "$ACL_BAK" ]] && echo "To restore the original ACL: install -o ${OWN%%:*} -g ${OWN##*:} -m $MOD $ACL_BAK $ACL" >&2
echo "Run the script again - it re-checks from the latest start attempt." >&2
show_status; exit 1
