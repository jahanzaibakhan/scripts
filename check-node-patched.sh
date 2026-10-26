#!/usr/bin/env bash
# check-node-patched.sh
# Read-only check: is Node.js on this server (installed, default, running) on a
# patched version per the October 2026 Node.js security releases?
#
# Patched: 22.23.4 / 24.22.1 / 26.12.1 (official NVM builds)
#          20.20.2-14 / 18.20.8-26 / 14.21.3-35 (TuxCare ELTS)
#
# Must be run as platformops:  sudo -u platformops bash check-node-patched.sh
# Exit codes: 0 = all good, 1 = vulnerable process running, 3 = unverified / vulnerable
#             installs only, 2 = wrong user. Set NO_COLOR=1 to disable colors.

set -u

if [ "$(id -un)" != "platformops" ]; then
  echo "ERROR: run this as the platformops user:  sudo -u platformops bash $0" >&2
  exit 2
fi

# ---------- colors ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] || [ -n "${FORCE_COLOR:-}" ]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; B=$'\033[1m'; D=$'\033[2m'; N=$'\033[0m'
else
  R=; G=; Y=; C=; B=; D=; N=
fi

SUDO=""
if [ "$(id -u)" -ne 0 ] && sudo -n true 2>/dev/null; then SUDO="sudo -n"; fi

min_for()       { case $1 in 22) echo 22.23.4;; 24) echo 24.22.1;; 26) echo 26.12.1;; esac; }
elts_for()      { case $1 in 20) echo 20.20.2;; 18) echo 18.20.8;; 14) echo 14.21.3;; esac; }
elts_full_for() { case $1 in 20) echo 20.20.2-14;; 18) echo 18.20.8-26;; 14) echo 14.21.3-35;; esac; }

ver_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]; }  # $1 >= $2

# Prints: PATCHED | VULNERABLE | VERIFY-ELTS | UNKNOWN
classify() {
  local v="${1#v}" major
  v="${v%%-*}"; major="${v%%.*}"
  if [ -n "$(min_for "$major")" ]; then
    ver_ge "$v" "$(min_for "$major")" && echo PATCHED || echo VULNERABLE
  elif [ -n "$(elts_for "$major")" ]; then
    # node -v cannot show the TuxCare build number (-14/-26/-35), so base >= is only "needs check"
    ver_ge "$v" "$(elts_for "$major")" && echo VERIFY-ELTS || echo VULNERABLE
  elif [ "$major" -gt 26 ] 2>/dev/null; then
    echo UNKNOWN
  else
    echo VULNERABLE   # EOL / unpatched line (25.x, 23.x, <14, ...)
  fi
}

# Fixed-width colored status badge
badge() {
  local col
  case "$1" in
    PATCHED) col=$G ;; VULNERABLE) col=$R ;; VERIFY-ELTS|UNKNOWN) col=$Y ;; *) col=$D ;;
  esac
  printf '%s%-11s%s' "$col" "$1" "$N"
}

rule() { printf '%s%s%s\n' "$D" "------------------------------------------------------------------------------" "$N"; }
head1() { echo; printf '%s%s%s\n' "$B$C" "$1" "$N"; rule; }

BAD_RUN=0; WARN=0
INST=""   # newline list of "major version" for every nvm install found

printf '%s%s%s\n' "$B" "Node.js patch check  |  host: $(hostname)  |  $(date -u +%FT%TZ)  |  user: $(id -un)" "$N"
[ -z "$SUDO" ] && [ "$(id -u)" -ne 0 ] && printf '%sNote: passwordless sudo not available - other users'"'"' files/processes may be hidden%s\n' "$Y" "$N"

