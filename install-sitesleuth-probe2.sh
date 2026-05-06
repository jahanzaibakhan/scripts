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

write_probe_php() {
  cat << 'PROBE_PHP_EOF'
<?php
/**
 * SiteSleuth customer probe — read-only WordPress / PHP / DB snapshot for remote diagnostics.
 *
 * Install:
 * 1. Copy this file to the site's web root (same folder as wp-load.php), e.g. https://example.com/sitesleuth-probe.php
 * 2. In wp-config.php (above "That's all, stop editing!"):
 *    define('SITESLEUTH_PROBE_SECRET', 'long-random-shared-secret');
 * 3. In SiteSleuth, set case "Server probe URL" to that full HTTPS URL and paste the same secret.
 *
 * Security: HTTPS only in production; rotate the secret after investigations; remove the file when done.
 */
declare(strict_types=1);

header('Content-Type: application/json; charset=utf-8');

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    http_response_code(405);
    echo json_encode(['ok' => false, 'error' => 'method_not_allowed']);
    exit;
}

$provided = isset($_SERVER['HTTP_X_SITESLEUTH_SECRET']) ? (string) $_SERVER['HTTP_X_SITESLEUTH_SECRET'] : '';
if ($provided === '') {
    http_response_code(401);
    echo json_encode(['ok' => false, 'error' => 'missing_secret']);
    exit;
}

$wpLoad = __DIR__ . '/wp-load.php';
$wpLoaded = is_readable($wpLoad);
if ($wpLoaded) {
    require_once $wpLoad;
}

$expected = '';
if (defined('SITESLEUTH_PROBE_SECRET')) {
    $expected = (string) constant('SITESLEUTH_PROBE_SECRET');
} else {
    $envSecret = getenv('SITESLEUTH_PROBE_SECRET');
    if (is_string($envSecret) && $envSecret !== '') {
        $expected = $envSecret;
    }
}

if ($expected === '') {
    http_response_code(503);
    echo json_encode([
        'ok' => false,
        'error' => 'probe_not_configured',
        'hint' => 'Define SITESLEUTH_PROBE_SECRET in wp-config.php, or set the SITESLEUTH_PROBE_SECRET environment variable for non-WordPress PHP.',
    ]);
    exit;
}

if (!hash_equals($expected, $provided)) {
    http_response_code(403);
    echo json_encode(['ok' => false, 'error' => 'forbidden']);
    exit;
}

$out = [
    'ok' => true,
    'probe_version' => 1,
    'php_version' => PHP_VERSION,
    'memory_limit' => ini_get('memory_limit') ?: null,
    'max_execution_time' => ini_get('max_execution_time') ?: null,
    'server_software' => $_SERVER['SERVER_SOFTWARE'] ?? null,
    'document_root' => $_SERVER['DOCUMENT_ROOT'] ?? null,
    'wordpress' => false,
];

$wpOk = $wpLoaded && defined('ABSPATH') && function_exists('get_option');
if (!$wpOk) {
    echo json_encode($out);
    exit;
}

if (!function_exists('get_plugins')) {
    require_once ABSPATH . 'wp-admin/includes/plugin.php';
}

global $wpdb;
if (!$wpdb instanceof wpdb) {
    $out['wordpress'] = true;
    $out['wp_error'] = 'wpdb_unavailable';
    echo json_encode($out);
    exit;
}

$active = (array) get_option('active_plugins', []);
$networkActive = is_multisite() ? array_keys((array) get_site_option('active_sitewide_plugins', [])) : [];
$plugins = get_plugins();
$rows = [];
foreach ($plugins as $file => $meta) {
    $rows[] = [
        'file' => $file,
        'name' => $meta['Name'] ?? $file,
        'version' => $meta['Version'] ?? null,
        'active' => in_array($file, $active, true) || in_array($file, $networkActive, true),
    ];
}
usort($rows, static function (array $a, array $b): int {
    if ($a['active'] !== $b['active']) {
        return $a['active'] ? -1 : 1;
    }
    return strcasecmp((string) $a['name'], (string) $b['name']);
});

