# V1.14.4 — Booth-Readiness Sprint Code Review

**Date:** 2026-05-09
**Reviewer:** gsd-code-reviewer subagent + author response
**Branch:** `v1.14.4/booth-readiness`
**Closures:**
- Item 1 — Channel FE placeholders (Teams + Email added; WhatsApp removed)
- Item 2 — Approval drop bug (production wiring intact; regression-lock test added)
- Item 3 — Subagent "received" bug (gateway OOM fail-loud + stderr fallback)
- Item 4 — Autonomy toggle end-to-end wire-up (ProductSettings field + parse/merge/apply)

**Build status (post-fixes):** 5983/6043 tests pass (+8 from V1.14.3 baseline of 5975), 60 skipped. ReleaseFast binary 9.9 MB. Frontend typecheck clean for source files (pre-existing test-tooling errors in *.test.tsx are unrelated).

---

## Verdict: **SHIP** (after first-pass fixes landed)

First-pass verdict was **SHIP-WITH-FIXES**. The reviewer caught one Critical contract mismatch (CR-01) that would have made the autonomy toggle visibly broken at the booth, plus four Medium and one Low requiring follow-through. All landed in the same branch.

---

## Findings + responses

### CRITICAL CR-01 — Autonomy enum string contract mismatch. **FIXED.**

**Issue:** Backend `AutonomyLevel.toString()` emitted `"readonly"` (no underscore) while the FE TypeScript union at `ZakiSettingsSheet.tsx:80` was strictly `"read_only" | "supervised" | "full"`. Round-trip break:
- First-load with non-default autonomy: FE radio group has nothing selected (no value matches `"readonly"`)
- Summary label key `levels.readonly.label` doesn't exist → i18next renders raw key
- Save flow: user clicks `read_only`, backend stores it, echoes `"readonly"`, problem persists

**Fix:** One-line change in `src/security/policy.zig:21`:
```zig
.read_only => "read_only",  // was "readonly"
```
Plus updated tests in `policy.zig:967` and `user_settings.zig:867` that asserted the old literal. `fromString` remains permissive (accepts both `"readonly"` and `"read_only"`) for backward-compat with stored configs.

**Verification sweep:** `grep -rn '"readonly"' src/ --include="*.zig"` post-fix shows only doc comments + the `fromString` accept-both branch. No other call site relied on the underscoreless form.

### HIGH HI-01 — Subagent stderr fallback comment vs code mismatch. **FIXED.**

**Issue:** Comment claimed "Debug builds: panic. Release builds: dump to stderr." Code did neither — the stderr dump fired in `std.debug.runtime_safety` builds (Debug + ReleaseSafe) but NOT in ReleaseFast. Production lost the content while the comment claimed it didn't.

**Fix:** Rewrote the comment block at `subagent.zig:709` to honestly describe what the code does:
- Debug + ReleaseSafe (`runtime_safety = true`): stderr dump fires
- ReleaseFast (production): log.warn only, content lost — same as pre-V1.14.4 on this branch

This is honest disclosure: production users still don't see the result. Acceptable for booth because the path that actually ships (gateway tenant) is now closed by the OOM-propagation fix elsewhere.

### HIGH HI-02 — "Fix B above" reference + missed second OOM site. **FIXED.**

**Issue:** Subagent.zig diff comment claimed "Now mitigated at the dispatch site (Fix B above)" — but Fix B didn't exist. Worse: `gateway.zig:18485` had the same `allocator.create(SubagentCompletionRouter) catch null` pattern that was supposedly closed at line 1411, but only one of the two sites was actually fixed.

**Fix:**
1. Applied the same `catch null` → `try` change at `gateway.zig:18485` (standalone-mode router init).
2. Rewrote the subagent.zig:709 comment to honestly describe what V1.14.4 closes vs what's deferred:
   - Tenant init OOM: **closed** (both line 1425 + line 18491 now `try`).
   - main.zig:2760 / 3083 standalone CLI: **NOT FIXED** at the dispatch site; only mitigated by debug-build stderr fallback. Tracked as F-2 for V1.14.5.

### MEDIUM MD-01 — Backward-compat hole in `deriveNearestFromAgentObject`. **FIXED.**

**Issue:** When a tenant's stored config had `cfg.autonomy.level = "supervised"` (operator-set) but no `product_settings` block, the legacy fallback path returned `defaults()` ⇒ autonomy=.full. This silently elevated autonomy beyond what the operator configured the moment the user opened the FE settings sheet.

**Fix:** Modified `deriveNearestFromConfigJson` at `user_settings.zig:218` to extract top-level `autonomy.level` BEFORE delegating to the agent-shape snapper, then merge it into the result. Three cases handled:
1. Operator-set `autonomy.level` + agent block → snap from agent, override autonomy from operator
2. Operator-set `autonomy.level` + no agent block → defaults() with autonomy override
3. Operator-set `autonomy.level` accepted in both new (`"read_only"`) and legacy (`"readonly"`) forms

Added test "V1.14.4 review MD-01: operator-set cfg.autonomy.level honored when product_settings absent" with 4 sub-cases: supervised/read_only/legacy-readonly/no-agent-block.

### MEDIUM MD-02 — Test struct field-shape audit. **CONFIRMED CLEAN.**

Reviewer flagged: confirm `SecurityPolicy.autonomy` field shape after CR-01 fix. Verified at `policy.zig:96` — field is `autonomy: AutonomyLevel = .supervised`, the test's `.autonomy = .full` initializer compiles correctly. No bug.

### MEDIUM MD-03 — FE/backend default autonomy mismatch. **FIXED.**