# ---------- installed (nvm) ----------
head1 "1. Installed Node versions (nvm)"
printf '%s%-11s %-10s %s%s\n' "$B" STATUS VERSION PATH "$N"
nvm_dirs=$($SUDO find /home /usr/local /opt -maxdepth 2 \( -name .nvm -o -name nvm \) -type d 2>/dev/null)
found=0
for d in $nvm_dirs; do
  for n in "$d"/versions/node/*/bin/node; do
    [ -e "$n" ] || continue
    found=1
    v=$(basename "$(dirname "$(dirname "$n")")")
    printf '%s %-10s %s\n' "$(badge "$(classify "$v")")" "$v" "$n"
    m=${v#v}; m=${m%%.*}
    INST="$INST$m ${v#v}"$'\n'
  done
done
[ "$found" -eq 0 ] && printf '%s(no nvm installs found)%s\n' "$D" "$N"

# ---------- defaults ----------
head1 "2. Default Node (what a new shell / restart without 'nvm use' picks up)"
sys=$(command -v node 2>/dev/null)
if [ -n "$sys" ]; then
  sv=$($sys -v); st=$(classify "$sv")
  printf '%s %-10s %s %s(PATH default)%s\n' "$(badge "$st")" "$sv" "$sys" "$D" "$N"
  [ "$st" = VULNERABLE ] && WARN=1
fi
for d in $nvm_dirs; do
  a=$($SUDO cat "$d/alias/default" 2>/dev/null) || continue
  [ -n "$a" ] || continue
  # alias may be a major ("20"), "lts/*", or a full version; resolve to newest matching install
  res=$(ls -1 "$d/versions/node" 2>/dev/null | sed 's/^v//' | grep -E "^${a#v}(\.|$)" | sort -V | tail -n1)
  if [ -n "$res" ]; then
    st=$(classify "$res"); printf '%s %-10s %s %s(nvm alias default -> %s)%s\n' "$(badge "$st")" "v$res" "$d" "$D" "$a" "$N"
    [ "$st" = VULNERABLE ] && WARN=1
  else
    printf '%s %-10s %s %s(nvm alias default -> %s, unresolved)%s\n' "$(badge UNKNOWN)" "?" "$d" "$D" "$a" "$N"
  fi
done

# ---------- running ----------
head1 "3. Running Node processes (these are what the patch must actually reach)"
printf '%s%-11s %-12s %-8s %-10s %s%s\n' "$B" STATUS USER PID VERSION COMMAND "$N"
any=0
for pid in $(pgrep -x node 2>/dev/null) $(pgrep -f 'PM2.*God Daemon' 2>/dev/null); do
  exe=$($SUDO readlink "/proc/$pid/exe" 2>/dev/null) || continue
  [ -n "$exe" ] || continue
  any=1
  v=$($SUDO "$exe" -v 2>/dev/null); [ -n "$v" ] || v="?"
  st=$(classify "$v")
  [ "$st" = VULNERABLE ] && BAD_RUN=1
  usr=$(ps -o user= -p "$pid" 2>/dev/null)
  cmd=$(ps -o args= -p "$pid" 2>/dev/null | cut -c1-60)
  printf '%s %-12s %-8s %-10s %s\n' "$(badge "$st")" "$usr" "$pid" "$v" "$cmd"
done
if [ "$any" -eq 0 ]; then
  printf '%sNo node processes visible to %s.%s\n' "$Y" "$(id -un)" "$N"
  if grep -q 'hidepid=[12]' /proc/mounts 2>/dev/null && [ -z "$SUDO" ]; then
    printf '%s/proc is mounted with hidepid and no sudo: other users'"'"' processes are hidden, so this does NOT prove nothing is running.%s\n' "$Y" "$N"
  else
    printf '%sEither no Node app is running, or it runs under another user - check with: ps aux | grep -i [n]ode ; pm2 ls (as the app user)%s\n' "$D" "$N"
  fi
  WARN=1
fi

# ---------- patched availability ----------
head1 "4. Is a patched build installed? (per major line found above)"
printf '%s%-7s %-22s %-14s %s%s\n' "$B" LINE REQUIRED "BEST INSTALLED" RESULT "$N"
majors=$(printf '%s' "$INST" | awk 'NF{print $1}' | sort -un)
for m in $majors; do
  best=$(printf '%s' "$INST" | awk -v m="$m" '$1==m{print $2}' | sort -V | tail -n1)
  if [ -n "$(min_for "$m")" ]; then
    req=$(min_for "$m")
    if ver_ge "$best" "$req"; then res="${G}OK - patched build present${N}"; else res="${R}MISSING - install ${req}${N}"; WARN=1; fi
  elif [ -n "$(elts_for "$m")" ]; then
    req="$(elts_full_for "$m") (ELTS)"
    if ver_ge "$best" "$(elts_for "$m")"; then res="${Y}base ok - confirm ELTS build${N}"; else res="${R}MISSING - needs TuxCare ELTS $(elts_full_for "$m")${N}"; WARN=1; fi
  else
    req="EOL - no patch"; res="${R}UNPATCHED LINE - move to 22/24/26${N}"; WARN=1
  fi
  printf '%-7s %-22s %-14s %s\n' "${m}.x" "$req" "v${best}" "$res"
done
[ -z "$majors" ] && printf '%s(nothing to evaluate)%s\n' "$D" "$N"

# ---------- verdict ----------
echo; rule
if [ "$BAD_RUN" -eq 1 ]; then
  printf '%s%s VERDICT: VULNERABLE - a running Node process uses an unpatched version.%s\n' "$B" "$R" "$N"
  printf '  Fix: nvm use <patched-version> ; pm2 restart all --interpreter <patched-version> ; pm2 save\n'
  rc=1
elif [ "$WARN" -eq 1 ]; then
  printf '%s%s VERDICT: NOT VERIFIED PATCHED - no vulnerable process was seen, but see warnings above%s\n' "$B" "$Y" "$N"
  printf '  (no visible running processes, and/or vulnerable/missing versions are installed or set as default)\n'
  rc=3
else
  printf '%s%s VERDICT: PATCHED - all running and default Node versions are patched.%s\n' "$B" "$G" "$N"
  rc=0
fi
printf '%sNote: for 20/18/14 (TuxCare ELTS) node -v hides the build number; confirm 20.20.2-14 / 18.20.8-26 / 14.21.3-35 separately.%s\n' "$D" "$N"
rule
exit "$rc"
