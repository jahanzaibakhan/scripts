#!/usr/bin/env bash
#
# imunify-resident-ram.sh
# Lowers the memory limit of the Imunify resident malware scanner
# (aibolit-resident.service -> rustbolit --resident) from 2G to 1G.
#
# The limit is hardcoded as --memory=2G in the ai-bolit package's
# /opt/ai-bolit/aibolit-resident-launcher.sh; the MALWARE_SCAN_INTENSITY
# resident_ram config key is not read by it, so `imunify360-agent config
# update` cannot change it. This script copies the launcher to /etc with
# --memory=1G and points the unit at the copy through a systemd drop-in,
# so ai-bolit package updates do not undo it. Every run regenerates the
# copy from the current packaged launcher and reports if it has drifted.
#
# If the scanner does not come back up with the new limit, the drop-in is
# removed and the original launcher restored automatically.
#
# Usage (as root):
#   bash imunify-resident-ram.sh            # report, confirm, apply 1G
#   bash imunify-resident-ram.sh --check    # report only, no changes
#   bash imunify-resident-ram.sh --yes      # apply without prompting
#   bash imunify-resident-ram.sh --revert   # back to the packaged 2G
#   curl -fsSL <raw-url> | sudo bash -s -- [option]

set -uo pipefail

NEW_MEM="1G"
UNIT="aibolit-resident.service"
SOCKET="aibolit-resident.socket"
LAUNCHER="/opt/ai-bolit/aibolit-resident-launcher.sh"
OVR_DIR="/etc/imunify-resident-ram"
OVR_LAUNCHER="$OVR_DIR/aibolit-resident-launcher.sh"
OVR_SRC_SUM="$OVR_DIR/source.sha256"
DROPIN_DIR="/etc/systemd/system/$UNIT.d"
DROPIN="$DROPIN_DIR/50-resident-ram.conf"
WAIT_SECS=45

if [[ -t 1 ]]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'
else
  R=""; G=""; Y=""; B=""; N=""
fi
die()  { echo "${R}ERROR:${N} $*" >&2; exit 1; }
info() { echo "${B}==${N} $*"; }
ok()   { echo "${G}OK:${N} $*"; }
warn() { echo "${Y}WARN:${N} $*"; }

# Green when the limit is the target, red when it is anything else,
# yellow when the scanner is not running.
mem_c() {
  if [[ -z "$1" ]]; then echo "${Y}n/a (not running)${N}"
  elif [[ "$1" == "$NEW_MEM" ]]; then echo "${G}$1${N}"
  else echo "${R}$1${N}"
  fi
}
state_c() { [[ "$1" == active ]] && echo "${G}$1${N}" || echo "${R}$1${N}"; }

MODE=apply
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --check|-c)  MODE=check ;;
    --revert|-r) MODE=revert ;;
    --yes|-y)    ASSUME_YES=1 ;;
    -h|--help)   sed -n '2,23p' "$0" 2>/dev/null; exit 0 ;;
    *) die "Unknown option: $arg (use --check, --yes, --revert or --help)" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Run this script as root."
command -v systemctl >/dev/null || die "systemctl not found."
systemctl cat "$UNIT" >/dev/null 2>&1 || die "$UNIT not found - is Imunify360/ImunifyAV installed?"
[[ -f "$LAUNCHER" ]] || die "$LAUNCHER not found - this Imunify version starts the resident scanner differently."

# --memory value of the running resident scanner, or empty if not running.
resident_mem() {
  local pid
  pid="$(systemctl show -p MainPID --value "$UNIT" 2>/dev/null)"
  [[ -n "$pid" && "$pid" != 0 && -r /proc/$pid/cmdline ]] || return 0
  tr '\0' '\n' < "/proc/$pid/cmdline" | sed -n 's/^--memory=//p' | head -n1
}

# Top Imunify / malware-scan processes by memory.
show_processes() {
  echo
  printf '%-8s %-6s %-9s %-12s %s\n' PID CPU% RSS_MB ELAPSED COMMAND
  ps -eo pid=,pcpu=,rss=,etime=,args= --sort=-rss \
    | awk '$5 !~ /(^|\/)(awk|mawk|gawk|grep)$/ && !/imunify-resident-ram/ && /imunify|rustbolit|ai-bolit|aibolit|im360|imav|defence360/ {
        cmd=$5; for (i=6; i<=NF; i++) cmd=cmd" "$i
        printf "%-8s %-6s %-9.0f %-12s %.90s\n", $1, $2, $3/1024, $4, cmd
      }' \
    | head -n 3
  echo
}

report() {
  info "Host: $(hostname)  |  $(uptime | sed 's/.*load average/load average/')"
  free -m | awk 'NR==1{print "   " $0} /^Mem|^Swap/{print "   " $0}'
  info "Top 3 Imunify / scan processes (by memory):"
  show_processes
  local cur state
  cur="$(resident_mem)"
  state="$(systemctl is-active "$UNIT" 2>/dev/null)"
  echo "Resident scanner ($UNIT): $(state_c "$state")"
  echo "Current --memory limit           : $(mem_c "$cur")"
  echo "Packaged launcher limit          : $(grep -m1 -o -- '^--memory=[^ ]*' "$LAUNCHER" | cut -d= -f2)"
  if [[ -f "$DROPIN" ]]; then
    echo "Override drop-in                 : ${G}present${N} ($DROPIN)"
    if [[ -f "$OVR_SRC_SUM" ]] && ! sha256sum --quiet -c "$OVR_SRC_SUM" >/dev/null 2>&1; then
      warn "the packaged launcher changed since the override was made (ai-bolit update); re-run this script to regenerate it."
    fi
  else
    echo "Override drop-in                 : ${Y}none${N}"
  fi
  if [[ "$state" != active ]]; then
    warn "$UNIT is not running - real-time malware scanning is off."
  fi
  echo
}

