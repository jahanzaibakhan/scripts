#!/usr/bin/env bash
#
# inode-check.sh
# Checks inode and disk usage on / and, when inodes are above the threshold,
# finds the directories holding them, offers to clear the safe ones (caches,
# tmp, sessions) and shows the result.
#
# Why: when inodes hit 100% a server hangs even though disk space looks fine
# (no new files can be created: sessions, temp files, logs, sockets). DO
# recovery / fsck only frees a few and it fills up again. Typical cause is a
# cache plugin (e.g. WordPress Breeze) creating millions of empty cache dirs.
#
# How it finds them: huge directories are big themselves (a directory with
# millions of entries is hundreds of MB), so `find -type d -size +8M` spots
# them without counting every file. Then it ranks apps by inode count.
#
# Only paths that look like cache/tmp/sessions are offered for clearing.
# Anything else (uploads, plugins, mail, backups) is shown for manual review
# and never touched. Say "n" at the prompt to get the manual commands.
#
# Usage (as root):
#   bash inode-check.sh                    # report, suggest, ask y/N
#   bash inode-check.sh --check            # report only, no changes
#   bash inode-check.sh --yes              # clear safe candidates, no prompt
#   bash inode-check.sh --threshold 70     # act above 70% (default 85)
#   bash inode-check.sh --force            # run the hunt even if below threshold
#   curl -fsSL <raw-url> | sudo bash -s -- [option]

set -uo pipefail

THRESHOLD=85
BIG_DIR_SIZE="+8M"
FIND_TIMEOUT=600
CHECK_ONLY=0
ASSUME_YES=0
FORCE=0
FS="/"
# paths we consider safe to empty (contents only; the directory itself stays)
SAFE_RE='(/wp-content/cache(/|$)|/wp-content/breeze-minification|/\.tmb(/|$)|/tmp(/|$)|/var/cache(/|$)|/var/lib/php/sessions(/|$)|/sessions(/|$))'

if [[ -t 1 ]]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; B=$'\e[1m'; N=$'\e[0m'
else
  R=""; G=""; Y=""; C=""; B=""; N=""
fi

say()  { printf '%s\n' "$*"; }
hdr()  { printf '\n%s== %s ==%s\n' "$B$C" "$*" "$N"; }
warn() { printf '%s%s%s\n' "$Y" "$*" "$N"; }
die()  { printf '%s%s%s\n' "$R" "$*" "$N" >&2; exit 1; }

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK_ONLY=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --force) FORCE=1 ;;
    --threshold) shift; THRESHOLD="${1:-}"; [[ "$THRESHOLD" =~ ^[0-9]+$ ]] || die "--threshold needs a number" ;;
    -h|--help) usage ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
  shift
done

[[ "$(uname -s)" == "Linux" ]] || die "Linux only."
[[ $EUID -eq 0 ]] || die "Run as root (sudo bash $0)."

ipct()  { df -P -i "$FS" | awk 'NR==2{gsub("%","",$5); print $5+0}'; }
iused() { df -P -i "$FS" | awk 'NR==2{print $3}'; }
ifree() { df -P -i "$FS" | awk 'NR==2{print $4}'; }
dpct()  { df -P "$FS" | awk 'NR==2{gsub("%","",$5); print $5+0}'; }

colorpct() {  # colorpct <pct>
  local p=$1 c=$G
  (( p >= THRESHOLD )) && c=$Y
  (( p >= 97 )) && c=$R
  printf '%s%s%%%s' "$B$c" "$p" "$N"
}

show_usage() {
  say "Inodes : $(colorpct "$(ipct)")  used $(iused)  free ${B}$(ifree)${N}"
  say "Disk   : $(colorpct "$(dpct)")  $(df -Ph "$FS" | awk 'NR==2{print $3" of "$2" used, "$4" free"}')"
}

hdr "Usage on $FS"
show_usage
START_PCT=$(ipct)

if (( START_PCT < THRESHOLD )) && (( FORCE == 0 )); then
  say
  say "${G}Inodes are below ${THRESHOLD}% - nothing to do.${N} (use --force to run the hunt anyway)"
  exit 0
fi

(( START_PCT >= THRESHOLD )) && warn $'\nInodes are at '"${START_PCT}%"$' (threshold '"${THRESHOLD}"$'%).'

# ---- 1. huge directories ---------------------------------------------------
hdr "Hunting huge directories (dir size > ${BIG_DIR_SIZE#+}, can take a few minutes)"
say "Low I/O priority, ${FIND_TIMEOUT}s limit..."
BIG=$(ionice -c3 nice -n19 timeout "$FIND_TIMEOUT" \
  find /home /var /tmp /root /opt -xdev -type d -size "$BIG_DIR_SIZE" -printf '%s\t%p\n' 2>/dev/null \
  | sort -rn | head -15)

