<?php
// PHP Patch Reports: sign-in and dashboard. Data comes from api/runs.php.

declare(strict_types=1);
require __DIR__ . '/../private_html/lib.php';

start_session();
$error = '';

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    if (!hash_equals(csrf_token(), (string)($_POST['csrf'] ?? ''))) {
        $error = 'Session expired, please try again.';
    } elseif (($_POST['action'] ?? '') === 'logout') {
        $_SESSION = [];
        session_destroy();
        header('Location: ./');
        exit;
    } elseif (password_verify((string)($_POST['password'] ?? ''), config()['admin_password_hash'])) {
        session_regenerate_id(true);
        $_SESSION['auth'] = true;
        header('Location: ./');
        exit;
    } else {
        sleep(1);
        $error = 'Wrong password.';
    }
}
$csrf = csrf_token();
?>
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>PHP Patch Reports</title>
<style>
:root {
    --bg: #f5f7fb; --card: #ffffff; --text: #0f172a; --muted: #64748b; --line: #e2e8f0;
    --head: #f1f5f9; --btn: #f1f5f9; --primary: #1d64b0; --primary-text: #fff;
    --total: #eef1f5; --ok-bg: #e6f6ec; --ok: #15803d; --run-bg: #e5effc; --run: #1d64b0;
    --none-bg: #fdf1dc; --none: #a16207; --fail-bg: #fde8ea; --fail: #b91c1c;
}
@media (prefers-color-scheme: dark) {
    :root {
        --bg: #0b1220; --card: #111a2c; --text: #e2e8f0; --muted: #94a3b8; --line: #1f2a40;
        --head: #16213a; --btn: #1a2540; --primary: #3b82f6;
        --total: #172036; --ok-bg: #0f2a1d; --ok: #4ade80; --run-bg: #10223f; --run: #60a5fa;
        --none-bg: #2d2410; --none: #fbbf24; --fail-bg: #2f1418; --fail: #f87171;
    }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--text); font: 15px/1.45 system-ui, -apple-system, "Segoe UI", sans-serif; }
