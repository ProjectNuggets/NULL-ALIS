#!/usr/bin/env bash
# Prove, through a REAL pgBouncer in transaction mode in front of pg16+pgvector,
# that the FIX (pg_try_advisory_xact_lock held inside an open BEGIN..COMMIT)
# serializes across connections, while the OLD session-lock pattern does not.
#
# Mechanism notes (verified empirically):
#   * pgBouncer runs server_reset_query (DISCARD ALL) ONLY in session mode by
#     default (server_reset_query_always=0). In transaction mode it is NOT run,
#     so a session advisory lock LINGERS on its backend; serialization fails
#     because concurrent acquirers land on OTHER pooled backends, and the
#     "you don't own a lock" warning appears when the engine's unlock lands on
#     a non-owning backend (assignment-dependent — the authoritative warning
#     check is the engine boot-log run, not this SQL micro-repro).
#   * Advisory locks are DATABASE-GLOBAL, so while the holder keeps the xact
#     lock in an open txn (pinned backend), ANY concurrent pg_try_advisory_lock
#     on the same key is denied -> deterministic serialization proof.
#
# No host psql needed: psql runs inside the pg container and connects to the
# pgbouncer service over the compose network (traffic goes THROUGH the pooler).
set -euo pipefail
cd "$(dirname "$0")"
KEY=$(printf '%d' 0x7A414B494D494752)   # MIGRATION_ADVISORY_LOCK_KEY ("zAKIMIGR") as signed int8
echo "MIGRATION_ADVISORY_LOCK_KEY = $KEY"

cleanup() { docker compose down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker compose up -d
PSQL() { docker compose exec -T pg psql "postgresql://zaki:zaki@pgbouncer:6432/zaki" "$@"; }
probe() { PSQL -tAc "SELECT pg_try_advisory_lock($KEY)" | tr -d '[:space:]'; }

echo "waiting for pgbouncer on :6432 ..."
for _ in $(seq 1 60); do PSQL -tAc 'select 1' >/dev/null 2>&1 && break; sleep 1; done
PSQL -tAc 'select 1' >/dev/null

echo
echo "=== OLD pattern (session pg_advisory_lock, NO open txn) — illustrative, non-deterministic ==="
( PSQL >/tmp/old_holder.out 2>/tmp/old_holder.err <<SQL
SELECT pg_try_advisory_lock($KEY) AS acquired;
SELECT pg_sleep(3);
SELECT pg_advisory_unlock($KEY) AS unlocked;
SQL
) & OLD_HOLDER=$!
sleep 1
OLD_PROBE=$(probe)
echo "concurrent session-lock probe while 'held' -> ${OLD_PROBE}  ==> $([ "$OLD_PROBE" = t ] && echo 'GRANTED = NOT serialized (the bug)' || echo 'denied (backend coincided)')"
[ "$OLD_PROBE" = t ] && PSQL -tAc "SELECT pg_advisory_unlock($KEY)" >/dev/null 2>&1 || true
wait "$OLD_HOLDER" || true
grep -qi "you don't own a lock" /tmp/old_holder.err \
  && echo ">> warning reproduced this run" \
  || echo ">> warning not surfaced this run (assignment-dependent; engine run is the authoritative check)"
PSQL -tAc "SELECT pg_advisory_unlock_all()" >/dev/null 2>&1 || true

echo
echo "=== NEW pattern (pg_try_advisory_xact_lock inside open BEGIN..COMMIT) — the fix ==="
( PSQL -v ON_ERROR_STOP=1 >/tmp/new_holder.out 2>/tmp/new_holder.err <<SQL
BEGIN;
SET LOCAL idle_in_transaction_session_timeout = 0;
SELECT pg_try_advisory_xact_lock($KEY) AS holder_got;
SELECT pg_sleep(3);
COMMIT;
SQL
) & NEW_HOLDER=$!
sleep 1
HOLDER_GOT=$(grep -A2 holder_got /tmp/new_holder.out | grep -Ex ' *[tf] *' | tr -d '[:space:]' || true)
NEW_PROBE=$(probe)
echo "holder_got=${HOLDER_GOT:-?}  | concurrent probe while xact-lock held -> ${NEW_PROBE}  ==> $([ "$NEW_PROBE" = f ] && echo 'DENIED = SERIALIZED (fixed)' || echo 'GRANTED = NOT serialized')"
[ "$NEW_PROBE" = t ] && PSQL -tAc "SELECT pg_advisory_unlock($KEY)" >/dev/null 2>&1 || true
wait "$NEW_HOLDER" || true
NEW_FREE=$(probe); [ "$NEW_FREE" = t ] && PSQL -tAc "SELECT pg_advisory_unlock($KEY)" >/dev/null 2>&1 || true
echo "after holder COMMIT, lock free again -> ${NEW_FREE} (expect t)"
grep -qi "you don't own a lock" /tmp/new_holder.err \
  && echo ">> UNEXPECTED: warning in NEW pattern" \
  || echo ">> NEW pattern emitted NO 'you don't own a lock' warning (COMMIT auto-releases)"

echo
echo "================ SUMMARY ================"
echo "OLD concurrent probe = ${OLD_PROBE}  (t = not serialized = the bug)"
echo "NEW: holder_got=${HOLDER_GOT:-?}  concurrent probe = ${NEW_PROBE} (f = serialized = fixed)  regrant = ${NEW_FREE}"
if [ "$NEW_PROBE" = f ] && [ "$NEW_FREE" = t ]; then echo "PASS: xact-lock-in-open-txn serializes through pgBouncer-transaction; no manual unlock / no warning."; else echo "FAIL"; exit 1; fi
