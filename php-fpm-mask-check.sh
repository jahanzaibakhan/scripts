#!/usr/bin/env bash
#
# php-fpm-mask-check.sh
# Read-only check, run from the jump server, for PHP-FPM services that were
# masked by automation (Oct 2026). Two known causes:
#
#  PATCH_RACE   patching_php.sh (PHP vulnerability patch) read the server as
#               single PHP at start, the multi-app PHP migration then started
#               the server PHP (cloudways.conf pool, usually 8.2) and set
#               multi_app_php=yes, and the patch masked that version at the
#               end from its stale snapshot.
#  UPGRADE      the PHP version upgrade playbook masked the old PHP and
#               enabled the new one before its pools existed, then failed
#               (e.g. at the newrelic reinstall) with no rollback.
#  APP_POOL_MISSING  an app's vhost points at an FPM socket with no pool
#               behind it (site returns 502), e.g. re-running a per-app PHP
#               change to the version it already had deletes its own pool.
#
# A version counts as "in use" if, on multi-app PHP servers, its pool.d has
# cloudways.conf (server PHP: Adminer, Imunify360 UI) or app pools; on single
# PHP servers, if it is the php= version in packages.fact. Nothing on the
# servers is changed.
#
# Usage:
#   bash php-fpm-mask-check.sh [options] IP [IP...]
#   bash php-fpm-mask-check.sh -f ips.txt
#   curl -fsSL <raw-url> | bash -s -- [options] IP [IP...]
#   curl -fsSL <raw-url> | sudo bash -s -- -l     # on the server itself
#
# Options:
#   -l        check this server (run as root), no SSH
#   -f FILE   read IPs from FILE (one per line, # comments allowed)
#   -u USER   SSH user (default: systeam)
#   -j N      servers checked in parallel (default: 8)
#   -s SINCE  journal window, journalctl --since syntax (default: "7 days ago")
#   -t SEC    SSH connect timeout (default: 10)
#   -a        print details for every server (default: affected/warn only)
#   -q        summary table only
#   -h        help
#
# Exit code: 0 all OK, 1 at least one server affected/warn, 2 usage/SSH errors.

set -uo pipefail