.wrap { max-width: 1240px; margin: 0 auto; padding: 32px 16px 48px; }
header { display: flex; flex-wrap: wrap; gap: 16px; justify-content: space-between; align-items: flex-start; margin-bottom: 28px; }
h1 { margin: 0; font-size: 30px; letter-spacing: -0.02em; }
.sub { margin: 4px 0 0; color: var(--muted); }
.actions { display: flex; gap: 10px; flex-wrap: wrap; }
button, .btn { font: inherit; font-weight: 600; border: 1px solid var(--line); background: var(--card); color: var(--text); padding: 9px 16px; border-radius: 10px; cursor: pointer; }
button:hover { filter: brightness(0.97); }
.primary { background: var(--primary); color: var(--primary-text); border-color: var(--primary); }
.cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: 16px; margin-bottom: 24px; }
.card { border-radius: 14px; padding: 18px 20px; border: 2px solid transparent; text-align: left; font: inherit; color: inherit; cursor: pointer; transition: opacity .15s, border-color .15s; }
.card:hover { filter: brightness(0.98); }
.cards.filtering .card[data-status]:not(.sel) { opacity: 0.45; }
.card.sel { border-color: var(--primary); }
.card .hint { font-size: 12px; color: var(--muted); margin-top: 2px; }
.filter-note { font-size: 14px; color: var(--muted); }
.filter-note button { padding: 3px 10px; font-size: 13px; margin-left: 6px; }
.card .label { font-weight: 600; color: var(--muted); font-size: 14px; }
.card .num { font-size: 34px; font-weight: 800; margin-top: 4px; }
.c-total { background: var(--total); } .c-ok { background: var(--ok-bg); } .c-run { background: var(--run-bg); }
.c-none { background: var(--none-bg); } .c-fail { background: var(--fail-bg); }
.toolbar { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 14px; margin-bottom: 20px; }
.toolbar input { font: inherit; flex: 1 1 260px; min-width: 0; padding: 9px 14px; border: 1px solid var(--line); border-radius: 10px; background: var(--card); color: var(--text); }
.range button { background: var(--btn); }
.range button.on { background: var(--primary); color: var(--primary-text); border-color: var(--primary); }
.updated { color: var(--muted); font-size: 14px; }
.table { background: var(--card); border: 1px solid var(--line); border-radius: 14px; overflow-x: auto; }
table { width: 100%; border-collapse: collapse; min-width: 820px; }
th { text-align: left; font-size: 13px; letter-spacing: 0.06em; text-transform: uppercase; color: var(--muted); background: var(--head); padding: 14px 18px; }
td { padding: 16px 18px; border-top: 1px solid var(--line); vertical-align: middle; }
.ip { font-weight: 700; font-size: 17px; }
.host, .muted { color: var(--muted); font-size: 14px; }
.pill { display: inline-flex; align-items: center; gap: 6px; font-size: 13px; font-weight: 700; letter-spacing: 0.04em; padding: 5px 12px; border-radius: 999px; white-space: nowrap; }
.p-COMPLETED { background: var(--ok-bg); color: var(--ok); }
.p-RUNNING { background: var(--run-bg); color: var(--run); }
.p-NO_ACTION { background: var(--none-bg); color: var(--none); }
.p-FAILED { background: var(--fail-bg); color: var(--fail); }
.dot { width: 8px; height: 8px; border-radius: 50%; background: currentColor; animation: pulse 1.2s infinite; }
@keyframes pulse { 50% { opacity: 0.3; } }
.empty { padding: 40px; text-align: center; color: var(--muted); }
.row-actions { display: flex; gap: 8px; }
dialog { width: min(960px, calc(100vw - 32px)); border: 1px solid var(--line); border-radius: 14px; background: var(--card); color: var(--text); padding: 0; }
dialog::backdrop { background: rgba(15, 23, 42, 0.5); }
.dlg-head { display: flex; justify-content: space-between; align-items: center; padding: 16px 20px; border-bottom: 1px solid var(--line); }
.dlg-body { padding: 16px 20px 20px; }
.kv { display: grid; grid-template-columns: max-content 1fr; gap: 6px 16px; margin-bottom: 14px; }
.kv div:nth-child(odd) { color: var(--muted); }
pre { background: var(--head); border-radius: 10px; padding: 14px; max-height: 55vh; overflow: auto; font-size: 13px; white-space: pre-wrap; word-break: break-word; margin: 0; }
.login { max-width: 380px; margin: 12vh auto; background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 28px; }
.login input { width: 100%; font: inherit; padding: 10px 14px; border: 1px solid var(--line); border-radius: 10px; margin: 14px 0; background: var(--card); color: var(--text); }
.login button { width: 100%; }
.err { color: var(--fail); margin-top: 10px; }
</style>
</head>
<body>
<?php if (!logged_in()): ?>
<form class="login" method="post">
    <h1>PHP Patch Reports</h1>
    <p class="sub">Sign in to view patch runs.</p>
    <input type="hidden" name="csrf" value="<?= e($csrf) ?>">
    <input type="password" name="password" placeholder="Password" autofocus required>
    <button class="primary" type="submit">Sign in</button>
    <?php if ($error): ?><div class="err"><?= e($error) ?></div><?php endif; ?>
