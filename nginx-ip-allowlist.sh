#!/usr/bin/env bash
#
# nginx-ip-allowlist.sh
# Adds an IP allowlist (allow ...; deny all;) to a Cloudways app's nginx vhost.
# Prompts for the app name, edits /etc/nginx/sites-available/<app> (via the
# sites-enabled symlink), tests, reloads nginx and verifies the rule is live.
#
# Usage (as root):  bash nginx-ip-allowlist.sh
#   or:             curl -fsSL <raw-url> | sudo bash

set -uo pipefail

ENABLED_DIR="/etc/nginx/sites-enabled"
ALLOW_IPS=(
  "143.198.206.48"
  "134.209.241.49"
  "144.126.255.60"
)

die() { echo "ERROR: $*" >&2; exit 1; }

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
read -r -p "Add IP allowlist to this app? [y/N]: " OK </dev/tty
[[ "$OK" =~ ^[Yy]$ ]] || die "Aborted."

# Idempotency: skip if the rule is already there.
if grep -qE '^\s*deny\s+all;' "$CONF" && grep -qF "allow ${ALLOW_IPS[0]};" "$CONF"; then
  echo "Allowlist already present in $CONF - nothing to do."
  exit 0
fi

BACKUP="$CONF.bak.$(date +%Y%m%d%H%M%S)"
cp -p "$CONF" "$BACKUP" || die "Backup failed."
echo "Backup: $BACKUP"

# Insert the rules after every server_name line (i.e. in each server block),
# reusing that line's indentation.
RULES="$(printf '%s\n' "${ALLOW_IPS[@]}")"
TMP="$(mktemp)"
RULES="$RULES" awk '
  { print }
  /^[ \t]*server_name[ \t;]/ {
    match($0, /^[ \t]*/); ind = substr($0, 1, RLENGTH)
    n = split(ENVIRON["RULES"], ips, "\n")
    for (i = 1; i <= n; i++) if (ips[i] != "") print ind "allow " ips[i] ";"
    print ind "deny all;"
    added++
  }
  END { if (!added) exit 3 }
' "$CONF" >"$TMP"
rc=$?
if [[ $rc -ne 0 ]]; then
  rm -f "$TMP" "$BACKUP"
  die "No server_name line found in $CONF; nothing changed."
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

# Verify: file contents and the config nginx actually loaded.
echo
echo "Verification:"
FAIL=0
for ip in "${ALLOW_IPS[@]}"; do
  if grep -qF "allow $ip;" "$CONF" && nginx -T 2>/dev/null | grep -qF "allow $ip;"; then
    echo "  [OK] allow $ip;"
  else
    echo "  [MISSING] allow $ip;"; FAIL=1
  fi
done
if grep -qE '^\s*deny\s+all;' "$CONF" && nginx -T 2>/dev/null | grep -qE '^\s*deny\s+all;'; then
  echo "  [OK] deny all;"
else
  echo "  [MISSING] deny all;"; FAIL=1
fi

echo
grep -nE '^\s*(allow|deny)\s' "$CONF"
echo
if [[ $FAIL -eq 0 ]]; then
  echo "Done: $APP is now restricted to the allowed proxy IPs. (Backup: $BACKUP)"
else
  echo "Rule not fully confirmed - check $CONF (backup: $BACKUP)." >&2
  exit 1
fi
