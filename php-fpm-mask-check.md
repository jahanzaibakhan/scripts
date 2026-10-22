# php-fpm-mask-check

Read-only check, run from the jump server against many servers at once. It finds in-use PHP-FPM versions that automation masked in October 2026, works out which job masked them, and shows whether each one is still down. It ends with a summary table.

It makes no changes to the servers. On each server it only reads systemd state, the Ansible facts, `/var/log/patching_php.log`, pool directories, monit and the journal.

## Run it

From the jump server:

```bash
curl -fsSL https://raw.githubusercontent.com/jahanzaibakhan/scripts/main/php-fpm-mask-check.sh | bash -s -- 45.76.181.133 108.61.96.118 158.247.248.248
```

IPs can be separated by spaces or commas, or read from a file (one per line, `#` comments allowed):

```bash
curl -fsSL https://raw.githubusercontent.com/jahanzaibakhan/scripts/main/php-fpm-mask-check.sh -o php-fpm-mask-check.sh
bash php-fpm-mask-check.sh -f ips.txt
```

Options:

| Option | Meaning |
|---|---|
| `-l` | Check this server instead of remote IPs (run as root) |
| `-f FILE` | Read IPs from FILE |
| `-u USER` | SSH user (default `systeam`; needs passwordless sudo on the target) |
| `-j N` | Servers checked in parallel (default 8) |
| `-s SINCE` | Journal window, `journalctl --since` syntax (default `"7 days ago"`) |
| `-t SEC` | SSH connect timeout (default 10) |
| `-a` | Details for every server, not just the affected ones |
| `-q` | Summary table only |

Exit code: `0` all OK, `1` at least one server affected or with a warning, `2` usage or SSH errors.

## Results

| Result | Meaning |
|---|---|
| `MASKED` | An in-use PHP-FPM is masked right now. The script prints the fix command. |
| `DOWN` | An in-use PHP-FPM is not masked but not running |
| `RECOVERED` | It was masked, but it is running now. Shows who masked it, when, and the manual unmask. |
| `WARN` | A PHP version with no pools is enabled and failing to start, a leftover from a failed upgrade |
| `OK` | Nothing found |
| `SSH_FAIL` | Could not connect, or sudo failed |

A version is **in use** if:
- on a multi-app PHP server, its `pool.d` has `cloudways.conf` (the server PHP that Adminer and the Imunify360 UI use) or app pools;
- on a single-PHP server, it is the `php=` version in `packages.fact`.

## Causes it identifies

| Cause | What happened |
|---|---|
| `PATCH_RACE` | `patching_php.sh` started, saw a single-PHP server (`multi_php=false`) and recorded which FPM versions were running. The multi-app PHP migration then started the server PHP (usually 8.2) and set `multi_app_php=yes`. When apt finished (or failed), the patch masked that version based on its out-of-date snapshot. |
| `UPGRADE` | The PHP upgrade playbook masked the old PHP and enabled the new one before the new version's pools existed. It then failed (for example retrying `apt-get install --reinstall newrelic-php5`) and never rolled back. |
| `PATCH` | `patching_php.sh` masked an in-use version without the race pattern |
| `UNKNOWN` | It was masked (`is masked` errors in the journal), but neither job's log shows the mask |

For each affected version the details show:
- when the migration or playbook started it;
- when `patching_php.sh` or an Ansible task masked it;
- when the mask symlink was created;
- the first and last monit `is masked` errors;
- any manual `systemctl unmask`.

Mask evidence comes from every run in `patching_php.log`, not only the latest, because a later re-run of the patch would otherwise hide it. If the journal has rotated, the outage window is taken from `monit.log`; that is shown in the details only and does not change the result.

They also show the patch run summary (start time, `multi_php`, versions running before, apt result, rc), the facts, and monit.