# ---------------------------------------------------------------------------
# Runs on each target server (sent over SSH with declare -f). Must be
# self-contained. Output lines:
#   H|hostname|uptime-since|multi_app_php|php fact|app versions
#   P|start|multi_php|running before|apt result|finish rc
#   V|ver|role|apps|enabled|active|masked since|patch mask|migration start|
#     ansible mask|first masked err|last masked err|manual unmask|status|cause
#   M|monit line
#   E|text   (error)
# ---------------------------------------------------------------------------
remote_check() {
  local since="$1"
  local fact_dir=/etc/ansible/facts.d plog=/var/log/patching_php.log
  local j run ver d role apps en ac link patch_mask pm_multi mig ans ferr lerr unmask status cause mon mon_only
  local mafact phpfact appv p_start p_multi p_before p_apt p_rc

  ts() { cut -c1-19 | tr 'T' ' '; }

  mafact=$(grep -h '^multi_app_php=' "$fact_dir/server_settings.fact" 2>/dev/null | cut -d= -f2)
  phpfact=$(grep -h '^php=' "$fact_dir/packages.fact" 2>/dev/null | cut -d= -f2)
  appv=$(sed -n '/^\[app_php_version\]/,/^\[/p' "$fact_dir/applications.fact" 2>/dev/null \
         | grep -v '^\[' | cut -d= -f2 | sort | uniq -c | awk '{printf "%s%sx%s", (NR>1?" ":""), $1, $2}')
  echo "H|$(hostname)|$(uptime -s 2>/dev/null)|${mafact:-no}|${phpfact:-?}|${appv:-none}"

  # Last patching_php.sh run only.
  if [ -r "$plog" ]; then
    run=$(awk '/patching_php.sh started/{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}' "$plog")
    p_start=$(printf '%s' "$run" | grep -m1 'started =====' | cut -c1-19)
    p_multi=$(printf '%s' "$run" | grep -m1 -o 'multi_php=[a-z]*' | cut -d= -f2)
    p_before=$(printf '%s' "$run" | grep -o 'Running before: php[0-9.]*' | sed 's/Running before: php//' | paste -sd, -)
    # Here-strings, not pipes: grep -q exits early and pipefail (local mode) would fail the test.
    if grep -q 'apt-get install completed' <<< "$run"; then p_apt=ok
    elif grep -q 'apt-get install failed' <<< "$run"; then
      p_apt="failed($(printf '%s' "$run" | grep -o 'apt-get install failed (rc=[0-9]*' | grep -o '[0-9]*$'))"
    else p_apt=unknown; fi
    p_rc=$(printf '%s' "$run" | grep -o 'finished rc=[0-9]*' | tail -1 | cut -d= -f2)
    echo "P|$p_start|${p_multi:-?}|${p_before:-none}|$p_apt|${p_rc:-running?}"
  else
    echo "P|||||not-run"
  fi

  j=$(journalctl --since "$since" --no-pager -o short-iso 2>/dev/null \
      | grep -E 'php[0-9]+\.[0-9]+-fpm|php-fpm[0-9]|patching_php|multi_php_migrate_hosts|reinstall newrelic|fpm/pool\.d/')

  for d in /etc/php/*/fpm; do
    [ -d "$d" ] || continue
    ver=$(basename "$(dirname "$d")")
    en=$(systemctl is-enabled "php$ver-fpm" 2>/dev/null); en=${en:-none}
    ac=$(systemctl is-active "php$ver-fpm" 2>/dev/null); ac=${ac:-none}
    apps=$(find "$d/pool.d" -maxdepth 1 -name '*.conf' ! -name cloudways.conf ! -name placeholder.conf ! -name www.conf 2>/dev/null | wc -l)
    if [ "${mafact:-}" = yes ]; then
      if [ -f "$d/pool.d/cloudways.conf" ]; then role=server; elif [ "$apps" -gt 0 ]; then role=apps; else role=unused; fi
      [ "$role" = server ] && [ "$apps" -gt 0 ] && role=server+apps
    else
      # Single PHP keeps pool files in every version dir; only the php= fact is live.
      if [ "$ver" = "${phpfact:-}" ]; then role=single; else role=unused; fi
    fi

    link=""
    [ "$(readlink "/etc/systemd/system/php$ver-fpm.service" 2>/dev/null)" = /dev/null ] && \
      link=$(stat -c '%y' "/etc/systemd/system/php$ver-fpm.service" 2>/dev/null | cut -c1-19)
    # Any patch run (not just the last) that masked this version, and that run's multi_php.
    IFS='|' read -r patch_mask pm_multi < <(awk -v u="Stopped and masked php$ver-fpm.service" '
      /patching_php.sh started/ {m = ""}
      match($0, /multi_php=[a-z]+/) {m = substr($0, RSTART + 10, RLENGTH - 10)}
      index($0, u) {t = substr($0, 1, 19); mm = m}
      END {print t "|" mm}' "$plog" 2>/dev/null)
    mig=$(printf '%s\n' "$j" | grep -E "name=php$ver-fpm masked=False" | tail -1 | ts)
    ans=$(printf '%s\n' "$j" | grep -E "_raw_params=systemctl mask php$ver-fpm |name=php$ver-fpm masked=True" | tail -1 | ts)
    ferr=$(printf '%s\n' "$j" | grep "Unit php$ver-fpm.service is masked" | head -1 | ts)
    lerr=$(printf '%s\n' "$j" | grep "Unit php$ver-fpm.service is masked" | tail -1 | ts)
    unmask=$(printf '%s\n' "$j" | grep -E "COMMAND=.*systemctl unmask php$ver-fpm" | tail -1 | ts)
    # Journal may be rotated; monit.log keeps the outage window (shown, not used for status).
    if [ -z "$ferr" ]; then
      mon="fpm${ver//./}"; [ "$role" = single ] && mon=fpm
      ferr=$(zcat -f /var/log/monit.log.1 /var/log/monit.log 2>/dev/null | grep "'$mon' process is not running" | head -1 | cut -c2-20 | tr 'T' ' ')
      lerr=$(zcat -f /var/log/monit.log.1 /var/log/monit.log 2>/dev/null | grep "'$mon' process is not running" | tail -1 | cut -c2-20 | tr 'T' ' ')
      [ -n "$ferr" ] && ferr="monit:$ferr"
      mon_only=1
    else
      mon_only=0
    fi

    status=ok; cause=-
    if [ "$role" = unused ]; then
      # A version with no pools should not be enabled: it fails to start.
      if [ "$en" = enabled ] && [ "$ac" != active ]; then status=warn; cause=ENABLED_NO_POOLS; fi
    else
      if [ "$en" = masked ]; then status=masked
      elif [ "$ac" != active ]; then status=down
      elif [ -n "$patch_mask" ] || [ -n "$ans" ] || { [ -n "$ferr" ] && [ "$mon_only" = 0 ]; }; then status=recovered; fi
      if [ "$status" != ok ]; then
        if [ -n "$patch_mask" ] && { [ "${pm_multi:-}" = false ] && [ "${mafact:-}" = yes ] || [[ -n "$mig" && "$mig" < "$patch_mask" ]]; }; then
          cause=PATCH_RACE
        elif [ -n "$ans" ]; then cause=UPGRADE
        elif [ -n "$patch_mask" ]; then cause=PATCH
        elif [ "$status" = down ]; then cause=NOT_RUNNING
        else cause=UNKNOWN; fi
      fi
    fi
    echo "V|$ver|$role|$apps|$en|$ac|$link|$patch_mask|$mig|$ans|$ferr|$lerr|$unmask|$status|$cause"
  done

  # Apps whose vhost points at an FPM socket that does not exist (site returns 502).
  local f app sock pv perr pdel
  for f in /etc/nginx/sites-available/*; do
    [ -f "$f" ] || continue
    app=$(basename "$f")
    sock=$(grep -m1 -oE '/var/run/fpm-[A-Za-z0-9_.-]+\.sock' "$f")
    [ -n "$sock" ] && [ ! -S "$sock" ] || continue
    pv=$(grep -h "^$app=" "$fact_dir/applications.fact" 2>/dev/null | cut -d= -f2)
    perr=$(grep -h "${sock##*/} failed" /home/*/"$app"/logs/*error*.log /var/log/nginx/error.log 2>/dev/null | cut -c1-19 | sort | head -1)
    pdel=$(printf '%s\n' "$j" | grep -E "path=/etc/php/[0-9.]+/fpm/pool.d/$app-[0-9]+\.conf state=absent" | tail -1 | ts)
    echo "A|$app|$sock|${pv:-?}|$perr|$pdel"
  done

  # Upgrade-playbook fingerprints (retries of the failing step).
  local nr; nr=$(printf '%s\n' "$j" | grep -c 'reinstall newrelic')
  [ "$nr" -gt 0 ] && echo "U|newrelic reinstall attempts: $nr"
  monit summary -B 2>/dev/null | grep -iE ' fpm' | sed 's/^ */M|/; s/  */ /g'
}

