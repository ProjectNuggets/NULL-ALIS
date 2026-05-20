# Stability JSONL — canary runbook

**Status:** ops procedure for v1.14.14+ production observability.
**Owner:** Nova (ops); diagnostic surface landed by Agent G v1.14.14.

## What this catches

A class of regression that is invisible to every other monitor we run:
**byte-level drift of the provider-cacheable prompt mid-session**.

Together, vLLM, Moonshot, and Anthropic all cache the leading bytes of an
inference request to skip tokenization + KV-prefill. A change that adds even
one byte to the assembled system prompt (or to the kept-history tail) between
turn N and turn N+1 of the same session **collapses the cache hit** —
the provider re-tokenizes and re-prefills from scratch. Effects:

- Latency: **+50–200%** per turn after the first.
- Cost: **+50–200%** per turn after the first (more tokens billed).
- Answer text: **unchanged** — the model sees identical content, just paid
  for from a cold cache.

Because the answer is unchanged, this regression passes LoCoMo, V-infinity,
τ-bench, and `zig build test`. It only shows up as "the Together bill jumped
12%" three weeks later.

The stability JSONL diagnostic, when activated, emits one record per turn
with the FNV-1a hash of both halves (`stable_prefix_hash` for the system
prompt; `tail_hash` for the kept history). Two same-session turns with
divergent hashes = the bug.

## Activation

### Step 1 — pick a canary host

A single production gateway box is enough. Drift is deterministic; if it
fires on canary, the same prompt-construction change is firing for every
production user. Don't fleet-roll the env var; one box catches everything.

### Step 2 — export the env var BEFORE starting the gateway

The gateway reads `NULLALIS_STABILITY_JSON_PATH` once at boot via
`std.process.getEnvVarOwned` inside `writeStabilityJsonl`. Setting the var
AFTER the gateway is already running does nothing — the gateway process
inherited an environment that lacked it.

```bash
# /etc/systemd/system/nullalis-gateway.service (or equivalent)
[Service]
Environment="NULLALIS_STABILITY_JSON_PATH=/var/log/nullalis/stability.jsonl"
ExecStart=/usr/local/bin/nullalis gateway --host 127.0.0.1 --port 3000
```

Or for ad-hoc / non-systemd launches:

```bash
export NULLALIS_STABILITY_JSON_PATH=/var/log/nullalis/stability.jsonl
mkdir -p /var/log/nullalis
sudo -u nullalis -E /usr/local/bin/nullalis gateway --host 127.0.0.1 --port 3000
```

### Step 3 — ensure the parent dir exists + is writable

`writeStabilityJsonl` does NOT call `makePath`. If the parent directory is
missing or unwritable, the `createFile` call fails silently (best-effort
diagnostic). To verify the gateway is writing:

```bash
# Issue one turn against the canary gateway, then check the file exists +
# has at least one line.
ls -la /var/log/nullalis/stability.jsonl
wc -l /var/log/nullalis/stability.jsonl
```

If the file is empty or missing after a real turn, either the env var
didn't reach the gateway process, or the directory is unwritable.

### Step 4 — set up logrotate

The JSONL grows ~340–400 bytes per turn (one line per turn including the
session identifier). A busy gateway doing 100 turns/hour writes ~1MB/day.
Cap with daily rotation, keep 7 days, compress old days:

```
# /etc/logrotate.d/nullalis-stability
/var/log/nullalis/stability.jsonl {
  daily
  rotate 7
  compress
  delaycompress
  maxsize 10M
  missingok
  notifempty
  copytruncate
}
```

`copytruncate` matters here: the gateway writes via `seekFromEnd + writeAll`
under an exclusive flock. We don't want logrotate to rename the file out
from under the active fd. Copy-then-truncate preserves the file handle.

## Dashboard query — drift detection

The same `jq` incantation that `.spike/run.sh` uses for CI. Point it at the
prod JSONL path:

```bash
jq -s 'group_by(.session) | map({
    session: .[0].session,
    prefix_hashes: ([.[].stable_prefix_hash] | unique),
    tail_hashes: ([.[].tail_hash] | unique),
    turns: length
  }) | map(select(
    .turns > 1 and
    ((.prefix_hashes | length) > 1 or (.tail_hashes | length) > 1)
  ))' \
  /var/log/nullalis/stability.jsonl
```

**Empty array** → no session drift detected; the cache contract holds.
**Non-empty array** → at least one session experienced drift mid-session.
Each element shows the session_key, both hash lists, and turn count.

For continuous monitoring, run this every 5 minutes via cron and emit a
counter to your metrics pipeline:

