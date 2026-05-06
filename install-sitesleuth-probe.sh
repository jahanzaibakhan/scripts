<?php
/**
 * SiteSleuth customer probe — read-only WordPress / PHP / DB snapshot for remote diagnostics.
 *
 * Install:
 * - Easiest: copy `install-sitesleuth-probe.sh` into the WordPress root and run `bash install-sitesleuth-probe.sh`, or manually:
 * 1. Place in web root (same folder as wp-load.php), e.g. https://example.com/sitesleuth-probe.php
 * 2. In wp-config.php (before wp-settings.php require): define('SITESLEUTH_PROBE_SECRET', 'long-random-shared-secret');
 * 3. In SiteSleuth, set case "Server probe URL" to that HTTPS URL and paste the same secret.
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