# ---------------------------------------------------------------------------
# Jump-server side
# ---------------------------------------------------------------------------
die() { echo "ERROR: $*" >&2; exit 2; }
usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}" 2>/dev/null; }

USER_SSH=systeam; JOBS=8; SINCE="7 days ago"; TIMEOUT=10; ALL=0; VERBOSE=0; QUIET=0; LOCAL=0
IPS=()
while getopts ":f:u:j:s:t:aqlh" opt; do
  case "$opt" in
    l) LOCAL=1 ;;
    f) [ -r "$OPTARG" ] || die "Cannot read $OPTARG"
       while read -r l; do l=${l%%#*}; l=${l//[[:space:]]/}; [ -n "$l" ] && IPS+=("$l"); done < "$OPTARG" ;;
    u) USER_SSH=$OPTARG ;;
    j) JOBS=$OPTARG ;;
    s) SINCE=$OPTARG ;;
    t) TIMEOUT=$OPTARG ;;
    a) ALL=1; VERBOSE=1 ;;
    q) QUIET=1 ;;
    h) usage; exit 0 ;;
    :) die "-$OPTARG needs a value" ;;
    *) die "Unknown option -$OPTARG (see -h)" ;;
  esac
done
shift $((OPTIND - 1))
# Accept IPs separated by spaces, commas or newlines.
for a in "$@"; do for ip in ${a//,/ }; do IPS+=("$ip"); done; done
if [ "$LOCAL" = 1 ]; then
  [ "$EUID" -eq 0 ] || die "Local mode (-l) must run as root: sudo bash $0 -l"
  IPS=(localhost); ALL=1
fi
[ "${#IPS[@]}" -gt 0 ] || { usage; die "No IPs given."; }

if [ -t 1 ]; then R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'; else R=; G=; Y=; B=; N=; fi

SSH_BIN=${SSH_BIN:-ssh}
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout="$TIMEOUT" -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR)
TMP=$(mktemp -d) || die "mktemp failed"
trap 'rm -rf "$TMP"' EXIT
PAYLOAD="$(declare -f remote_check); remote_check $(printf '%q' "$SINCE")"

