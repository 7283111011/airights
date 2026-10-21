#!/usr/bin/env bash
# run_local.sh — spin up a throwaway PostgreSQL 16 cluster, apply the bootstrap
# stub + all migrations in order, run the smoke tests, then tear down.
# Validates the migrations against a real database. Not used in production.
set -euo pipefail

# Postgres server binaries (initdb, pg_ctl) live outside the default PATH on
# Debian/Ubuntu. Add the newest installed version's bin dir.
for d in /usr/lib/postgresql/*/bin; do
  [ -d "$d" ] && PATH="$d:$PATH"
done
export PATH

HERE="$(cd "$(dirname "$0")" && pwd)"
SUPA_DIR="$(cd "$HERE/.." && pwd)"
MIG_DIR="$SUPA_DIR/migrations"

WORK="${PV_TEST_WORK:-${TMPDIR:-/tmp}/pv_pgtest}"
PGDATA="$WORK/data"
SOCK="$WORK/sock"
PORT="${PV_TEST_PORT:-55432}"
LOG="$WORK/postgres.log"

cleanup() {
  if [ -f "$PGDATA/postmaster.pid" ]; then
    pg_ctl -D "$PGDATA" -m immediate stop >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

rm -rf "$WORK"
mkdir -p "$PGDATA" "$SOCK"

echo "==> initdb"
initdb -D "$PGDATA" -U postgres --auth=trust >/dev/null

echo "==> start postgres (port $PORT, socket $SOCK)"
pg_ctl -D "$PGDATA" -l "$LOG" \
  -o "-p $PORT -k $SOCK -c listen_addresses=''" -w start >/dev/null

export PGHOST="$SOCK" PGPORT="$PORT" PGUSER=postgres PGDATABASE=postgres

createdb pv

PSQL=(psql -v ON_ERROR_STOP=1 -X -q -d pv)

echo "==> bootstrap (local auth stub + roles)"
"${PSQL[@]}" -f "$HERE/00_local_bootstrap.sql"

echo "==> apply migrations"
for f in $(ls "$MIG_DIR"/*.sql | sort); do
  echo "    - $(basename "$f")"
  "${PSQL[@]}" -f "$f"
done

echo "==> run smoke tests"
# Show NOTICE output (test pass/fail lines).
PGOPTIONS='--client-min-messages=notice' "${PSQL[@]}" -f "$HERE/10_smoke.sql"

echo "==> OK"
