<?php
// Shared code for the PHP Patch Reports app. Lives outside public_html.
// config.php (not in git) returns: db_host, db_name, db_user, db_pass,
// report_token, admin_password_hash.

declare(strict_types=1);

const STATUSES = ['RUNNING', 'COMPLETED', 'FAILED', 'NO_ACTION'];

function config(): array
{
    static $config;
    return $config ??= require __DIR__ . '/config.php';
}

function db(): PDO
{
    static $pdo;
    if ($pdo) {
        return $pdo;
    }
    $c = config();
    $pdo = new PDO(
        "mysql:host={$c['db_host']};dbname={$c['db_name']};charset=utf8mb4",
        $c['db_user'],
        $c['db_pass'],
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC]
    );
    $pdo->exec("SET time_zone = '+00:00'");
    $pdo->exec("CREATE TABLE IF NOT EXISTS patch_runs (
        id INT AUTO_INCREMENT PRIMARY KEY,
        run_id VARCHAR(100) NOT NULL UNIQUE,
        server_ip VARCHAR(45) NOT NULL,
        hostname VARCHAR(255) NOT NULL DEFAULT '',
        status ENUM('RUNNING','COMPLETED','FAILED','NO_ACTION') NOT NULL,
        result VARCHAR(40) NOT NULL DEFAULT '',
        detail VARCHAR(1000) NOT NULL DEFAULT '',
        step VARCHAR(500) NOT NULL DEFAULT '',
        packages TEXT,
        log MEDIUMTEXT,
        started_at DATETIME NOT NULL,
        updated_at DATETIME NOT NULL,
        completed_at DATETIME NULL,
        KEY server_ip (server_ip),
        KEY updated_at (updated_at)
    ) CHARACTER SET utf8mb4");
    return $pdo;
}

function json_out(int $code, array $body): never
{
    http_response_code($code);
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
    echo json_encode($body, JSON_UNESCAPED_SLASHES);
    exit;
}

function start_session(): void
{
    session_set_cookie_params(['httponly' => true, 'secure' => true, 'samesite' => 'Lax']);
    session_name('patchreports');
    session_start();
}

function logged_in(): bool
{
    return !empty($_SESSION['auth']);
}

function csrf_token(): string
{
    return $_SESSION['csrf'] ??= bin2hex(random_bytes(16));
}

function e(?string $s): string
{
    return htmlspecialchars((string)$s, ENT_QUOTES, 'UTF-8');
}