```bash
#!/usr/bin/env bash
# /etc/cron.5min/nullalis-stability-check
DRIFT_SESSIONS=$(jq -s 'group_by(.session) | map(select(
    length > 1 and
    (([.[].stable_prefix_hash] | unique | length) > 1 or
     ([.[].tail_hash] | unique | length) > 1)
  )) | length' /var/log/nullalis/stability.jsonl 2>/dev/null || echo 0)
echo "nullalis.stability.drift_sessions $DRIFT_SESSIONS" | nc -w1 metrics 8125
```

(StatsD-style example; substitute your metrics ingestion.)

## Alarm thresholds

| Signal | Threshold | Action |
|--------|-----------|--------|
| `drift_sessions == 0` | (steady state) | green |
| `drift_sessions > 0` in any 5-min window | one session drifted | **page** — production regression in flight |
| Gateway restart + drift fires immediately on next session | the new deploy introduced drift | **rollback** that deploy |

The "any drift = page" sensitivity is correct because drift is not a
sometimes-acceptable event. Either the prompt-construction code preserves
byte stability or it doesn't. There's no graceful-degradation zone.

## Triage runbook

When the alarm fires:

1. **Identify the drifting session**:
   ```bash
   jq -s 'group_by(.session) | map(select(
       length > 1 and
       (([.[].stable_prefix_hash] | unique | length) > 1 or
        ([.[].tail_hash] | unique | length) > 1)
     )) | .[]' /var/log/nullalis/stability.jsonl | head -50
   ```

2. **Determine which half drifted**:
   - `prefix_hashes` length > 1 → system prompt drifted.
     Likely cause: a volatile-block field is rendering into the stable half,
     or vice-versa. Check the most recent `src/agent/prompt.zig` change
     plus `src/agent/context_engine.zig::assemble` callsite.
   - `tail_hashes` length > 1 → kept-history tail drifted.
     Likely cause: Pass-C summarization is firing on a turn that should
     have kept the tail unchanged; or `F-PA2 drop-from-middle` invariants
     broke. Check most recent compaction.zig change.

3. **Reproduce locally**:
   ```bash
   export NULLALIS_STABILITY_JSON_PATH=/tmp/repro.jsonl
   rm -f $NULLALIS_STABILITY_JSON_PATH
   ./zig-out/bin/nullalis gateway --host 127.0.0.1 --port 3000 &
   # Replay 2+ turns of the same session_key matching the drifting one
   # (use curl + same X-Internal-Token).
   jq -c '.' /tmp/repro.jsonl
   ```

4. **Find the offending commit**:
   ```bash
   git log --since="<deploy window>" -- src/agent/prompt.zig src/agent/context_engine.zig src/agent/compaction.zig
   ```

5. **Fix** — typically: the new field is rendering into the stable half but
   contains turn-variable data (timestamps, conversation context, memory
   slot, etc.). Move it to the volatile half (`buildVolatileSystemPrompt`).

## Rollback

Stability emission is a passive diagnostic — disabling it has zero impact
on agent behavior. To rollback (e.g., disk pressure, unforeseen issue):

```bash
# Single-host:
sudo systemctl unset-environment NULLALIS_STABILITY_JSON_PATH
sudo systemctl restart nullalis-gateway

# Or edit the systemd unit:
sudo systemctl edit nullalis-gateway
#   ... remove Environment= line ...
sudo systemctl daemon-reload
sudo systemctl restart nullalis-gateway
```

The gateway boots without the env var; `writeStabilityJsonl` no-ops
(`getEnvVarOwned ... catch return`). The existing JSONL file remains for
post-mortem analysis until logrotate prunes it.

## Honest config notes (§14.6)

- The env var is **default OFF in production** and **default ON in
  `.spike/run.sh`** (the CI bench harness). Operators must opt in for prod.
- The JSONL is **append-only**, **flock-serialized across writers**, and
  **best-effort** (all filesystem errors are silent at the writer side —
  drift detection is diagnostic, not blocking).
- The drift assertion in CI (`.spike/run.sh`) fails the bench with `exit 2`
  on detected drift. The production canary uses the same `jq` shape but is
  consumed by your metrics pipeline, not by an exit code.

## What this does NOT catch

- **Inter-session drift.** Two different sessions naturally have different
  hashes (different session_id in the volatile prompt, possibly different
  identity slot content). The assertion only fires on **intra-session**
  hash divergence.
- **Cross-deploy stability.** When you deploy v1.14.X → v1.14.Y, the stable
  prefix legitimately changes (new prompt content, new tool descriptions).
  Sessions that span the deploy boundary will show drift. This is expected
  and benign. Restart sessions on deploy if you want clean signal.
- **Provider-side cache evictions.** If Together's KV cache is full and
  evicts your prefix, the cache miss is invisible to us — we'd still see
  byte-stable hashes. This monitor catches OUR drift, not the provider's.
