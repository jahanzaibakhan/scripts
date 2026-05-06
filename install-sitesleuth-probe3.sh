#!/usr/bin/env bash
# Install SiteSleuth read-only probe into the WordPress document root.
#
# Usage (run from the folder that contains wp-config.php and wp-load.php):
#   bash install-sitesleuth-probe.sh
#   bash install-sitesleuth-probe.sh /path/to/public_html
#
# Options:
#   --dry-run          Print actions only; do not write files
#   --secret=VALUE     Use this secret (min 16 chars); default: random hex from openssl
#   --domain=BASE      HTTPS base URL for this WordPress folder (printed in summary); e.g. https://www.example.com or https://example.com/subdir (no trailing slash required)
#   -d BASE            Same as --domain=
#   --non-interactive, -y  Do not prompt for domain (shows YOUR-DOMAIN unless --domain is set)
#   --force            Overwrite sitesleuth-probe.php if it already exists
#   -h, --help         Show this help
#
# Requires: openssl (for default secret), cp, grep, sed (GNU sed preferred for -i).

set -euo pipefail

DRY_RUN=0
FORCE_PHP=0
NON_INTERACTIVE=0
CUSTOM_SECRET=""
DOMAIN_FLAG=""
ROOT=""
PROBE_FILE="sitesleuth-probe.php"

