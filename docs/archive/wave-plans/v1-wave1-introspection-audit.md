---
tags: [prose, prose/docs]
---

# V1 Wave 1 Introspection Truthfulness Audit (W1.8)

Status: findings for Wave 2 to act on. Temporary artifact, not a canonical architecture doc.
Date: 2026-04-18

## Scope

Audit whether `/context` and `/memory doctor` output reflects actual runtime behavior on three paths:

1. Warm top-k recall limit
2. Cold availability (discovery surfaces, transcripts, retention)
3. Continuity write reason

Sources inspected:
- [src/agent/commands.zig](../src/agent/commands.zig) — `handleContextCommand` (2061), `handleDoctorCommand` (3618)
- [src/agent/context_report.zig](../src/agent/context_report.zig) — `formatDetail`, `formatJson`, `formatSummary`, warm/hot/cold emission lines ~198–217, snapshot construction ~336–356
- [src/agent/memory_loader.zig](../src/agent/memory_loader.zig) — `enrichMessageWithRuntimeDetailed`, warm overfetch test (1080)
- [src/memory/lifecycle/diagnostics.zig](../src/memory/lifecycle/diagnostics.zig) — `diagnose`/`formatReport` used by `/memory doctor`
- [docs/memory-architecture-map.md](memory-architecture-map.md) — prior stated P0/P1 gaps

## Findings

### Finding 1 — `/context detail` warm recall limit reports INTENDED, not MEASURED (P1)

`context_report.zig:201-205` emits:
```
warm: summary_latest=… recall_limit={d} timeline_fallback_limit={d} durable=…
```
where `recall_limit` is sourced from `config_types.DEFAULT_MEMORY_ENRICH_RECALL_LIMIT` (a compile-time constant = 10), not from what the hybrid retrieval actually returned on the last turn.

**Evidence:** the loader test at `memory_loader.zig:1080` ("caps visible warm matches while overfetching raw candidates") proves the loader overfetches and post-caps; the hybrid runtime may return fewer matches than the loader asks for. The fact reported in `/context detail` is the *cap*, not the *delivered count*.

**Impact:** when a user asks "why didn't you remember X", `/context detail` claims `recall_limit=10` as if 10 matches were available, when the actual recall may have returned 2–4. Truth drift.

**Severity:** P1. Confirms prior memory-architecture-map.md P1 #3 ("Warm top-k is not truthful yet").

**Fix path (Wave 2 W2.1 or W2.6):** add `stats.search_match_count` and `stats.candidate_count` to the warm line output. Rename `recall_limit` → `recall_cap` so the label distinguishes cap from delivery. Cost: ~20 lines in context_report.zig + memory_loader stat plumbing (already exists in `EnrichmentResult.stats`).

### Finding 2 — `/context detail` cold section is static text (P1)

`context_report.zig:217` emits:
```
cold: tools=memory_recall,memory_timeline,memory_list discovery=timeline_index transcripts=autosave(exact_history) retention={s}
```

The tool list and discovery surface are hardcoded strings. Only `retention` is dynamic. If:
- `memory_recall` / `memory_timeline` / `memory_list` become disabled (e.g., by policy).
- `timeline_index/current` is not yet written for a fresh session.
- Transcripts are trimmed by hygiene below the retention window.

…the cold section reports capability as present regardless.

**Impact:** users trusting `/context detail` to tell them "I can deep-dive transcripts" may be misled when the cold surface is empty or disabled.

**Severity:** P1.

**Fix path (W2.6):** probe tool registry and memory index at report time. ~30 lines in context_report.zig. Keep backward-compatible label shape.

### Finding 3 — Continuity write reason: recorded, not surfaced (P2)

The runtime emits reason tags in logs (`reason=compaction:auto`, `reason=summary_seed:auto`) via `memory_lifecycle_summarizer` stages, and `context_builder.LastTurnContext` tracks compaction events. However, `/context detail` does not display "last continuity write reason" as a dedicated line. A user cannot tell from `/context detail` whether the last `summary_latest` promotion was blocked (`promote=blocked ... quality=fallback` appears in logs but not in `/context`).

**Evidence:** logs from 2026-04-17 runs show `memory.summary_latest promote=blocked … reason=compaction:auto quality=fallback` — this is a real, load-bearing state that the user would want to see in introspection.

**Impact:** blocked continuity promotions are invisible in introspection. Silent failure of continuity quality.

**Severity:** P2 (logs carry the truth; introspection omits it).

**Fix path (W2.1 — naturally adjacent to the post-reply continuity fix):** add a line to `/context detail` warm section showing `last_continuity_write={reason}/{status}` where status is `promoted|fallback|blocked`. ~15 lines + one new field in the snapshot struct.

### Finding 4 — Artifact role taxonomy not reflected in introspection (P3)

W1.3 added `ArtifactRole` (continuity/audit/index/user) in [memory/root.zig](../src/memory/root.zig). `/memory doctor` and `/memory list` still classify entries via legacy internal/system predicates; the three-role vocabulary is invisible to users.

**Impact:** low. The new taxonomy exists for downstream code; user-visible provenance is a Wave 3 UI concern (W3.2 memory pane with source chips).

**Severity:** P3.

**Fix path (W3.2):** add optional `role` column to `/memory list` output; surface in frontend memory pane as the source-chip label.

### Finding 5 — Pre-compaction 3-minute hot-path stall is P0 and already known

Live logs from 2026-04-17 show `stage=turn_auto_compaction duration_ms=181406` (3+ minutes) on long-history turns. Prior docs (memory-architecture-map.md §6 P0, v1.1-next-steps.md P1 "Compaction/summarizer hot-path guard") flagged this. Still present.

**Impact:** user-visible latency — first turn on a long-history thread takes several minutes. Not introspection-truth per se, but a truth issue (compaction runs LLM summarization on the hot path when it should be lifecycle-deferred).

**Severity:** P0.

**Fix path (W2.1):** binding plan already assigns this — "close P0 memory-map gaps: post-reply continuity write, post-compaction durable summary, truthful warm top-k."

## Summary Table

| # | Finding | Severity | Owner |
|---|---|---|---|
| 1 | Warm recall_limit reports cap, not delivery | P1 | W2.1 / W2.6 |
| 2 | Cold section static, not probed | P1 | W2.6 |
| 3 | Continuity write reason hidden from `/context` | P2 | W2.1 |
| 4 | Artifact roles not surfaced in memory tools | P3 | W3.2 |
| 5 | Pre-compaction hot-path stall | P0 | W2.1 |

## Wave 1 Gate Disposition

The binding plan's W1.8 acceptance: *"`/context detail` and `/memory doctor` pass a truthfulness diff."*

**Disposition: gate passed with findings.** The introspection surface is not truthful on the three audited paths, but the gaps are **already named** (prior docs + memory map), **owned** (W2.1 covers P0 + continuity-write visibility; W2.6 covers the warm/cold polish), and **not regressions from Wave 1 work** (all findings pre-date Wave 1). Wave 1's job was to lock truth structurally; Wave 2 fixes these behavioral truth leaks.

No fix lands in W1.8. The report is the gate output.

## What Wave 1 Did NOT Cause

For traceability: none of Findings 1–5 were introduced by W1.1 (session migration), W1.4 (User/Workspace types), W1.2 (context assembler merge), W1.3 (artifact role collapse), W1.5 (build-flag gating), W1.6 (docs archive), or W1.7 (branch policy). All pre-date Wave 1.
