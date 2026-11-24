#!/usr/bin/env bash
#
# varnish-vcl-fix.sh
# Fixes Varnish failing to start ("VCL compilation failed") when the cause is
# in an APP's custom VCL, never in the core Cloudways VCL:
#   - deleted/half-deleted app: an include points to
#     /home/<server>/<app>/conf/custom-recv.vcl (or -resp) that no longer
#     exists ("Cannot read file ... No such file or directory")
#     -> creates the missing file empty (exactly what a fresh app has)
#   - Windows backslashes in a URL regex, e.g. "\wp-content\themes\x.js"
#     ("a numbered reference must not be zero" and friends) -> "/" instead
#   - unbalanced brackets in a regex ("missing )") -> closing ")" added
#   - any other error inside an app's custom-*.vcl -> that line is commented
#     out ("# DISABLED by varnish-vcl-fix ..."); if one file keeps failing,
#     the whole file is commented out
# How: /etc/varnish and every app conf/custom-*.vcl are copied to a temp
# sandbox, compiled there with varnishd -C (same -f/-p options as the
# service) and fixed one error at a time until the VCL compiles. Only then are
# the changed APP files written back (originals backed up first) and the real
# VCL compiled once more. Files under /etc/varnish are NEVER written. Errors
# in core files are reported, not touched.
# Finally starts varnish if it was down and shows the status.
#
# Usage (as root):
#   bash varnish-vcl-fix.sh            # check, show planned changes, confirm, fix
#   bash varnish-vcl-fix.sh --check    # check only - runs the whole fix in the sandbox, changes nothing
#   bash varnish-vcl-fix.sh --yes      # fix without the confirmation prompt
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
command -v varnishd >/dev/null || die "varnishd not found."
command -v perl >/dev/null || die "perl not found."

confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  local ok; read -r -p "$1 [y/N]: " ok </dev/tty || return 1
  [[ "$ok" =~ ^[Yy]$ ]]
}

SVC=varnish
TS="$(date '+%F %H:%M')"
APP_RE='^/home/[^/]+/[^/]+/conf/custom-[a-z]+\.vcl$'   # the only files this script may write
MAX_ROUNDS=40
SEP=$'\x1f'                                  # field separator for the action list

show_status() {
  hr
  echo "== Varnish status"
  systemctl status "$SVC" --no-pager 2>&1 | sed -n '1,4p'
  printf 'listening : %s\n' "$(ss -ltnp 2>/dev/null | awk '/varnishd/{print $4}' | sort -u | tr '\n' ' ')"
  command -v monit >/dev/null && printf 'monit     : %s\n' "$(monit summary 2>/dev/null | grep -iE '^\s*varnish\b' | sed 's/^ *//')"
  hr
  if systemctl is-active --quiet "$SVC"; then green "VARNISH STATUS: RUNNING"; else red "VARNISH STATUS: NOT RUNNING"; fi
}