usage() {
  sed -n '2,17p' "$0"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --force) FORCE_PHP=1 ;;
    --non-interactive|-y) NON_INTERACTIVE=1 ;;
    --secret=*)
      CUSTOM_SECRET="${1#*=}"
      ;;
    --domain=*)
      DOMAIN_FLAG="${1#*=}"
      ;;
    --domain|-d)
      if [[ $# -lt 2 ]]; then echo "Error: $1 requires a value (HTTPS base URL)" >&2; exit 1; fi
      DOMAIN_FLAG="$2"
      shift 2
      continue
      ;;
    -h|--help) usage ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      if [[ -n "$ROOT" ]]; then
        echo "Only one directory argument allowed." >&2
        exit 1
      fi
      ROOT="$1"
      ;;
  esac
  shift
done

if [[ -z "$ROOT" ]]; then
  ROOT="$(pwd)"
fi

ROOT="$(cd "$ROOT" && pwd)"

WP_CONFIG="${ROOT}/wp-config.php"
WP_LOAD="${ROOT}/wp-load.php"
PROBE_PATH="${ROOT}/${PROBE_FILE}"

if [[ ! -f "$WP_CONFIG" ]]; then
  echo "Error: wp-config.php not found in: $ROOT" >&2
  echo "Run this script from the WordPress root (same directory as wp-config.php)." >&2
  exit 1
fi

if [[ ! -f "$WP_LOAD" ]]; then
  echo "Warning: wp-load.php not found — is this the correct WordPress root?" >&2
fi

if [[ -f "$PROBE_PATH" && "$FORCE_PHP" -eq 0 ]]; then
  echo "Error: ${PROBE_FILE} already exists. Use --force to overwrite, or delete it first." >&2
  exit 1
fi

php_contains_sitesleuth_marker() {
  grep -q 'SiteSleuth probe — added by install-sitesleuth-probe.sh' "$WP_CONFIG" 2>/dev/null
}

wp_config_has_secret_define() {
  grep -qE "define\s*\(\s*['\"]SITESLEUTH_PROBE_SECRET['\"]" "$WP_CONFIG" 2>/dev/null
}

install_sitesleuth_probe_php() {
  local _d _src
  _d="$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]:-.}")" >/dev/null 2>&1 && pwd || true)"
  if [[ -n "$_d" && -f "${_d}/sitesleuth-probe.php" ]]; then
    cp -a "${_d}/sitesleuth-probe.php" "$PROBE_PATH"
    return 0
  fi
  # Embedded probe (v3) when installer is piped from curl without sibling file.
  openssl base64 -d <<'PROBE_B64_BLOCK' >"$PROBE_PATH" 2>/dev/null
PD9waHAKLyoqCiAqIFNpdGVTbGV1dGggY3VzdG9tZXIgcHJvYmUg4oCUIHJlYWQtb25seSBXb3Jk
UHJlc3MgLyBQSFAgLyBEQiAvIGhvb2tzIHNuYXBzaG90LgogKgogKiBwcm9iZV92ZXJzaW9uIGlu
Y3JlbWVudHMgd2hlbiBwYXlsb2FkIHNoYXBlIGdyb3dzOyBrZWVwIGluc3RhbGxlciBzY3JpcHQg
aW4gc3luYy4KICovCmRlY2xhcmUoc3RyaWN0X3R5cGVzPTEpOwoKLyoqCiAqIFJlZmxlY3QgYSBX
UCBob29rIGNhbGxhYmxlIHRvIGEgZGVjbGFyaW5nIGZpbGUgcGF0aCwgaWYgcG9zc2libGUuCiAq
CiAqIEBwYXJhbSBtaXhlZCAkY2FsbGJhY2sKICovCmZ1bmN0aW9uIHNpdGVzbGV1dGhfcHJvYmVf
Y2FsbGJhY2tfZmlsZSgkY2FsbGJhY2spOiA/c3RyaW5nIHsKICAgIHRyeSB7CiAgICAgICAgaWYg
KCRjYWxsYmFjayBpbnN0YW5jZW9mIENsb3N1cmUpIHsKICAgICAgICAgICAgJHIgPSBuZXcgUmVm
bGVjdGlvbkZ1bmN0aW9uKCRjYWxsYmFjayk7CiAgICAgICAgICAgIHJldHVybiB3cF9ub3JtYWxp
emVfcGF0aCgkci0+Z2V0RmlsZU5hbWUoKSk7CiAgICAgICAgfQogICAgICAgIGlmIChpc19zdHJp
bmcoJGNhbGxiYWNrKSkgewogICAgICAgICAgICBpZiAoc3RycG9zKCRjYWxsYmFjaywgJzo6Jykg
IT09IGZhbHNlKSB7CiAgICAgICAgICAgICAgICBbJGNscywgJG1ldGhdID0gZXhwbG9kZSgnOjon
LCAkY2FsbGJhY2ssIDIpOwogICAgICAgICAgICAgICAgaWYgKGNsYXNzX2V4aXN0cygkY2xzKSkg
ewogICAgICAgICAgICAgICAgICAgICRtciA9IG5ldyBSZWZsZWN0aW9uTWV0aG9kKCRjbHMsICRt
ZXRoKTsKCiAgICAgICAgICAgICAgICAgICAgcmV0dXJuIHdwX25vcm1hbGl6ZV9wYXRoKCRtci0+
Z2V0RmlsZU5hbWUoKSk7CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgIH0KICAgICAgICAg
ICAgaWYgKGZ1bmN0aW9uX2V4aXN0cygkY2FsbGJhY2spKSB7CiAgICAgICAgICAgICAgICAkciA9
IG5ldyBSZWZsZWN0aW9uRnVuY3Rpb24oJGNhbGxiYWNrKTsKCiAgICAgICAgICAgICAgICByZXR1
cm4gd3Bfbm9ybWFsaXplX3BhdGgoJHItPmdldEZpbGVOYW1lKCkpOwogICAgICAgICAgICB9Cgog
ICAgICAgICAgICByZXR1cm4gbnVsbDsKICAgICAgICB9CiAgICAgICAgaWYgKCFpc19hcnJheSgk
Y2FsbGJhY2spIHx8IGNvdW50KCRjYWxsYmFjaykgIT09IDIpIHsKICAgICAgICAgICAgcmV0dXJu
IG51bGw7CiAgICAgICAgfQogICAgICAgIFskYSwgJGJdID0gJGNhbGxiYWNrOwogICAgICAgIGlm
IChpc19vYmplY3QoJGEpICYmIGlzX3N0cmluZygkYikpIHsKICAgICAgICAgICAgJG1yID0gbmV3
IFJlZmxlY3Rpb25NZXRob2QoJGEsICRiKTsKCiAgICAgICAgICAgIHJldHVybiB3cF9ub3JtYWxp
emVfcGF0aCgkbXItPmdldEZpbGVOYW1lKCkpOwogICAgICAgIH0KICAgICAgICBpZiAoaXNfc3Ry
aW5nKCRhKSAmJiBpc19zdHJpbmcoJGIpICYmIGNsYXNzX2V4aXN0cygkYSkpIHsKICAgICAgICAg
ICAgJG1yID0gbmV3IFJlZmxlY3Rpb25NZXRob2QoJGEsICRiKTsKCiAgICAgICAgICAgIHJldHVy
biB3cF9ub3JtYWxpemVfcGF0aCgkbXItPmdldEZpbGVOYW1lKCkpOwogICAgICAgIH0KICAgIH0g
Y2F0Y2ggKFRocm93YWJsZSAkZSkgewogICAgICAgIHJldHVybiBudWxsOwogICAgfQoKICAgIHJl
dHVybiBudWxsOwp9CgovKioKICogTWFwIGFic29sdXRlIHBhdGggdG8gcGx1Z2luIG1haW4gZmls
ZSBrZXkgKGFzIGluIGdldF9wbHVnaW5zIGtleXMpIG9yIHNlbnRpbmVsLgogKgogKiBAcGFyYW0g
YXJyYXk8c3RyaW5nLCBhcnJheTxzdHJpbmcsIHN0cmluZz4+ICRfcGx1Z2lucyBJZ25vcmVkIG1l
dGE7IGtleXMgb25seSBtYXR0ZXIKICoKICogQHJldHVybiBzdHJpbmcgcGx1Z2luIGZpbGUga2V5
fCdjb3JlJ3wnbXVzdF91c2VfcGx1Z2luJ3wnZHJvcGluJ3wndGhlbWUnfCd1bmtub3duJwogKi8K
ZnVuY3Rpb24gc2l0ZXNsZXV0aF9wcm9iZV9hdHRyaWJ1dGVfcGF0aChzdHJpbmcgJGZpbGUsIGFy
cmF5ICRfcGx1Z2lucyk6IHN0cmluZyB7CiAgICAkZmlsZSA9IHdwX25vcm1hbGl6ZV9wYXRoKCRm
aWxlKTsKICAgICRtdWRvYyA9IHdwX25vcm1hbGl6ZV9wYXRoKFdQTVVfUExVR0lOX0RJUik7Cgog
ICAgaWYgKHN0cnBvcygkZmlsZSwgJG11ZG9jIC4gJy8nKSA9PT0gMCkgewogICAgICAgIHJldHVy
biAnbXVzdF91c2VfcGx1Z2luJzsKICAgIH0KCiAgICBmb3JlYWNoIChhcnJheV9rZXlzKCRfcGx1
Z2lucykgYXMgJGtleSkgewogICAgICAgICRtYWluID0gd3Bfbm9ybWFsaXplX3BhdGgoV1BfUExV
R0lOX0RJUiAuICcvJyAuICRrZXkpOwogICAgICAgICRwbHVnRGlyID0gZGlybmFtZSgkbWFpbik7
CiAgICAgICAgaWYgKCRmaWxlID09PSAkbWFpbiB8fCBzdHJwb3MoJGZpbGUsICRwbHVnRGlyIC4g
Jy8nKSA9PT0gMCkgewogICAgICAgICAgICByZXR1cm4gJGtleTsKICAgICAgICB9CiAgICB9Cgog
ICAgaWYgKHN0cnBvcygkZmlsZSwgJy93cC1pbmNsdWRlcy8nKSAhPT0gZmFsc2UgfHwgc3RycG9z
KCRmaWxlLCAnL3dwLWFkbWluLycpICE9PSBmYWxzZSkgewogICAgICAgIHJldHVybiAnY29yZSc7
CiAgICB9CiAgICAkdGQgPSB3cF9ub3JtYWxpemVfcGF0aChnZXRfdGVtcGxhdGVfZGlyZWN0b3J5
KCkpOwogICAgJHNkID0gd3Bfbm9ybWFsaXplX3BhdGgoZ2V0X3N0eWxlc2hlZXRfZGlyZWN0b3J5
KCkpOwogICAgaWYgKCgkdGQgJiYgc3RycG9zKCRmaWxlLCAkdGQgLiAnLycpID09PSAwKSB8fCAo
JHNkICYmIHN0cnBvcygkZmlsZSwgJHNkIC4gJy8nKSA9PT0gMCkpIHsKICAgICAgICByZXR1cm4g
J3RoZW1lJzsKICAgIH0KICAgIGlmIChzdHJwb3MoJGZpbGUsICcvd3AtY29udGVudC8nKSAhPT0g
ZmFsc2UpIHsKICAgICAgICByZXR1cm4gJ3dwX2NvbnRlbnRfb3RoZXInOwogICAgfQoKICAgIHJl
dHVybiAndW5rbm93bic7Cn0KCi8qKgogKiBTdW1tYXJpc2UgcmVnaXN0ZXJlZCBjYWxsYmFja3Mg
b24ga2V5IGhvb2tzLCBhdHRyaWJ1dGVkIHRvIHBsdWdpbnMgLyBjb3JlLgogKgogKiBAcmV0dXJu
IGFycmF5PHN0cmluZywgYXJyYXl7dG90YWxfY2FsbGJhY2tzOmludCwgYnlfc291cmNlOiBhcnJh
eTxzdHJpbmcsIGludD59PgogKi8KZnVuY3Rpb24gc2l0ZXNsZXV0aF9wcm9iZV9ob29rX3N1bW1h
cnkoYXJyYXkgJHBsdWdpbktleXMpOiBhcnJheSB7CiAgICBnbG9iYWwgJHdwX2ZpbHRlcjsKICAg
ICR0YWdzID0gWwogICAgICAgICdwbHVnaW5zX2xvYWRlZCcsCiAgICAgICAgJ3NldHVwX3RoZW1l
JywKICAgICAgICAnYWZ0ZXJfc2V0dXBfdGhlbWUnLAogICAgICAgICdpbml0JywKICAgICAgICAn
d3BfbG9hZGVkJywKICAgICAgICAncmVzdF9hcGlfaW5pdCcsCiAgICAgICAgJ3dpZGdldHNfaW5p
dCcsCiAgICAgICAgJ3dwX2VucXVldWVfc2NyaXB0cycsCiAgICAgICAgJ2FkbWluX2luaXQnLAog
ICAgICAgICd0ZW1wbGF0ZV9yZWRpcmVjdCcsCiAgICAgICAgJ3dwJywKICAgICAgICAnc2h1dGRv
d24nLAogICAgXTsKICAgICRvdXQgPSBbXTsKICAgIGZvcmVhY2ggKCR0YWdzIGFzICR0YWcpIHsK
ICAgICAgICBpZiAoIWlzc2V0KCR3cF9maWx0ZXJbJHRhZ10pIHx8ICFpc19vYmplY3QoJHdwX2Zp
bHRlclskdGFnXSkpIHsKICAgICAgICAgICAgY29udGludWU7CiAgICAgICAgfQogICAgICAgIC8q
KiBAdmFyIFdQX0hvb2sgJGhvb2sgKi8KICAgICAgICAkaG9vayA9ICR3cF9maWx0ZXJbJHRhZ107
CiAgICAgICAgJGJ5ID0gW107CiAgICAgICAgJHRvdGFsID0gMDsKICAgICAgICBmb3JlYWNoICgk
aG9vay0+Y2FsbGJhY2tzIGFzICRwcmlvcml0eSA9PiAkbGlzdCkgewogICAgICAgICAgICBmb3Jl
YWNoICgkbGlzdCBhcyAkaXRlbSkgewogICAgICAgICAgICAgICAgJGZuID0gJGl0ZW1bJ2Z1bmN0
aW9uJ10gPz8gbnVsbDsKICAgICAgICAgICAgICAgIGlmICgkZm4gPT09IG51bGwpIHsKICAgICAg
ICAgICAgICAgICAgICBjb250aW51ZTsKICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAg
ICsrJHRvdGFsOwogICAgICAgICAgICAgICAgJHBhdGggPSBzaXRlc2xldXRoX3Byb2JlX2NhbGxi
YWNrX2ZpbGUoJGZuKTsKICAgICAgICAgICAgICAgICRsYWJlbCA9ICRwYXRoID8gc2l0ZXNsZXV0
aF9wcm9iZV9hdHRyaWJ1dGVfcGF0aCgkcGF0aCwgJHBsdWdpbktleXMpIDogJ3VucmVzb2x2YWJs
ZV9jYWxsYmFjayc7CiAgICAgICAgICAgICAgICAkYnlbJGxhYmVsXSA9ICgkYnlbJGxhYmVsXSA/
PyAwKSArIDE7CiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICAgICAgYXJzb3J0KCRieSk7CiAg
ICAgICAgJG91dFskdGFnXSA9IFsKICAgICAgICAgICAgJ3RvdGFsX2NhbGxiYWNrcycgPT4gJHRv
dGFsLAogICAgICAgICAgICAnYnlfc291cmNlJyA9PiBhcnJheV9zbGljZSgkYnksIDAsIDQwLCB0
cnVlKSwKICAgICAgICBdOwogICAgfQoKICAgIHJldHVybiAkb3V0Owp9CgovKioKICogSGV1cmlz
dGljICJoZWF2eSBwbHVnaW4iIGxpc3Q6IG1hbnkgaG9va3Mgb24gaW5pdCAvIHdwX2xvYWRlZCAo
bm90IHdhbGwgdGltZSkuCiAqCiAqIEBwYXJhbSBhcnJheTxzdHJpbmcsIGFycmF5e3RvdGFsX2Nh
bGxiYWNrczppbnQsIGJ5X3NvdXJjZTogYXJyYXk8c3RyaW5nLCBpbnQ+fT4gJGhvb2tTdW1tYXJ5
CiAqCiAqIEByZXR1cm4gbGlzdDxhcnJheXtwbHVnaW46c3RyaW5nLCBpbml0X2NhbGxiYWNrczpp
bnQsIHdwX2xvYWRlZF9jYWxsYmFja3M6aW50LCBzY29yZTppbnR9PgogKi8KZnVuY3Rpb24gc2l0
ZXNsZXV0aF9wcm9iZV9oZWF2eV9wbHVnaW5faGludHMoYXJyYXkgJGhvb2tTdW1tYXJ5LCBhcnJh
eSAkYWN0aXZlUGx1Z2luRmlsZXMpOiBhcnJheSB7CiAgICAkc2NvcmVzID0gW107CiAgICAkbWVy
Z2VUYWcgPSBzdGF0aWMgZnVuY3Rpb24gKHN0cmluZyAkdGFnKSB1c2UgKCYkc2NvcmVzLCAkaG9v
a1N1bW1hcnkpOiB2b2lkIHsKICAgICAgICBpZiAoIWlzc2V0KCRob29rU3VtbWFyeVskdGFnXVsn
Ynlfc291cmNlJ10pKSB7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgZm9y
ZWFjaCAoJGhvb2tTdW1tYXJ5WyR0YWddWydieV9zb3VyY2UnXSBhcyAkc3JjID0+ICRuKSB7CiAg
ICAgICAgICAgIGlmICgkc3JjID09PSAnY29yZScgfHwgJHNyYyA9PT0gJ3RoZW1lJyB8fCAkc3Jj
ID09PSAndW5rbm93bicgfHwgc3RycG9zKCRzcmMsICdtdXN0X3VzZScpID09PSAwKSB7CiAgICAg
ICAgICAgICAgICBjb250aW51ZTsKICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAoJHNyYyA9
PT0gJ3dwX2NvbnRlbnRfb3RoZXInKSB7CiAgICAgICAgICAgICAgICBjb250aW51ZTsKICAgICAg
ICAgICAgfQogICAgICAgICAgICAkc2NvcmVzWyRzcmNdID8/PSBbJ2luaXQnID0+IDAsICd3cF9s
b2FkZWQnID0+IDBdOwogICAgICAgICAgICBpZiAoJHRhZyA9PT0gJ2luaXQnKSB7CiAgICAgICAg
ICAgICAgICAkc2NvcmVzWyRzcmNdWydpbml0J10gKz0gJG47CiAgICAgICAgICAgIH0KICAgICAg
ICAgICAgaWYgKCR0YWcgPT09ICd3cF9sb2FkZWQnKSB7CiAgICAgICAgICAgICAgICAkc2NvcmVz
WyRzcmNdWyd3cF9sb2FkZWQnXSArPSAkbjsKICAgICAgICAgICAgfQogICAgICAgIH0KICAgIH07
CgogICAgJG1lcmdlVGFnKCdpbml0Jyk7CiAgICAkbWVyZ2VUYWcoJ3dwX2xvYWRlZCcpOwoKICAg
ICRyb3dzID0gW107CiAgICBmb3JlYWNoICgkc2NvcmVzIGFzICRwbHVnaW5GaWxlID0+ICRjKSB7
CiAgICAgICAgaWYgKCEgaW5fYXJyYXkoJHBsdWdpbkZpbGUsIFsnY29yZScsICd0aGVtZScsICd1
bmtub3duJywgJ3dwX2NvbnRlbnRfb3RoZXInLCAnbXVzdF91c2VfcGx1Z2luJ10sIHRydWUpKSB7
CiAgICAgICAgICAgICRzY29yZSA9ICgkY1snaW5pdCddID8/IDApICogMyArICgkY1snd3BfbG9h
ZGVkJ10gPz8gMCkgKiAyOwogICAgICAgICAgICAkcm93c1tdID0gWwogICAgICAgICAgICAgICAg
J3BsdWdpbicgPT4gJHBsdWdpbkZpbGUsCiAgICAgICAgICAgICAgICAnYWN0aXZlJyA9PiBpbl9h
cnJheSgkcGx1Z2luRmlsZSwgJGFjdGl2ZVBsdWdpbkZpbGVzLCB0cnVlKSwKICAgICAgICAgICAg
ICAgICdpbml0X2NhbGxiYWNrcycgPT4gJGNbJ2luaXQnXSA/PyAwLAogICAgICAgICAgICAgICAg
J3dwX2xvYWRlZF9jYWxsYmFja3MnID0+ICRjWyd3cF9sb2FkZWQnXSA/PyAwLAogICAgICAgICAg
ICAgICAgJ3Njb3JlJyA9PiAkc2NvcmUsCiAgICAgICAgICAgICAgICAnbm90ZScgPT4gJ0hldXJp
c3RpYzogbWFueSBob29rZWQgY2FsbGJhY2tzIOKAlCBwcm9maWxlIHdpdGggUXVlcnkgTW9uaXRv
ciBvciBzaW1pbGFyIGZvciByZWFsIENQVS90aW1lLicsCiAgICAgICAgICAgIF07CiAgICAgICAg
fQogICAgfQogICAgdXNvcnQoJHJvd3MsIHN0YXRpYyBmbiAoYXJyYXkgJGEsIGFycmF5ICRiKSA9
PiAkYlsnc2NvcmUnXSA8PT4gJGFbJ3Njb3JlJ10pOwoKICAgIHJldHVybiBhcnJheV9zbGljZSgk
cm93cywgMCwgMjUpOwp9CgpoZWFkZXIoJ0NvbnRlbnQtVHlwZTogYXBwbGljYXRpb24vanNvbjsg
Y2hhcnNldD11dGYtOCcpOwoKaWYgKCgkX1NFUlZFUlsnUkVRVUVTVF9NRVRIT0QnXSA/PyAnJykg
IT09ICdQT1NUJykgewogICAgaHR0cF9yZXNwb25zZV9jb2RlKDQwNSk7CiAgICBlY2hvIGpzb25f
ZW5jb2RlKFsnb2snID0+IGZhbHNlLCAnZXJyb3InID0+ICdtZXRob2Rfbm90X2FsbG93ZWQnXSk7
CiAgICBleGl0Owp9CgokcHJvdmlkZWQgPSBpc3NldCgkX1NFUlZFUlsnSFRUUF9YX1NJVEVTTEVV
VEhfU0VDUkVUJ10pID8gKHN0cmluZykgJF9TRVJWRVJbJ0hUVFBfWF9TSVRFU0xFVVRIX1NFQ1JF
VCddIDogJyc7CmlmICgkcHJvdmlkZWQgPT09ICcnKSB7CiAgICBodHRwX3Jlc3BvbnNlX2NvZGUo
NDAxKTsKICAgIGVjaG8ganNvbl9lbmNvZGUoWydvaycgPT4gZmFsc2UsICdlcnJvcicgPT4gJ21p
c3Npbmdfc2VjcmV0J10pOwogICAgZXhpdDsKfQoKJHdwTG9hZFN0YXJ0ID0gbWljcm90aW1lKHRy
dWUpOwokd3BMb2FkID0gX19ESVJfXyAuICcvd3AtbG9hZC5waHAnOwokd3BMb2FkZWQgPSBpc19y
ZWFkYWJsZSgkd3BMb2FkKTsKaWYgKCR3cExvYWRlZCkgewogICAgcmVxdWlyZV9vbmNlICR3cExv
YWQ7Cn0KJHdwQm9vdHN0cmFwU2Vjb25kcyA9IHJvdW5kKG1pY3JvdGltZSh0cnVlKSAtICR3cExv
YWRTdGFydCwgNCk7CgokZXhwZWN0ZWQgPSAnJzsKaWYgKGRlZmluZWQoJ1NJVEVTTEVVVEhfUFJP
QkVfU0VDUkVUJykpIHsKICAgICRleHBlY3RlZCA9IChzdHJpbmcpIGNvbnN0YW50KCdTSVRFU0xF
VVRIX1BST0JFX1NFQ1JFVCcpOwp9IGVsc2UgewogICAgJGVudlNlY3JldCA9IGdldGVudignU0lU
RVNMRVVUSF9QUk9CRV9TRUNSRVQnKTsKICAgIGlmIChpc19zdHJpbmcoJGVudlNlY3JldCkgJiYg
JGVudlNlY3JldCAhPT0gJycpIHsKICAgICAgICAkZXhwZWN0ZWQgPSAkZW52U2VjcmV0OwogICAg
fQp9CgppZiAoJGV4cGVjdGVkID09PSAnJykgewogICAgaHR0cF9yZXNwb25zZV9jb2RlKDUwMyk7
CiAgICBlY2hvIGpzb25fZW5jb2RlKFsKICAgICAgICAnb2snID0+IGZhbHNlLAogICAgICAgICdl
cnJvcicgPT4gJ3Byb2JlX25vdF9jb25maWd1cmVkJywKICAgICAgICAnaGludCcgPT4gJ0RlZmlu
ZSBTSVRFU0xFVVRIX1BST0JFX1NFQ1JFVCBpbiB3cC1jb25maWcucGhwLCBvciBzZXQgdGhlIFNJ
VEVTTEVVVEhfUFJPQkVfU0VDUkVUIGVudmlyb25tZW50IHZhcmlhYmxlIGZvciBub24tV29yZFBy
ZXNzIFBIUC4nLAogICAgXSk7CiAgICBleGl0Owp9CgppZiAoISBoYXNoX2VxdWFscygkZXhwZWN0
ZWQsICRwcm92aWRlZCkpIHsKICAgIGh0dHBfcmVzcG9uc2VfY29kZSg0MDMpOwogICAgZWNobyBq
c29uX2VuY29kZShbJ29rJyA9PiBmYWxzZSwgJ2Vycm9yJyA9PiAnZm9yYmlkZGVuJ10pOwogICAg
ZXhpdDsKfQoKJG91dCA9IFsKICAgICdvaycgPT4gdHJ1ZSwKICAgICdwcm9iZV92ZXJzaW9uJyA9
PiAzLAogICAgJ3dvcmRwcmVzcycgPT4gZmFsc2UsCiAgICAndGltaW5nJyA9PiBbCiAgICAgICAg
J3NlY29uZHNfd3BfYm9vdHN0cmFwX3Rocm91Z2hfd3BfbG9hZCcgPT4gJHdwQm9vdHN0cmFwU2Vj
b25kcywKICAgICAgICAnaGludCcgPT4gJ1dhbGwgdGltZSBsb2FkaW5nIFdvcmRQcmVzcyBjb3Jl
ICsgcGx1Z2lucy9tdS1wbHVnaW5zIGZvciB0aGlzIHJlcXVlc3QgKG5vdCBwZXJmIG9mIGZyb250
IHBhZ2UgSFRNTCkuIENvbXBhcmUgYWNyb3NzIGVudmlyb25tZW50cy4nLAogICAgXSwKICAgICdw
aHBfdmVyc2lvbicgPT4gUEhQX1ZFUlNJT04sCiAgICAnbWVtb3J5X2xpbWl0JyA9PiBpbmlfZ2V0
KCdtZW1vcnlfbGltaXQnKSA/OiBudWxsLAogICAgJ21heF9leGVjdXRpb25fdGltZScgPT4gaW5p
X2dldCgnbWF4X2V4ZWN1dGlvbl90aW1lJykgPzogbnVsbCwKICAgICdzZXJ2ZXJfc29mdHdhcmUn
ID0+ICRfU0VSVkVSWydTRVJWRVJfU09GVFdBUkUnXSA/PyBudWxsLAogICAgJ2RvY3VtZW50X3Jv
b3QnID0+ICRfU0VSVkVSWydET0NVTUVOVF9ST09UJ10gPz8gbnVsbCwKXTsKCiR3cE9rID0gJHdw
TG9hZGVkICYmIGRlZmluZWQoJ0FCU1BBVEgnKSAmJiBmdW5jdGlvbl9leGlzdHMoJ2dldF9vcHRp
b24nKTsKaWYgKCEgJHdwT2spIHsKICAgIGVjaG8ganNvbl9lbmNvZGUoJG91dCk7CiAgICBleGl0
Owp9CgppZiAoISBmdW5jdGlvbl9leGlzdHMoJ2dldF9wbHVnaW5zJykpIHsKICAgIHJlcXVpcmVf
b25jZSBBQlNQQVRIIC4gJ3dwLWFkbWluL2luY2x1ZGVzL3BsdWdpbi5waHAnOwp9CgpnbG9iYWwg
JHdwZGI7CmlmICghICR3cGRiIGluc3RhbmNlb2Ygd3BkYikgewogICAgJG91dFsnd29yZHByZXNz
J10gPSB0cnVlOwogICAgJG91dFsnd3BfZXJyb3InXSA9ICd3cGRiX3VuYXZhaWxhYmxlJzsKICAg
IGVjaG8ganNvbl9lbmNvZGUoJG91dCk7CiAgICBleGl0Owp9CgokZGJOYW1lID0gZGVmaW5lZCgn
REJfTkFNRScpID8gREJfTkFNRSA6IG51bGw7CgokcGx1Z2luTGlzdCA9IGdldF9wbHVnaW5zKCk7
CiRwbHVnaW5LZXlzID0gYXJyYXlfZmlsbF9rZXlzKGFycmF5X2tleXMoJHBsdWdpbkxpc3QpLCBb
XSk7CiRhY3RpdmUgPSAoYXJyYXkpIGdldF9vcHRpb24oJ2FjdGl2ZV9wbHVnaW5zJywgW10pOwok
bmV0d29ya0FjdGl2ZSA9IGlzX211bHRpc2l0ZSgpID8gYXJyYXlfa2V5cygoYXJyYXkpIGdldF9z
aXRlX29wdGlvbignYWN0aXZlX3NpdGV3aWRlX3BsdWdpbnMnLCBbXSkpIDogW107CiRwbHVnaW5z
T3V0ID0gW107CmZvcmVhY2ggKCRwbHVnaW5MaXN0IGFzICRmaWxlID0+ICRtZXRhKSB7CiAgICAk
cGx1Z2luc091dFtdID0gWwogICAgICAgICdmaWxlJyA9PiAkZmlsZSwKICAgICAgICAnbmFtZScg
PT4gJG1ldGFbJ05hbWUnXSA/PyAkZmlsZSwKICAgICAgICAndmVyc2lvbicgPT4gJG1ldGFbJ1Zl
cnNpb24nXSA/PyBudWxsLAogICAgICAgICdhY3RpdmUnID0+IGluX2FycmF5KCRmaWxlLCAkYWN0
aXZlLCB0cnVlKSB8fCBpbl9hcnJheSgkZmlsZSwgJG5ldHdvcmtBY3RpdmUsIHRydWUpLAogICAg
XTsKfQp1c29ydCgkcGx1Z2luc091dCwgc3RhdGljIGZ1bmN0aW9uIChhcnJheSAkYSwgYXJyYXkg
JGIpOiBpbnQgewogICAgaWYgKCgkYVsnYWN0aXZlJ10gPz8gZmFsc2UpICE9PSAoJGJbJ2FjdGl2
ZSddID8/IGZhbHNlKSkgewogICAgICAgIHJldHVybiAoJGFbJ2FjdGl2ZSddID8/IGZhbHNlKSA/
IC0xIDogMTsKICAgIH0KCiAgICByZXR1cm4gc3RyY2FzZWNtcCgoc3RyaW5nKSAoJGFbJ25hbWUn
XSA/PyAnJyksIChzdHJpbmcpICgkYlsnbmFtZSddID8/ICcnKSk7Cn0pOwoKJG11ID0gZnVuY3Rp
b25fZXhpc3RzKCdnZXRfbXVfcGx1Z2lucycpID8gZ2V0X211X3BsdWdpbnMoKSA6IFtdOwokbXVM
aXN0ID0gW107CmZvcmVhY2ggKCRtdSBhcyAkZmlsZSA9PiAkbWV0YSkgewogICAgJG11TGlzdFtd
ID0gWwogICAgICAgICdmaWxlJyA9PiAkZmlsZSwKICAgICAgICAnbmFtZScgPT4gJG1ldGFbJ05h
bWUnXSA/PyAkZmlsZSwKICAgICAgICAndmVyc2lvbicgPT4gJG1ldGFbJ1ZlcnNpb24nXSA/PyBu
dWxsLAogICAgXTsKfQoKJHRoZW1lID0gd3BfZ2V0X3RoZW1lKCk7CiRwYXJlbnQgPSAkdGhlbWUt
PnBhcmVudCgpOwoKJHVwZGF0ZU5vdGUgPSAnVXNlcyBXb3JkUHJlc3Mub3JnIHVwZGF0ZSB0cmFu
c2llbnRzOyBtYXkgY29udGFjdCBhcGkud29yZHByZXNzLm9yZyAoc2hvcnQpLiBTZXQgU0lURVNM
RVVUSF9QUk9CRV9TS0lQX1VQREFURV9DSEVDSz0xIHRvIHNraXAgcmVtb3RlIGNoZWNrcy4nOwoK
JHBsdWdpblVwZGF0ZXNPdXQgPSBbXTsKJHRoZW1lVXBkYXRlc091dCA9IFtdOwokY29yZVVwZGF0
ZU91dCA9IG51bGw7Cgokc2tpcFJlbW90ZSA9IGdldGVudignU0lURVNMRVVUSF9QUk9CRV9TS0lQ
X1VQREFURV9DSEVDSycpID09PSAnMScgfHwgZ2V0ZW52KCdTSVRFU0xFVVRIX1BST0JFX1NLSVBf
VVBEQVRFX0NIRUNLJykgPT09ICd0cnVlJzsKCmlmICghICRza2lwUmVtb3RlICYmIGZpbGVfZXhp
c3RzKEFCU1BBVEggLiAnd3AtYWRtaW4vaW5jbHVkZXMvdXBkYXRlLnBocCcpKSB7CiAgICByZXF1
aXJlX29uY2UgQUJTUEFUSCAuICd3cC1hZG1pbi9pbmNsdWRlcy91cGRhdGUucGhwJzsKICAgIGlm
IChmdW5jdGlvbl9leGlzdHMoJ3dwX3VwZGF0ZV9wbHVnaW5zJykpIHsKICAgICAgICBAd3BfdXBk
YXRlX3BsdWdpbnMoKTsKICAgIH0KICAgIGlmIChmdW5jdGlvbl9leGlzdHMoJ3dwX3VwZGF0ZV90
aGVtZXMnKSkgewogICAgICAgIEB3cF91cGRhdGVfdGhlbWVzKCk7CiAgICB9CiAgICBpZiAoZnVu
Y3Rpb25fZXhpc3RzKCd3cF92ZXJzaW9uX2NoZWNrJykpIHsKICAgICAgICBAd3BfdmVyc2lvbl9j
aGVjayhbXSwgdHJ1ZSk7CiAgICB9CgogICAgJHVwUGwgPSBnZXRfc2l0ZV90cmFuc2llbnQoJ3Vw
ZGF0ZV9wbHVnaW5zJyk7CiAgICBpZiAoaXNfb2JqZWN0KCR1cFBsKSAmJiAhIGVtcHR5KCR1cFBs
LT5yZXNwb25zZSkgJiYgaXNfYXJyYXkoJHVwUGwtPnJlc3BvbnNlKSkgewogICAgICAgIGZvcmVh
Y2ggKCR1cFBsLT5yZXNwb25zZSBhcyAkZmlsZSA9PiAkZGF0YSkgewogICAgICAgICAgICAkY3Vy
ID0gJHBsdWdpbkxpc3RbJGZpbGVdWydWZXJzaW9uJ10gPz8gbnVsbDsKICAgICAgICAgICAgJHBs
dWdpblVwZGF0ZXNPdXRbXSA9IFsKICAgICAgICAgICAgICAgICdmaWxlJyA9PiAkZmlsZSwKICAg
ICAgICAgICAgICAgICduYW1lJyA9PiAkcGx1Z2luTGlzdFskZmlsZV1bJ05hbWUnXSA/PyAkZmls
ZSwKICAgICAgICAgICAgICAgICdpbnN0YWxsZWRfdmVyc2lvbicgPT4gJGN1ciwKICAgICAgICAg
ICAgICAgICduZXdfdmVyc2lvbicgPT4gJGRhdGEtPm5ld192ZXJzaW9uID8/IG51bGwsCiAgICAg
ICAgICAgICAgICAncGFja2FnZV9hdmFpbGFibGUnID0+ICEgZW1wdHkoJGRhdGEtPnBhY2thZ2Up
LAogICAgICAgICAgICAgICAgJ3JlcXVpcmVzX3BocCcgPT4gJGRhdGEtPnJlcXVpcmVzX3BocCA/
PyBudWxsLAogICAgICAgICAgICAgICAgJ3JlcXVpcmVzX3dwJyA9PiAkZGF0YS0+cmVxdWlyZXMg
Pz8gbnVsbCwKICAgICAgICAgICAgICAgICd0ZXN0ZWRfd3AnID0+ICRkYXRhLT50ZXN0ZWQgPz8g
bnVsbCwKICAgICAgICAgICAgXTsKICAgICAgICB9CiAgICB9CgogICAgJHVwVGggPSBnZXRfc2l0
ZV90cmFuc2llbnQoJ3VwZGF0ZV90aGVtZXMnKTsKICAgIGlmIChpc19vYmplY3QoJHVwVGgpICYm
ICEgZW1wdHkoJHVwVGgtPnJlc3BvbnNlKSAmJiBpc19hcnJheSgkdXBUaC0+cmVzcG9uc2UpKSB7
CiAgICAgICAgZm9yZWFjaCAoJHVwVGgtPnJlc3BvbnNlIGFzICRzbHVnID0+ICRkYXRhKSB7CiAg
ICAgICAgICAgICR0aGVtZVVwZGF0ZXNPdXRbXSA9IFsKICAgICAgICAgICAgICAgICdzdHlsZXNo
ZWV0JyA9PiAkc2x1ZywKICAgICAgICAgICAgICAgICduZXdfdmVyc2lvbicgPT4gJGRhdGFbJ25l
d192ZXJzaW9uJ10gPz8gbnVsbCwKICAgICAgICAgICAgICAgICdwYWNrYWdlX2F2YWlsYWJsZScg
PT4gISBlbXB0eSgkZGF0YVsncGFja2FnZSddKSwKICAgICAgICAgICAgXTsKICAgICAgICB9CiAg
ICB9CgogICAgJHVwQ29yZSA9IGdldF9zaXRlX3RyYW5zaWVudCgndXBkYXRlX2NvcmUnKTsKICAg
IGlmIChpc19vYmplY3QoJHVwQ29yZSkgJiYgISBlbXB0eSgkdXBDb3JlLT51cGRhdGVzKSAmJiBp
c19hcnJheSgkdXBDb3JlLT51cGRhdGVzKSkgewogICAgICAgICRvZmZlciA9ICR1cENvcmUtPnVw
ZGF0ZXNbMF0gPz8gbnVsbDsKICAgICAgICBpZiAoJG9mZmVyICE9PSBudWxsICYmICEgZW1wdHko
JG9mZmVyLT5yZXNwb25zZSkpIHsKICAgICAgICAgICAgJGNvcmVVcGRhdGVPdXQgPSBbCiAgICAg
ICAgICAgICAgICAnaW5zdGFsbGVkJyA9PiAkR0xPQkFMU1snd3BfdmVyc2lvbiddID8/IG51bGws
CiAgICAgICAgICAgICAgICAnb2ZmZXJfdmVyc2lvbicgPT4gJG9mZmVyLT52ZXJzaW9uID8/IG51
bGwsCiAgICAgICAgICAgICAgICAncmVzcG9uc2VfdHlwZScgPT4gJG9mZmVyLT5yZXNwb25zZSwK
ICAgICAgICAgICAgXTsKICAgICAgICB9CiAgICB9Cn0KCiRob29rU3VtbWFyeSA9IHNpdGVzbGV1
dGhfcHJvYmVfaG9va19zdW1tYXJ5KCRwbHVnaW5LZXlzKTsKJGhlYXZ5SGludHMgPSBzaXRlc2xl
dXRoX3Byb2JlX2hlYXZ5X3BsdWdpbl9oaW50cygkaG9va1N1bW1hcnksICRhY3RpdmUpOwoKJGRi
VmVyc2lvbiA9ICR3cGRiLT5nZXRfdmFyKCdTRUxFQ1QgVkVSU0lPTigpJyk7CgokbXlzcWxWYXJz
V2FudCA9IFsKICAgICdtYXhfY29ubmVjdGlvbnMnLAogICAgJ2lubm9kYl9idWZmZXJfcG9vbF9z
aXplJywKICAgICd0bXBfdGFibGVfc2l6ZScsCiAgICAnbWF4X2hlYXBfdGFibGVfc2l6ZScsCiAg
ICAnaW5ub2RiX2ZsdXNoX2xvZ19hdF90cnhfY29tbWl0JywKICAgICdzbG93X3F1ZXJ5X2xvZycs
CiAgICAnc2xvd19xdWVyeV9sb2dfZmlsZScsCiAgICAnbG9uZ19xdWVyeV90aW1lJywKICAgICd2
ZXJzaW9uX2NvbW1lbnQnLApdOwoKJG15c3FsVmFyaWFibGVzID0gW107CmZvcmVhY2ggKCRteXNx
bFZhcnNXYW50IGFzICRuYW1lKSB7CiAgICAkcm93ID0gJHdwZGItPmdldF9yb3coJHdwZGItPnBy
ZXBhcmUoJ1NIT1cgVkFSSUFCTEVTIExJS0UgJXMnLCAkbmFtZSksIEFSUkFZX0EpOwogICAgaWYg
KCRyb3cgIT09IG51bGwgJiYgaXNzZXQoJHJvd1snVmFsdWUnXSkpIHsKICAgICAgICAkbXlzcWxW
YXJpYWJsZXNbJG5hbWVdID0gJHJvd1snVmFsdWUnXTsKICAgIH0KfQoKJHRhYmxlc091dCA9IFtd
OwppZiAoJGRiTmFtZSAhPT0gbnVsbCkgewogICAgJGxpa2VQcmVmaXggPSBzdHJfcmVwbGFjZSgn
XycsICdcXF8nLCAkd3BkYi0+cHJlZml4KS4nJSc7CgogICAgLyoqIEBwaHBzdGFuLWlnbm9yZS1u
ZXh0LWxpbmUgdW5wcmVwYXJlZF9zcWwgKi8KICAgICR0YWJsZXNPdXQgPSAkd3BkYi0+Z2V0X3Jl
c3VsdHMoCiAgICAgICAgJHdwZGItPnByZXBhcmUoCiAgICAgICAgICAgICJTRUxFQ1QgVEFCTEVf
TkFNRSwgRU5HSU5FLCBUQUJMRV9ST1dTLCBST1VORCgoREFUQV9MRU5HVEgrSU5ERVhfTEVOR1RI
KS8xMDI0LzEwMjQsMikgQVMgc2l6ZV9tYl9hcHByb3gKICAgICAgICAgICBGUk9NIGluZm9ybWF0
aW9uX3NjaGVtYS5UQUJMRVMgV0hFUkUgVEFCTEVfU0NIRU1BPSVzIEFORCBUQUJMRV9OQU1FIExJ
S0UgJXMKICAgICAgICAgICBPUkRFUiBCWSAoREFUQV9MRU5HVEgrSU5ERVhfTEVOR1RIKSBERVND
IExJTUlUIDg1IiwKICAgICAgICAgICAgJGRiTmFtZSwKICAgICAgICAgICAgJGxpa2VQcmVmaXgs
CiAgICAgICAgKSwKICAgICAgICBBUlJBWV9BLAogICAgKSA/OiBbXTsKfQoKJHBvc3RUeXBlcyA9
ICR3cGRiLT5nZXRfcmVzdWx0cygKICAgICJTRUxFQ1QgcG9zdF90eXBlLCBwb3N0X3N0YXR1cywg
Q09VTlQoKikgQVMgY291bnQgRlJPTSB7JHdwZGItPnBvc3RzfSBHUk9VUCBCWSBwb3N0X3R5cGUs
IHBvc3Rfc3RhdHVzIE9SREVSIEJZIGNvdW50IERFU0MgTElNSVQgNjAiLAogICAgQVJSQVlfQSwK
KSA/OiBbXTsKCiRiaWdNZXRhID0gJHdwZGItPmdldF9yZXN1bHRzKAogICAgIlNFTEVDVCBtZXRh
X2tleSwgQ09VTlQoKikgQVMgY3QgRlJPTSB7JHdwZGItPnBvc3RtZXRhfSBHUk9VUCBCWSBtZXRh
X2tleSBPUkRFUiBCWSBjdCBERVNDIExJTUlUIDI1IiwKICAgIEFSUkFZX0EsCikgPzogW107Cgok
YmlnVXNlcm1ldGEgPSBudWxsOwokdGFibGVVc2VybWV0YSA9ICR3cGRiLT5wcmVmaXggLiAndXNl
cm1ldGEnOwokaGFzVW0gPSAoJHdwZGItPmdldF92YXIoJHdwZGItPnByZXBhcmUoJ1NIT1cgVEFC
TEVTIExJS0UgJXMnLCAkdGFibGVVc2VybWV0YSkpID09PSAkdGFibGVVc2VybWV0YSk7CgppZiAo
JGhhc1VtKSB7CiAgICAkYmlnVXNlcm1ldGEgPSAkd3BkYi0+Z2V0X3Jlc3VsdHMoCiAgICAgICAg
IlNFTEVDVCBtZXRhX2tleSwgQ09VTlQoKikgQVMgY3QgRlJPTSB7JHdwZGItPnVzZXJtZXRhfSBH
Uk9VUCBCWSBtZXRhX2tleSBPUkRFUiBCWSBjdCBERVNDIExJTUlUIDIwIiwKICAgICAgICBBUlJB
WV9BLAogICAgKSA/OiBbXTsKfQoKJGF1dG9sb2FkSGVhdnkgPSAkd3BkYi0+Z2V0X3Jlc3VsdHMo
CiAgICAiU0VMRUNUIG9wdGlvbl9uYW1lLCBMRU5HVEgob3B0aW9uX3ZhbHVlKSBBUyBieXRlcyBG
Uk9NIHskd3BkYi0+b3B0aW9uc30KICAgICBXSEVSRSBhdXRvbG9hZD0neWVzJyBPUkRFUiBCWSBM
RU5HVEgob3B0aW9uX3ZhbHVlKSBERVNDIExJTUlUIDMwIiwKICAgIEFSUkFZX0EsCikgPzogW107
CgokZGJTaXplTWIgPSBudWxsOwppZiAoJGRiTmFtZSAhPT0gbnVsbCkgewogICAgJGRiU2l6ZU1i
ID0gJHdwZGItPmdldF92YXIoCiAgICAgICAgJHdwZGItPnByZXBhcmUoCiAgICAgICAgICAgICdT
RUxFQ1QgUk9VTkQoU1VNKGRhdGFfbGVuZ3RoICsgaW5kZXhfbGVuZ3RoKSAvIDEwMjQgLyAxMDI0
LCAyKSBGUk9NIGluZm9ybWF0aW9uX3NjaGVtYS50YWJsZXMgV0hFUkUgdGFibGVfc2NoZW1hID0g
JXMnLAogICAgICAgICAgICAkZGJOYW1lLAogICAgICAgICksCiAgICApOwp9CgokYXV0b2xvYWRP
cHRpb25zID0gKGludCkgJHdwZGItPmdldF92YXIoIlNFTEVDVCBDT1VOVCgqKSBGUk9NIHskd3Bk
Yi0+b3B0aW9uc30gV0hFUkUgYXV0b2xvYWQgPSAneWVzJyIpOwokYXV0b2xvYWRLYiA9ICR3cGRi
LT5nZXRfdmFyKAogICAgIlNFTEVDVCBST1VORChTVU0oQ0hBUl9MRU5HVEgob3B0aW9uX3ZhbHVl
KSkgLyAxMDI0LCAxKSBGUk9NIHskd3BkYi0+b3B0aW9uc30gV0hFUkUgYXV0b2xvYWQgPSAneWVz
JyIsCik7CiR0cmFuc2llbnRSb3dzID0gKGludCkgJHdwZGItPmdldF92YXIoCiAgICAiU0VMRUNU
IENPVU5UKCopIEZST00geyR3cGRiLT5vcHRpb25zfSBXSEVSRSBvcHRpb25fbmFtZSBMSUtFICdf
dHJhbnNpZW50XyUnIE9SIG9wdGlvbl9uYW1lIExJS0UgJ19zaXRlX3RyYW5zaWVudF8lJyIsCik7
CiRyZXZpc2lvbkNvdW50ID0gKGludCkgJHdwZGItPmdldF92YXIoJHdwZGItPnByZXBhcmUoCiAg
ICAnU0VMRUNUIENPVU5UKCopIEZST00geyR3cGRiLT5wb3N0c30gV0hFUkUgcG9zdF90eXBlID0g
JXMnLAogICAgJ3JldmlzaW9uJywKKSk7CgokcG9zdFN0YXR1c1Jvd3MgPSAkd3BkYi0+Z2V0X3Jl
c3VsdHMoCiAgICAiU0VMRUNUIHBvc3Rfc3RhdHVzLCBDT1VOVCgqKSBBUyBjIEZST00geyR3cGRi
LT5wb3N0c30gV0hFUkUgcG9zdF90eXBlID0gJ3Bvc3QnIEdST1VQIEJZIHBvc3Rfc3RhdHVzIiwK
ICAgIEFSUkFZX0EsCikgPzogW107CgokY3Jvbkhvb2tzID0gW107CmlmIChmdW5jdGlvbl9leGlz
dHMoJ19nZXRfY3Jvbl9hcnJheScpKSB7CiAgICAkY3JvbiA9IF9nZXRfY3Jvbl9hcnJheSgpOwog
ICAgaWYgKGlzX2FycmF5KCRjcm9uKSkgewogICAgICAgIGZvcmVhY2ggKCRjcm9uIGFzICR0cyA9
PiAkaG9va3MpIHsKICAgICAgICAgICAgaWYgKCEgaXNfYXJyYXkoJGhvb2tzKSkgewogICAgICAg
ICAgICAgICAgY29udGludWU7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgZm9yZWFjaCAoYXJy
YXlfa2V5cygkaG9va3MpIGFzICRob29rKSB7CiAgICAgICAgICAgICAgICAkY3Jvbkhvb2tzWyRo
b29rXSA9ICgkY3Jvbkhvb2tzWyRob29rXSA/PyAwKSArIDE7CiAgICAgICAgICAgIH0KICAgICAg
ICB9CiAgICAgICAgYXJzb3J0KCRjcm9uSG9va3MpOwogICAgICAgICRjcm9uSG9va3MgPSBhcnJh
eV9zbGljZSgkY3Jvbkhvb2tzLCAwLCAzMCwgdHJ1ZSk7CiAgICB9Cn0KCiRvcGNhY2hlQnJpZWYg
PSBudWxsOwppZiAoZnVuY3Rpb25fZXhpc3RzKCdvcGNhY2hlX2dldF9zdGF0dXMnKSkgewogICAg
JHN0ID0gb3BjYWNoZV9nZXRfc3RhdHVzKGZhbHNlKTsKICAgIGlmIChpc19hcnJheSgkc3QpKSB7
CiAgICAgICAgJG9wY2FjaGVCcmllZiA9IFsKICAgICAgICAgICAgJ2VuYWJsZWQnID0+ICRzdFsn
b3BjYWNoZV9lbmFibGVkJ10gPz8gbnVsbCwKICAgICAgICAgICAgJ2NhY2hlX2Z1bGwnID0+ICRz
dFsnY2FjaGVfZnVsbCddID8/IG51bGwsCiAgICAgICAgICAgICdtZW1vcnlfdXNhZ2UnID0+IGlz
c2V0KCRzdFsnbWVtb3J5X3VzYWdlJ10pICYmIGlzX2FycmF5KCRzdFsnbWVtb3J5X3VzYWdlJ10p
ID8KICAgICAgICAgICAgICAgIHJvdW5kKCgkc3RbJ21lbW9yeV91c2FnZSddWyd1c2VkX21lbW9y
eSddID8/IDApIC8gMTA0ODU3NiwgMikgOiBudWxsLAogICAgICAgIF07CiAgICB9Cn0KCiR3cGRi
TnVtUXVlcmllcyA9IG51bGw7CmlmIChpc3NldCgkd3BkYi0+bnVtX3F1ZXJpZXMpKSB7CiAgICAk
d3BkYk51bVF1ZXJpZXMgPSAkd3BkYi0+bnVtX3F1ZXJpZXM7Cn0KCiRvdXRbJ3dvcmRwcmVzcydd
ID0gdHJ1ZTsKJG91dFsnd3BfdmVyc2lvbiddID0gJEdMT0JBTFNbJ3dwX3ZlcnNpb24nXSA/PyBu
dWxsOwokb3V0Wydpc19tdWx0aXNpdGUnXSA9IGlzX211bHRpc2l0ZSgpOwokb3V0WydwbHVnaW5z
J10gPSBhcnJheV9zbGljZSgkcGx1Z2luc091dCwgMCwgMTIwKTsKJG91dFsncGx1Z2luX3VwZGF0
ZXNfcGVuZGluZyddID0gJHBsdWdpblVwZGF0ZXNPdXQ7CiRvdXRbJ3RoZW1lX3VwZGF0ZXNfcGVu
ZGluZyddID0gJHRoZW1lVXBkYXRlc091dDsKJG91dFsnY29yZV91cGRhdGVfcGVuZGluZyddID0g
JGNvcmVVcGRhdGVPdXQ7CiRvdXRbJ3VwZGF0ZXNfbWV0YSddID0gWydub3RlJyA9PiAkdXBkYXRl
Tm90ZSwgJ3JlbW90ZV9jaGVja3Nfc2tpcHBlZCcgPT4gJHNraXBSZW1vdGVdOwoKJG91dFsnbXVz
dF91c2VfcGx1Z2lucyddID0gJG11TGlzdDsKJG91dFsndGhlbWUnXSA9IFsKICAgICduYW1lJyA9
PiAkdGhlbWUtPmdldCgnTmFtZScpLAogICAgJ3ZlcnNpb24nID0+ICR0aGVtZS0+Z2V0KCdWZXJz
aW9uJyksCiAgICAnc3R5bGVzaGVldCcgPT4gJHRoZW1lLT5nZXRfc3R5bGVzaGVldCgpLAogICAg
J3RlbXBsYXRlJyA9PiAkdGhlbWUtPmdldF90ZW1wbGF0ZSgpLAogICAgJ3BhcmVudCcgPT4gJHBh
cmVudCA/ICRwYXJlbnQtPmdldCgnTmFtZScpIDogbnVsbCwKXTsKJG91dFsnZGF0YWJhc2UnXSA9
IFsKICAgICdteXNxbF92ZXJzaW9uJyA9PiBpc19zdHJpbmcoJGRiVmVyc2lvbikgPyAkZGJWZXJz
aW9uIDogbnVsbCwKICAgICdzY2hlbWFfbmFtZScgPT4gJGRiTmFtZSwKICAgICdhcHByb3hfc2No
ZW1hX21iJyA9PiBpc19zdHJpbmcoJGRiU2l6ZU1iKSB8fCBpc19mbG9hdCgkZGJTaXplTWIpID8g
KGZsb2F0KSAkZGJTaXplTWIgOiBudWxsLAogICAgJ215c3FsX3ZhcmlhYmxlcycgPT4gJG15c3Fs
VmFyaWFibGVzLAogICAgJ25vdGVfdGFibGVfcm93cycgPT4gJ1RBQkxFX1JPV1MgaXMgYXBwcm94
aW1hdGUgZm9yIElubm9EQicsCiAgICAndGFibGVzX3RvcF9ieV9zaXplJyA9PiAkdGFibGVzT3V0
LAogICAgJ3Bvc3RtZXRhX2tleXNfdG9wJyA9PiAkYmlnTWV0YSwKICAgICd1c2VybWV0YV9rZXlz
X3RvcCcgPT4gJGJpZ1VzZXJtZXRhLAogICAgJ3Bvc3RzX2J5X3R5cGVfc3RhdHVzJyA9PiAkcG9z
dFR5cGVzLAogICAgJ2F1dG9sb2FkZWRfb3B0aW9uc19jb3VudCcgPT4gJGF1dG9sb2FkT3B0aW9u
cywKICAgICdhdXRvbG9hZGVkX29wdGlvbnNfa2InID0+IGlzX3N0cmluZygkYXV0b2xvYWRLYikg
fHwgaXNfZmxvYXQoJGF1dG9sb2FkS2IpID8gKGZsb2F0KSAkYXV0b2xvYWRLYiA6IG51bGwsCiAg
ICAnYXV0b2xvYWRlZF9vcHRpb25zX2xhcmdlc3RfYnlfYnl0ZXMnID0+ICRhdXRvbG9hZEhlYXZ5
LAogICAgJ3RyYW5zaWVudF9vcHRpb25fcm93cycgPT4gJHRyYW5zaWVudFJvd3MsCiAgICAncmV2
aXNpb25fcm93X2NvdW50JyA9PiAkcmV2aXNpb25Db3VudCwKICAgICdwb3N0c19ieV9zdGF0dXMn
ID0+ICRwb3N0U3RhdHVzUm93cywKICAgICd3cGRiX251bV9xdWVyaWVzX3RoaXNfcmVxdWVzdCcg
PT4gJHdwZGJOdW1RdWVyaWVzLAogICAgJ3NhdmVxdWVyaWVzX2NvbnN0YW50JyA9PiBkZWZpbmVk
KCdTQVZFUVVFUklFUycpICYmIFNBVkVRVUVSSUVTLApdOwoKJG91dFsnaG9va3MnXSA9IFsKICAg
ICdzdW1tYXJ5X2J5X3RhZycgPT4gJGhvb2tTdW1tYXJ5LAogICAgJ2hlYXZ5X3BsdWdpbl9oaW50
cycgPT4gJGhlYXZ5SGludHMsCiAgICAnbm90ZScgPT4gJ0NhbGxiYWNrIGNvdW50cyBwZXIgaG9v
ayBhcmUgbm90IHdhbGwtY2xvY2sgdGltZS4gVXNlIFF1ZXJ5IE1vbml0b3Igb3IgWGRlYnVnIGZv
ciByZWFsIHRyYWNpbmcuJywKXTsKCiRvdXRbJ2Nyb24nXSA9IFsKICAgICdzY2hlZHVsZWRfaG9v
a19jb3VudHMnID0+ICRjcm9uSG9va3MsCl07Cgokb3V0WydjYWNoaW5nJ10gPSBbCiAgICAndXNp
bmdfZXh0X29iamVjdF9jYWNoZScgPT4gd3BfdXNpbmdfZXh0X29iamVjdF9jYWNoZSgpLAogICAg
J29wY2FjaGUnID0+ICRvcGNhY2hlQnJpZWYsCl07Cgokb3V0Wydjb25zdGFudHNfc2FtcGxlJ10g
PSBbCiAgICAnV1BfREVCVUcnID0+IGRlZmluZWQoJ1dQX0RFQlVHJykgPyAoYm9vbCkgV1BfREVC
VUcgOiBmYWxzZSwKICAgICdXUF9ERUJVR19MT0cnID0+IGRlZmluZWQoJ1dQX0RFQlVHX0xPRycp
ID8gKGJvb2wpIFdQX0RFQlVHX0xPRyA6IGZhbHNlLAogICAgJ1NDUklQVF9ERUJVRycgPT4gZGVm
aW5lZCgnU0NSSVBUX0RFQlVHJykgPyAoYm9vbCkgU0NSSVBUX0RFQlVHIDogZmFsc2UsCiAgICAn
Q09NUFJFU1NfQ1NTJyA9PiBkZWZpbmVkKCdDT01QUkVTU19DU1MnKSA/IChib29sKSBDT01QUkVT
U19DU1MgOiBmYWxzZSwKICAgICdDT01QUkVTU19TQ1JJUFRTJyA9PiBkZWZpbmVkKCdDT01QUkVT
U19TQ1JJUFRTJykgPyAoYm9vbCkgQ09NUFJFU1NfU0NSSVBUUyA6IGZhbHNlLAogICAgJ0NPTkNB
VEVOQVRFX1NDUklQVFMnID0+IGRlZmluZWQoJ0NPTkNBVEVOQVRFX1NDUklQVFMnKSA/IChib29s
KSBDT05DQVRFTkFURV9TQ1JJUFRTIDogZmFsc2UsCl07CgplY2hvIGpzb25fZW5jb2RlKCRvdXQs
IEpTT05fVU5FU0NBUEVEX1NMQVNIRVMgfCBKU09OX0lOVkFMSURfVVRGOF9TVUJTVElUVVRFKTsK

PROBE_B64_BLOCK
  if [[ ! -s "$PROBE_PATH" ]]; then
    echo "Error: could not decode embedded probe (need openssl base64). Place sitesleuth-probe.php next to this script." >&2
    rm -f "$PROBE_PATH"
    exit 1
  fi
  return 0
}


