---
phase: 03
slug: canonical-session-and-context-runtime
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-11
---

# Phase 03 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Zig built-in test runner |
| **Config file** | `build.zig` (test step) |
| **Quick run command** | `zig build test --summary all 2>&1 \| tail -20` |
| **Full suite command** | `zig build test --summary all` |
| **Estimated runtime** | ~45 seconds |

---

## Sampling Rate

- **After every task commit:** Run `zig build test --summary all 2>&1 | tail -20`
- **After every plan wave:** Run `zig build test --summary all`
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** 45 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 03-01-01 | 01 | 1 | REQ-007 | T-03-01 | sessionKeyOwnedByUser check | unit | `zig build test --summary all` | ❌ W0 | ⬜ pending |
| 03-01-02 | 01 | 1 | REQ-007 | — | :main removal, thread key generation | unit | `zig build test --summary all` | Partial (existing key tests) | ⬜ pending |
| 03-02-01 | 02 | 2 | REQ-008 | — | session_controls compact delegates | unit | `zig build test --summary all` | ❌ W0 | ⬜ pending |
| 03-02-02 | 02 | 2 | REQ-008 | — | session_controls reset clears, keeps metadata | unit | `zig build test --summary all` | ❌ W0 | ⬜ pending |
| 03-03-01 | 03 | 2 | REQ-009 | — | context_engine 4 phase lifecycle | unit | `zig build test --summary all` | ❌ W0 | ⬜ pending |
| 03-04-01 | 04 | 3 | REQ-009 | — | context report endpoint returns JSON | integration | `zig build test --summary all` | ❌ W0 | ⬜ pending |
| 03-05-01 | 05 | 1 | REQ-017 | T-03-02 | saveMessage passes provenance to Postgres | unit | `zig build test --summary all` | ❌ W0 | ⬜ pending |
| 03-05-02 | 05 | 1 | REQ-017 | — | deriveMemoryProvenance correct for all 4 lanes | unit | `zig build test --summary all` | YES | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] Tests for `listSessions` method in `src/session.zig`
- [ ] Tests for `session_controls.zig` (compact/reset/export functions)
- [ ] Tests for `context_engine.zig` (4 phase lifecycle)
- [ ] Tests for updated `saveMessage` vtable signature (provenance params)
- [ ] Tests for `/api/v1/sessions` endpoint handlers in gateway

*Existing test infrastructure covers all other claims — no framework install needed.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Thread sidebar renders in ZAKI-Prod | REQ-007 | Frontend activation via external repo | Open ZAKI-Prod, verify thread list populates via SSE |
| Session controls buttons work | REQ-008 | UI integration requires frontend | Click compact/export/reset in ZAKI-Prod |
| Context transparency panel | REQ-009 | Visual verification needed | Check context panel shows provenance badges |
| Provenance badges display correctly | REQ-017 | Frontend rendering | Send messages from different channels, verify badges |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 45s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
