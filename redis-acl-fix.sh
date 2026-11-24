#!/usr/bin/env bash
#
# redis-acl-fix.sh
# Fixes Redis failing to start because of a broken ACL file (/etc/redis/users.acl),
# seen after the Redis 7.x upgrade (Nov 2026):
#   - duplicate users ("Duplicate user 'x' found on line N"): old Redis
#     accepted them, 7.x aborts -> each user's lines are merged into one,
#     keeping ALL password hashes, so whichever one the app uses still works
#   - two entries glued on one line ("Error in applying operation
#     '+@alluser'") -> split back into separate lines
#   - CRLF line endings / blank lines -> cleaned
# The merged file is test-loaded in a throw-away redis-server (no TCP port,
# no persistence) before it replaces the real one; the original is kept as
# users.acl.pre-fix-<timestamp>. Then redis-server is started (if it was down)
# and its status is shown.
# Also reports (does not fix) another process holding the Redis port.
#
# Usage (as root):
#   bash redis-acl-fix.sh            # check, confirm, fix
#   bash redis-acl-fix.sh --check    # check only, no changes
#   bash redis-acl-fix.sh --yes      # fix without the confirmation prompt
#   curl -fsSL <raw-url> | sudo bash -s -- [--check|--yes]

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
ACL="$(awk '/^[[:space:]]*aclfile[[:space:]]/{print $2}' "$CONF" | tail -n1 | tr -d '"')"
PORT="$(awk '/^[[:space:]]*port[[:space:]]/{print $2}' "$CONF" | tail -n1)"; PORT="${PORT:-6379}"
LOG="$(awk '/^[[:space:]]*logfile[[:space:]]/{print $2}' "$CONF" | tail -n1 | tr -d '"')"
LOG="${LOG:-/var/log/redis/redis-server.log}"

ping_redis() { timeout 3 redis-cli -p "$PORT" ping 2>&1 | head -n1; }
is_up() { systemctl is-active --quiet "$SVC" && [[ "$(ping_redis)" =~ PONG|NOAUTH ]]; }

show_status() {
  hr
  echo "== Redis status"
  systemctl status "$SVC" --no-pager 2>&1 | sed -n '1,6p'
  echo
  printf 'redis-cli ping : %s\n' "$(ping_redis)"
  printf 'listening      : %s\n' "$(ss -ltnp 2>/dev/null | awk -v p=":$PORT" '$4 ~ p"$"{print $4, $6}' | tr '\n' ' ')"
  command -v monit >/dev/null && printf 'monit          : %s\n' "$(monit summary 2>/dev/null | grep -iE '^\s*redis\b' | sed 's/^ *//')"
  hr
  if is_up; then green "REDIS STATUS: RUNNING"; else red "REDIS STATUS: NOT RUNNING"; fi
}

echo "== Check: $(hostname)"
echo "Redis     : $(redis-server --version 2>/dev/null | grep -oP 'v=\K\S+') ($(systemctl is-active "$SVC" 2>/dev/null))"
echo "ACL file  : ${ACL:-none configured}"

if [[ -z "$ACL" ]]; then
  echo "RESULT: no aclfile in $CONF - nothing for this script to fix."
  show_status; exit 3
fi
[[ -f "$ACL" ]] || die "$ACL is configured but does not exist."

# --- Normalise: strip CR, split glued entries, drop blank lines ----------------
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

# --- Merge duplicate users, keeping every distinct rule/hash in order --------
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
split_acl "$ACL" > "$TMPD/split.acl"
merge_acl < "$TMPD/split.acl" > "$TMPD/fixed.acl"

LINES_ORIG="$(grep -cve '^\s*$' "$ACL")"
GLUED="$(( $(wc -l < "$TMPD/split.acl") - LINES_ORIG ))"
CRLF="$(grep -c $'\r' "$ACL")"
DUPS="$(awk '$1=="user"{print $2}' "$TMPD/split.acl" | sort | uniq -d)"
NDUPS="$(grep -c . <<<"$DUPS")"
CONFLICT="$(awk '$1=="user"{for(i=3;i<=NF;i++) if($i=="on"||$i=="off") s[$2]=s[$2]" "$i} END{for(u in s) if(s[u] ~ /on/ && s[u] ~ /off/) print u}' "$TMPD/split.acl")"

echo "Entries   : $LINES_ORIG lines -> $(wc -l < "$TMPD/fixed.acl") users after fix"
echo
echo "== Findings"
ISSUES=()
(( GLUED > 0 )) && ISSUES+=("GLUED: $GLUED line(s) hold two entries joined together (e.g. '+@alluser').")
(( NDUPS > 0 )) && ISSUES+=("DUPLICATE: $NDUPS user(s) defined more than once - lines will be merged, keeping all password hashes.")
(( CRLF > 0 ))  && ISSUES+=("CRLF: $CRLF line(s) have Windows line endings.")
[[ -n "$CONFLICT" ]] && yellow "WARNING: these users are both 'on' and 'off' in different lines; after merging the last one wins: $(tr '\n' ' ' <<<"$CONFLICT")"

