# debian12-upgrade-check

Read-only health check for servers upgraded from Debian 11 (bullseye) to Debian 12 (bookworm), built for Cloudways-style stacks. It reports what the upgrade left unfinished, with the date and how long each issue has been there, and ends with a red/green summary.

It makes no changes to the server. The only thing it writes is a temporary directory under `/tmp` for the Varnish VCL compile test, removed on exit.

## Run it

```bash
curl -fsSL https://raw.githubusercontent.com/jahanzaibakhan/scripts/main/debian12-upgrade-check.sh | sudo bash
```

Summary only:

```bash
curl -fsSL https://raw.githubusercontent.com/jahanzaibakhan/scripts/main/debian12-upgrade-check.sh | sudo bash -s -- --summary
```

Options: `--summary` (only the final summary), `--no-color` (or `NO_COLOR=1`).

Exit code: `0` all good, `1` warnings only, `2` failures found, `3` not run as root.

## What it checks

| Area | Checks |
|---|---|
| OS | Debian version, bullseye entries left in APT sources, still running a Debian 11 kernel, not rebooted since the upgrade, reboot-required flag |
| Packages | `dpkg --audit`, half-installed or unconfigured packages, `apt-get check`, packages dpkg failed on during the upgrade (and whether they recovered), apt runs that ended in an error, leftover `deb11` packages, held packages |
| MariaDB / MySQL | Service running, `mariadb-upgrade --check-if-upgrade-is-needed` (system tables still at the old version), `Incorrect definition of table` errors and whether they are current or from before the fix, `debian-sys-maint` startup errors, crashed tables, other errors in the last 24h |
| Varnish | Masked / failed / disabled, missing storage directory, VCL compiles on the installed Varnish version (Cloudways VCL uses `return (miss)`, which Varnish 7.x rejects), package source |
| PHP-FPM | Running versions, inactive versions that are the only ones defining a pool, every Cloudways application has a pool in a running PHP-FPM and its socket exists |
| Services | nginx, apache2, redis-server, memcached, monit, imunify360-agent (only if installed) |
| Failed units | Any failed systemd unit, with the time it failed and its last error line |
| Python | `boto`, `boto3`, `botocore` import, version and whether they came from apt or pip |
| Resources | Disk usage, available memory, swap, out-of-memory kills since the upgrade |

Python modules and services to check can be overridden:

```bash
curl -fsSL https://raw.githubusercontent.com/jahanzaibakhan/scripts/main/debian12-upgrade-check.sh | sudo PY_MODULES="boto boto3 botocore" SERVICES="nginx apache2 mariadb" bash
```

## Example summary

```
================================ SUMMARY ================================
  Host    : 123456.cloudwaysapps.com (203.0.113.10)
  Checked : 2026-10-06 08:23:36 UTC
  Upgrade : started 2026-10-05 06:33 UTC (1d 1h ago)
  Booted  : 2026-09-25 12:20 UTC (10d 20h ago)

  UPGRADE INCOMPLETE: 9 failure(s), 2 warning(s)

  [FAIL] Kernel     Running Debian 11 kernel 6.1.0-0.deb11.50-amd64: server not rebooted into the Debian 12 kernel
                    since 2026-10-05 06:33 UTC (1d 1h ago)
  [FAIL] MariaDB    System tables NOT upgraded: data at 10.5.22-MariaDB, server 10.11.19-MariaDB-deb12-log. mariadb-upgrade was never run
                    since 2026-10-05 06:35 UTC (1d 1h ago)
  [FAIL] Varnish    Storage directory missing: /var/lib/varnish/instance (varnishd cannot create /var/lib/varnish/instance/varnish_storage.bin)
  [FAIL] Python     Python module 'boto' is missing
  ...
  Missing packages: boto boto3 botocore
=========================================================================
```
