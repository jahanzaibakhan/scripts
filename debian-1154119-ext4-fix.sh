#!/usr/bin/env bash
# debian-1154119-ext4-fix.sh
# Detect / remediate Debian bug #1154119:
#   "NULL pointer dereference in ext4_mb_load_buddy_gfp" on Debian 12 (bookworm)
#   linux-image-6.1.0-55-amd64 (linux 6.1.192-1). Fixed in linux 6.1.192-2.
#
# Usage:
#   sudo ./debian-1154119-ext4-fix.sh            # check only (default, no changes)
#   sudo ./debian-1154119-ext4-fix.sh --upgrade  # apt upgrade to fixed kernel (6.1.192-2+), then reboot manually
#   sudo ./debian-1154119-ext4-fix.sh --rollback # make GRUB boot the previous good kernel (6.1.0-53) and hold bad one
#
# Notes:
#   - A reboot is always required; this script never reboots.
#   - If the box is already hung/unkillable from the oops, a hard reboot is the only way out.

set -euo pipefail

BAD_PKG_VER="6.1.192-1"
FIXED_MIN="6.1.192-2"
MODE="check"
case "${1:-}" in
  --upgrade)  MODE="upgrade" ;;
  --rollback) MODE="rollback" ;;
  ""|--check) MODE="check" ;;
  *) echo "Unknown option: $1"; exit 2 ;;
esac

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo)."; exit 1; }
. /etc/os-release
echo "OS: ${PRETTY_NAME:-unknown} | running kernel: $(uname -r) ($(uname -v))"

echo; echo "== Installed kernel images =="
dpkg-query -W -f='${Package}\t${Version}\t${db:Status-Abbrev}\n' 'linux-image-6.1.*' 2>/dev/null | grep -E '\sii' || echo "none"

echo; echo "== Candidate meta-package version =="
apt-cache policy linux-image-amd64 2>/dev/null | sed -n '1,4p' || true

echo; echo "== Oops evidence (this boot and previous) =="
{ journalctl -k -b 0 --no-pager 2>/dev/null; journalctl -k -b -1 --no-pager 2>/dev/null; dmesg 2>/dev/null; } \
  | grep -E 'ext4_mb_load_buddy_gfp|NULL pointer dereference' | sort -u | head -20 \
  || true
[ "${PIPESTATUS[0]:-0}" -eq 0 ] || true

RUNNING_VER="$(dpkg-query -W -f='${Version}' "linux-image-$(uname -r)" 2>/dev/null || echo unknown)"
echo; echo "Running kernel package version: $RUNNING_VER"
if [ "$RUNNING_VER" != unknown ] && dpkg --compare-versions "$RUNNING_VER" lt "$FIXED_MIN" \
   && dpkg --compare-versions "$RUNNING_VER" ge "$BAD_PKG_VER"; then
  echo "STATUS: AFFECTED (running $RUNNING_VER, fixed in $FIXED_MIN)"
elif [ "$RUNNING_VER" != unknown ] && dpkg --compare-versions "$RUNNING_VER" ge "$FIXED_MIN"; then
  echo "STATUS: OK (running fixed kernel)"
else
  echo "STATUS: not in the affected range"
fi

case "$MODE" in
check)
  echo; echo "Check only. Re-run with --upgrade (preferred) or --rollback."
  ;;
upgrade)
  echo; echo "== Upgrading kernel =="
  apt-get update
  # unhold in case a previous rollback held it
  apt-mark unhold linux-image-amd64 "linux-image-6.1.0-55-amd64" 2>/dev/null || true
  apt-get install -y --only-upgrade linux-image-amd64 linux-image-6.1.0-55-amd64 || apt-get install -y linux-image-amd64
  NEWVER="$(apt-cache policy linux-image-amd64 | awk '/Installed:/{print $2}')"
  echo "Installed meta version: $NEWVER"
  echo "Verify the new kernel package is >= $FIXED_MIN:"
  dpkg-query -W -f='${Package} ${Version}\n' 'linux-image-6.1.*' || true
  echo "Reboot when ready: sudo systemctl reboot"
  ;;
rollback)
  echo; echo "== Rolling back to 6.1.0-53 =="
  if ! dpkg -s linux-image-6.1.0-53-amd64 >/dev/null 2>&1; then
    echo "linux-image-6.1.0-53-amd64 not installed. Trying to install (may not be in the repo anymore)."
    apt-get install -y linux-image-6.1.0-53-amd64 || { echo "Not available. Use --upgrade instead."; exit 1; }
  fi
  apt-mark hold linux-image-amd64 linux-image-6.1.0-55-amd64 2>/dev/null || true
  cp -a /etc/default/grub "/etc/default/grub.bak.$(date +%s)"
  ENTRY="Advanced options for Debian GNU/Linux>Debian GNU/Linux, with Linux 6.1.0-53-amd64"
  sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT="'"$ENTRY"'"/' /etc/default/grub
  update-grub
  echo "GRUB default set to 6.1.0-53. Reboot: sudo systemctl reboot"
  echo "Remember: apt-mark unhold linux-image-amd64 linux-image-6.1.0-55-amd64 after $FIXED_MIN is available, then run --upgrade."
  ;;
esac
