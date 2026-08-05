#!/usr/bin/env bash
#
# Service outage / upgrade verification checker
# Usage: curl -s https://raw.githubusercontent.com/<you>/opsgenie/main/backup.ini6.sh | bash
#
# Prompts for a service name, runs a battery of checks (apt/dpkg state,
# systemd status, logs, OOM signatures, port/health checks), prints a
# colorized PASS/FAIL report, and writes JSON + TXT reports to
# /var/cw/systeam/deplog/

set -uo pipefail

# ---------- colors ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# ---------- input (works even when this script is piped via curl|bash) ----------
if [ -t 0 ]; then
  read -rp "Enter service name to check (e.g. memcached, redis-server, imunify360, opensearch): " SERVICE
else
  read -rp "Enter service name to check (e.g. memcached, redis-server, imunify360, opensearch): " SERVICE < /dev/tty
fi

if [ -z "${SERVICE:-}" ]; then
  echo -e "${RED}No service name provided. Exiting.${NC}"
  exit 1
fi

TS="$(date '+%Y-%m-%d_%H-%M-%S')"
REPORT_DIR="/var/cw/systeam/deplog"
JSON_FILE="${REPORT_DIR}/${SERVICE}_${TS}.json"
TXT_FILE="${REPORT_DIR}/${SERVICE}_${TS}.txt"

mkdir -p "$REPORT_DIR" 2>/dev/null
if [ ! -w "$REPORT_DIR" ]; then
  echo -e "${YELLOW}Warning: no write permission on ${REPORT_DIR}, re-run with sudo to save reports.${NC}"
fi

# ---------- helpers ----------
declare -a CHECK_NAMES=()
declare -a CHECK_STATUS=()
declare -a CHECK_DETAIL=()

DPKG_LOCK_WAIT_SECS=60   # how long to wait for a busy dpkg/apt lock before giving up

# Returns 0 (locked) with holder info on stdout, or 1 (free) with nothing.
dpkg_lock_holder() {
  local holder=""
  holder="$(sudo fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock 2>/dev/null | awk '{print $NF}' | head -1)"
  if [ -z "$holder" ]; then
    return 1
  fi
  local pid="${holder//[!0-9]/}"
  local cmd=""
  if [ -n "$pid" ]; then
    cmd="$(ps -o cmd= -p "$pid" 2>/dev/null)"
  fi
  echo "PID ${pid} (${cmd:-unknown process})"
  return 0
}

# Waits up to DPKG_LOCK_WAIT_SECS for the dpkg lock to free.
# Echoes final holder info (empty if it freed up) and returns 0 if free, 1 if still busy.
wait_for_dpkg_unlock() {
  local waited=0 holder=""
  while [ "$waited" -lt "$DPKG_LOCK_WAIT_SECS" ]; do
    holder="$(dpkg_lock_holder)"
    if [ -z "$holder" ]; then
      return 0
    fi
    sleep 3
    waited=$((waited+3))
  done
  echo "$holder"
  return 1
}

run_check() {
  local name="$1" cmd="$2"
  local out status_word color
  out="$(eval "$cmd" 2>&1)"
  local rc=$?
  if [ $rc -eq 0 ] && [ -n "$out" ]; then
    status_word="PASS"; color="$GREEN"
  elif [ $rc -eq 0 ] && [ -z "$out" ]; then
    status_word="PASS"; color="$GREEN"
    out="(no output — clean)"
  else
    status_word="FAIL"; color="$RED"
  fi
  CHECK_NAMES+=("$name")
  CHECK_STATUS+=("$status_word")
  CHECK_DETAIL+=("$out")

  echo -e "${BOLD}== ${name} ==${NC}"
  echo -e "${color}[${status_word}]${NC}"
  echo "$out" | sed 's/^/  /'
  echo ""
}

