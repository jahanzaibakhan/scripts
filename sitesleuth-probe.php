<?php
/**
 * SiteSleuth customer probe — read-only WordPress / PHP / DB / hooks snapshot.
 *
 * probe_version increments when payload shape grows; keep installer script in sync.
 *
 * No declare(strict_types): WordPress core/plugin callbacks pass loose types; strict mode can fatal the probe.
 */

/**
 * Reflect a WP hook callable to a declaring file path, if possible.
 *
 * @param mixed $callback
 */
function sitesleuth_probe_callback_file($callback): ?string {
    try {
        if ($callback instanceof Closure) {
            $r = new ReflectionFunction($callback);
            return wp_normalize_path($r->getFileName());
        }
        if (is_string($callback)) {
            if (strpos($callback, '::') !== false) {
                [$cls, $meth] = explode('::', $callback, 2);
                if (class_exists($cls)) {
                    $mr = new ReflectionMethod($cls, $meth);

                    return wp_normalize_path($mr->getFileName());
                }
            }
            if (function_exists($callback)) {
                $r = new ReflectionFunction($callback);

                return wp_normalize_path($r->getFileName());
            }

            return null;
        }
        if (!is_array($callback) || count($callback) !== 2) {
            return null;
        }
        [$a, $b] = $callback;
        if (is_object($a) && is_string($b)) {
            $mr = new ReflectionMethod($a, $b);

            return wp_normalize_path($mr->getFileName());
        }
        if (is_string($a) && is_string($b) && class_exists($a)) {
            $mr = new ReflectionMethod($a, $b);

            return wp_normalize_path($mr->getFileName());
        }
    } catch (Throwable $e) {
        return null;
    }

    return null;
}

/**
 * Map absolute path to plugin main file key (as in get_plugins keys) or sentinel.
 *
 * @param array<string, array<string, string>> $_plugins Ignored meta; keys only matter
 *
 * @return string plugin file key|'core'|'must_use_plugin'|'dropin'|'theme'|'unknown'
 */
function sitesleuth_probe_attribute_path(string $file, array $_plugins): string {
    $file = wp_normalize_path($file);
    $mudoc = wp_normalize_path(WPMU_PLUGIN_DIR);

    if (strpos($file, $mudoc . '/') === 0) {
        return 'must_use_plugin';
    }

    foreach (array_keys($_plugins) as $key) {
        $main = wp_normalize_path(WP_PLUGIN_DIR . '/' . $key);
        $plugDir = dirname($main);
        if ($file === $main || strpos($file, $plugDir . '/') === 0) {
            return $key;
        }
    }

    if (strpos($file, '/wp-includes/') !== false || strpos($file, '/wp-admin/') !== false) {
        return 'core';
    }
    $td = wp_normalize_path(get_template_directory());
    $sd = wp_normalize_path(get_stylesheet_directory());
    if (($td && strpos($file, $td . '/') === 0) || ($sd && strpos($file, $sd . '/') === 0)) {
        return 'theme';
    }
    if (strpos($file, '/wp-content/') !== false) {
        return 'wp_content_other';
    }

    return 'unknown';
}

/**
 * Summarise registered callbacks on key hooks, attributed to plugins / core.
 *
 * @return array<string, array{total_callbacks:int, by_source: array<string, int>}>
 */
function sitesleuth_probe_hook_summary(array $pluginKeys): array {
    global $wp_filter;
    $tags = [
        'plugins_loaded',
        'setup_theme',
        'after_setup_theme',
        'init',
        'wp_loaded',
        'rest_api_init',
        'widgets_init',
        'wp_enqueue_scripts',
        'admin_init',
        'template_redirect',
        'wp',
        'shutdown',
    ];
    $out = [];
    foreach ($tags as $tag) {
        if (!isset($wp_filter[$tag]) || !is_object($wp_filter[$tag])) {
            continue;
        }
        /** @var WP_Hook $hook */
        $hook = $wp_filter[$tag];
        $by = [];
        $total = 0;
        foreach ($hook->callbacks as $priority => $list) {
            foreach ($list as $item) {
                $fn = $item['function'] ?? null;
                if ($fn === null) {
                    continue;
                }
                ++$total;
                $path = sitesleuth_probe_callback_file($fn);
                $label = $path ? sitesleuth_probe_attribute_path($path, $pluginKeys) : 'unresolvable_callback';
                $by[$label] = ($by[$label] ?? 0) + 1;
            }
        }
        arsort($by);
        $out[$tag] = [
            'total_callbacks' => $total,
            'by_source' => array_slice($by, 0, 40, true),
        ];
    }

    return $out;
}

/**
 * Heuristic "heavy plugin" list: many hooks on init / wp_loaded (not wall time).
 *
 * @param array<string, array{total_callbacks:int, by_source: array<string, int>}> $hookSummary
 *
 * @return list<array{plugin:string, init_callbacks:int, wp_loaded_callbacks:int, score:int}>
 */
