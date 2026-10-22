<?php
// Receives status reports from php-patch-with-cleanup.sh.
// POST JSON, header "Authorization: Bearer <report_token>".
// Body: runId, serverIp, hostname, status, result, detail, step, packages, log, startedAt.

declare(strict_types=1);
require __DIR__ . '/../../private_html/lib.php';

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    json_out(405, ['error' => 'POST only']);
}

$auth = $_SERVER['HTTP_AUTHORIZATION'] ?? $_SERVER['REDIRECT_HTTP_AUTHORIZATION'] ?? '';
$token = preg_match('/^Bearer\s+(\S+)$/', $auth, $m) ? $m[1] : '';
if ($token === '' || !hash_equals(config()['report_token'], $token)) {
    json_out(401, ['error' => 'invalid token']);
}

$in = json_decode(file_get_contents('php://input') ?: '', true);
if (!is_array($in)) {
    json_out(400, ['error' => 'invalid JSON']);
}

$str = fn(string $key, int $max) => mb_substr(trim((string)($in[$key] ?? '')), 0, $max);
$runId = $str('runId', 100);
$ip = $str('serverIp', 45);
$status = strtoupper($str('status', 20));
if ($runId === '' || $ip === '' || !in_array($status, STATUSES, true)) {
    json_out(400, ['error' => 'runId, serverIp and a valid status are required']);
}
$startedTs = strtotime($str('startedAt', 40)) ?: time();

$pdo = db();
$existing = $pdo->prepare('SELECT status FROM patch_runs WHERE run_id = ?');
$existing->execute([$runId]);
$current = $existing->fetchColumn();

// A late "still running" ping must not undo a final status.
if ($current !== false && $current !== 'RUNNING' && $status === 'RUNNING') {
    json_out(200, ['ok' => true, 'ignored' => 'run already finished']);
}

$final = $status !== 'RUNNING';
$row = [
    'run_id' => $runId,
    'server_ip' => $ip,
    'hostname' => $str('hostname', 255),
    'status' => $status,
    'result' => $str('result', 40),
    'detail' => $str('detail', 1000),
    'step' => $str('step', 500),
    'packages' => $str('packages', 5000),
    'log' => mb_substr((string)($in['log'] ?? ''), -400000),
    'started_at' => gmdate('Y-m-d H:i:s', $startedTs),
];

$pdo->prepare('INSERT INTO patch_runs
        (run_id, server_ip, hostname, status, result, detail, step, packages, log, started_at, updated_at, completed_at)
    VALUES
        (:run_id, :server_ip, :hostname, :status, :result, :detail, :step, :packages, :log, :started_at, UTC_TIMESTAMP(), ' . ($final ? 'UTC_TIMESTAMP()' : 'NULL') . ')
    ON DUPLICATE KEY UPDATE
        hostname = VALUES(hostname), status = VALUES(status), result = VALUES(result),
        detail = VALUES(detail), step = IF(VALUES(step) = \'\', step, VALUES(step)),
        packages = IF(VALUES(packages) = \'\', packages, VALUES(packages)),
        log = IF(VALUES(log) = \'\', log, VALUES(log)),
        updated_at = UTC_TIMESTAMP(), completed_at = VALUES(completed_at)')
    ->execute($row);

json_out(200, ['ok' => true]);
