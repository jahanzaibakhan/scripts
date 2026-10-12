#!/usr/bin/env bash
#
# nginx-ip-allowlist.sh
# Adds (or removes) an IP allowlist (allow ...; deny all;) in a Cloudways
# app's nginx vhost. Prompts for the app name, edits
# /etc/nginx/sites-available/<app> (via the sites-enabled symlink), tests,
# reloads nginx and verifies the change.
#
# Usage (as root):
#   bash nginx-ip-allowlist.sh            # add the allowlist
#   bash nginx-ip-allowlist.sh --remove   # remove the allowlist
#   curl -fsSL <raw-url> | sudo bash -s -- [--remove]

set -uo pipefail

ENABLED_DIR="/etc/nginx/sites-enabled"
BACKUP_DIR="/var/cw/systeam"
ALLOW_IPS=(
  "143.198.206.48"
  "134.209.241.49"
  "144.126.255.60"
)

die() { echo "ERROR: $*" >&2; exit 1; }

ACTION=add
case "${1:-}" in
  "") ;;
  --remove|-r) ACTION=remove ;;
  -h|--help) sed -n '2,12p' "$0" 2>/dev/null; exit 0 ;;
  *) die "Unknown option: $1 (use --remove or no option)" ;;
esac

[[ $EUID -eq 0 ]] || die "Run this script as root."
command -v nginx >/dev/null || die "nginx not found."

# Read from the terminal so it also works when piped (curl | bash).
read -r -p "Enter app name (e.g. szgxfnspru): " APP </dev/tty
APP="${APP//[[:space:]]/}"
[[ "$APP" =~ ^[A-Za-z0-9_-]+$ ]] || die "Invalid app name."

LINK="$ENABLED_DIR/$APP"
[[ -e "$LINK" ]] || die "$LINK does not exist."
CONF="$(readlink -f "$LINK")"
[[ -f "$CONF" ]] || die "Could not resolve a config file for $APP."

echo
ls -l "$LINK"
echo "Config file: $CONF"
if [[ $ACTION == add ]]; then
  read -r -p "Add IP allowlist to this app? [y/N]: " OK </dev/tty
else
  read -r -p "REMOVE IP allowlist from this app? [y/N]: " OK </dev/tty
fi
[[ "$OK" =~ ^[Yy]$ ]] || die "Aborted."

has_rule() { grep -qE "^[[:space:]]*allow[[:space:]]+${ALLOW_IPS[0]//./\\.}[[:space:]]*;" "$CONF"; }

if [[ $ACTION == add ]] && has_rule; then
  echo "Allowlist already present in $CONF - nothing to do."
  exit 0
fi
if [[ $ACTION == remove ]] && ! has_rule; then
  echo "No allowlist found in $CONF - nothing to remove."
  exit 0
fi

[[ -d "$BACKUP_DIR" ]] || die "Backup directory $BACKUP_DIR does not exist."
BACKUP="$BACKUP_DIR/$APP.nginx.bak.$(date +%Y%m%d%H%M%S)"
cp -p "$CONF" "$BACKUP" || die "Backup failed."
echo "Backup: $BACKUP"

RULES="$(printf '%s\n' "${ALLOW_IPS[@]}")"
TMP="$(mktemp)"