check_one() {
  local ip=$1
  printf '%s\n' "$PAYLOAD" | "$SSH_BIN" "${SSH_OPTS[@]}" "$USER_SSH@$ip" \
    'if sudo -n true 2>/dev/null; then sudo -n bash -s; else echo "E|no passwordless sudo, results limited"; bash -s; fi' \
    > "$TMP/$ip.out" 2> "$TMP/$ip.err"
  echo $? > "$TMP/$ip.rc"
}

if [ "$LOCAL" = 1 ]; then
  echo "${B}Checking this server, journal since \"$SINCE\"...${N}" >&2
  remote_check "$SINCE" > "$TMP/localhost.out" 2> "$TMP/localhost.err"
  echo 0 > "$TMP/localhost.rc"
else
  echo "${B}Checking ${#IPS[@]} server(s) as $USER_SSH, $JOBS in parallel, journal since \"$SINCE\"...${N}" >&2
  for ip in "${IPS[@]}"; do
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n 2>/dev/null || sleep 0.2; done
    check_one "$ip" &
  done
  wait
fi

# Overall per-server result: the worst version status wins.
rank() { case "$1" in masked) echo 5;; down) echo 4;; recovered) echo 3;; warn) echo 2;; ok) echo 1;; *) echo 0;; esac; }
colour() { case "$1" in MASKED|DOWN|SSH_FAIL) echo "$R";; RECOVERED|WARN) echo "$Y";; OK) echo "$G";; *) echo "";; esac; }