# Like run_check, but for dpkg/apt commands that fail purely because the
# lock is held by an in-progress upgrade. Waits briefly, and if the lock is
# still busy after the wait, reports BUSY (yellow) instead of FAIL, naming
# the process/package holding it — so an active upgrade isn't mistaken for
# a broken package.
run_apt_check() {
  local name="$1" cmd="$2"
  local holder out status_word color

  holder="$(dpkg_lock_holder || true)"
  if [ -n "$holder" ]; then
    echo -e "${YELLOW}dpkg/apt lock currently held by ${holder} — waiting up to ${DPKG_LOCK_WAIT_SECS}s...${NC}"
    if wait_for_dpkg_unlock >/tmp/.dpkg_wait_result 2>&1; then
      holder=""
    else
      holder="$(cat /tmp/.dpkg_wait_result)"
      rm -f /tmp/.dpkg_wait_result
    fi
  fi

  if [ -n "$holder" ]; then
    status_word="BUSY"; color="$YELLOW"
    out="An update/upgrade is currently running and holds the dpkg lock: ${holder}. This check was skipped — it is NOT a broken-package failure, just an in-progress deployment. Re-run once the upgrade finishes."
  else
    out="$(eval "$cmd" 2>&1)"
    local rc=$?
    if [ $rc -eq 0 ] && [ -n "$out" ]; then
      status_word="PASS"; color="$GREEN"
    elif [ $rc -eq 0 ] && [ -z "$out" ]; then
      status_word="PASS"; color="$GREEN"
      out="(no output — clean)"
    else
      status_word="FAIL"; color="$RED"
    fi
  fi

  CHECK_NAMES+=("$name")
  CHECK_STATUS+=("$status_word")
  CHECK_DETAIL+=("$out")

  echo -e "${BOLD}== ${name} ==${NC}"
  echo -e "${color}[${status_word}]${NC}"
  echo "$out" | sed 's/^/  /'
  echo ""
}

echo -e "${BOLD}Starting checks for service: ${SERVICE}${NC}"
echo -e "Timestamp: ${TS}"
echo "-----------------------------------------------------"

# ---------- 1. systemd status ----------
run_check "systemd status" "systemctl status '$SERVICE' --no-pager -l"

# ---------- 2. journal logs (last 200 lines) ----------
run_check "journalctl (last 200 lines)" "journalctl -u '$SERVICE' --no-pager -n 200"

# ---------- 3. reboot / uptime ----------
run_check "last reboot" "last -x reboot | head -5"
run_check "uptime / load" "uptime"

# ---------- 4. memory / OOM signatures ----------
run_check "memory (free -h)" "free -h"
run_check "OOM kill signatures (dmesg)" "dmesg -T 2>/dev/null | grep -iE 'oom|killed process' | tail -50 || true"

# ---------- 5. dpkg / apt package state ----------
run_apt_check "dpkg audit (broken packages)" "dpkg --audit"
run_apt_check "apt-get check (dependency issues)" "apt-get check"
run_apt_check "package version/status" "dpkg -s '$SERVICE' 2>/dev/null | grep -E 'Status|Version' || dpkg -l | grep -i '$SERVICE'"

# ---------- 6. recent apt upgrade history for this package ----------
run_check "apt history for package" "grep -i '$SERVICE' /var/log/apt/history.log | tail -20"

# ---------- 7. pending reboot required ----------
run_check "pending reboot required" "[ -f /var/run/reboot-required ] && cat /var/run/reboot-required || echo 'no pending reboot'"

# ---------- 8. ansible / orchestration trace ----------
run_check "ansible activity in syslog" "grep -i ansible /var/log/syslog 2>/dev/null | tail -30 || echo 'no ansible entries found'"

# ---------- 9. service-specific health check ----------
case "$SERVICE" in
  memcached)
    run_check "memcached port health (11211)" "echo stats | timeout 2 nc 127.0.0.1 11211 | head -20"
    ;;
  redis-server|redis)
    run_check "redis ping" "redis-cli ping"
    run_check "redis persistence status" "redis-cli info persistence | grep -E 'rdb_last_bgsave_status|aof_last_bgrewrite_status'"
    ;;
  opensearch)
    run_check "opensearch cluster health" "curl -s -k http://localhost:9200/_cluster/health?pretty"
    run_check "opensearch nodes" "curl -s -k http://localhost:9200/_cat/nodes?v"
    ;;
  imunify360|imunify-antivirus|imunify)
    run_check "imunify agent log tail" "tail -100 /var/log/imunify360/imunify360-agent.log 2>/dev/null || echo 'log not found'"
    ;;
  *)
    run_check "generic port/process check" "ps aux | grep -i '$SERVICE' | grep -v grep"
    ;;