if [[ $ACTION == add ]]; then
  # Insert the rules (preceded by a blank line) right after the app's
  # include ".../conf/server.nginx"; line. Fall back to just after
  # "server {" if that include isn't present.
  if grep -qE '^[[:space:]]*include[[:space:]]+"?[^;]*/conf/server\.nginx"?[[:space:]]*;' "$CONF"; then
    MODE=include
  else
    MODE=server
  fi
  MODE="$MODE" RULES="$RULES" awk '
    function emit(ind,   n, i, ips) {
      n = split(ENVIRON["RULES"], ips, "\n")
      for (i = 1; i <= n; i++) if (ips[i] != "") print ind "allow " ips[i] ";"
      print ind "deny all;"
      added++
    }
    { print }
    ENVIRON["MODE"] == "include" && /^[ \t]*include[ \t]+"?[^;]*\/conf\/server\.nginx"?[ \t]*;/ {
      match($0, /^[ \t]*/); print ""; emit(substr($0, 1, RLENGTH))
    }
    ENVIRON["MODE"] == "server" && /^[ \t]*server[ \t]*\{/ {
      match($0, /^[ \t]*/); emit(substr($0, 1, RLENGTH) "        ")
    }
    END { if (!added) exit 3 }
  ' "$CONF" >"$TMP"
else
  # Remove only our block: consecutive "allow <our IP>;" lines followed by
  # "deny all;", plus the blank line directly above it. Other allow/deny
  # rules in the file (e.g. inside location blocks) are left untouched.
  RULES="$RULES" awk '
    function norm(l) { gsub(/[ \t]+/, " ", l); sub(/^ /, "", l); sub(/ $/, "", l); sub(/ ;$/, ";", l); return l }
    function ours(l,   i) { l = norm(l); for (i = 1; i <= n; i++) if (ips[i] != "" && l == "allow " ips[i] ";") return 1; return 0 }
    BEGIN { n = split(ENVIRON["RULES"], ips, "\n") }
    {
      if (inblk) {
        if (ours($0)) { buf = buf $0 "\n"; next }
        if (norm($0) == "deny all;") { inblk = 0; buf = ""; held = ""; removed++; next }
        printf "%s%s", held, buf; held = ""; buf = ""; inblk = 0
      }
      if (ours($0)) { inblk = 1; buf = $0 "\n"; next }
      if ($0 ~ /^[ \t]*$/) { printf "%s", held; held = $0 "\n"; next }
      printf "%s", held; held = ""; print
    }
    END { printf "%s%s", held, buf; if (!removed) exit 3 }
  ' "$CONF" >"$TMP"
fi
rc=$?
if [[ $rc -ne 0 ]]; then
  rm -f "$TMP" "$BACKUP"
  if [[ $ACTION == add ]]; then
    die "No insertion point found in $CONF; nothing changed."
  else
    die "Allowlist block (allow ...; deny all;) not found as a group in $CONF; nothing changed."
  fi
fi
cat "$TMP" >"$CONF" && rm -f "$TMP"

rollback() {
  echo "Restoring backup..." >&2
  cp -p "$BACKUP" "$CONF"
}

if ! nginx -t; then
  rollback
  die "nginx -t failed; original config restored."
fi

systemctl reload nginx || { rollback; nginx -t && systemctl reload nginx; die "Reload failed; original config restored."; }

# Verify against the file and the config nginx actually loaded. nginx -T
# prints each file under a "# configuration file <path>:" header, using the
# path it was included by (the sites-enabled symlink), so accept either path.
loaded_conf() {
  nginx -T 2>/dev/null | awk -v a="# configuration file $LINK:" -v b="# configuration file $CONF:" '
    /^# configuration file / { on = ($0 == a || $0 == b); next } on'
}
LOADED="$(loaded_conf)"

echo
echo "Verification:"
FAIL=0
for ip in "${ALLOW_IPS[@]}"; do
  in_file=0; in_loaded=0
  grep -qF "allow $ip;" "$CONF" && in_file=1
  grep -qF "allow $ip;" <<<"$LOADED" && in_loaded=1
  if [[ $ACTION == add ]]; then
    if [[ $in_file -eq 1 && $in_loaded -eq 1 ]]; then echo "  [OK] allow $ip;"; else echo "  [MISSING] allow $ip;"; FAIL=1; fi
  else
    if [[ $in_file -eq 0 && $in_loaded -eq 0 ]]; then echo "  [REMOVED] allow $ip;"; else echo "  [STILL PRESENT] allow $ip;"; FAIL=1; fi
  fi
done

echo
echo "allow/deny lines now in $CONF:"
grep -nE '^\s*(allow|deny)\s' "$CONF" || echo "  (none)"
echo
if [[ $FAIL -eq 0 ]]; then
  if [[ $ACTION == add ]]; then
    echo "Done: $APP is now restricted to the allowed proxy IPs. (Backup: $BACKUP)"
  else
    echo "Done: allowlist removed from $APP. (Backup: $BACKUP)"
  fi
else
  echo "Change not fully confirmed - check $CONF (backup: $BACKUP)." >&2
  exit 1
fi