**Issue:** Backend default `.full` (config_types.zig:67) vs FE default `"supervised"` (ZakiSettingsSheet.tsx:102). Fresh-install tenants would silently demote autonomy on first save (FE patch logic detected the inequality and sent the FE default).

**Fix:** Changed FE `DEFAULT_SETTINGS.autonomy` to `"full"` to match the backend. Comment block explains the rationale (config_types.zig:60-66 has the canonical "v1 single-pod ships .full" justification). The `(recommended)` label on the supervised radio remains as a SAFETY recommendation for future shared-pod scenarios; v1's actual default is full.

### MEDIUM MD-04 — Redundant import path. **FIXED.**

**Issue:** `user_settings.zig:4-5` imported `security/policy.zig` directly to get `AutonomyLevel`, but `config_types.zig:13` already re-exports it as `config_types.AutonomyLevel` with a documented "single source of truth" comment. The direct import bypassed the documented indirection.

**Fix:** Switched to `const AutonomyLevel = config_types.AutonomyLevel;` honoring the existing re-export.

### LOW LO-01 — Stale "WhatsApp" comment. **FIXED.**

Updated the comment block at `ZakiSettingsSheet.tsx:438` to reflect the V1.14.4 swap: "Telegram, Slack, Discord, Microsoft Teams, Email" with rationale for dropping WhatsApp (Meta Business API auth dance out of booth-week scope).

### LOW LO-02 — Built artifacts in working tree. **NOTED, NOT FIXED.**

`dist/index.html` + `dist/assets/index-*.{css,js}` deleted/added in working tree. Author flagged "ignore" but acknowledges this is sloppy. Not booth-blocking; clean up in next FE deploy commit.

### LOW LO-03 — Unnecessary `defaultValue` fallbacks. **NOTED, NOT FIXED.**

The `defaultValue` argument on `t()` calls for Teams + Email is dead code given both en.json and ar.json have the keys. Defensive style for the rare third-locale case; harmless. Leave.

### LOW LO-04 — `.empty` initializer in test agent. **NOTED, INFORMATIONAL.**

Reviewer flagged for `git blame` posterity: `defer agent.history.deinit(allocator)` on a never-grown empty list is a no-op. Kept for symmetry. No change.

---

## Tests added in V1.14.4 + post-review

| File | Test | Purpose |
|---|---|---|
| `user_settings.zig` | `V1.14.4: autonomy default is .full and survives patch round-trip` | Default + patch coverage |
| `user_settings.zig` | `V1.14.4: applyPatchToSettingsJson rejects invalid autonomy` | Bad-input rejection |
| `user_settings.zig` | `V1.14.4: applySettingsToConfig propagates autonomy into cfg.autonomy.level` | Config propagation across all 3 levels |
| `user_settings.zig` | `V1.14.4: pre-V1.14.4 stored configs without autonomy key default to .full` | Backward-compat with old configs |
| `user_settings.zig` | `V1.14.4: renderSettingsJson includes autonomy` | Wire-format render |
| `user_settings.zig` | `V1.14.4: mergeSettingsIntoConfigJson writes canonical autonomy` | Wire-format merge |
| `user_settings.zig` | `V1.14.4 review MD-01: operator-set cfg.autonomy.level honored when product_settings absent` | Backward-compat hole closed |
| `agent/root.zig` | `V1.14.4 booth-readiness: approval_continues_turn defaults to true (regression lock)` | Lock the production default |

Test count delta: **+8** from V1.14.3 baseline (5975 → 5983 passing; 6035 → 6043 total).

---

## Open follow-ups (V1.14.5+)

| ID | Item | Severity | Notes |
|---|---|---|---|
| F-1 | main.zig:2760 + 3083 standalone CLI subagent dispatch sites | Medium | No completion_delivery wired. Mitigated by debug-build stderr fallback only; ReleaseFast standalone CLI still loses subagent results. CLI is rare for booth (gateway tenant is the demo path). |
| F-2 | Built artifacts (`dist/`) tracked in zaki-prod | Low | Tracked deploy artifact policy needs review; clean up in next deploy. |
| F-3 | G-12 PII scrubbing admin CLI | Medium | Carry-over from V1.14 audit. Legal/GDPR for B2C launch. |

---

## Booth-week ship judgment

**SHIP.** The V1.14.4 sprint closes the four booth-blocking items the way it claimed to:
- Autonomy toggle works end-to-end (after CR-01 fix).
- Approval flow is production-wired and regression-locked.
- Subagent "received" bug closes the production tenant path; standalone CLI mitigated for debug, deferred for V1.14.5.
- Channel placeholders refreshed for booth's GCC/MENA + B2B audiences.

The reviewer's first-pass dissent was material — CR-01 alone would have made the headline feature visibly broken on stage. Author responded by landing every blocking + Medium fix in the same branch. No deferred booth-blockers remain.

---

## Files changed (final)

```
src/agent/root.zig         | 43 ++ — approval regression-lock test
src/gateway.zig            | 24 ++ — fail-loud OOM at TWO router init sites
src/security/policy.zig    | 14 ~~ — toString emits "read_only"; tests + comment
src/subagent.zig           | 41 ~~ — honest comment on stderr fallback scope
src/user_settings.zig      | 234 ++ — autonomy field + 7 tests + MD-01 fallback
docs/REVIEW-v1.14.4-...md  | NEW   — this doc

zaki-prod/.../ZakiSettingsSheet.tsx  | 38 ~~ — Teams+Email; FE default .full; comment
zaki-prod/.../i18n/locales/en.json   | 10 ~~ — teams + email keys
zaki-prod/.../i18n/locales/ar.json   | 10 ~~ — Arabic translations
```

Verdict: **SHIP.**
