#!/usr/bin/env bash
# Adversarial stress tests for the migration xact-lock fix, through a REAL
# pgBouncer in transaction mode (the exact mechanism the engine's migrate()
# relies on). Run after verify.sh.
#
#   S1: N concurrent acquirers of the migration advisory lock must be STRICTLY
#       MUTUALLY EXCLUSIVE (no overlapping critical sections) and emit NO
#       "you don't own a lock" warning, even when N >> pgBouncer's backend
#       budget (no deadlock under backend exhaustion).
#   S2: while the lock holder's conn is IDLE-IN-TRANSACTION (as it is in the
#       engine while migrateLocked() runs DDL on OTHER conns), it must NOT be
#       reaped. Proves SET LOCAL idle_in_transaction_session_timeout=0 defends
#       even when the SERVER imposes a low idle_in_transaction_session_timeout.
# NOTE: deliberately not `set -e` — this is a diagnostic harness where commands
# like `grep -l` returning non-zero (no match = good, no warnings) are expected.
set -uo pipefail
cd "$(dirname "$0")"
KEY=$(printf '%d' 0x7A414B494D494752)
N=${1:-10}

cleanup() { docker compose down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker compose up -d
PSQL() { docker compose exec -T pg psql "postgresql://zaki:zaki@pgbouncer:6432/zaki" "$@"; }
for _ in $(seq 1 60); do PSQL -tAc 'select 1' >/dev/null 2>&1 && break; sleep 1; done
PSQL -tAc 'select 1' >/dev/null

echo "============ S1: ${N}-way mutual exclusion through pgBouncer ============"
PSQL -tAc "DROP TABLE IF EXISTS stress_log; CREATE TABLE stress_log(id serial primary key, worker int, phase text);" >/dev/null
rm -f /tmp/s1_*.err
pids=()
for w in $(seq 1 "$N"); do
  ( PSQL -v w="$w" -v ON_ERROR_STOP=1 >/dev/null 2>/tmp/s1_$w.err <<SQL
BEGIN;
SET LOCAL lock_timeout = 0;
SET LOCAL idle_in_transaction_session_timeout = 0;
SELECT pg_advisory_xact_lock($KEY);
INSERT INTO stress_log(worker, phase) VALUES (:w, 'enter');
SELECT pg_sleep(0.15);
INSERT INTO stress_log(worker, phase) VALUES (:w, 'exit');
COMMIT;
SQL
  ) &
  pids+=($!)
done
fail=0
for p in "${pids[@]}"; do wait "$p" || fail=1; done
# Inserts happen only inside the critical section, so serial id order == the
# order critical sections ran. If serialized, phases alternate enter,exit,...
# An 'enter' immediately followed by anything other than 'exit' = an overlap.
OVERLAP=$(PSQL -tAc "WITH o AS (SELECT phase, id, row_number() OVER (ORDER BY id) rn FROM stress_log) SELECT count(*) FROM o a JOIN o b ON b.rn=a.rn+1 WHERE a.phase='enter' AND b.phase<>'exit';")
ROWS=$(PSQL -tAc "SELECT count(*) FROM stress_log;")
WARN1=$(grep -li "you don't own a lock" /tmp/s1_*.err 2>/dev/null | wc -l | tr -d ' ')
echo "workers=$N rows=$ROWS (expect $((N*2)))  any-worker-failed=$fail  enter/exit-overlaps=$OVERLAP  warn-files=$WARN1"
S1=fail; { [ "$fail" = 0 ] && [ "$OVERLAP" = 0 ] && [ "$WARN1" = 0 ] && [ "$ROWS" = "$((N*2))" ]; } && S1=pass
echo "S1: $S1 (pass = strictly serialized, all completed, no warnings)"

echo
echo "============ S2: idle-in-transaction reaping resistance ============"
# Adverse server config: reap idle-in-transaction sessions after 1s.
PSQL -tAc "ALTER DATABASE zaki SET idle_in_transaction_session_timeout = '1000ms';" >/dev/null
docker compose restart pgbouncer >/dev/null 2>&1; sleep 2
for _ in $(seq 1 30); do PSQL -tAc 'select 1' >/dev/null 2>&1 && break; sleep 1; done

# (a) NO mitigation: idle 3s in an open txn -> server should kill it at 1s.
A=ok
{ echo "BEGIN;"; echo "SELECT pg_try_advisory_xact_lock($KEY);"; sleep 3; echo "COMMIT;"; } | PSQL -v ON_ERROR_STOP=1 >/tmp/s2a.out 2>/tmp/s2a.err || A=killed
echo "(a) no mitigation     -> $A (expect killed)"; sed -n '1,3p' /tmp/s2a.err 2>/dev/null || true
PSQL -tAc "SELECT pg_advisory_unlock_all();" >/dev/null 2>&1 || true

# (b) WITH mitigation (engine's SET LOCAL=0): idle 3s -> must SURVIVE.
B=killed
{ echo "BEGIN;"; echo "SET LOCAL idle_in_transaction_session_timeout = 0;"; echo "SELECT pg_try_advisory_xact_lock($KEY);"; sleep 3; echo "COMMIT;"; } | PSQL -v ON_ERROR_STOP=1 >/tmp/s2b.out 2>/tmp/s2b.err && B=ok
echo "(b) SET LOCAL = 0     -> $B (expect ok)"; sed -n '1,3p' /tmp/s2b.err 2>/dev/null || true
PSQL -tAc "ALTER DATABASE zaki RESET idle_in_transaction_session_timeout;" >/dev/null 2>&1 || true
PSQL -tAc "SELECT pg_advisory_unlock_all();" >/dev/null 2>&1 || true
S2=fail; { [ "$A" = killed ] && [ "$B" = ok ]; } && S2=pass
echo "S2: $S2 (pass = unmitigated reaped, SET LOCAL=0 survives)"

echo
echo "================ STRESS SUMMARY ================"
echo "S1=$S1  S2=$S2"
{ [ "$S1" = pass ] && [ "$S2" = pass ]; } && echo "STRESS PASS" || { echo "STRESS FAIL"; exit 1; }
