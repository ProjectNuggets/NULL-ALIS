---
tags: [prose, prose/docs]
---

# Session 1 — `.spike/run.sh` benchmark gate

**Copy the block below into a fresh Claude Code session at `/Users/nova/Desktop/nullalis`.**

---

You are running the `.spike/run.sh` benchmark harness against a locally-running nullalis gateway (already up on `127.0.0.1:3000`). Your job is to gate the Sprint 2 (PR #10) and D8 (PR #11) PRs by confirming no regression vs the `87cb435` baseline.

## Working directory

`/Users/nova/Desktop/nullalis`

## What's running

- Gateway on `127.0.0.1:3000` (Nova started it; don't kill it).
- PostgreSQL local (same machine, whatever port/config nullalis's `config.json` points at — you don't need to touch it directly).

## What to do

Run each step, report the result, STOP and ask if anything fails unexpectedly.

### Step 1 — sanity check the gateway is up

```sh
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:3000/health
# expect: 200
```

If not 200, stop and tell Nova.

### Step 2 — cold battery

```sh
./.spike/run.sh
```

Save the last line (TSV row) and the per-category summary. The harness writes full outputs to `.spike/runs/<timestamp>/`.

### Step 3 — polluted battery

```sh
./.spike/run.sh --polluted
```

Same capture. Polluted mode reuses the `:main` session key — exercises accumulated context, which is where Sprint 2's entitlement-gate changes could drift pass rates.

### Step 4 — compare to baseline

The prior iteration baseline is tagged on commit **`87cb435`**. Look at `.spike/results.tsv` for the baseline row. Compute the delta against the run you just did:

- **Pass rate** — if ≥ 5% regression → BLOCK. Tell Nova.
- **Mean latency p50** — if ≥ 20% regression → BLOCK. Tell Nova.
- **Mean tool calls** — informational; big swings are interesting but not gating.

### Step 5 — report

Post ONE message to the user containing:

1. Cold TSV row + pass rate + p50 vs baseline delta.
2. Polluted TSV row + pass rate + p50 vs baseline delta.
3. PASS / BLOCK verdict for Sprint 2 + D8.
4. Any benchmark that regressed by ID — paste the benchmark's `grading` block from `.spike/benchmark.json` + your summary of what the agent actually did in the run.
5. Path to the full run directory so Nova can spelunk.

Nothing more. Do not start any remediation. Do not edit code. Do not commit. Your output is the verdict.

## If the gateway isn't on :3000

```sh
# Quick probe
nc -z 127.0.0.1 3000 && echo "up" || echo "down"
```

If down: tell Nova. Don't try to start it — you don't have the right config + API keys loaded.

## Don't

- Don't modify `.spike/benchmark.json` or `.spike/run.sh` (both are locked for iteration-loop reproducibility).
- Don't commit anything.
- Don't delete `.spike/runs/` entries — Nova uses them as audit trail.

## Cites

- `.spike/run.sh` comments — usage contract
- `.spike/results.tsv` — baseline row at `87cb435`
- `docs/sprints/sprint-2.md` — scope of what the benchmark is gating