function sitesleuth_probe_heavy_plugin_hints(array $hookSummary, array $activePluginFiles): array {
    $scores = [];
    $mergeTag = static function (string $tag) use (&$scores, $hookSummary): void {
        if (!isset($hookSummary[$tag]['by_source'])) {
            return;
        }
        foreach ($hookSummary[$tag]['by_source'] as $src => $n) {
            if ($src === 'core' || $src === 'theme' || $src === 'unknown' || strpos($src, 'must_use') === 0) {
                continue;
            }
            if ($src === 'wp_content_other') {
                continue;
            }
            $scores[$src] ??= ['init' => 0, 'wp_loaded' => 0];
            if ($tag === 'init') {
                $scores[$src]['init'] += $n;
            }
            if ($tag === 'wp_loaded') {
                $scores[$src]['wp_loaded'] += $n;
            }
        }
    };

    $mergeTag('init');
    $mergeTag('wp_loaded');

    $rows = [];
    foreach ($scores as $pluginFile => $c) {
        if (! in_array($pluginFile, ['core', 'theme', 'unknown', 'wp_content_other', 'must_use_plugin'], true)) {
            $score = ($c['init'] ?? 0) * 3 + ($c['wp_loaded'] ?? 0) * 2;
            $rows[] = [
                'plugin' => $pluginFile,
                'active' => in_array($pluginFile, $activePluginFiles, true),
                'init_callbacks' => $c['init'] ?? 0,
                'wp_loaded_callbacks' => $c['wp_loaded'] ?? 0,
                'score' => $score,
                'note' => 'Heuristic: many hooked callbacks — profile with Query Monitor or similar for real CPU/time.',
            ];
        }
    }
    usort($rows, static fn (array $a, array $b) => $b['score'] <=> $a['score']);

    return array_slice($rows, 0, 25);
}

/**
 * Runs a SQL snippet multiple times — mirrors cloud1.py DB query timing (+ EXPLAIN rows).
 *
 * @param object $wpdb WordPress $wpdb instance
 *
 * @return array{query:string, sql:string, avg_ms:float, samples_ms:float[], explain:string[], status:string}
 */
function sitesleuth_probe_benchmark_sql($wpdb, string $label, string $sql, int $runs = 3): array {
    $runs = max(1, min(5, $runs));
    $sql = preg_replace('#;\s*$#', '', trim($sql)) ?? trim($sql);
    $samples = [];
    for ($i = 0; $i < $runs; $i++) {
        $t0 = microtime(true);
        if (method_exists($wpdb, 'flush')) {
            $wpdb->flush();
        }
        $wpdb->suppress_errors(true);
        $wpdb->query($sql);
        $wpdb->suppress_errors(false);
        $samples[] = round((microtime(true) - $t0) * 1000, 4);
        if ($wpdb->last_error !== '') {
            return [
                'query' => $label,
                'sql' => $sql,
                'avg_ms' => 0,
                'samples_ms' => $samples,
                'explain' => [],
                'status' => 'failed',
                'db_error' => $wpdb->last_error,
                'parity' => 'cloud1.py BackendMetrics.check_database_query_performance',
            ];
        }
    }
    $avgMs = round(array_sum($samples) / count($samples), 3);

    $explainRows = [];
    $wpdb->suppress_errors(true);
    $ex = $wpdb->get_results('EXPLAIN '.$sql, ARRAY_A);
    $wpdb->suppress_errors(false);

    if (is_array($ex)) {
        foreach ($ex as $row) {
            $explainRows[] = wp_json_encode($row, JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE) ?: '';
        }
    }

    return [
        'query' => $label,
        'sql' => $sql,
        'avg_ms' => $avgMs,
        'samples_ms' => $samples,
        'explain' => array_slice($explainRows, 0, 40),
        'status' => $avgMs < 100 ? 'good' : ($avgMs < 500 ? 'warning' : 'critical'),
        'parity' => 'cloud1.py BackendMetrics.check_database_query_performance',
    ];
}

/**
 * COUNT(*) helper (returns null on failure).
 *
 * @param object $wpdb
 */
function sitesleuth_probe_count_safe($wpdb, string $sql): ?int {
    $wpdb->suppress_errors(true);
    $val = $wpdb->get_var($sql);
    $wpdb->suppress_errors(false);
    if ($wpdb->last_error !== '') {
        return null;
    }
    return is_numeric($val) ? (int) $val : null;
}

/**
 * Homepage loopback TTF (cloud1 FrontendMetrics.measure_ttfb style, server-side HTTP).
 *
 * @return array{sampling:int, url:string, timings_ms:number[], avg_ms:float|null, http_codes:number[], body_kb_avg:float|null, note:string}
 */
