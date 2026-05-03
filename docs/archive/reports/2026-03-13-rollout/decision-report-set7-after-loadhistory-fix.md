---
tags: [prose, prose/docs]
---

# Decision Report (Set7 After `Agent.loadHistory` Safety Patch)

Date: 2026-03-13  
Owner: Codex (runtime/platform)  
Scope: single rerun set with same posture as set6 after `Agent.loadHistory` copy-safety patch

## Posture (unchanged from set6)

- endpoint: `/api/v1/chat/stream`
- token: `dev-internal-token`
- timeout: `240s`
- isolation probe: user `1000`, `count=3`, `interval_ms=250`
- lane strategy:
  - 20 users: `main_only`
  - 50 users: `mixed_real`
  - 100 users: `main_only`

Artifacts:
- `canary-set7-20.json`
- `canary-set7-50.json`
- `canary-set7-100.json`
- `set7-prerun-diagnostics.json`

## Results

20 users:
- success: `0/20`
- errors: `100%`
- reason mix: `sse_error_done=19`, `http_error=1`
- isolation: `inconclusive`

50 users:
- success: `0/50`
- errors: `100%`
- reason mix: `exception=35`, `stream_no_done=15`
- isolation: `inconclusive`

100 users:
- success: `0/100`
- errors: `100%`
- reason mix: `sse_error_done=85`, `http_error=15`
- isolation: `inconclusive`

## Crash Evidence in Set7

Latest crash reports during this run:
- `~/Library/Logs/DiagnosticReports/nullalis-2026-03-13-022700.ips`
- `~/Library/Logs/DiagnosticReports/nullalis-2026-03-13-023225.ips`

Faulting stack (both):
- `debug.FullPanic(...).incorrectAlignment`
- `mem.Allocator.dupe`
- `memory.engines.markdown.MarkdownMemory.parseEntries`

## Interpretation

1. The patched `Agent.loadHistory` path is no longer the active crash signature in this rerun.
2. The current dominant crash path under burst is now in markdown memory parsing (`MarkdownMemory.parseEntries`).
3. Rollout remains blocked (`HOLD`), and isolation remains inconclusive because all tiers failed.

## Decision

Decision: **HOLD**

## Next Action

Apply the next P0 fix to the markdown parsing copy path:
- harden `memory.engines.markdown.MarkdownMemory.parseEntries` against incorrect-alignment/unsafe-dupe conditions,
- add a targeted regression test around misaligned/edge line parsing,
- rerun one clean set under the same posture.
