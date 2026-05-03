---
tags: [prose, prose/docs]
---

# QA/QS Fix Baseline — 2026-03-13

## Baseline Snapshot

- Branch: `v0.2-scale-exec-swisswatch`
- SHA: `97feaafe6ea48ecde23e286df1f7c786a0308647`
- Timestamp (local): `2026-03-13`
- Working tree at baseline: dirty (pre-existing knob-wiring changes in docs + runtime files)

## Dirty Tree Inventory (Pre-fix)

- `docs/branches/v0.2-scale-exec-swisswatch.md`
- `docs/v0.2-single-source-of-truth.md`
- `src/agent/root.zig`
- `src/channel_loop.zig`
- `src/diagnostics/runtime_truth.zig`
- `src/doctor.zig`
- `src/gateway.zig`
- `src/main.zig`
- `src/session.zig`
- `src/status.zig`
- `src/tools/message.zig`
- `src/tools/runtime_info.zig`
- `src/voice.zig`
- `docs/reports/2026-03-13-knob-wiring/` (new report directory)

## Gate Results (Pre-edit)

1. `zig build test --summary all`
   - Result: PASS
   - Summary: `4542 passed`, `21 skipped`
2. `zig build -Dengines=base,sqlite,postgres`
   - Result: PASS

## Notes

- This baseline is the start point for phased QA/QS fixes:
  - session TTL safety race
  - queue semantics alignment
  - config+slash knob parity
  - TTS text non-mutation behavior