function sitesleuth_probe_homepage_loopback(int $runs = 3): array {
    if (!function_exists('home_url') || !function_exists('wp_remote_get')) {
        return [
            'sampling' => 0,
            'url' => '',
            'timings_ms' => [],
            'avg_ms' => null,
            'http_codes' => [],
            'body_kb_avg' => null,
            'note' => 'WordPress HTTP helpers unavailable',
        ];
    }
    $url = home_url('/');
    $runs = max(1, min(8, $runs));
    $ms = [];
    $codes = [];
    $sizes = [];
    for ($i = 0; $i < $runs; $i++) {
        $t0 = microtime(true);
        $hit = add_query_arg('_ssprobe', (string) $i.'_'.wp_generate_password(3, false), $url);
        $res = wp_remote_get(
            $hit,
            [
                'timeout' => 30,
                'redirection' => 3,
                'headers' => [
                    'Accept' => 'text/html,*/*',
                    'Cache-Control' => 'no-cache',
                    'User-Agent' => 'SiteSleuthProbe/4 (+loopback-internal)',
                ],
                'sslverify' => apply_filters('https_local_ssl_verify', true),
            ],
        );

        $ms[] = round((microtime(true) - $t0) * 1000, 3);
        if (is_wp_error($res)) {
            $codes[] = null;
            $sizes[] = 0;

            continue;
        }
        $codes[] = (int) wp_remote_retrieve_response_code($res);
        $body = (string) wp_remote_retrieve_body($res);

        $sizes[] = strlen($body) / 1024;

        usleep(200000);

    }

    return [
        'sampling' => $runs,
        'url' => $url,
        'timings_ms' => $ms,
        'avg_ms' => $ms!==[] ? round(array_sum($ms) / count($ms), 3) : null,
        'min_ms' => $ms!==[] ? round(min($ms), 3) : null,
        'max_ms' => $ms!==[] ? round(max($ms), 3) : null,
        'http_codes' => $codes,
        'body_kb_avg' => $sizes!==[] ? round(array_sum($sizes) / count($sizes), 2) : null,
        'note' => 'Server-side wp_remote_get to home_url(); approximates cloud1 FrontendMetrics.measure_ttfb / page latency. Disabled SSL verify via wp-config SITELEUTH_WP_HTTP_SSLVERIFY_DISABLED is not bundled — sslverify stays default true.',
        'parity' => 'cloud1.py FrontendMetrics.measure_ttfb + measure_page_size (partial)',
    ];
}

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

$wpLoadStart = microtime(true);
$wpLoad = __DIR__ . '/wp-load.php';
$wpLoaded = is_readable($wpLoad);
if ($wpLoaded) {
    require_once $wpLoad;
}
$wpBootstrapSeconds = round(microtime(true) - $wpLoadStart, 4);

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

if (! hash_equals($expected, $provided)) {
    http_response_code(403);
    echo json_encode(['ok' => false, 'error' => 'forbidden']);
    exit;
}

$out = [
    'ok' => true,
    'probe_version' => 4,
    'wordpress' => false,
    'timing' => [
        'seconds_wp_bootstrap_through_wp_load' => $wpBootstrapSeconds,
        'hint' => 'Wall time loading WordPress core + plugins/mu-plugins for this request (not perf of front page HTML). Compare across environments.',
    ],
    'php_version' => PHP_VERSION,
    'memory_limit' => ini_get('memory_limit') ?: null,
    'max_execution_time' => ini_get('max_execution_time') ?: null,
    'server_software' => $_SERVER['SERVER_SOFTWARE'] ?? null,
    'document_root' => $_SERVER['DOCUMENT_ROOT'] ?? null,
];

$wpOk = $wpLoaded && defined('ABSPATH') && function_exists('get_option');
if (! $wpOk) {
    echo json_encode($out);
    exit;
}

if (! function_exists('get_plugins')) {
    require_once ABSPATH . 'wp-admin/includes/plugin.php';
}

global $wpdb;
if (! $wpdb instanceof wpdb) {
    $out['wordpress'] = true;
    $out['wp_error'] = 'wpdb_unavailable';
    echo json_encode($out);
    exit;
}

$dbName = defined('DB_NAME') ? DB_NAME : null;