esac

echo "-----------------------------------------------------"
echo -e "${BOLD}Summary${NC}"

FAIL_COUNT=0
BUSY_COUNT=0
for i in "${!CHECK_NAMES[@]}"; do
  case "${CHECK_STATUS[$i]}" in
    FAIL)
      echo -e "  ${RED}[FAIL]${NC} ${CHECK_NAMES[$i]}"
      FAIL_COUNT=$((FAIL_COUNT+1))
      ;;
    BUSY)
      echo -e "  ${YELLOW}[BUSY]${NC} ${CHECK_NAMES[$i]} (upgrade in progress)"
      BUSY_COUNT=$((BUSY_COUNT+1))
      ;;
    *)
      echo -e "  ${GREEN}[PASS]${NC} ${CHECK_NAMES[$i]}"
      ;;
  esac
done

if [ "$FAIL_COUNT" -eq 0 ] && [ "$BUSY_COUNT" -eq 0 ]; then
  echo -e "\n${GREEN}${BOLD}Overall: HEALTHY — no broken/failed checks detected.${NC}"
elif [ "$FAIL_COUNT" -eq 0 ]; then
  echo -e "\n${YELLOW}${BOLD}Overall: HEALTHY, but ${BUSY_COUNT} check(s) skipped — an update/upgrade is currently running (dpkg lock busy). Re-run once it finishes for a full result.${NC}"
else
  echo -e "\n${RED}${BOLD}Overall: ${FAIL_COUNT} check(s) FAILED (plus ${BUSY_COUNT} skipped due to an in-progress upgrade) — review above for root cause.${NC}"
fi

# ---------- write TXT report ----------
{
  echo "Service Verification Report"
  echo "Service: ${SERVICE}"
  echo "Timestamp: ${TS}"
  echo "======================================================="
  for i in "${!CHECK_NAMES[@]}"; do
    echo ""
    echo "== ${CHECK_NAMES[$i]} =="
    echo "STATUS: ${CHECK_STATUS[$i]}"
    echo "${CHECK_DETAIL[$i]}"
  done
  echo ""
  echo "======================================================="
  echo "Total failed checks: ${FAIL_COUNT}"
  echo "Total busy/skipped checks (upgrade in progress): ${BUSY_COUNT}"
} > "$TXT_FILE" 2>/dev/null

# ---------- write JSON report ----------
json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null <<< "$1" || \
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "%s\\n", $0}' | sed '1s/^/"/; $s/$/"/'
}

{
  echo "{"
  echo "  \"service\": \"${SERVICE}\","
  echo "  \"timestamp\": \"${TS}\","
  echo "  \"failed_count\": ${FAIL_COUNT},"
  echo "  \"busy_count\": ${BUSY_COUNT},"
  echo "  \"checks\": ["
  for i in "${!CHECK_NAMES[@]}"; do
    name_json=$(json_escape "${CHECK_NAMES[$i]}")
    detail_json=$(json_escape "${CHECK_DETAIL[$i]}")
    sep=","
    if [ "$i" -eq $((${#CHECK_NAMES[@]}-1)) ]; then sep=""; fi
    echo "    {\"name\": ${name_json}, \"status\": \"${CHECK_STATUS[$i]}\", \"detail\": ${detail_json}}${sep}"
  done
  echo "  ]"
  echo "}"
} > "$JSON_FILE" 2>/dev/null

echo ""
echo -e "${BOLD}Reports saved:${NC}"
echo "  TXT : ${TXT_FILE}"
echo "  JSON: ${JSON_FILE}"
