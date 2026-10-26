#!/usr/bin/env bash
# app-backup.sh
# Creates a downloadable zip of an app's files and database.
# Output: /home/master/applications/<app>/public_html/<app>-backup-dd-mm-yyyy.zip
#
# Usage (on the Cloudways server, as the master user):  bash app-backup.sh
# The zip is readable by the app's system user (the owner of public_html).

set -u

APPS_ROOT="/home/master/applications"

C_G=$'\e[32m'; C_R=$'\e[31m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_0=$'\e[0m'
step() { echo; echo "${C_B}==> $*${C_0}"; }
ok()   { echo "${C_G}    ✔ $*${C_0}"; }
warn() { echo "${C_Y}    ! $*${C_0}"; }
err()  { echo "${C_R}    ✘ $*${C_0}"; }

TMP_DIR=""
ZIP_PATH=""
cleanup() {
  [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"
}
fail() {
  err "$1"
  [ -n "$ZIP_PATH" ] && rm -f "$ZIP_PATH"
  cleanup
  exit 1
}
trap cleanup EXIT

# ---------------------------------------------------------------- Step 1
step "1/5 Input"
read -rp "    App name (e.g. wchfqkswxk): " APP </dev/tty
[[ "$APP" =~ ^[A-Za-z0-9_-]+$ ]] || fail "Invalid app name."

APP_DIR="$APPS_ROOT/$APP"
WEB_DIR="$APP_DIR/public_html"
[ -d "$WEB_DIR" ] || fail "Not found: $WEB_DIR"
ok "Found $WEB_DIR"

command -v zip >/dev/null       || fail "zip is not installed."
command -v mysqldump >/dev/null || fail "mysqldump is not installed."

# ---------------------------------------------------------------- Step 2
step "2/5 Database credentials"
WP_CONFIG="$WEB_DIR/wp-config.php"
if [ -f "$WP_CONFIG" ]; then
  DB_NAME=$(grep -oP "DB_NAME',\s*'\K[^']+" "$WP_CONFIG" | head -1)
  DB_USER=$(grep -oP "DB_USER',\s*'\K[^']+" "$WP_CONFIG" | head -1)
  DB_PASS=$(grep -oP "DB_PASSWORD',\s*'\K[^']*" "$WP_CONFIG" | head -1)
  DB_HOST=$(grep -oP "DB_HOST',\s*'\K[^']+" "$WP_CONFIG" | head -1)
  ok "Read database settings from wp-config.php"
else
  read -rp "    Database name: " DB_NAME </dev/tty
  read -rp "    Database user: " DB_USER </dev/tty
  read -rsp "    Database password: " DB_PASS </dev/tty; echo
  DB_HOST="localhost"
fi
DB_HOST=${DB_HOST:-localhost}
[ -n "${DB_NAME:-}" ] && [ -n "${DB_USER:-}" ] || fail "Database name or user is missing."

# ---------------------------------------------------------------- Step 3
step "3/5 Space check"
need_kb=$(du -sk "$APP_DIR" | cut -f1)
avail_kb=$(df -Pk "$APP_DIR" | awk 'NR==2 {print $4}')
if [ "$avail_kb" -lt "$need_kb" ]; then
  fail "Not enough free disk space: need about $((need_kb / 1024)) MB, have $((avail_kb / 1024)) MB."
fi
ok "Space OK: need about $((need_kb / 1024)) MB, have $((avail_kb / 1024)) MB"

# ---------------------------------------------------------------- Step 4
step "4/5 Dump database and create zip"
DATE=$(date +%d-%m-%Y)
ZIP_NAME="$APP-backup-$DATE.zip"
ZIP_PATH="$WEB_DIR/$ZIP_NAME"
OWNER=$(stat -c %U "$WEB_DIR")

# Temp dir lives outside public_html so the DB dump is never web-accessible.
TMP_DIR=$(mktemp -d "$APP_DIR/.backup-tmp.XXXXXX") || fail "Could not create temp dir."
umask 077
CNF="$TMP_DIR/my.cnf"
printf '[client]\nhost=%s\nuser=%s\npassword=%s\n' "$DB_HOST" "$DB_USER" "$DB_PASS" > "$CNF"

mysqldump --defaults-extra-file="$CNF" --single-transaction --routines --triggers \
  "$DB_NAME" > "$TMP_DIR/database.sql" || fail "Database dump failed."
ok "Database dumped ($DB_NAME)"

rm -f "$CNF"
rm -f "$ZIP_PATH"
(cd "$TMP_DIR" && zip -q "$ZIP_PATH" database.sql) || fail "Adding database dump to zip failed."
# Exclude older backup zips so they are not nested inside the new one.
(cd "$APP_DIR" && zip -rq "$ZIP_PATH" public_html -x "public_html/*-backup-*.zip") \
  || fail "Adding files to zip failed."
ok "Zip created"

chmod 644 "$ZIP_PATH"
if [ "$(id -u)" -eq 0 ]; then
  chown "$OWNER:$OWNER" "$ZIP_PATH"
elif [ "$(stat -c %U "$ZIP_PATH")" != "$OWNER" ]; then
  warn "Zip is owned by $(stat -c %U "$ZIP_PATH"), not $OWNER. Run as root to change ownership."
fi

# ---------------------------------------------------------------- Step 5
step "5/5 Done"
ok "Backup: $ZIP_PATH"
ok "Size:   $(du -h "$ZIP_PATH" | cut -f1)"
ok "Download path: /$ZIP_NAME  (https://<your-domain>/$ZIP_NAME)"
warn "The file is public to anyone with the URL. Delete it from public_html after downloading."
