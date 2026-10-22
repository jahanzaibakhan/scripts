<?php
// Dashboard data. GET ?range=today|7d|all&q=... -> latest run per server in range.
// GET ?id=N -> one run including its full log.

declare(strict_types=1);
require __DIR__ . '/../../private_html/lib.php';

start_session();
if (!logged_in()) {
    json_out(401, ['error' => 'not signed in']);
}
session_write_close();

$pdo = db();

if (isset($_GET['id'])) {
    $q = $pdo->prepare('SELECT * FROM patch_runs WHERE id = ?');
    $q->execute([(int)$_GET['id']]);
    $run = $q->fetch();
    $run ? json_out(200, ['run' => $run]) : json_out(404, ['error' => 'not found']);
}

// "Today" is the calendar day in Karachi, the timezone the dashboard shows.
$tz = new DateTimeZone('Asia/Karachi');
$since = match ($_GET['range'] ?? 'today') {
    '7d' => (new DateTime('today -6 days', $tz)),
    'all' => (new DateTime('@0')),
    default => (new DateTime('today', $tz)),
};
$since = $since->setTimezone(new DateTimeZone('UTC'))->format('Y-m-d H:i:s');

$search = trim((string)($_GET['q'] ?? ''));
$where = 'updated_at >= ?';
$args = [$since];
if ($search !== '') {
    $where .= ' AND (server_ip LIKE ? OR hostname LIKE ?)';
    $args[] = "%$search%";
    $args[] = "%$search%";
}

$q = $pdo->prepare("SELECT r.id, r.server_ip, r.hostname, r.status, r.result, r.detail, r.step, r.packages,
        r.started_at, r.updated_at, r.completed_at,
        TIMESTAMPDIFF(MINUTE, r.updated_at, UTC_TIMESTAMP()) AS minutes_since_update
    FROM patch_runs r
    JOIN (SELECT server_ip, MAX(id) AS id FROM patch_runs WHERE $where GROUP BY server_ip) latest ON latest.id = r.id
    ORDER BY r.updated_at DESC");
$q->execute($args);
$runs = $q->fetchAll();

$counts = array_fill_keys(STATUSES, 0);
foreach ($runs as $run) {
    $counts[$run['status']]++;
}

json_out(200, ['runs' => $runs, 'counts' => $counts, 'total' => count($runs), 'serverTime' => gmdate('c')]);
