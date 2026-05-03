---
tags: [prose, prose/docs]
---

# Sprint 8 — Design Decisions — CLOSED 6/6 (2026-04-24)

**Branch:** `repair/sprint-8-design-decisions` (off `main` tip `31e812f`)
**Opened:** 2026-04-24
**Closed:** 2026-04-24 — 6 decisions captured with rationale, code, and date.
**Target:** every W5 ambiguity gets a YES/NO/DEFER call with written rationale; resulting code lands in this branch; deferred follow-ups go to the register.

## Decisions (6)

### S8.1 — Lane-aware memory retrieval — **B (Label)**
SHA: `462ce54`

**The question:** today, memory retrieval filters by session_id implicitly (the lane is buried in the session_id string format). Should we elevate that to: keep-as-is, label retrievals with their origin lane, or filter at the vtable level?

**The call:** Label. Add `lane: []const u8 = "unknown"` to `MemoryEntry` + `RetrievalCandidate`, populate via the new public `laneFromSessionId()` helper. Borrowed-string-literal pointer — no alloc/free coupling. The agent layer can now rank same-lane candidates higher heuristically without re-parsing session_id at every call site.

**Why not Filter (Option C):** would have forced a vtable signature change across pgvector + sqlite + qdrant impls (~6-8 files). Latent value, real cost. Future evolution preserved if cross-lane noise ever shows.

**Why not Keep-as-is (Option A):** the filtering is real today but invisible to callers. Exposing the label costs 3 fields and pays off any time we want to tune ranking.

**Wire:** `src/memory/root.zig` (struct field + public helper), `src/memory/retrieval/engine.zig` (struct field + mirror in `entriesToCandidates`), `src/memory/engines/sqlite.zig` (row reader populates lane).

---

### S8.2 — `buildThreadSessionKey` legacy vs canonical — **B (Dual-formatter, formalize)**
SHA: `d722b39`

**The question:** two parallel session-key thread builders coexist. Migrate, dual-parser, or deprecate?

**The call (revised mid-sprint):** initial pick was Migrate (A). Closer investigation revealed they're not legacy-vs-canonical at all — they serve two different routing surfaces:
- `agent_routing.buildThreadSessionKey(base, thread_id)` builds the **channel-routed** family `agent:{agent_id}:{channel}:{kind}:{id}:thread:{tid}` used by `daemon.zig:1709` for inbound from Telegram/Discord/Slack.
- `session/root.userThreadSessionKey(buf, user_id, conv)` builds the **user-cell** family `agent:zaki-bot:user:{id}:thread:{conv}` used by HTTP/SSE turn loops.

Migrating the daemon caller to the user-cell formatter would have silently produced a key shape inbound reply paths can't decode — a real regression dressed as cleanup.

**Wire:** doc comments on both formatters cross-referencing each other, inline anti-migrate guard at `daemon.zig:1709`. Three files, zero behavior change.

**Optional polish:** D30 in the deferred register tracks an optional rename (`buildChannelRoutedThreadSessionKey`) to kill the name collision. ~20 ref-site updates; not load-bearing.

---

### S8.3 — `NULLCLAW_` → `NULLALIS_` rebrand — **C (Park with deadline)**
SHA: `1be6e1a`

**The question:** 80 NULLCLAW_* refs vs 61 NULLALIS_* refs across the codebase. Mass-replace, park, or park-with-deadline?

**The call:** park with deadline. **Sunset 2026-05-15** baked into `sentry_runtime.NULLCLAW_SUNSET_DATE`. The three `*WithFallback` shim helpers in `sentry_runtime.zig` now fire a once-per-process banner via `cmpxchgStrong`-guarded atomic flag, and the per-key warning includes the date string. `observability.zig::OtelObserver.fromEnv` warning text matches the same format.

**Why not full migration (A):** breaks operators still setting NULLCLAW_*. Mass replace is a big lift and offers nothing today's shim doesn't.

**Why not indefinite park (B):** locks in the dual-name tax forever. The 80-ref tail is too big to leave as "done."

