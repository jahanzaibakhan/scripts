#!/usr/bin/env bash
#
# adminer-cert-mismatch-fix.sh
# Detects and fixes the Apache outage caused by Cloudways playbook v275
# (Oct 2026): /etc/ssl/adminer/adminer.pem was replaced with an RSA cert
# issued for the retired pre-Oct-12 key, while adminer.key is the current
# EC key. Apache's adminer vhost (:8082) fails with AH02565 and the whole
# apache2 service exits.
#
# Fix: restore adminer.pem_bak (the EC cert that matches adminer.key),
# keeping the broken cert as adminer.pem.broken-<timestamp>, then start
# or reload apache2.
#
# Usage (as root):
#   bash adminer-cert-mismatch-fix.sh            # check, confirm, fix
#   bash adminer-cert-mismatch-fix.sh --check    # check only, no changes
#   curl -fsSL <raw-url> | sudo bash -s -- [--check]

set -uo pipefail

DIR="/etc/ssl/adminer"
PEM="$DIR/adminer.pem"
KEY="$DIR/adminer.key"
PEM_BAK="$DIR/adminer.pem_bak"
FACT="/etc/ansible/facts.d/playbook_version.fact"

die() { echo "ERROR: $*" >&2; exit 1; }

MODE=fix
case "${1:-}" in
  "") ;;
  --check|-c) MODE=check ;;
  -h|--help) sed -n '2,17p' "$0" 2>/dev/null; exit 0 ;;
  *) die "Unknown option: $1 (use --check or no option)" ;;
esac

[[ $EUID -eq 0 ]] || die "Run this script as root."
command -v openssl >/dev/null || die "openssl not found."
[[ -f "$PEM" ]] || die "$PEM does not exist."
[[ -f "$KEY" ]] || die "$KEY does not exist."

# md5 of the DER public key, so certs and keys of any type can be compared.
cert_fp() { openssl x509 -in "$1" -noout -pubkey 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | md5sum | cut -c1-12; }
key_fp()  { openssl pkey -in "$1" -pubout -outform DER 2>/dev/null | md5sum | cut -c1-12; }
cert_info() { openssl x509 -in "$1" -noout -enddate 2>/dev/null | sed 's/notAfter=/expires /'; }
EMPTY_FP="d41d8cd98f00"   # md5 of empty input = file could not be parsed

PEM_FP="$(cert_fp "$PEM")"
KEY_FP="$(key_fp "$KEY")"
[[ "$PEM_FP" != "$EMPTY_FP" ]] || die "Could not read a certificate from $PEM."
[[ "$KEY_FP" != "$EMPTY_FP" ]] || die "Could not read a private key from $KEY."

echo "== Check: $(hostname)"
echo "Playbook version : $(grep -h '^playbook=' "$FACT" 2>/dev/null || echo unknown)"
echo "apache2          : $(systemctl is-active apache2 2>/dev/null)"
echo "adminer.pem      : $PEM_FP  ($(cert_info "$PEM"), modified $(date -r "$PEM" '+%F %T'))"
echo "adminer.key      : $KEY_FP  (modified $(date -r "$KEY" '+%F %T'))"
echo "Last AH02565     : $(grep -h 'AH02565' /var/log/apache2/error.log 2>/dev/null | tail -n1 | cut -c1-60)"
echo

if [[ "$PEM_FP" == "$KEY_FP" ]]; then
  echo "RESULT: no key mismatch - adminer.pem matches adminer.key. Nothing to fix."
  if ! systemctl is-active --quiet apache2; then
    echo "apache2 is not running, but not because of this issue. Check: journalctl -u apache2 -n 30"
  fi
  exit 0
fi

echo "RESULT: KEY MISMATCH - adminer.pem does not match adminer.key."

# Verify the known fix applies: the backup cert must match the current key.
[[ -f "$PEM_BAK" ]] || die "$PEM_BAK not found - cannot apply the standard fix. Escalate."
BAK_FP="$(cert_fp "$PEM_BAK")"
echo "adminer.pem_bak  : $BAK_FP  ($(cert_info "$PEM_BAK"))"
if [[ "$BAK_FP" != "$KEY_FP" ]]; then
  die "adminer.pem_bak does not match adminer.key either - this is a different issue. No changes made. Escalate."
fi
echo "VERIFIED: adminer.pem_bak matches adminer.key - the standard fix applies."
echo

if [[ $MODE == check ]]; then
  echo "Check only (--check) - no changes made."
  exit 0
fi

echo "The fix will:"
echo "  1. copy $PEM -> $PEM.broken-<timestamp>"
echo "  2. copy $PEM_BAK -> $PEM"
echo "  3. test the Apache config, then start/reload apache2"
read -r -p "Apply the fix? [y/N]: " OK </dev/tty
[[ "$OK" =~ ^[Yy]$ ]] || die "Aborted. No changes made."
echo

BROKEN="$PEM.broken-$(date +%Y%m%d%H%M%S)"
cp -a "$PEM" "$BROKEN" || die "Backup of $PEM failed. No changes made."
echo "Backup: $BROKEN"

cp -a "$PEM_BAK" "$PEM" || die "Restore failed. Original is still at $BROKEN."

if [[ "$(cert_fp "$PEM")" != "$KEY_FP" ]]; then
  cp -a "$BROKEN" "$PEM"
  die "Cert still does not match the key after restore - rolled back to the original."
fi
echo "OK: adminer.pem now matches adminer.key."

if ! apache2ctl -t >/dev/null 2>&1; then
  apache2ctl -t
  die "apache2ctl -t failed (unrelated to the cert). Cert fix is in place; apache2 not touched."
fi

if systemctl is-active --quiet apache2; then
  systemctl reload apache2
else
  systemctl start apache2
fi
sleep 2

echo
if systemctl is-active --quiet apache2; then
  echo "SUCCESS: apache2 is $(systemctl is-active apache2)."
else
  echo "apache2 is still not running. Last log lines:" >&2
  tail -n 5 /var/log/apache2/error.log >&2
  exit 1
fi

if command -v nginx >/dev/null; then
  nginx -t >/dev/null 2>&1 && echo "nginx -t: OK" || echo "WARNING: nginx -t failed - run 'nginx -t' to see why." >&2
fi
