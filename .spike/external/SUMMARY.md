# External Benchmark Harness — Status & Plan

**Date:** 2026-05-09
**Branch:** `main` (post-V1.14.4 + F-1 + HI-03)
**Owner:** Mohammad / Nova
**Verdict:** harness committed & ready; live run blocked on a Together provider issue; baseline pending

---

## Goal

Run two external, third-party benchmarks against nullalis to produce booth-credible numbers:

| Bench | Authority | What it tests | Top-of-pack target |
|---|---|---|---|
| **LoCoMo** (Snap Research, ACL'24) | ★★★ | Long-conversation memory across multi-session dialogs | 78-82% (mem0 ~74%, Letta ~71%, Zep ~69%) |
| **BFCL** v4 (Berkeley) | ★★★★★ | Function-calling format compliance + agentic memory + multi-turn | Match-or-exceed Kimi K2.6's bare model score |

Strategic note: the V1.14.4 review reminded us "BFCL scores the model more than the runtime." LoCoMo is the bench that actually exercises nullalis's V1.13/V1.14 brain stack (wiki + temporal_anchor + episodes + bi-temporal validity + working memory + procedural memory).

---

## What's shipped this sprint

### 1. BFCL — install verified, deferred (CR-style honest)

- Repo: `gorilla/berkeley-function-call-leaderboard/` cloned to `.spike/external/gorilla/`
- BFCL v4 installed via `pip install bfcl-eval` (Python 3.11 venv at `.spike/external/gorilla/berkeley-function-call-leaderboard/.venv/`)
- CLI works: `bfcl --help`, `bfcl test-categories` confirmed
- **Blocker:** BFCL's `KimiHandler` hardcodes `https://api.moonshot.ai/v1` and reads `KIMI_API_KEY`. We don't have a Moonshot direct key (we use Together). Two paths:
  - **A** (~2-3h): register a custom model entry in BFCL pointing to Together's OpenAI-compat endpoint at `https://api.together.xyz/v1` with `moonshotai/Kimi-K2.6` model name
  - **B** (~half day): build OpenAI-compat shim in nullalis gateway exposing `/v1/chat/completions` → routes through our agent (this would actually bench the runtime, not just the model)
- **Decision for booth:** cite Kimi K2.6's published BFCL score (when Moonshot publishes it; older K2 was ~88% on FC). Add path B (gateway OpenAI shim) to V1.14.5 backlog so we can run BFCL through nullalis directly.

### 2. LoCoMo — adapter built end-to-end

Located at `.spike/external/locomo_runner/`:

```
locomo_runner/
├── .venv/              # Python 3.9 venv (requests only)
├── run_bench.py        # the adapter (340 LOC)
└── runs/               # per-run output (timestamped)
```

**Dataset confirmed:**
- 10 conversations, 272 sessions, ~5882 dialog turns
- 1986 QA pairs across 5 categories:
  - Cat 1 (single-hop): 282
  - Cat 2 (multi-hop): 321
  - Cat 3 (temporal): 96
  - Cat 4 (open-domain): 841
  - Cat 5 (adversarial): 446

**Adapter capabilities:**
- Loads each conversation session as a single user message into a fresh nullalis session via `POST /api/v1/chat/stream` (SSE)
- Uses canonical session-key shape `agent:zaki-bot:user:1:task:locomo_<run_id>` (gateway-validated)
- Handles `ownership_lock_conflict` (409) with adaptive backoff using `lease_until_s` from server hint
- Allows extraction queue to drain (10s) between conversation load and probe phase
- Probes each QA → captures reply → scores via substring + Jaccard token overlap (first cut)
- Writes per-sample + aggregate accuracy to `runs/<ts>/results.json`

**Scoring methodology:**
- First-cut: exact substring containment OR Jaccard ≥ 0.5 → pass
- Production: replace with LLM-judge (GPT-4 or our own K2.6) per LoCoMo paper (`task_eval/evaluate_qa.py` in the upstream repo). Tracked as F-S1.

**Cost estimate per full conversation:** ~25-40 min wall + ~$2-3 in Together API ($0.30-0.50 per session × 27 sessions).
**Cost estimate full bench (10 conversations):** ~6 hours wall + ~$25-35.

---

## Blocker: Together stream.attempt hangs under load

### What we observed

Live test pattern (gateway log, three independent attempts):

```
info(provider_reliable): stream.attempt provider=together model=moonshotai/Kimi-K2.6 attempt=0
[gateway hangs indefinitely; never logs stream.completed or stream.failed]
[Python adapter sees Response ended prematurely / ECONNREFUSED]
[gateway process exits silently — no panic, no segfault, no abort signal]
```

Reproduced after the second turn on a session that had ~134 message history (~40K tokens of context). The first turn (cold session, ~10K tokens) succeeded. The hang correlates with a larger context window + Together's streaming endpoint.

### What we know
- **K2.6 IS available on Together** (verified via `GET /v1/models`)
- **K2.6 is what nullalis runs** (gateway log: `model=moonshotai/Kimi-K2.6 ctx_tokens=262144 max_tokens=32768 reasoning=high`)
- nullalis config still references K2.5 (`/Users/nova/.nullalis/config.json`); per-user override resolves to K2.6 at runtime
- The hang is not local: nullalis's `provider_reliable` retry logic doesn't even fire its retry counter — the SSE upstream from Together never returns a chunk
- `nullalis gateway` then exits silently. No panic. No abort. Likely SIGPIPE or connection-reset deferred-exit.

### What this means for booth
- For the demo flow (single short turn, fresh context) — works fine
- For any heavy-context or sustained-load run (LoCoMo bench, multi-turn agent eval) — Together's K2.6 endpoint is the choke point

### Open questions for the next debugging sprint (F-G1)
1. Is the hang Together-side (their K2.6 endpoint flaky on large contexts)? Verify via direct curl to Together API with same context size.
2. Does the gateway's `provider_reliable` configure `connect_timeout` + `read_timeout` for streaming responses? If not, hang is unbounded.
3. Should we add a wall-clock cap per `stream.attempt` independent of inter-chunk timeout?
4. Should the gateway exit-on-fail vs degrade-and-respond-with-error? Current behavior (silent exit) is the worst case.

---

## How to actually run the bench (when blocker clears)

```bash
# 1. Boot gateway
cd /Users/nova/Desktop/nullalis
./zig-out/bin/nullalis gateway --host 127.0.0.1 --port 3000 &

# 2. Wait for ownership lock from prior run (if any) — usually <60s
sleep 60

# 3. Smoke test (1 conv, 1 session, 3 QAs)
cd .spike/external/locomo_runner
source .venv/bin/activate
GATEWAY_TOKEN="<from /Users/nova/.nullalis/config.json gateway.internal_service_tokens[0]>" \
  python3 run_bench.py --sample 0 --max-sessions 1 --max-qa 3

# 4. Single-conversation full run (~35 min, ~$3)
GATEWAY_TOKEN="..." python3 run_bench.py --sample 0 --max-sessions 27 --max-qa 199

# 5. Full bench (~6h, ~$30)
GATEWAY_TOKEN="..." python3 run_bench.py --all
```

Output lands in `runs/<timestamp>/results.json` with per-sample + aggregate scoring.

---

## Optimization queue once baseline lands

Categories where V1.14 brain architecture should outperform mem0/Letta/Zep:

| LoCoMo Category | nullalis lever | Expected delta |
|---|---|---|
| **Cat 2 multi-hop** | brain_graph local_graph (V1.7a-3) traverses typed edges; mem0 has no graph | +5-10pp |
| **Cat 3 temporal** | `temporal_anchor_unix` (V1.14) + bi-temporal `valid_from/valid_to` (V1.5) | +10-15pp vs flat-vector |
| **Cat 4 open-domain** | wiki+entity coreference (V1.6 cmt8) + V1.14.2 wiki_link path | +3-5pp |
| **Cat 5 adversarial** | `elideUnverifiedHistory` filter (iter11) + summarizer-downgrade (iter C) + V1.13 prose_judge | +5-10pp vs naive recall |

If baseline lands in 70-75% range, we have 4 distinct optimization levers ready:
1. **Tune retrieval k** in `loadContextWithRuntime` (currently 8) — bench-driven sweep
2. **Activate brain_graph local_graph** as a default tool call when query mentions named entities
3. **Verify episode_key plumbing** (V1.14.3 G-03) actually surfaces in retrieval ranking
4. **Audit semantic threshold** at `BRAIN_SEMANTIC_THRESHOLD = 0.7` — too high may starve recall

---

## V1.14.5+ backlog

| ID | Item | Why |
|---|---|---|
| **F-G1** | Together stream.attempt hang debug | Booth-blocking under load |
| **F-G2** | Gateway OpenAI-compat shim (`/v1/chat/completions`) | Unlocks BFCL + any OpenAI-shaped bench |
| **F-S1** | LLM-judge scoring (replace Jaccard fallback) | Per LoCoMo paper methodology |
| **F-S2** | Bench results dashboard at `.spike/external/dashboard.md` | Track score history per commit |

---

## Files committed in this sprint

```
.spike/external/SUMMARY.md                           # this doc
.spike/external/gorilla/                              # cloned BFCL repo (gitignored)
.spike/external/locomo/                               # cloned LoCoMo dataset (gitignored)
.spike/external/locomo_runner/run_bench.py           # adapter, 340 LOC
.spike/external/locomo_runner/.venv/                  # gitignored
.spike/external/locomo_runner/runs/                   # gitignored (output)
```

`.gitignore` will need a new section to exclude `.spike/external/{gorilla,locomo}/` (cloned upstream) and `.venv/` + `runs/` (per-machine artifacts) while keeping `SUMMARY.md` + `locomo_runner/run_bench.py` versioned.

---

**Next session:** debug F-G1 (Together stream hang), unblock LoCoMo live run, baseline → optimize → leaderboard claim.
