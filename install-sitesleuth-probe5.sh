#!/usr/bin/env bash
# Install SiteSleuth probe by downloading sitesleuth-probe.php from GitHub raw (no embedded base64).
# Ideal for: curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/REF/customer-probe/install-sitesleuth-probe-from-github.sh | bash -s -- --force --domain=https://example.com
#
# Usage (run from WordPress root or pass path):
#   bash install-sitesleuth-probe-from-github.sh
#   bash install-sitesleuth-probe-from-github.sh /path/to/public_html
#
# GitHub source (override any):
#   SITESLEUTH_PROBE_RAW_URL   Full URL to raw PHP (highest priority)
#   SITESLEUTH_GITHUB_REPO     default: jahanzaibakhan/sitesleuth
#   SITESLEUTH_GITHUB_REF      branch/tag/commit, default: main
#   SITESLEUTH_GITHUB_PATH     path in repo, default: customer-probe/sitesleuth-probe.php
#
# Options (same style as install-sitesleuth-probe.sh):
#   --dry-run          Print actions only
#   --secret=VALUE     min 16 chars; default random hex
#   --domain=BASE      HTTPS base for printed probe URL
#   -d BASE            same as --domain=
#   --non-interactive|-y
#   --force            Overwrite existing sitesleuth-probe.php
#   -h, --help
#
# Requires: curl, openssl (unless --secret passed), grep, sed (GNU preferred for wp-config tooling elsewhere)

set -euo pipefail

DRY_RUN=0
FORCE_PHP=0
NON_INTERACTIVE=0
CUSTOM_SECRET=""
DOMAIN_FLAG=""
ROOT=""
PROBE_FILE="sitesleuth-probe.php"

# --- GitHub defaults (fork: set env or fork this script) ---
: "${SITESLEUTH_GITHUB_REPO:=jahanzaibakhan/sitesleuth}"
: "${SITESLEUTH_GITHUB_REF:=main}"
: "${SITESLEUTH_GITHUB_PATH:=customer-probe/sitesleuth-probe.php}"

DEFAULT_RAW="https://raw.githubusercontent.com/${SITESLEUTH_GITHUB_REPO}/${SITESLEUTH_GITHUB_REF}/${SITESLEUTH_GITHUB_PATH}"
PROBE_DOWNLOAD_URL="${SITESLEUTH_PROBE_RAW_URL:-$DEFAULT_RAW}"