# Wait until the unit is active with the expected --memory value.
wait_for() {
  local want="$1" i cur
  for ((i = 0; i < WAIT_SECS; i++)); do
    if systemctl is-active --quiet "$UNIT"; then
      cur="$(resident_mem)"
      [[ "$cur" == "$want" ]] && return 0
    fi
    sleep 1
  done
  return 1
}

restart_resident() {
  systemctl daemon-reload
  systemctl start "$SOCKET" 2>/dev/null || true
  systemctl reset-failed "$UNIT" 2>/dev/null || true
  systemctl restart "$UNIT"
}

remove_override() {
  rm -f "$DROPIN"
  rmdir "$DROPIN_DIR" 2>/dev/null || true
  rm -rf "$OVR_DIR"
}

verify_hint() {
  echo
  info "Verify manually:"
  cat <<'EOF'
  tr '\0' ' ' < /proc/$(systemctl show -p MainPID --value aibolit-resident.service)/cmdline | grep -o -- '--memory=[^ ]*'
  systemctl is-active aibolit-resident.service aibolit-resident.socket
  systemctl cat aibolit-resident.service | grep '^ExecStart'
EOF
}

report

if [[ "$MODE" == check ]]; then
  echo "Check only - no changes made."
  verify_hint
  exit 0
fi

PKG_MEM="$(grep -m1 -o -- '^--memory=[^ ]*' "$LAUNCHER" | cut -d= -f2)"

if [[ "$MODE" == revert ]]; then
  [[ -f "$DROPIN" ]] || { echo "No override installed - nothing to revert."; exit 0; }
  info "Removing override and restarting $UNIT ..."
  remove_override
  restart_resident
  if wait_for "$PKG_MEM"; then
    ok "resident scanner running with packaged --memory=$PKG_MEM"
  else
    die "$UNIT did not come back with --memory=$PKG_MEM. Check: journalctl -u $UNIT -n 30"
  fi
  show_processes
  verify_hint
  exit 0
fi

# Apply.
[[ "$(grep -c -- '^--memory=' "$LAUNCHER")" -eq 1 ]] \
  || die "Expected exactly one --memory= line in $LAUNCHER; its layout changed. Not touching it."

if [[ -f "$DROPIN" && "$(resident_mem)" == "$NEW_MEM" ]] \
   && sha256sum --quiet -c "$OVR_SRC_SUM" >/dev/null 2>&1; then
  ok "already applied - resident scanner is running with --memory=$NEW_MEM."
  verify_hint
  exit 0
fi

if [[ $ASSUME_YES -ne 1 ]]; then
  # Read from the terminal so the prompt works under `curl | bash`.
  [[ -r /dev/tty ]] || die "No terminal to prompt on; re-run with --yes to apply non-interactively."
  read -r -p "Reduce Imunify resident scanner RAM limit to 1024MB (--memory=$NEW_MEM)? [y/N] " ans < /dev/tty
  [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]] || { echo "Aborted - no changes made."; exit 0; }
fi

info "Writing $OVR_LAUNCHER ..."
mkdir -p "$OVR_DIR" "$DROPIN_DIR" || die "Could not create $OVR_DIR or $DROPIN_DIR."
TMP="$(mktemp "$OVR_DIR/.launcher.XXXXXX")" || die "mktemp failed."
sed "s/^--memory=[^ ]*\$/--memory=$NEW_MEM/" "$LAUNCHER" > "$TMP" \
  && [[ "$(grep -c -- "^--memory=$NEW_MEM\$" "$TMP")" -eq 1 ]] \
  && sh -n "$TMP" \
  || { rm -f "$TMP"; die "Generated launcher failed validation; nothing changed."; }
chmod 0750 "$TMP"
mv -f "$TMP" "$OVR_LAUNCHER"
sha256sum "$LAUNCHER" > "$OVR_SRC_SUM"

info "Writing $DROPIN ..."
cat > "$DROPIN" <<EOF
# Managed by imunify-resident-ram.sh - remove with: imunify-resident-ram.sh --revert
# Runs a copy of $LAUNCHER with --memory=$NEW_MEM.
[Service]
ExecStart=
ExecStart=$OVR_LAUNCHER
EOF

info "Restarting $UNIT (waiting up to ${WAIT_SECS}s) ..."
restart_resident
if wait_for "$NEW_MEM"; then
  ok "resident scanner running with --memory=$NEW_MEM"
else
  warn "$UNIT did not come up with --memory=$NEW_MEM - rolling back to the packaged launcher."
  journalctl -u "$UNIT" -n 10 --no-pager 2>/dev/null | sed 's/^/   /'
  remove_override
  restart_resident
  if wait_for "$PKG_MEM"; then
    die "Rolled back; resident scanner is running again with --memory=$PKG_MEM."
  fi
  die "Rollback done but $UNIT is not running. Start it: systemctl start $SOCKET $UNIT"
fi

info "After:"
show_processes
echo "Resident scanner ($UNIT): $(state_c "$(systemctl is-active "$UNIT")")"
echo "Socket ($SOCKET)        : $(state_c "$(systemctl is-active "$SOCKET")")"
echo "New --memory limit      : $(mem_c "$(resident_mem)")"
verify_hint