SAFE=(); OTHER=()
if [[ -n "$BIG" ]]; then
  say
  printf '%s%-12s %-9s %s%s\n' "$B" "DIR SIZE" "ACTION" "PATH" "$N"
  while IFS=$'\t' read -r sz path; do
    [[ -z "$path" ]] && continue
    human=$(numfmt --to=iec "$sz" 2>/dev/null || echo "${sz}B")
    if [[ "$path" =~ $SAFE_RE ]]; then
      SAFE+=("$path")
      printf '%-12s %s%-9s%s %s\n' "$human" "$G" "clearable" "$N" "$path"
    else
      OTHER+=("$path")
      printf '%-12s %s%-9s%s %s\n' "$human" "$Y" "review" "$N" "$path"
    fi
  done <<< "$BIG"
else
  say "${Y}No directory over ${BIG_DIR_SIZE#+} found.${N} The inodes are spread across many normal directories."
fi

# ---- 2. apps ranked by inode count ----------------------------------------
hdr "Top apps by inode count"
APPROOT=$(ls -d /home/*.cloudwaysapps.com 2>/dev/null | head -1)
if [[ -n "$APPROOT" ]]; then
  for a in $(ls "$APPROOT" | grep -E '^[a-z]{10}$'); do
    n=$(ionice -c3 timeout 60 du -x --inodes -s "$APPROOT/$a" 2>/dev/null | cut -f1)
    printf '%s\t%s\n' "${n:-0}" "$a"
  done | sort -rn | head -8 | while IFS=$'\t' read -r n a; do
    printf '%s%12s%s  %s\n' "$B" "$n" "$N" "$APPROOT/$a"
  done
  say "(an app that never finishes counts as 0 here - check the huge directories above)"
else
  say "No /home/*.cloudwaysapps.com layout found, skipping app ranking."
fi

# ---- 3. act ----------------------------------------------------------------
manual_cmds() {
  hdr "Manual commands"
  say "Re-check usage:"
  say "  ${B}df -i / && df -h /${N}"
  if (( ${#SAFE[@]} > 0 )); then
    say
    say "Empty a cache directory gently (low I/O priority, keeps the directory):"
    say "  ${B}sudo mkdir -p /root/empty${N}"
    for p in "${SAFE[@]}"; do
      say "  ${B}sudo ionice -c3 nice -n19 rsync -a --delete /root/empty/ '$p/'${N}"
    done
    say "  ${B}sudo rmdir /root/empty${N}"
    say "Do not use plain 'rm -rf' on millions of entries - it is slow and stalls the disk."
  fi
  if (( ${#OTHER[@]} > 0 )); then
    say
    say "Review these before deleting (not touched by this script):"
    for p in "${OTHER[@]}"; do say "  ${Y}$p${N}"; done
    say "  count entries: ${B}sudo ls -f <dir> | wc -l${N}"
  fi
  say
  say "Find hogs yourself:"
  say "  ${B}sudo find /home -xdev -type d -size +8M -printf '%s %p\\n' | sort -rn | head${N}"
  say "  ${B}sudo ionice -c3 du -x --inodes -d1 /home/*.cloudwaysapps.com | sort -rn | head${N}"
  say "Then stop whatever is creating them (cache plugin, bots hitting random URLs) or it comes back."
}

if (( ${#SAFE[@]} == 0 )); then
  hdr "Result"
  warn "Nothing safe to clear automatically."
  manual_cmds
  exit 0
fi

if (( CHECK_ONLY )); then
  hdr "Check only - no changes made"
  manual_cmds
  exit 0
fi

hdr "Suggested clean-up"
say "These contents would be ${B}deleted${N} (the directories themselves are kept):"
for p in "${SAFE[@]}"; do say "  ${R}$p${N}"; done
say
say "Cache contents are rebuilt by the site on demand. Do it off-peak: it is heavy on disk I/O."

ans="n"
if (( ASSUME_YES )); then
  ans="y"
else
  printf '%sClear them now? [y/N]: %s' "$B" "$N"
  read -r ans < /dev/tty 2>/dev/null || ans="n"
fi

if [[ ! "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]; then
  say "${Y}Skipped - nothing was changed.${N}"
  manual_cmds
  exit 0
fi

EMPTY=$(mktemp -d)
trap 'rmdir "$EMPTY" 2>/dev/null' EXIT
for p in "${SAFE[@]}"; do
  [[ -d "$p" && ! -L "$p" ]] || { warn "skip (not a plain directory): $p"; continue; }
  say "Clearing ${B}$p${N} ..."
  if command -v rsync >/dev/null 2>&1; then
    ionice -c3 nice -n19 rsync -a --delete "$EMPTY"/ "$p"/
  else
    ionice -c3 nice -n19 find "$p" -mindepth 1 -delete
  fi
  if [[ $? -eq 0 ]]; then say "  ${G}done${N}"; else warn "  finished with errors"; fi
done
sync

hdr "Result"
say "Before:"; say "  Inodes ${B}${START_PCT}%${N}"
say "After:"; show_usage | sed 's/^/  /'
END_PCT=$(ipct)
if (( END_PCT < THRESHOLD )); then
  say; say "${G}Inodes are back under ${THRESHOLD}%.${N}"
else
  say; warn "Still above ${THRESHOLD}% - the rest is in the 'review' paths or the app ranking above."
  manual_cmds
fi
say
say "Find out what created them (cache plugin, bot traffic) or this will fill up again."