**Honest scope:** this commit only upgrades the SHIM-helper paths. Direct-read sites in `cell_k8s_api.zig` (16 vars) + `providers/api_key.zig` + `zaki_state.zig` test gates bypass the shims and stay quiet for now. **D28** is the hard-deadline forcing function: those direct-read sites must migrate to dual-name before sunset.

---

### S8.4 — Dormant channel implementations — **A (Delete dingtalk; defer flag-gating)**
SHA: `c969e88` (combined with S8.6)

**The question:** 15 (actually 19 + virtual webhook) dormant channels. Delete, formalize as flag set, or keep?

**The call:** delete only the one stub with no working code (dingtalk: 121 LoC, 0 tests, comment admitted incomplete Stream Mode WebSocket). The other 5 dormant-working channels (whatsapp, lark, email, line, maixcam) carry full implementations and stay as roadmap code. Formalizing flag-gating as `@import` conditionals is infrastructure work that belongs in its own PR; not in scope for Sprint 8.

**Surface cleaned (10 files):** dingtalk.zig deleted, 9 other files lose their dingtalk references (channel_catalog enum + meta + 3 dispatch arms; channel_manager test fixture + assertions; config.zig type re-export + parse-test; config_types.zig struct + field + accessor; integrations.zig catalog row; websocket.zig header; gateway.zig route comment; build.zig flag + parse + addOption + help text).

---

### S8.5 — `.task` lane production path — **A (Already wired; tick and close)**
SHA: this docs commit

**The question:** wire when multiagent flips, delete until ready, or keep inert?

**The call:** the question's premise is stale. Audit found `.task` lane is FULLY wired across `subagent.zig:890` (`isTaskLaneSession`), `spawn.zig:178`, `runtime_info.zig` (multiple test asserts), `diagnostics/runtime_truth.zig:323`, and the gateway lane-metric counters. Activation is gated by `NULLALIS_ENABLE_MULTIAGENT` (S6.3); when off, the spawn tool is filtered from the metadata registry so task-lane sessions never get created — but the machinery is ready. No code change needed; closure is the doc capture itself.

---

### S8.6 — `channels/dingtalk.zig` — **C (Delete)**
SHA: `c969e88` (rolled into S8.4)

**The question:** add tests, mark dormant, or delete?

**The call:** delete. 121 LoC, 0 tests, no roadmap signal, no customer demand. Recreating from scratch costs less than maintaining a dead stub. Recovery comments left in `channel_catalog.zig` + `channels/root.zig` + `config_types.zig` so a future maintainer who needs DingTalk knows exactly which surfaces to restore.

---

## Deferred to the register (3 new)

- **D28** — NULLCLAW_* direct-read migration (cell_k8s_api.zig + api_key.zig + zaki_state test gates) before 2026-05-15 sunset. Hard deadline.
- **D29** — Vtable-level lane filtering if cross-lane noise becomes observable. Conditional, not scheduled.
- **D30** — Rename `agent_routing.buildThreadSessionKey` → `buildChannelRoutedThreadSessionKey`. Optional polish.

(D25-D27 from Sprint 7B land via PR #21 when it merges into main.)

## Sprint 8 DoD

- [x] Each of the 6 decisions has a YES/NO/DEFER with written rationale and date.
- [x] Code lands per decision in atomic commits with SHAs cited above.
- [x] Follow-up code queued in the deferred-register with explicit triggers (sunset date for D28, conditional for D29, optional for D30).
- [x] `zig build test -Dengines=base,sqlite,postgres -Dchannels=cli,telegram` green at every commit.

## Pattern observation worth preserving

Mid-sprint course correction on S8.2 was the right kind of Swiss-watch discipline: the original recommendation (Migrate) would have shipped a regression. Pausing to verify, surfacing the correction to the operator, and re-pitching honestly cost ~10 minutes and avoided a real bug. Future decision sprints should expect at least one such pause-and-re-pitch — they're a feature, not a friction tax.