$mu = function_exists('get_mu_plugins') ? get_mu_plugins() : [];
$muList = [];
foreach ($mu as $file => $meta) {
    $muList[] = [
        'file' => $file,
        'name' => $meta['Name'] ?? $file,
        'version' => $meta['Version'] ?? null,
    ];
}

$theme = wp_get_theme();
$parent = $theme->parent();
$dbVersion = $wpdb->get_var('SELECT VERSION()');

$autoloadOptions = (int) $wpdb->get_var("SELECT COUNT(*) FROM {$wpdb->options} WHERE autoload = 'yes'");
$autoloadKb = $wpdb->get_var("SELECT ROUND(SUM(CHAR_LENGTH(option_value)) / 1024, 1) FROM {$wpdb->options} WHERE autoload = 'yes'");
$transientRows = (int) $wpdb->get_var(
    "SELECT COUNT(*) FROM {$wpdb->options} WHERE option_name LIKE '_transient_%' OR option_name LIKE '_site_transient_%'",
);
$revisionCount = (int) $wpdb->get_var($wpdb->prepare("SELECT COUNT(*) FROM {$wpdb->posts} WHERE post_type = %s", 'revision'));

$postStatusRows = $wpdb->get_results(
    "SELECT post_status, COUNT(*) AS c FROM {$wpdb->posts} WHERE post_type = 'post' GROUP BY post_status",
    ARRAY_A,
) ?: [];

$dbSizeMb = null;
$dbName = defined('DB_NAME') ? DB_NAME : null;
if ($dbName !== null) {
    $dbSizeMb = $wpdb->get_var(
        $wpdb->prepare(
            'SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) FROM information_schema.tables WHERE table_schema = %s',
            $dbName,
        ),
    );
}

$out['wordpress'] = true;
$out['wp_version'] = $GLOBALS['wp_version'] ?? null;
$out['is_multisite'] = is_multisite();
$out['plugins'] = $rows;
$out['must_use_plugins'] = $muList;
$out['theme'] = [
    'name' => $theme->get('Name'),
    'version' => $theme->get('Version'),
    'stylesheet' => $theme->get_stylesheet(),
    'template' => $theme->get_template(),
    'parent' => $parent ? $parent->get('Name') : null,
];
$out['database'] = [
    'mysql_version' => is_string($dbVersion) ? $dbVersion : null,
    'approx_schema_mb' => is_string($dbSizeMb) || is_float($dbSizeMb) ? (float) $dbSizeMb : null,
    'autoloaded_options_count' => $autoloadOptions,
    'autoloaded_options_kb' => is_string($autoloadKb) || is_float($autoloadKb) ? (float) $autoloadKb : null,
    'transient_option_rows' => $transientRows,
    'revision_row_count' => $revisionCount,
    'posts_by_status' => $postStatusRows,
];
$out['caching'] = [
    'using_ext_object_cache' => wp_using_ext_object_cache(),
];
$out['constants_sample'] = [
    'WP_DEBUG' => defined('WP_DEBUG') ? (bool) WP_DEBUG : false,
    'WP_DEBUG_LOG' => defined('WP_DEBUG_LOG') ? (bool) WP_DEBUG_LOG : false,
    'SCRIPT_DEBUG' => defined('SCRIPT_DEBUG') ? (bool) SCRIPT_DEBUG : false,
    'COMPRESS_CSS' => defined('COMPRESS_CSS') ? (bool) COMPRESS_CSS : false,
    'COMPRESS_SCRIPTS' => defined('COMPRESS_SCRIPTS') ? (bool) COMPRESS_SCRIPTS : false,
    'CONCATENATE_SCRIPTS' => defined('CONCATENATE_SCRIPTS') ? (bool) CONCATENATE_SCRIPTS : false,
];

echo json_encode($out);
PROBE_PHP_EOF
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
write_probe_php >"$PROBE_PATH"
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
