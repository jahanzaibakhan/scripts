#!/usr/bin/env bash
# fix_crashed_tables.sh
# Backs up, repairs and converts crashed MyISAM tables (ENGINE NULL /
# "marked as crashed and last repair failed") to InnoDB.
#
# Usage (as root, or a user with sudo):  bash fix_crashed_tables.sh

set -u

BACKUP_ROOT="/root/mysql_table_backups"
MYSQL="mysql"
[ "$(id -u)" -ne 0 ] && MYSQL="sudo mysql"

C_G=$'\e[32m'; C_R=$'\e[31m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_0=$'\e[0m'
step() { echo; echo "${C_B}==> [$1] $2${C_0}"; }
ok()   { echo "${C_G}    ✔ $*${C_0}"; }
warn() { echo "${C_Y}    ! $*${C_0}"; }
err()  { echo "${C_R}    ✘ $*${C_0}"; }

FIXED=(); FAILED=()

# ---------------------------------------------------------------- Step 1
step "1/6" "Checking MySQL/MariaDB access"
if ! $MYSQL -e "SELECT 1" >/dev/null 2>&1; then
  err "Cannot connect with '$MYSQL'. Run as root / a sudo user."; exit 1
fi
DATADIR=$($MYSQL -N -e "SELECT @@datadir" | sed 's:/*$::')
ok "Connected. Data directory: $DATADIR"

# ---------------------------------------------------------------- Step 2
step "2/6" "Input"
read -rp "    Database name: " DB </dev/tty
[[ "$DB" =~ ^[A-Za-z0-9_]+$ ]] || { err "Invalid database name."; exit 1; }
read -rp "    Corrupt table name(s) (space or comma separated): " TABLE_INPUT </dev/tty
TABLES=(${TABLE_INPUT//,/ })
[ ${#TABLES[@]} -gt 0 ] || { err "No table given."; exit 1; }
for t in "${TABLES[@]}"; do
  [[ "$t" =~ ^[A-Za-z0-9_]+$ ]] || { err "Invalid table name: $t"; exit 1; }
done
if [ ! -d "$DATADIR/$DB" ]; then err "Database directory $DATADIR/$DB not found."; exit 1; fi
ok "Database: $DB | Tables: ${TABLES[*]}"

# ---------------------------------------------------------------- Step 3
step "3/6" "Creating backup"
BK="$BACKUP_ROOT/${DB}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BK" || { err "Cannot create $BK"; exit 1; }
VALID=()
for t in "${TABLES[@]}"; do
  if ls "$DATADIR/$DB/$t".* >/dev/null 2>&1; then
    cp -a "$DATADIR/$DB/$t".* "$BK/" && ok "Backed up $t -> $BK" && VALID+=("$t")
  else
    err "No files found for $DB.$t, skipping."; FAILED+=("$t")
  fi
done
[ ${#VALID[@]} -gt 0 ] || { err "Nothing to fix."; exit 1; }

# ---------------------------------------------------------------- Step 4
step "4/6" "Fixing tables (REPAIR)"
for t in "${VALID[@]}"; do
  echo "    Repairing $DB.$t ..."
  OUT=$($MYSQL -t -e "REPAIR TABLE \`$DB\`.\`$t\`;" 2>&1)
  if ! echo "$OUT" | grep -qE "\| status +\| OK"; then
    warn "Normal repair failed, retrying with USE_FRM"
    OUT=$($MYSQL -t -e "REPAIR TABLE \`$DB\`.\`$t\` USE_FRM;" 2>&1)
  fi
  echo "$OUT" | sed 's/^/    /'
  if echo "$OUT" | grep -qE "\| status +\| OK"; then ok "$t repaired"; else err "$t repair FAILED"; FAILED+=("$t"); fi
done

# ---------------------------------------------------------------- Step 5
step "5/6" "Converting to InnoDB"
for t in "${VALID[@]}"; do
  [[ " ${FAILED[*]} " == *" $t "* ]] && continue
  ENG=$($MYSQL -N -e "SELECT ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DB' AND TABLE_NAME='$t'")
  if [ "$ENG" = "InnoDB" ]; then ok "$t already InnoDB"; FIXED+=("$t"); continue; fi
  if $MYSQL -e "ALTER TABLE \`$DB\`.\`$t\` ENGINE=InnoDB;" 2>/tmp/fix_err.$$; then
    ok "$t converted to InnoDB"; FIXED+=("$t")
  else
    err "$t conversion failed: $(cat /tmp/fix_err.$$)"; FAILED+=("$t")
  fi
done
rm -f /tmp/fix_err.$$

# ---------------------------------------------------------------- Step 6
step "6/6" "Fixing complete - status"
LIST=$(printf "'%s'," "${VALID[@]}"); LIST=${LIST%,}
$MYSQL -t -e "SELECT TABLE_SCHEMA, TABLE_NAME, ENGINE, TABLE_ROWS FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DB' AND TABLE_NAME IN ($LIST);"

echo
echo "${C_B}Summary${C_0}"
[ ${#FIXED[@]}  -gt 0 ] && ok  "Fixed tables : $DB.{$(IFS=,; echo "${FIXED[*]}")}"
[ ${#FAILED[@]} -gt 0 ] && err "Failed tables: $DB.{$(IFS=,; echo "${FAILED[*]}")}"
echo "    Backup location: $BK"
[ ${#FAILED[@]} -eq 0 ]