EXIT=0
SUMMARY=()
DETAILS=""
for ip in "${IPS[@]}"; do
  out="$TMP/$ip.out"; rc=$(cat "$TMP/$ip.rc" 2>/dev/null || echo 255)
  if [ "$rc" != 0 ] || ! grep -q '^H|' "$out" 2>/dev/null; then
    err=$(tr '\n' ' ' < "$TMP/$ip.err" 2>/dev/null | cut -c1-70)
    SUMMARY+=("$ip|?|SSH_FAIL|-|-|-|${err:-ssh exit $rc}")
    EXIT=2; continue
  fi
  IFS='|' read -r _ host up mafact phpfact appv < <(grep -m1 '^H|' "$out")
  IFS='|' read -r _ p_start p_multi p_before p_apt p_rc < <(grep -m1 '^P|' "$out")

  worst=ok; wver=-; wcause=-; wnow=-; wwhen=-
  while IFS='|' read -r _ ver role apps en ac link pm mig ans ferr lerr unm st cause; do
    if [ "$(rank "$st")" -gt "$(rank "$worst")" ]; then
      worst=$st; wver=$ver; wcause=$cause; wnow="$en/$ac"
      wwhen=${pm:-${ans:-${ferr:--}}}
    fi
  done < <(grep '^V|' "$out")
  while IFS='|' read -r _ app sock pv perr pdel; do
    if [ "$(rank down)" -gt "$(rank "$worst")" ]; then
      worst=down; wver=$pv; wcause=APP_POOL_MISSING; wnow="app $app"; wwhen=${pdel:-${perr:--}}
    fi
  done < <(grep '^A|' "$out")
  verdict=$(echo "$worst" | tr '[:lower:]' '[:upper:]')
  [ "$worst" != ok ] && [ "$EXIT" -lt 1 ] && EXIT=1
  SUMMARY+=("$ip|${host%%.*}|$verdict|$wcause|$wver|$wnow|$wwhen")

  [ "$QUIET" = 1 ] && continue
  [ "$ALL" = 1 ] || [ "$worst" != ok ] || continue
  DETAILS+=$'\n'"${B}== $ip ($host)  $(colour "$verdict")$verdict${N}${B}  cause: $wcause${N}"$'\n'
  DETAILS+="  Facts      : multi_app_php=$mafact, server php=$phpfact, apps: $appv, up since $up"$'\n'
  if [ "$p_rc" = not-run ]; then
    DETAILS+="  Patch      : patching_php.sh has not run (no /var/log/patching_php.log)"$'\n'
  else
    DETAILS+="  Patch      : started $p_start, multi_php=$p_multi, running before=$p_before, apt=$p_apt, finished rc=$p_rc"$'\n'
  fi
  DETAILS+="  Versions   :"$'\n'
  while IFS='|' read -r _ ver role apps en ac link pm mig ans ferr lerr unm st cause; do
    [ "$role" = unused ] && [ "$st" = ok ] && [ "$VERBOSE" = 0 ] && continue
    line="    php$ver  $(printf '%-12s' "$role") apps=$apps  $en/$ac  -> $st"
    [ "$cause" != - ] && line+=" ($cause)"
    DETAILS+="$line"$'\n'
    [ -n "$mig" ]  && DETAILS+="        started by migration/playbook : $mig"$'\n'
    [ -n "$pm" ]   && DETAILS+="        masked by patching_php.sh      : $pm"$'\n'
    [ -n "$ans" ]  && DETAILS+="        masked by Ansible task         : $ans"$'\n'
    [ -n "$link" ] && DETAILS+="        mask symlink created           : $link"$'\n'
    if [[ "$ferr" == monit:* ]]; then
      [ "$st" != ok ] && DETAILS+="        monit 'not running' (monit.log): ${ferr#monit:} -> $lerr"$'\n'
    elif [ -n "$ferr" ]; then
      DETAILS+="        'is masked' errors             : $ferr -> $lerr"$'\n'
    fi
    [ -n "$unm" ]  && DETAILS+="        manual unmask                  : $unm"$'\n'
  done < <(grep '^V|' "$out")
  while IFS='|' read -r _ app sock pv perr pdel; do
    DETAILS+="  ${R}App down${N}   : $app (php $pv) vhost uses $sock, which does not exist (no pool)"$'\n'
    [ -n "$pdel" ] && DETAILS+="        pool deleted by Ansible task   : $pdel"$'\n'
    [ -n "$perr" ] && DETAILS+="        first nginx 'failed' error     : $perr"$'\n'
    DETAILS+="        fix: recreate /etc/php/$pv/fpm/pool.d/$app-${pv//./}.conf (or set the app's PHP version again in the platform), then reload php$pv-fpm"$'\n'
  done < <(grep '^A|' "$out")
  while IFS='|' read -r _ msg; do DETAILS+="  Upgrade    : $msg"$'\n'; done < <(grep '^U|' "$out")
  while IFS='|' read -r _ msg; do DETAILS+="  Monit      : $msg"$'\n'; done < <(grep '^M|' "$out")
  while IFS='|' read -r _ msg; do DETAILS+="  ${R}Error${N}      : $msg"$'\n'; done < <(grep '^E|' "$out")
  case "$worst/$wcause" in
    */APP_POOL_MISSING) ;;
    masked/*|down/*)
      DETAILS+="  ${B}Fix${N}        : systemctl unmask php$wver-fpm && systemctl enable --now php$wver-fpm && monit monitor fpm${wver//./}"$'\n' ;;
  esac
  if grep -q '^V|[^|]*|unused|.*|warn|ENABLED_NO_POOLS' "$out"; then
    v=$(grep '^V|[^|]*|unused|.*|warn|ENABLED_NO_POOLS' "$out" | cut -d'|' -f2 | head -1)
    DETAILS+="  ${B}Cleanup${N}    : systemctl disable --now php$v-fpm && systemctl mask php$v-fpm"$'\n'
  fi
done

[ -n "$DETAILS" ] && printf '%s' "$DETAILS"
echo
printf "${B}%-16s %-9s %-10s %-17s %-5s %-17s %s${N}\n" IP HOST RESULT CAUSE PHP NOW "MASKED/EVENT AT"
for row in "${SUMMARY[@]}"; do
  IFS='|' read -r ip host verdict cause ver now when <<< "$row"
  printf "%-16s %-9s %s%-10s%s %-17s %-5s %-17s %s\n" "$ip" "$host" "$(colour "$verdict")" "$verdict" "$N" "$cause" "$ver" "$now" "$when"
done
echo
echo "RESULT: MASKED/DOWN = in-use PHP not running now | RECOVERED = was masked, running now | WARN = enabled PHP with no pools | OK"
exit "$EXIT"