LASTERR="$(grep -h 'ACL errors' "$LOG" 2>/dev/null | tail -n1 | cut -c1-300)"
[[ -n "$LASTERR" ]] && red "Last ACL error in log: ${LASTERR#*# }"

HOLDER="$(ss -ltnp 2>/dev/null | awk -v p=":$PORT" '$4 ~ p"$"{print $6}' | head -n1)"
if [[ -n "$HOLDER" ]] && ! systemctl is-active --quiet "$SVC"; then
  HPID="$(grep -oP 'pid=\K[0-9]+' <<<"$HOLDER" | head -n1)"
  echo "PORT      : $PORT is held by another process while $SVC is down:"
  ps -o pid=,user=,etime=,cmd= -p "$HPID" 2>/dev/null | sed 's/^/            /'
  echo "            ($(cat /proc/"$HPID"/cgroup 2>/dev/null | tail -n1)) - a rogue/manual redis-server; stop it and check crontabs."
  ISSUES+=("PORT: port $PORT is in use by PID $HPID - this script does not stop it; redis-server will not start until it is gone.")
fi

if (( ${#ISSUES[@]} == 0 )); then
  green "RESULT: ACL file has no duplicate, glued or CRLF problems."
  if ! is_up; then
    red "$SVC is not running for another reason. Last log lines:"
    grep -vE 'overcommit|oO0Oo|Supervised|Configuration loaded|monotonic' "$LOG" 2>/dev/null | tail -n 5 | cut -c1-250
  fi
  show_status; exit 0
fi

red "RESULT: ACL ISSUE FOUND - this is why redis-server will not start:"
for i in "${ISSUES[@]}"; do red "  - $i"; done
echo

# --- Validate the fixed file in a throw-away redis-server -----------------------
# No TCP port, no RDB/AOF, its own temp dir; if the ACL is bad it aborts at once.
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

ACL_FIXABLE=0
if (( GLUED > 0 || NDUPS > 0 || CRLF > 0 )); then
  if validate_acl "$TMPD/fixed.acl"; then
    green "VERIFIED: the fixed ACL file loads cleanly in a test redis-server ($(wc -l < "$TMPD/fixed.acl") users)."
    ACL_FIXABLE=1
  else
    red "The fixed file still fails to load (error above) - not applying it. No changes made." >&2
    show_status; exit 2
  fi
fi

if [[ $MODE == check ]]; then
  echo "Check only (--check) - no changes made."
  show_status; exit 0
fi

(( ACL_FIXABLE )) || { echo "Nothing this script can change (see PORT above). No changes made."; show_status; exit 2; }

echo
echo "The fix will:"
echo "  1. copy $ACL -> $ACL.pre-fix-<timestamp>"
echo "  2. replace it with the fixed version (same owner/permissions)"
if is_up; then
  echo "  3. leave the running redis-server alone (the file is used at its next restart)"
else
  echo "  3. reset-failed and start $SVC"
fi
confirm "Apply the fix?" || die "Aborted. No changes made."
echo

BAK="$ACL.pre-fix-$(date +%Y%m%d-%H%M%S)"
cp -a "$ACL" "$BAK" || die "Backup failed. No changes made."
echo "Backup: $BAK"
OWN="$(stat -c '%U:%G' "$ACL")"; MOD="$(stat -c '%a' "$ACL")"
install -o "${OWN%%:*}" -g "${OWN##*:}" -m "$MOD" "$TMPD/fixed.acl" "$ACL" || { cp -a "$BAK" "$ACL"; die "Writing $ACL failed - original restored."; }
echo "Wrote $ACL ($(wc -l < "$ACL") users, $OWN, $MOD)."

if is_up; then
  show_status
  green "SUCCESS: ACL file fixed. $SVC is RUNNING (it was already up and was not restarted)."
  exit 0
fi

if [[ -n "${HPID:-}" ]] && kill -0 "$HPID" 2>/dev/null; then
  show_status
  red "ACL file fixed, but port $PORT is still held by PID $HPID - stop it, then: systemctl reset-failed $SVC && systemctl start $SVC"
  exit 1
fi

echo "Starting $SVC ..."
systemctl reset-failed "$SVC" 2>/dev/null
systemctl start "$SVC" 2>&1 | tail -n 3
for _ in $(seq 1 15); do is_up && break; sleep 1; done

echo
if is_up; then
  command -v monit >/dev/null && monit monitor redis >/dev/null 2>&1
  echo "Original ACL kept at $BAK"
  show_status
  green "SUCCESS: $SVC is RUNNING (redis-cli ping: $(ping_redis))."
  exit 0
fi

red "FAILED: $SVC is still not running. Newest log lines:" >&2
grep -vE 'overcommit|oO0Oo|Supervised|Configuration loaded|monotonic' "$LOG" 2>/dev/null | tail -n 5 | cut -c1-300 >&2
echo "To restore the original ACL: install -o ${OWN%%:*} -g ${OWN##*:} -m $MOD $BAK $ACL" >&2
show_status; exit 1