build_probe_url_from_base() {
  local s="${1:-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  [[ -z "$s" ]] && echo "" && return
  [[ ! "$s" =~ ^https?:// ]] && s="https://${s}"
  while [[ "$s" == */ ]]; do s="${s%/}"; done
  printf '%s/%s\n' "$s" "$PROBE_FILE"
}

prompt_or_resolve_probe_url() {
  if [[ -n "$DOMAIN_FLAG" ]]; then
    build_probe_url_from_base "$DOMAIN_FLAG"
    return
  fi
  if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
    echo ""
    return
  fi

  echo "" >&2
  echo "HTTPS base URL for this WordPress folder (shown in probe URL below; no trailing slash)." >&2
  echo "Examples: https://www.example.com — or https://www.example.com/shop — or just: example.com" >&2
  echo "Leave empty if you prefer to substitute the hostname yourself." >&2

  local raw=""
  if [[ -r /dev/tty ]]; then
    read -r -p "Probe base URL: " raw </dev/tty || raw=""
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"
  else
    echo "No readable /dev/tty (often when stdin is piped). Use --domain=https://..., or rerun on a SSH session." >&2
    echo "(Tip: bash -lc \"curl -fsSL … | bash -s -- --domain=https://example.com\")" >&2
  fi
  build_probe_url_from_base "$raw"
}

insert_wp_config_block() {
  local tmp snippet line
  snippet=$(mktemp)
  {
    echo ""
    echo "/** SiteSleuth probe — added by install-sitesleuth-probe.sh; rotate after audits */"
    echo "if (!defined('SITESLEUTH_PROBE_SECRET')) {"
    echo "	define('SITESLEUTH_PROBE_SECRET', '${SECRET}');"
    echo "}"
  } >"$snippet"

  line="$(grep -nE "require_once[[:space:]]+ABSPATH[[:space:]]*\.[[:space:]]*['\"]wp-settings\.php['\"]" "$WP_CONFIG" | head -1 | cut -d: -f1 || true)"
  if [[ -z "${line:-}" ]]; then
    line="$(grep -nF "That's all, stop editing" "$WP_CONFIG" | head -1 | cut -d: -f1 || true)"
  fi
  if [[ -z "${line:-}" ]]; then
    echo "Error: could not find a safe insertion point in wp-config.php (wp-settings.php require or 'That's all' comment)." >&2
    rm -f "$snippet"
    exit 1
  fi

  tmp="$(mktemp)"
  head -n "$((line - 1))" "$WP_CONFIG" >"$tmp"
  cat "$snippet" >>"$tmp"
  tail -n "+${line}" "$WP_CONFIG" >>"$tmp"
  rm -f "$snippet"
  mv "$tmp" "$WP_CONFIG"
}

# --- main ---

echo "WordPress root: $ROOT"

NEED_WP_PATCH=1
if php_contains_sitesleuth_marker; then
  NEED_WP_PATCH=0
  echo "wp-config.php already contains the SiteSleuth installer block — will not modify wp-config."
elif wp_config_has_secret_define; then
  NEED_WP_PATCH=0
  echo "wp-config.php already defines SITESLEUTH_PROBE_SECRET — will not modify wp-config."
fi

SECRET=""
if [[ "$NEED_WP_PATCH" -eq 1 ]]; then
  if [[ -n "$CUSTOM_SECRET" ]]; then
    if [[ ${#CUSTOM_SECRET} -lt 16 ]]; then
      echo "Error: --secret must be at least 16 characters (SiteSleuth UI enforces the same)." >&2
      exit 1
    fi
    SECRET="$CUSTOM_SECRET"
  else
    if ! command -v openssl >/dev/null 2>&1; then
      echo "Error: openssl not found; install it or pass --secret=..." >&2
      exit 1
    fi
    SECRET="$(openssl rand -hex 32)"
  fi
  if [[ "$SECRET" == *"'"* ]]; then
    echo "Error: secret must not contain single quotes (use hex/alphanumeric)." >&2
    exit 1
  fi
elif [[ -n "$CUSTOM_SECRET" ]]; then
  echo "Note: --secret ignored because wp-config.php already defines the probe secret."
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[dry-run] Would write: $PROBE_PATH"
  if [[ "$NEED_WP_PATCH" -eq 1 ]]; then
    echo "[dry-run] Would insert SITESLEUTH_PROBE_SECRET into wp-config.php"
    echo "[dry-run] Secret would be: ${SECRET:-<generated>}"
  else
    echo "[dry-run] Would skip wp-config (already configured)"
  fi
  exit 0
fi

echo "Writing ${PROBE_FILE}..."
install_sitesleuth_probe_php
chmod 644 "$PROBE_PATH" || true

if [[ "$NEED_WP_PATCH" -eq 1 ]]; then
  backup="${WP_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
  echo "Backing up wp-config.php to ${backup}"
  cp -a "$WP_CONFIG" "$backup"
  echo "Inserting SITESLEUTH_PROBE_SECRET into wp-config.php..."
  insert_wp_config_block
fi

PROBE_FULL_URL="$(prompt_or_resolve_probe_url)"
if [[ -z "$PROBE_FULL_URL" ]]; then
  URL_LINE="https://YOUR-DOMAIN/${PROBE_FILE}"
  CURL_SAMPLE="curl -sS -o /dev/null -w '%{http_code}\\n' -X POST \"${URL_LINE}\""
else
  URL_LINE="$PROBE_FULL_URL"
  CURL_SAMPLE="curl -sS -o /dev/null -w '%{http_code}\\n' -X POST \"${URL_LINE}\""
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Done. Add this to your SiteSleuth case (Server probe):"
echo ""
echo "  Probe URL:  ${URL_LINE}"
if [[ -n "$SECRET" ]]; then
  echo "  Secret:     ${SECRET}"
else
  echo "  Secret:     (copy the value of SITESLEUTH_PROBE_SECRET from wp-config.php)"
fi
echo ""
echo "Quick check (expects HTTP 401 without header — proves file is reachable):"
echo "  ${CURL_SAMPLE}"
echo ""
echo "Remove ${PROBE_FILE} and the wp-config block when the audit is finished."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