</form>
<?php else: ?>
<div class="wrap">
    <header>
        <div>
            <h1>PHP Patch Reports</h1>
            <p class="sub">Live results from php-patch-with-cleanup.sh runs.</p>
        </div>
        <div class="actions">
            <button id="refresh">Refresh</button>
            <form method="post" style="margin:0">
                <input type="hidden" name="csrf" value="<?= e($csrf) ?>">
                <button class="primary" name="action" value="logout">Sign out</button>
            </form>
        </div>
    </header>

    <section class="cards" id="cards">
        <button class="card c-total" data-all title="Show all statuses"><div class="label">Total servers</div><div class="num" id="n-total">0</div><div class="hint">Show all</div></button>
        <button class="card c-ok" data-status="COMPLETED" title="Click to filter, click more to combine"><div class="label">Completed</div><div class="num" id="n-COMPLETED">0</div></button>
        <button class="card c-run" data-status="RUNNING" title="Click to filter, click more to combine"><div class="label">Running</div><div class="num" id="n-RUNNING">0</div></button>
        <button class="card c-none" data-status="NO_ACTION" title="Click to filter, click more to combine"><div class="label">No action</div><div class="num" id="n-NO_ACTION">0</div></button>
        <button class="card c-fail" data-status="FAILED" title="Click to filter, click more to combine"><div class="label">Failed</div><div class="num" id="n-FAILED">0</div></button>
    </section>

    <section class="toolbar">
        <input id="q" type="search" placeholder="Search server IP or hostname">
        <div class="range" style="display:flex;gap:8px;flex-wrap:wrap">
            <button data-range="today" class="on">Today</button>
            <button data-range="7d">Last 7 Days</button>
            <button data-range="all">All Time</button>
        </div>
        <span class="filter-note" id="filter-note"></span>
        <span class="updated" id="updated"></span>
    </section>

    <section class="table">
        <table>
            <thead><tr><th>Status</th><th>Server</th><th>Last update (Karachi)</th><th>Details</th><th>Actions</th></tr></thead>
            <tbody id="rows"><tr><td colspan="5" class="empty">Loading...</td></tr></tbody>
        </table>
    </section>
</div>

<dialog id="dlg">
    <div class="dlg-head"><strong id="dlg-title"></strong><button id="dlg-close">Close</button></div>
    <div class="dlg-body"><div class="kv" id="dlg-kv"></div><pre id="dlg-log"></pre></div>
</dialog>

<script>
const LABELS = { COMPLETED: 'Completed', RUNNING: 'Running', NO_ACTION: 'No action', FAILED: 'Failed' };
const ICONS = { COMPLETED: '✓', NO_ACTION: '–', FAILED: '✕' };
let range = 'today', timer, lastRuns = [];

// Status filter: empty set = all statuses. Remembered per browser.
const selected = new Set((() => { try { return JSON.parse(localStorage.getItem('statusFilter') || '[]'); } catch { return []; } })());
function saveFilter() { try { localStorage.setItem('statusFilter', JSON.stringify([...selected])); } catch {} }

const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const karachi = utc => utc ? new Date(utc.replace(' ', 'T') + 'Z').toLocaleString('en-GB', {
    timeZone: 'Asia/Karachi', day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: true
}).replace(',', ',') + ' PKT' : '–';
const pill = s => `<span class="pill p-${s}">${s === 'RUNNING' ? '<span class="dot"></span>' : ICONS[s]} ${esc(LABELS[s]).toUpperCase()}</span>`;

function summary(r) {
    if (r.status === 'RUNNING') {
        const stale = r.minutes_since_update >= 15 ? ` <span style="color:var(--fail)">(no update for ${r.minutes_since_update} min)</span>` : '';
        return `${esc(r.step || 'Started')}${stale}`;
    }
    if (r.status === 'COMPLETED' || r.status === 'NO_ACTION') {
        const pk = (r.packages || '').split(',').filter(Boolean);
        return `${esc(r.status === 'NO_ACTION' ? 'Already patched' : 'Patched + verified')}${pk.length ? `<div class="muted">${esc(pk.join(', '))}</div>` : ''}`;
    }
    return `<span style="color:var(--fail)">${esc(r.result)}</span><div class="muted">${esc(r.detail)}</div>`;
}

