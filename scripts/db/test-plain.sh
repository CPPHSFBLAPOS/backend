#!/usr/bin/env bash
# Run the migrations, seed and pgTAP tests against a throwaway plain Postgres
# cluster, for machines without Docker. CI runs `supabase test db` instead.
#
# Needs Postgres 15+ binaries (initdb, pg_ctl, psql) on PATH or in
# /usr/lib/postgresql/<version>/bin, and pgTAP installed into that Postgres.
#
#   scripts/db/test-plain.sh            # migrations + seed + all tests
#   scripts/db/test-plain.sh --no-tests # just build the database
#   KEEP=1 scripts/db/test-plain.sh     # leave it running on 127.0.0.1 and
#                                       # print DATABASE_URL (for test:concurrency)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PGBIN="${PGBIN:-$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)}"
export PATH="$PGBIN:$PATH"
PORT="${PGPORT_TEST:-54329}"
WORK="$(mktemp -d)"
RUN_AS=()
if [ "$(id -u)" = "0" ]; then
  chown postgres "$WORK"
  RUN_AS=(runuser -u postgres --)
fi

cleanup() {
  if [ "${KEEP:-}" = "1" ]; then
    echo "DATABASE_URL=postgresql://postgres@127.0.0.1:$PORT/app  (stop: pg_ctl -D $WORK/data stop)"
    return
  fi
  "${RUN_AS[@]}" pg_ctl -D "$WORK/data" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

"${RUN_AS[@]}" initdb -D "$WORK/data" -U postgres -A trust >/dev/null
"${RUN_AS[@]}" pg_ctl -D "$WORK/data" -o "-p $PORT -k $WORK -c listen_addresses='${KEEP:+127.0.0.1}'" -l "$WORK/log" -w start >/dev/null

PSQL=("${RUN_AS[@]}" psql -X -q -v ON_ERROR_STOP=1 -h "$WORK" -p "$PORT" -U postgres)
"${PSQL[@]}" -d postgres -c "create database app" >/dev/null
"${PSQL[@]}" -d app -c "alter database app set search_path = \"\$user\", public, extensions" >/dev/null

"${PSQL[@]}" -d app -f "$ROOT/scripts/db/supabase-shim.sql" >/dev/null
for f in "$ROOT"/supabase/migrations/*.sql; do
  echo "migrate $(basename "$f")"
  "${PSQL[@]}" -d app -f "$f" >/dev/null
done
echo "seed"
"${PSQL[@]}" -d app -f "$ROOT/supabase/seed.sql" >/dev/null

if [ "${1:-}" = "--no-tests" ]; then
  exit 0
fi

failed=0
for t in "$ROOT"/supabase/tests/*.sql; do
  out="$("${PSQL[@]}" -d app -t -A -f "$t" 2>&1)" || true
  if echo "$out" | grep -qE '^not ok|ERROR|Looks like'; then
    echo "FAIL $(basename "$t")"
    echo "$out" | grep -vE '^ok |^\s*$' | sed 's/^/    /'
    failed=1
  else
    n="$(echo "$out" | grep -cE '^ok ' || true)"
    echo "ok   $(basename "$t") ($n assertions)"
  fi
done
exit $failed