# --- Same VCL file and -p options as the service ----------------------------------
EXEC="$(systemctl show -p ExecStart --value "$SVC" 2>/dev/null | grep -oP 'argv\[\]=\K[^;]*' | head -n1)"
[[ -n "$EXEC" ]] || EXEC="$(systemctl cat "$SVC" 2>/dev/null | grep -oP '^ExecStart=\K.*varnishd.*' | tail -n1)"
read -r -a ARGV <<<"$EXEC"
VCL=""; PARAMS=()
for ((i=0; i<${#ARGV[@]}; i++)); do
  case "${ARGV[i]}" in
    -f) VCL="${ARGV[i+1]}" ;;
    -p) [[ "${ARGV[i+1]}" == vcl_path=* ]] || PARAMS+=(-p "${ARGV[i+1]}") ;;
  esac
done
VCL="${VCL:-/etc/varnish/default.vcl}"
[[ -f "$VCL" ]] || die "VCL file $VCL (from the service ExecStart) does not exist."

TMP="$(mktemp -d /tmp/varnish-vcl-fix.XXXXXX)" || die "mktemp failed."
trap 'rm -rf "$TMP"' EXIT
SB="$TMP/root"          # sandbox root: $SB/etc/varnish/..., $SB/home/...

compile() {  # compile <vcl> <vcl_path>; prints compiler errors, returns its status
  varnishd -C -n "$TMP/work" -f "$1" -p vcl_path="$2" "${PARAMS[@]}" 2>&1 >/dev/null
}
real() { sed "s#$SB##g"; }   # map sandbox paths back to real ones

echo "== Check: $(hostname)"
echo "Varnish   : $(varnishd -V 2>&1 | grep -oP 'varnish-\S+' | head -n1) ($(systemctl is-active "$SVC" 2>/dev/null))"
echo "Main VCL  : $VCL"

ERR="$(compile "$VCL" /etc/varnish)"
if [[ $? -eq 0 ]]; then
  green "RESULT: the VCL compiles cleanly - no VCL problem to fix."
  if ! systemctl is-active --quiet "$SVC"; then
    red "$SVC is down for another reason. Last log lines:"
    journalctl -u "$SVC" -n 8 -o cat --no-pager 2>/dev/null | cut -c1-220
  fi
  show_status; exit 0
fi

red "RESULT: VARNISH VCL ISSUE FOUND - VCL compilation fails:"
grep -vE '^\s*$|^Error:$|^Running VCC-compiler failed|^VCL compilation failed' <<<"$ERR" | head -n 8 | cut -c1-220 | while IFS= read -r l; do red "  $l"; done
echo

# --- Build the sandbox -----------------------------------------------------------------
mkdir -p "$SB/etc" "$TMP/work"
cp -a /etc/varnish "$SB/etc/" || die "Could not copy /etc/varnish to the sandbox."
shopt -s nullglob
for f in /home/*/*/conf/custom-*.vcl; do
  mkdir -p "$SB$(dirname "$f")"; cp -a "$f" "$SB$f"
done
shopt -u nullglob
# Point every absolute include into the sandbox.
find "$SB" -name '*.vcl' -type f -exec sed -i "s#include \"/#include \"$SB/#g" {} +
SBVCL="$SB$VCL"

# --- Fix loop, inside the sandbox only -----------------------------------------------
ACTIONS=(); CHANGED=(); NEWFILES=(); BLOCKER=""
declare -A TRIES
note_changed() { [[ " ${CHANGED[*]:-} " == *" $1 "* ]] || CHANGED+=("$1"); }

for ((round=1; round<=MAX_ROUNDS; round++)); do
  ERR="$(compile "$SBVCL" "$SB/etc/varnish")" && break
  RERR="$(real <<<"$ERR")"
  LOC="$(grep -oP "\('\K[^']+' Line [0-9]+ Pos [0-9]+(?=\))" <<<"$ERR" | head -n1)"
  LOCFILE="${LOC%%\'*}"; LOCLINE="$(grep -oP "Line \K[0-9]+" <<<"$LOC")"
  RLOCFILE="${LOCFILE#$SB}"

  # 1. Missing include file.
  MISSING="$(grep -oP "Cannot read file '\K[^']+" <<<"$ERR" | head -n1)"
  if [[ -n "$MISSING" ]]; then
    RM="${MISSING#$SB}"
    if [[ -f "$RM" && ! -e "$MISSING" ]]; then
      # Exists for real, just not copied into the sandbox yet (include outside the usual places).
      mkdir -p "$(dirname "$MISSING")"; cp -a "$RM" "$MISSING"
      sed -i "s#include \"/#include \"$SB/#g" "$MISSING"
      continue
    fi
    if [[ "$RM" =~ $APP_RE ]]; then
      mkdir -p "$(dirname "$MISSING")" && : > "$MISSING"
      NEWFILES+=("$RM"); note_changed "$RM"
      ACTIONS+=("CREATE empty $RM (included by ${RLOCFILE} line ${LOCLINE}; the app's conf/ file is missing - deleted or half-deleted app)")
      continue
    fi
    BLOCKER="missing file $RM is not an app custom VCL - not touching it."; break
  fi

  [[ -n "$LOCFILE" ]] || { BLOCKER="could not find the error location in the compiler output."; break; }
  if [[ ! "$RLOCFILE" =~ $APP_RE ]]; then
    BLOCKER="the error is in ${RLOCFILE} line ${LOCLINE} - a core VCL file; this script does not change core files."; break
  fi

  TRIES[$RLOCFILE]=$(( ${TRIES[$RLOCFILE]:-0} + 1 ))
  OLDLINE="$(sed -n "${LOCLINE}p" "$LOCFILE")"
  MSG="$(awk '/Message from VCC-compiler:/{f=1; next} f && /^\(/{exit} f && NF' <<<"$ERR" | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-160)"

  if (( TRIES[$RLOCFILE] > 4 )); then
    LN=0 TSX="$TS" perl -i -pe '$_="# DISABLED by varnish-vcl-fix $ENV{TSX}: $_" unless /^\s*#/' "$LOCFILE"
    note_changed "$RLOCFILE"
    ACTIONS+=("DISABLE whole file $RLOCFILE (it kept failing after 4 line fixes; all lines commented out)")
    continue
  fi

  FIXED=0
  if [[ "$MSG" == *"Regexp compilation error"* ]]; then
    # a) backslashes used as path separators: no "/" in the regex and 2+ "\letter".
    cp "$LOCFILE" "$TMP/before"
    LN="$LOCLINE" perl -i -pe 'if ($. == $ENV{LN}) { s{"([^"]*)"}{ my $r=$1; my $n=()=$r=~/\\[A-Za-z0-9_-]/g; if ($r !~ m{/} && $n >= 2) { $r =~ tr{\\}{/}; } "\"$r\"" }ge }' "$LOCFILE"
    if ! cmp -s "$TMP/before" "$LOCFILE"; then
      FIXED=1; note_changed "$RLOCFILE"
      ACTIONS+=("FIX backslashes -> '/' in $RLOCFILE line $LOCLINE${SEP}$OLDLINE${SEP}$(sed -n "${LOCLINE}p" "$LOCFILE")")
    elif [[ "$MSG" == *"missing )"* ]]; then
      # b) more "(" than ")" in a regex string: close them at the end.
      LN="$LOCLINE" perl -i -pe 'if ($. == $ENV{LN}) { s{"([^"]*)"}{ my $r=$1; my $o=()=$r=~/(?<!\\)\(/g; my $c=()=$r=~/(?<!\\)\)/g; $r .= ")" x ($o-$c) if $o > $c; "\"$r\"" }ge }' "$LOCFILE"
      if ! cmp -s "$TMP/before" "$LOCFILE"; then
        FIXED=1; note_changed "$RLOCFILE"
        ACTIONS+=("FIX unbalanced '(' in $RLOCFILE line $LOCLINE${SEP}$OLDLINE${SEP}$(sed -n "${LOCLINE}p" "$LOCFILE")")
      fi
    fi
  fi
  if (( ! FIXED )); then
    # c) anything else in an app file: comment that line out.
    if [[ "$OLDLINE" =~ ^[[:space:]]*# ]]; then
      BLOCKER="the error line $RLOCFILE:$LOCLINE is already a comment - cannot fix automatically."; break
    fi
    LN="$LOCLINE" TSX="$TS" perl -i -pe 'if ($. == $ENV{LN}) { $_ = "# DISABLED by varnish-vcl-fix $ENV{TSX}: $_" }' "$LOCFILE"
    note_changed "$RLOCFILE"
    ACTIONS+=("DISABLE line $LOCLINE of $RLOCFILE ($MSG)${SEP}$OLDLINE${SEP}$(sed -n "${LOCLINE}p" "$LOCFILE")")
  fi
done
(( round > MAX_ROUNDS )) && BLOCKER="still failing after $MAX_ROUNDS fixes - stopping."

# --- Report -------------------------------------------------------------------------
echo "== Planned changes (all inside app conf/ folders; /etc/varnish untouched)"
if (( ${#ACTIONS[@]} == 0 )); then echo "  (none)"; fi
for a in "${ACTIONS[@]}"; do
  IFS=$'\x1f' read -r what old new <<<"$a"
  echo "  - $what"
  [[ -n "$old" ]] && echo "      before: $(cut -c1-180 <<<"$old")"
  [[ -n "$new" ]] && echo "      after : $(real <<<"$new" | cut -c1-180)"
done
echo

if [[ -n "$BLOCKER" ]]; then
  red "CANNOT FIX AUTOMATICALLY: $BLOCKER"
  red "Compiler output:"
  real <<<"$ERR" | grep -vE '^\s*$' | head -n 10 | cut -c1-220 | while IFS= read -r l; do red "  $l"; done
  echo "No changes made."
  show_status; exit 2
fi
green "VERIFIED: with these changes the VCL compiles cleanly (tested in a sandbox copy)."
for f in "${NEWFILES[@]}"; do
  app="$(cut -d/ -f4 <<<"$f")"
  yellow "  Note: app '$app' has no conf/ folder - if the app was deleted, its include lines in /etc/varnish/additional_vcls/*.vcl"
  yellow "        can be commented out by hand later (#app-$app). The empty file keeps Varnish working until then."
done

if [[ $MODE == check ]]; then
  echo
  echo "Check only (--check) - no changes made."
  show_status; exit 0
fi

echo
confirm "Apply these changes to the app files?" || die "Aborted. No changes made."

# --- Apply: back up, write back app files only, recompile the real VCL -----------------------
BK="/root/varnish-vcl-fix-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BK" || die "Could not create backup dir $BK."
for f in "${CHANGED[@]}"; do
  [[ "$f" =~ $APP_RE ]] || die "Refusing to write non-app file $f."       # belt and braces
  if [[ -e "$f" ]]; then mkdir -p "$BK$(dirname "$f")"; cp -a "$f" "$BK$f"; fi
done
echo "Backups of changed files: $BK"

rollback() {
  for f in "${CHANGED[@]}"; do
    if [[ -e "$BK$f" ]]; then cp -a "$BK$f" "$f"; else rm -f "$f"; fi
  done
}
for f in "${CHANGED[@]}"; do
  mkdir -p "$(dirname "$f")"
  # Sandbox copies have rewritten include paths only in /etc/varnish copies, but be safe:
  sed "s#$SB/#/#g" "$SB$f" > "$f.vclfix.tmp" && mv "$f.vclfix.tmp" "$f"
  chown root:root "$f"; chmod 644 "$f"
  echo "  wrote $f"
done

ERR="$(compile "$VCL" /etc/varnish)"
if [[ $? -ne 0 ]]; then
  rollback
  red "The real VCL still fails to compile - all changes rolled back:"
  grep -vE '^\s*$' <<<"$ERR" | head -n 8 | cut -c1-220
  show_status; exit 1
fi
green "Real VCL compiles: OK"

if systemctl is-active --quiet "$SVC"; then
  yellow "$SVC is running; the fixed files are used at its next restart/reload (not restarted now)."
else
  echo "Starting $SVC ..."
  systemctl reset-failed "$SVC" 2>/dev/null
  systemctl start "$SVC" 2>&1 | tail -n 3
  sleep 2
fi
if systemctl is-active --quiet "$SVC"; then
  command -v monit >/dev/null && monit monitor varnish >/dev/null 2>&1
  show_status
  green "SUCCESS: Varnish is RUNNING. Restore any file from $BK if needed."
  exit 0
fi
show_status
red "Varnish still did not start (VCL is fine now). Last log lines:"
journalctl -u "$SVC" -n 10 -o cat --no-pager 2>/dev/null | cut -c1-220
exit 1
