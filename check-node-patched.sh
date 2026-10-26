#!/usr/bin/env bash
# check-node-patched.sh
# Read-only check: is Node.js on this server (installed + running) on a patched
# version per the October 2026 Node.js security releases?
#
# Patched: 22.23.4 / 24.22.1 / 26.12.1 (official NVM builds)
#          20.20.2-14 / 18.20.8-26 / 14.21.3-35 (TuxCare ELTS)
#
# Must be run as platformops:  sudo -u platformops bash check-node-patched.sh
# Exit codes: 0 = nothing running vulnerable, 1 = vulnerable process found, 2 = wrong user

set -u

if [ "$(id -un)" != "platformops" ]; then
  echo "ERROR: run this as the platformops user:  sudo -u platformops bash $0" >&2
  exit 2
fi

SUDO=""
if [ "$(id -u)" -ne 0 ] && sudo -n true 2>/dev/null; then SUDO="sudo -n"; fi

declare -A MIN=( [22]=22.23.4 [24]=24.22.1 [26]=26.12.1 )
declare -A ELTS=( [20]=20.20.2 [18]=18.20.8 [14]=14.21.3 )
declare -A ELTS_BUILD=( [20]=14 [18]=26 [14]=35 )

ver_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]; }  # $1 >= $2

# Prints: PATCHED | VULNERABLE | VERIFY-ELTS | UNKNOWN
classify() {
  local v="${1#v}" major
  v="${v%%-*}"; major="${v%%.*}"
  if [ -n "${MIN[$major]:-}" ]; then
    ver_ge "$v" "${MIN[$major]}" && echo PATCHED || echo VULNERABLE
  elif [ -n "${ELTS[$major]:-}" ]; then
    # node -v cannot show the TuxCare build number (-14/-26/-35), so base >= is only "needs check"
    ver_ge "$v" "${ELTS[$major]}" && echo VERIFY-ELTS || echo VULNERABLE
  elif [ "$major" -gt 26 ] 2>/dev/null; then
    echo UNKNOWN
  else
    echo VULNERABLE   # EOL / unpatched line (25.x, 23.x, <14, ...)
  fi
}

echo "== Host: $(hostname) | $(date -u +%FT%TZ) | run as: $(id -un) =="
echo
echo "-- Installed Node versions (nvm) --"
printf '%-10s %-14s %s\n' STATUS VERSION PATH
nvm_dirs=$($SUDO find /home /usr/local /opt -maxdepth 2 \( -name .nvm -o -name nvm \) -type d 2>/dev/null)
found=0
for d in $nvm_dirs; do
  for n in "$d"/versions/node/*/bin/node; do
    [ -e "$n" ] || continue
    found=1
    v=$(basename "$(dirname "$(dirname "$n")")")
    printf '%-10s %-14s %s\n' "$(classify "$v")" "$v" "$n"
  done
done
[ "$found" -eq 0 ] && echo "(none found under nvm)"
sys=$(command -v node 2>/dev/null) && printf '%-10s %-14s %s (PATH default)\n' "$(classify "$($sys -v)")" "$($sys -v)" "$sys"

echo
echo "-- Running Node processes --"
printf '%-10s %-12s %-8s %-9s %s\n' STATUS USER PID VERSION CMD
bad=0; any=0
for pid in $(pgrep -x node 2>/dev/null) $(pgrep -f 'PM2.*God Daemon' 2>/dev/null); do
  exe=$($SUDO readlink "/proc/$pid/exe" 2>/dev/null) || continue
  [ -n "$exe" ] || continue
  any=1
  v=$($SUDO "$exe" -v 2>/dev/null); [ -n "$v" ] || v="?"
  st=$(classify "$v")
  [ "$st" = VULNERABLE ] && bad=1
  usr=$(ps -o user= -p "$pid" 2>/dev/null)
  cmd=$(ps -o args= -p "$pid" 2>/dev/null | cut -c1-70)
  printf '%-10s %-12s %-8s %-9s %s\n' "$st" "$usr" "$pid" "$v" "$cmd"
done
[ "$any" -eq 0 ] && echo "(no running node processes)"

echo
echo "Legend: PATCHED ok | VULNERABLE switch (nvm use <patched>) + restart | VERIFY-ELTS 20/18/14 line: node -v hides the TuxCare build, confirm ELTS build 20.20.2-14 / 18.20.8-26 / 14.21.3-35 manually | UNKNOWN newer than known list"
[ "$bad" -eq 1 ] && { echo "RESULT: VULNERABLE Node process(es) running"; exit 1; }
echo "RESULT: no vulnerable running Node process detected"
exit 0