usage() {
  sed -n '2,34p' "$0"
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
  echo "Run this script from the WordPress root." >&2
  exit 1
fi

if [[ ! -f "$WP_LOAD" ]]; then
  echo "Warning: wp-load.php not found — is this the correct WordPress root?" >&2
fi

if [[ -f "$PROBE_PATH" && "$FORCE_PHP" -eq 0 ]]; then
  echo "Error: ${PROBE_FILE} already exists. Use --force to overwrite." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl is required to download from GitHub." >&2
  exit 1
fi

php_contains_sitesleuth_marker() {
  grep -q 'SiteSleuth probe — added' "$WP_CONFIG" 2>/dev/null
}

wp_config_has_secret_define() {
  grep -qE "define\s*\(\s*['\"]SITESLEUTH_PROBE_SECRET['\"]" "$WP_CONFIG" 2>/dev/null
}

install_sitesleuth_probe_from_github() {
  local tmp
  tmp="$(mktemp)"
  echo "Downloading probe from:" >&2
  echo "  ${PROBE_DOWNLOAD_URL}" >&2
  if ! curl -fsSL --connect-timeout 20 --max-time 120 "$PROBE_DOWNLOAD_URL" -o "$tmp"; then
    rm -f "$tmp"
    echo "Error: curl failed. Check URL, branch (SITESLEUTH_GITHUB_REF), repo, or set SITESLEUTH_PROBE_RAW_URL." >&2
    exit 1
  fi
  if ! grep -q '<?php' "$tmp" || ! grep -q 'SiteSleuth' "$tmp"; then
    rm -f "$tmp"
    echo "Error: download does not look like sitesleuth-probe.php (missing <?php or marker)." >&2
    exit 1
  fi
  mv "$tmp" "$PROBE_PATH"
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
  echo "HTTPS base URL for probe (no trailing slash). Leave empty to use YOUR-DOMAIN placeholder." >&2
  local raw=""
  if [[ -r /dev/tty ]]; then
    read -r -p "Probe base URL: " raw </dev/tty || raw=""
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"
  else
    echo "No /dev/tty — use --domain=https://... when piping this script." >&2
  fi
  build_probe_url_from_base "$raw"
}

insert_wp_config_block() {
  local tmp snippet line
  snippet=$(mktemp)
  {
    echo ""
    echo "/** SiteSleuth probe — added by install-sitesleuth-probe-from-github.sh; rotate after audits */"
    echo "if (!defined('SITESLEUTH_PROBE_SECRET')) {"
    echo "	define('SITESLEUTH_PROBE_SECRET', '${SECRET}');"
    echo "}"
  } >"$snippet"

  line="$(grep -nE "require_once[[:space:]]+ABSPATH[[:space:]]*\.[[:space:]]*['\"]wp-settings\.php['\"]" "$WP_CONFIG" | head -1 | cut -d: -f1 || true)"
  if [[ -z "${line:-}" ]]; then
    line="$(grep -nF "That's all, stop editing" "$WP_CONFIG" | head -1 | cut -d: -f1 || true)"
  fi
  if [[ -z "${line:-}" ]]; then
    echo "Error: could not find wp-settings.php require or 'That's all' in wp-config.php." >&2
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

echo "WordPress root: $ROOT"

NEED_WP_PATCH=1
if php_contains_sitesleuth_marker; then
  NEED_WP_PATCH=0
  echo "wp-config.php already contains a SiteSleuth installer block — will not modify wp-config."
elif wp_config_has_secret_define; then
  NEED_WP_PATCH=0
  echo "wp-config.php already defines SITESLEUTH_PROBE_SECRET — will not modify wp-config."
fi

SECRET=""
if [[ "$NEED_WP_PATCH" -eq 1 ]]; then
  if [[ -n "$CUSTOM_SECRET" ]]; then
    if [[ ${#CUSTOM_SECRET} -lt 16 ]]; then
      echo "Error: --secret must be at least 16 characters." >&2
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
    echo "Error: secret must not contain single quotes." >&2
    exit 1
  fi
elif [[ -n "$CUSTOM_SECRET" ]]; then
  echo "Note: --secret ignored (wp-config already has probe secret)."
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[dry-run] Would download: ${PROBE_DOWNLOAD_URL}"
  echo "[dry-run] Would write: $PROBE_PATH"
  if [[ "$NEED_WP_PATCH" -eq 1 ]]; then
    echo "[dry-run] Would insert SITESLEUTH_PROBE_SECRET (${SECRET:+set})"
  fi
  exit 0
fi

echo "Writing ${PROBE_FILE}..."
install_sitesleuth_probe_from_github
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
else
  URL_LINE="$PROBE_FULL_URL"
fi
CURL_SAMPLE="curl -sS -o /dev/null -w '%{http_code}\\n' -X POST \"${URL_LINE}\""

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Done (GitHub-sourced probe). Add to SiteSleuth → Server probe:"
echo ""
echo "  Probe URL:  ${URL_LINE}"
if [[ -n "$SECRET" ]]; then
  echo "  Secret:     ${SECRET}"
else
  echo "  Secret:     (copy SITESLEUTH_PROBE_SECRET from wp-config.php)"
fi
echo ""
echo "Source was: ${PROBE_DOWNLOAD_URL}"
echo ""
echo "Quick check (expects 401 without X-SiteSleuth-Secret):"
echo "  ${CURL_SAMPLE}"
echo ""
echo "Remove ${PROBE_FILE} and wp-config block when the audit ends."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