try {
$pluginList = get_plugins();
$pluginKeys = array_fill_keys(array_keys($pluginList), []);
$active = (array) get_option('active_plugins', []);
$networkActive = is_multisite() ? array_keys((array) get_site_option('active_sitewide_plugins', [])) : [];
$pluginsOut = [];
foreach ($pluginList as $file => $meta) {
    $pluginsOut[] = [
        'file' => $file,
        'name' => $meta['Name'] ?? $file,
        'version' => $meta['Version'] ?? null,
        'active' => in_array($file, $active, true) || in_array($file, $networkActive, true),
    ];
}
usort($pluginsOut, static function (array $a, array $b): int {
    if (($a['active'] ?? false) !== ($b['active'] ?? false)) {
        return ($a['active'] ?? false) ? -1 : 1;
    }

    return strcasecmp((string) ($a['name'] ?? ''), (string) ($b['name'] ?? ''));
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

$updateNote = 'Uses WordPress.org update transients; may contact api.wordpress.org (short). Set SITESLEUTH_PROBE_SKIP_UPDATE_CHECK=1 to skip remote checks.';

$pluginUpdatesOut = [];
$themeUpdatesOut = [];
$coreUpdateOut = null;

$skipRemote = getenv('SITESLEUTH_PROBE_SKIP_UPDATE_CHECK') === '1' || getenv('SITESLEUTH_PROBE_SKIP_UPDATE_CHECK') === 'true';

if (! $skipRemote && file_exists(ABSPATH . 'wp-admin/includes/update.php')) {
    try {
        require_once ABSPATH . 'wp-admin/includes/update.php';
        if (function_exists('wp_update_plugins')) {
            @wp_update_plugins();
        }
        if (function_exists('wp_update_themes')) {
            @wp_update_themes();
        }
        if (function_exists('wp_version_check')) {
            @wp_version_check([], true);
        }
    } catch (Throwable $updateEx) {
        $updateNote .= ' Remote update check raised: '.$updateEx->getMessage().'.';
    }

    $upPl = get_site_transient('update_plugins');
    if (is_object($upPl) && ! empty($upPl->response) && is_array($upPl->response)) {
        foreach ($upPl->response as $file => $data) {
            $cur = $pluginList[$file]['Version'] ?? null;
            $pluginUpdatesOut[] = [
                'file' => $file,
                'name' => $pluginList[$file]['Name'] ?? $file,
                'installed_version' => $cur,
                'new_version' => $data->new_version ?? null,
                'package_available' => ! empty($data->package),
                'requires_php' => $data->requires_php ?? null,
                'requires_wp' => $data->requires ?? null,
                'tested_wp' => $data->tested ?? null,
            ];
        }
    }

    $upTh = get_site_transient('update_themes');
    if (is_object($upTh) && ! empty($upTh->response) && is_array($upTh->response)) {
        foreach ($upTh->response as $slug => $data) {
            $themeUpdatesOut[] = [
                'stylesheet' => $slug,
                'new_version' => $data['new_version'] ?? null,
                'package_available' => ! empty($data['package']),
            ];
        }
    }

    $upCore = get_site_transient('update_core');
    if (is_object($upCore) && ! empty($upCore->updates) && is_array($upCore->updates)) {
        $offer = $upCore->updates[0] ?? null;
        if ($offer !== null && ! empty($offer->response)) {
            $coreUpdateOut = [
                'installed' => $GLOBALS['wp_version'] ?? null,
                'offer_version' => $offer->version ?? null,
                'response_type' => $offer->response,
            ];
        }
    }
}

$hookSummary = sitesleuth_probe_hook_summary($pluginKeys);
$heavyHints = sitesleuth_probe_heavy_plugin_hints($hookSummary, $active);

$dbVersion = $wpdb->get_var('SELECT VERSION()');

$mysqlVarsWant = [
    'max_connections',
    'innodb_buffer_pool_size',
    'tmp_table_size',
    'max_heap_table_size',
    'innodb_flush_log_at_trx_commit',
    'slow_query_log',
    'slow_query_log_file',
    'long_query_time',
    'version_comment',
];

$mysqlVariables = [];
foreach ($mysqlVarsWant as $name) {
    $row = $wpdb->get_row($wpdb->prepare('SHOW VARIABLES LIKE %s', $name), ARRAY_A);
    if ($row !== null && isset($row['Value'])) {
        $mysqlVariables[$name] = $row['Value'];
    }
}

$tablesOut = [];
if ($dbName !== null) {
    $likePrefix = str_replace('_', '\\_', $wpdb->prefix).'%';

    /** @phpstan-ignore-next-line unprepared_sql */
    $tablesOut = $wpdb->get_results(
        $wpdb->prepare(
            "SELECT TABLE_NAME, ENGINE, TABLE_ROWS, ROUND((DATA_LENGTH+INDEX_LENGTH)/1024/1024,2) AS size_mb_approx
           FROM information_schema.TABLES WHERE TABLE_SCHEMA=%s AND TABLE_NAME LIKE %s
           ORDER BY (DATA_LENGTH+INDEX_LENGTH) DESC LIMIT 85",
            $dbName,
            $likePrefix,
        ),
        ARRAY_A,
    ) ?: [];
}

$postTypes = $wpdb->get_results(
    "SELECT post_type, post_status, COUNT(*) AS count FROM {$wpdb->posts} GROUP BY post_type, post_status ORDER BY count DESC LIMIT 60",
    ARRAY_A,
) ?: [];

$bigMeta = $wpdb->get_results(
    "SELECT meta_key, COUNT(*) AS ct FROM {$wpdb->postmeta} GROUP BY meta_key ORDER BY ct DESC LIMIT 25",
    ARRAY_A,
) ?: [];

$bigUsermeta = null;
$tableUsermeta = $wpdb->prefix . 'usermeta';
$hasUm = ($wpdb->get_var($wpdb->prepare('SHOW TABLES LIKE %s', $tableUsermeta)) === $tableUsermeta);

if ($hasUm) {
    $bigUsermeta = $wpdb->get_results(
        "SELECT meta_key, COUNT(*) AS ct FROM {$wpdb->usermeta} GROUP BY meta_key ORDER BY ct DESC LIMIT 20",
        ARRAY_A,
    ) ?: [];
}

$autoloadHeavy = $wpdb->get_results(
    "SELECT option_name, LENGTH(option_value) AS bytes FROM {$wpdb->options}
     WHERE autoload='yes' ORDER BY LENGTH(option_value) DESC LIMIT 30",
    ARRAY_A,
) ?: [];

$dbSizeMb = null;
if ($dbName !== null) {
    $dbSizeMb = $wpdb->get_var(
        $wpdb->prepare(
            'SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) FROM information_schema.tables WHERE table_schema = %s',
            $dbName,
        ),
    );
}

$autoloadOptions = (int) $wpdb->get_var("SELECT COUNT(*) FROM {$wpdb->options} WHERE autoload = 'yes'");
$autoloadKb = $wpdb->get_var(
    "SELECT ROUND(SUM(CHAR_LENGTH(option_value)) / 1024, 1) FROM {$wpdb->options} WHERE autoload = 'yes'",
);
$transientRows = (int) $wpdb->get_var(
    "SELECT COUNT(*) FROM {$wpdb->options} WHERE option_name LIKE '_transient_%' OR option_name LIKE '_site_transient_%'",
);
$revisionCount = (int) $wpdb->get_var($wpdb->prepare(
    'SELECT COUNT(*) FROM {$wpdb->posts} WHERE post_type = %s',
    'revision',
));

$postStatusRows = $wpdb->get_results(
    "SELECT post_status, COUNT(*) AS c FROM {$wpdb->posts} WHERE post_type = 'post' GROUP BY post_status",
    ARRAY_A,
) ?: [];

$cronHooks = [];
if (function_exists('_get_cron_array')) {
    $cron = _get_cron_array();
    if (is_array($cron)) {
        foreach ($cron as $ts => $hooks) {
            if (! is_array($hooks)) {
                continue;
            }
            foreach (array_keys($hooks) as $hook) {
                $cronHooks[$hook] = ($cronHooks[$hook] ?? 0) + 1;
            }
        }
        arsort($cronHooks);
        $cronHooks = array_slice($cronHooks, 0, 30, true);
    }
}

$cronScheduledTotal = 0;
if (function_exists('_get_cron_array')) {
    $cronArray = _get_cron_array();
    if (is_array($cronArray)) {
        foreach ($cronArray as $ts => $hooks) {
            if (! is_array($hooks)) {
                continue;
            }
            foreach ($hooks as $ids) {
                $cronScheduledTotal += is_array($ids) ? count($ids) : 0;
            }
        }
    }
}

$transientBreakdown = [
    'standard_transients' => (int) sitesleuth_probe_count_safe(
        $wpdb,
        "SELECT COUNT(*) FROM {$wpdb->options} WHERE option_name LIKE '_transient_%' AND option_name NOT LIKE '_transient_timeout_%'",
    ),
    'transient_timeouts' => (int) sitesleuth_probe_count_safe(
        $wpdb,
        "SELECT COUNT(*) FROM {$wpdb->options} WHERE option_name LIKE '_transient_timeout_%'",
    ),
    'site_transients' => (int) sitesleuth_probe_count_safe(
        $wpdb,
        "SELECT COUNT(*) FROM {$wpdb->options} WHERE option_name LIKE '_site_transient_%' AND option_name NOT LIKE '_site_transient_timeout_%'",
    ),
    'site_transient_timeouts' => (int) sitesleuth_probe_count_safe(
        $wpdb,
        "SELECT COUNT(*) FROM {$wpdb->options} WHERE option_name LIKE '_site_transient_timeout_%'",
    ),
    'parity' => 'cloud1.py BackendMetrics.check_transients',
];

$p = $wpdb->prefix;
$dbBenchmarks = [];

$coreBench = [
    ['Published posts', "SELECT COUNT(*) FROM {$p}posts WHERE post_status='publish'"],
    ['Options siteurl lookup', "SELECT option_value FROM {$p}options WHERE option_name='siteurl' LIMIT 1"],
    ['Postmeta rows', "SELECT COUNT(*) FROM {$p}postmeta"],
    ['Recent published posts', "SELECT ID FROM {$p}posts WHERE post_type='post' AND post_status='publish' ORDER BY post_date DESC LIMIT 10"],
    ['Thumbnail join sample', "SELECT pm.post_id FROM {$p}postmeta pm INNER JOIN {$p}posts p ON pm.post_id=p.ID WHERE pm.meta_key='_thumbnail_id' AND p.post_status='publish' LIMIT 100"],
    ['Approved comments', "SELECT COUNT(*) FROM {$p}comments WHERE comment_approved='1'"],
    ['Category relations', "SELECT COUNT(*) FROM {$p}term_relationships tr INNER JOIN {$p}term_taxonomy tt ON tr.term_taxonomy_id=tt.term_taxonomy_id WHERE tt.taxonomy='category'"],
    ['Autoload bytes sum', "SELECT SUM(LENGTH(option_value)) FROM {$p}options WHERE autoload='yes'"],
];

foreach ($coreBench as [$label, $sql]) {
    $dbBenchmarks[] = sitesleuth_probe_benchmark_sql($wpdb, $label, $sql, 3);
}

$wooActive = class_exists('WooCommerce', false) || in_array('woocommerce/woocommerce.php', $active, true) || in_array('woocommerce/woocommerce.php', $networkActive, true);

$woocommerceBlock = ['installed' => $wooActive, 'mode' => 'not_installed', 'query_benchmarks' => []];

if ($wooActive) {
    $woocommerceBlock['mode'] = 'legacy';

    $hp = strtolower((string) get_option('woocommerce_custom_orders_table_enabled', ''));
    if (in_array($hp, ['yes', '1', 'true'], true)) {
        $woocommerceBlock['mode'] = 'hpos';
    }

    if ($woocommerceBlock['mode'] === 'hpos' && $wpdb->get_var($wpdb->prepare('SHOW TABLES LIKE %s', "{$p}wc_orders")) === "{$p}wc_orders") {

        $woocommerceBlock['query_benchmarks'][] = sitesleuth_probe_benchmark_sql($wpdb, 'Woo HPOS processing+completed orders', "SELECT COUNT(*) FROM {$p}wc_orders WHERE status IN ('wc-processing','wc-completed')");

        $woocommerceBlock['query_benchmarks'][] = sitesleuth_probe_benchmark_sql($wpdb, 'Woo HPOS meta _order_total', "SELECT COUNT(*) FROM {$p}wc_orders_meta WHERE meta_key='_order_total'");

    } else {

        $woocommerceBlock['query_benchmarks'][] = sitesleuth_probe_benchmark_sql($wpdb, 'Woo legacy shop orders', "SELECT COUNT(*) FROM {$p}posts WHERE post_type='shop_order' AND post_status IN ('wc-processing','wc-completed')");

        $woocommerceBlock['query_benchmarks'][] = sitesleuth_probe_benchmark_sql($wpdb, 'Woo legacy order_total join', "SELECT pm.post_id FROM {$p}postmeta pm INNER JOIN {$p}posts p ON pm.post_id=p.ID WHERE p.post_type='shop_order' AND pm.meta_key='_order_total' LIMIT 200");

        $woocommerceBlock['query_benchmarks'][] = sitesleuth_probe_benchmark_sql($wpdb, 'Woo SKU meta count', "SELECT COUNT(*) FROM {$p}postmeta WHERE meta_key='_sku'");

    }
}

$dbCleanup = [];

$skipHeavy = getenv('SITESLEUTH_PROBE_SKIP_HEAVY_CLEANUP') === '1';

if (!$skipHeavy) {
    $dbCleanup = [
        'posts_revisions' => sitesleuth_probe_count_safe($wpdb, "SELECT COUNT(*) FROM {$p}posts WHERE post_type='revision'"),
        'posts_auto_draft' => sitesleuth_probe_count_safe($wpdb, "SELECT COUNT(*) FROM {$p}posts WHERE post_status='auto-draft'"),
        'comments_deletedish' => sitesleuth_probe_count_safe($wpdb, "SELECT COUNT(*) FROM {$p}comments WHERE comment_approved IN ('trash','post-trashed','deleted')"),
        'comments_unapproved' => sitesleuth_probe_count_safe($wpdb, "SELECT COUNT(*) FROM {$p}comments WHERE comment_approved='0'"),
        'comments_spam' => sitesleuth_probe_count_safe($wpdb, "SELECT COUNT(*) FROM {$p}comments WHERE comment_approved='spam'"),
        'orphan_post_meta' => sitesleuth_probe_count_safe($wpdb, "SELECT COUNT(*) FROM {$p}postmeta pm LEFT JOIN {$p}posts p ON pm.post_id=p.ID WHERE p.ID IS NULL"),
        'orphan_comment_meta' => sitesleuth_probe_count_safe($wpdb, "SELECT COUNT(*) FROM {$p}commentmeta cm LEFT JOIN {$p}comments c ON cm.comment_id=c.comment_ID WHERE c.comment_ID IS NULL"),
        'orphan_user_meta' => sitesleuth_probe_count_safe($wpdb, "SELECT COUNT(*) FROM {$p}usermeta um LEFT JOIN {$p}users u ON um.user_id=u.ID WHERE u.ID IS NULL"),
        'orphan_term_meta' => sitesleuth_probe_count_safe($wpdb, "SELECT COUNT(*) FROM {$p}termmeta tm LEFT JOIN {$p}terms t ON tm.term_id=t.term_id WHERE t.term_id IS NULL"),
        'orphan_term_relationships' => sitesleuth_probe_count_safe($wpdb, "SELECT COUNT(*) FROM {$p}term_relationships tr LEFT JOIN {$p}term_taxonomy tt ON tr.term_taxonomy_id=tt.term_taxonomy_id LEFT JOIN {$p}posts p ON tr.object_id=p.ID WHERE tt.term_taxonomy_id IS NULL OR p.ID IS NULL"),
        'unused_terms_count_zero' => sitesleuth_probe_count_safe($wpdb, "SELECT COUNT(*) FROM {$p}term_taxonomy WHERE count=0"),
        'duplicate_postmeta_groups' => sitesleuth_probe_count_safe($wpdb, "SELECT COUNT(*) FROM (SELECT post_id, meta_key, COUNT(*) AS c FROM {$p}postmeta GROUP BY post_id, meta_key HAVING c>1) dup"),
        'oembed_cache_meta' => sitesleuth_probe_count_safe($wpdb, "SELECT COUNT(*) FROM {$p}postmeta WHERE meta_key LIKE '_oembed_%' AND meta_key NOT LIKE '_oembed_time_%'"),
        'parity' => 'cloud1.py BackendMetrics.check_database_cleanup_metrics',
    ];
} else {
    $dbCleanup = ['skipped' => true, 'reason' => 'SITESLEUTH_PROBE_SKIP_HEAVY_CLEANUP=1'];
}

$benchSorted = $dbBenchmarks;
usort($benchSorted, static fn ($a, $b) => ($b['avg_ms'] ?? 0) <=> ($a['avg_ms'] ?? 0));
foreach ($woocommerceBlock['query_benchmarks'] as $wb) {
    $benchSorted[] = $wb;
}
usort($benchSorted, static fn ($a, $b) => ($b['avg_ms'] ?? 0) <=> ($a['avg_ms'] ?? 0));

$loopbackSamples = (int) (getenv('SITESLEUTH_PROBE_LOOPBACK_SAMPLES') ?: 3);
$loopbackSamples = max(1, min(8, $loopbackSamples));
$skipLoopback = getenv('SITESLEUTH_PROBE_SKIP_LOOPBACK') === '1';
$frontendLoopback = $skipLoopback ? ['skipped' => true, 'reason' => 'SITESLEUTH_PROBE_SKIP_LOOPBACK=1'] : sitesleuth_probe_homepage_loopback($loopbackSamples);

$phpRuntime = [
    'memory_usage_mb' => round(memory_get_usage(true) / 1048576, 3),
    'memory_peak_mb' => function_exists('memory_get_peak_usage') ? round(memory_get_peak_usage(true) / 1048576, 3) : null,
    'parity' => 'cloud1.py BackendMetrics.check_memory_usage',
];

$insights = [];
$topSlow = array_slice($benchSorted, 0, 8);
foreach ($topSlow as $row) {
    if (($row['status'] ?? '') === 'failed') {
        continue;
    }
    if (($row['avg_ms'] ?? 0) > 200) {
        $insights[] = 'Slow SQL relative to cloud1 thresholds: '.($row['query'] ?? '').' avg '.($row['avg_ms'] ?? 0).'ms — review indexes / table size / related plugins.';
    }
}
foreach (array_slice($heavyHints, 0, 5) as $h) {
    $insights[] = 'High init/wp_loaded callback count: '.($h['plugin'] ?? '').' (score '.($h['score'] ?? 0).') — candidate for Query Monitor / profiling (not proof of wall time).';
}
$insights[] = 'cloud1.py slow-log parsing needs filesystem access; not included in web probe. Enable MySQL slow_query_log (see mysql_variables) and parse on server if needed.';

$opcacheBrief = null;
if (function_exists('opcache_get_status')) {
    $st = opcache_get_status(false);
    if (is_array($st)) {
        $opcacheBrief = [
            'enabled' => $st['opcache_enabled'] ?? null,
            'cache_full' => $st['cache_full'] ?? null,
            'memory_usage' => isset($st['memory_usage']) && is_array($st['memory_usage']) ?
                round(($st['memory_usage']['used_memory'] ?? 0) / 1048576, 2) : null,
        ];
    }
}

$wpdbNumQueries = null;
if (isset($wpdb->num_queries)) {
    $wpdbNumQueries = $wpdb->num_queries;
}

$out['wordpress'] = true;
$out['wp_version'] = $GLOBALS['wp_version'] ?? null;
$out['is_multisite'] = is_multisite();
$out['plugins'] = array_slice($pluginsOut, 0, 120);
$out['plugin_updates_pending'] = $pluginUpdatesOut;
$out['theme_updates_pending'] = $themeUpdatesOut;
$out['core_update_pending'] = $coreUpdateOut;
$out['updates_meta'] = ['note' => $updateNote, 'remote_checks_skipped' => $skipRemote];

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
    'schema_name' => $dbName,
    'approx_schema_mb' => is_string($dbSizeMb) || is_float($dbSizeMb) ? (float) $dbSizeMb : null,
    'mysql_variables' => $mysqlVariables,
    'note_table_rows' => 'TABLE_ROWS is approximate for InnoDB',
    'tables_top_by_size' => $tablesOut,
    'postmeta_keys_top' => $bigMeta,
    'usermeta_keys_top' => $bigUsermeta,
    'posts_by_type_status' => $postTypes,
    'autoloaded_options_count' => $autoloadOptions,
    'autoloaded_options_kb' => is_string($autoloadKb) || is_float($autoloadKb) ? (float) $autoloadKb : null,
    'autoloaded_options_largest_by_bytes' => $autoloadHeavy,
    'transient_option_rows' => $transientRows,
    'transients_breakdown' => $transientBreakdown,
    'revision_row_count' => $revisionCount,
    'posts_by_status' => $postStatusRows,
    'wpdb_num_queries_this_request' => $wpdbNumQueries,
    'savequeries_constant' => defined('SAVEQUERIES') && SAVEQUERIES,
    'cleanup_candidates' => $dbCleanup,
    'query_benchmarks' => $dbBenchmarks,
    'query_benchmarks_slowest_first' => array_slice($benchSorted, 0, 15),
];

$out['woocommerce'] = $woocommerceBlock;

$out['frontend_loopback'] = $frontendLoopback;

$out['php_runtime_memory'] = $phpRuntime;

$out['probe_insights'] = $insights;

$out['cloud_health_reference'] = [
    'source' => 'Aligned with github.com/jahanzaibakhan/python cloud1.py (WP-CLI + local slow-log scans).',
    'included_in_probe' => 'DB micro-benchmarks+EXPLAIN, WC mode, cleanup counts, transients breakdown, cron event total, homepage loopback timing, hooks callback map, PHP memory, updates.',
    'not_in_web_probe' => 'Throughput/rps thread test (cloud1 FrontendMetrics.measure_throughput), speculative FCP from HTML size, filesystem PHP slow-log parsing — use Lighthouse + hosting metrics.',
];

$out['hooks'] = [
    'summary_by_tag' => $hookSummary,
    'heavy_plugin_hints' => $heavyHints,
    'note' => 'Callback counts per hook are not wall-clock time. Use Query Monitor or Xdebug for real tracing.',
];

$out['cron'] = [
    'scheduled_hook_counts' => $cronHooks,
    'total_scheduled_events' => $cronScheduledTotal,
];

$out['caching'] = [
    'using_ext_object_cache' => wp_using_ext_object_cache(),
    'opcache' => $opcacheBrief,
];

$out['constants_sample'] = [
    'WP_DEBUG' => defined('WP_DEBUG') ? (bool) WP_DEBUG : false,
    'WP_DEBUG_LOG' => defined('WP_DEBUG_LOG') ? (bool) WP_DEBUG_LOG : false,
    'SCRIPT_DEBUG' => defined('SCRIPT_DEBUG') ? (bool) SCRIPT_DEBUG : false,
    'COMPRESS_CSS' => defined('COMPRESS_CSS') ? (bool) COMPRESS_CSS : false,
    'COMPRESS_SCRIPTS' => defined('COMPRESS_SCRIPTS') ? (bool) COMPRESS_SCRIPTS : false,
    'CONCATENATE_SCRIPTS' => defined('CONCATENATE_SCRIPTS') ? (bool) CONCATENATE_SCRIPTS : false,
];

echo json_encode($out, JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE);
} catch (Throwable $e) {
    $errOut = [
        'ok' => false,
        'error' => 'probe_exception',
        'probe_version' => 4,
        'message' => $e->getMessage(),
        'exception' => get_class($e),
        'file' => $e->getFile(),
        'line' => $e->getLine(),
        'hint' => 'Check Cloudways / hosting PHP error log; disable plugins or set SITESLEUTH_PROBE_SKIP_UPDATE_CHECK=1 and SITESLEUTH_PROBE_SKIP_HEAVY_CLEANUP=1 in the server environment if memory/timeouts occur.',
    ];
    $trace = $e->getTraceAsString();
    if (is_string($trace) && $trace !== '') {
        $lines = explode("\n", $trace);
        $errOut['trace_sample'] = array_slice($lines, 0, 12);
    }
    echo json_encode($errOut, JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE);