async function load() {
    clearTimeout(timer);
    const params = new URLSearchParams({ range, q: document.getElementById('q').value.trim() });
    try {
        const res = await fetch('api/runs.php?' + params);
        if (res.status === 401) { location.reload(); return; }
        const data = await res.json();
        document.getElementById('n-total').textContent = data.total;
        for (const s in data.counts) document.getElementById('n-' + s).textContent = data.counts[s];
        lastRuns = data.runs;
        renderRows();
        document.getElementById('updated').textContent = 'Updated ' + karachi(data.serverTime.replace('T', ' ').slice(0, 19)) + ' · auto-refresh 15s';
    } catch (e) {
        document.getElementById('updated').textContent = 'Could not load data, retrying...';
    }
    timer = setTimeout(load, 15000);
}

function renderRows() {
    document.querySelectorAll('#cards [data-status]').forEach(c => c.classList.toggle('sel', selected.has(c.dataset.status)));
    document.getElementById('cards').classList.toggle('filtering', selected.size > 0);
    document.getElementById('filter-note').innerHTML = selected.size
        ? 'Showing: ' + [...selected].map(s => esc(LABELS[s])).join(', ') + '<button id="clear-filter">Clear</button>' : '';
    const runs = selected.size ? lastRuns.filter(r => selected.has(r.status)) : lastRuns;
    document.getElementById('rows').innerHTML = runs.length ? runs.map(r => `
            <tr>
                <td>${pill(r.status)}</td>
                <td><div class="ip">${esc(r.server_ip)}</div><div class="host">${esc(r.hostname)}</div></td>
                <td>${karachi(r.updated_at)}<div class="muted">started ${karachi(r.started_at)}</div></td>
                <td>${summary(r)}</td>
                <td><div class="row-actions"><button data-id="${r.id}">View details</button><button title="Copy IP" data-copy="${esc(r.server_ip)}">⧉</button></div></td>
            </tr>`).join('') : `<tr><td colspan="5" class="empty">${selected.size && lastRuns.length ? 'No servers with the selected status.' : 'No patch runs in this range yet.'}</td></tr>`;
}

async function details(id) {
    const res = await fetch('api/runs.php?id=' + id);
    const { run: r } = await res.json();
    document.getElementById('dlg-title').innerHTML = `${esc(r.server_ip)} &nbsp; ${pill(r.status)}`;
    document.getElementById('dlg-kv').innerHTML = [
        ['Hostname', r.hostname], ['Result', r.result], ['Detail', r.detail], ['Current step', r.step],
        ['Packages', (r.packages || '').split(',').join(', ')], ['Started', karachi(r.started_at)],
        ['Last update', karachi(r.updated_at)], ['Completed', karachi(r.completed_at)], ['Run ID', r.run_id]
    ].filter(([, v]) => v && v !== '–' || v === 0).map(([k, v]) => `<div>${k}</div><div>${esc(v)}</div>`).join('');
    document.getElementById('dlg-log').textContent = r.log || 'No log received yet.';
    document.getElementById('dlg').showModal();
}

document.getElementById('refresh').onclick = load;
document.getElementById('cards').addEventListener('click', e => {
    const card = e.target.closest('.card');
    if (!card) return;
    if (card.hasAttribute('data-all')) selected.clear();
    else selected.has(card.dataset.status) ? selected.delete(card.dataset.status) : selected.add(card.dataset.status);
    saveFilter();
    renderRows();
});
document.querySelector('.toolbar').addEventListener('click', e => {
    if (e.target.id === 'clear-filter') { selected.clear(); saveFilter(); renderRows(); }
});
document.getElementById('dlg-close').onclick = () => document.getElementById('dlg').close();
document.getElementById('q').addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(load, 300); });
document.querySelectorAll('[data-range]').forEach(b => b.onclick = () => {
    range = b.dataset.range;
    document.querySelectorAll('[data-range]').forEach(x => x.classList.toggle('on', x === b));
    load();
});
document.getElementById('rows').addEventListener('click', e => {
    const b = e.target.closest('button');
    if (!b) return;
    if (b.dataset.id) details(b.dataset.id);
    if (b.dataset.copy) navigator.clipboard.writeText(b.dataset.copy).then(() => { b.textContent = '✓'; setTimeout(() => b.textContent = '⧉', 1200); });
});
load();
</script>
<?php endif; ?>
</body>
</html>
