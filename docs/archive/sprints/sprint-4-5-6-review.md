---
tags: [prose, prose/docs]
---

# Sprint 4 / 5 / 6 consolidated self-review

Post-hoc review of PRs #15 (Sprint 4 — Silent-Catch), #16 (Sprint 5 —
Architectural Correctness), #17 (Sprint 6 — Dead Code Removal). Same
structure as `sprint-2-review.md`: findings classified HIGH / MEDIUM /
LOW / INFO; HIGHs fixed inline on the matching branch; MEDIUMs either
fixed inline or tracked as deferred items; LOWs noted.

## Scope

Fourteen commits reviewed end-to-end:

- **Sprint 4** — `5d2c04a`, `0bbeadf`, `19ed54a`, `0503468`, `e2a6203`
- **Sprint 5** — `477d520`, `3a8da9e`, `831a50c`, `0e997de`, `3550539`, `4a23d6c`
- **Sprint 6** — `08f3729`, `917b9ce`, `46ef65e`, `4492bf3`

## Findings

### HIGH

None. All 14 commits compile, tests pass, and the changes do what the
commit messages claim.

### MEDIUM

**MED-1 — `cachedConfigForCaps()` returns a pointer that would dangle
on reassignment (S5.7, PR #16).**

File: `src/agent/root.zig`. `cachedConfigForCaps` returns
`if (self.cached_config) |*cfg| cfg else null` — the pointer is into
the optional payload of `self.cached_config`. Safe today because no
call site reassigns the field. Latent hazard if a future
`invalidateConfigCache()` helper lands and reassigns without regard
for outstanding pointers.

Disposition: **fixed inline on PR #16** with an explicit invariant
comment on the field declaration forbidding reassignment after first
successful load.

**MED-2 — Streaming context-exhaust retry misses the `llm_response
success=true` event (S5.3, PR #16).**

File: `src/agent/root.zig`. On retry success the code falls through
to normal stream-result handling but does not emit a second
`llm_response` observer event to match the initial
`llm_response success=false`. Dashboard aggregating `llm.response`
outcomes would undercount successes in the specific retry path.

Disposition: **fixed inline on PR #16**. On retry success the code now
emits `llm_response success=true` with the retry duration + null
error_message, so both halves of the retry pair show up in the event
stream.

**MED-3 — Two readers of `NULLALIS_ENABLE_MULTIAGENT` could disagree
(S6.3, PR #17).**

`buildDefaultTools` reads the env once at Agent construction;
`multiagentEnabledEnv` reads it on every `defaultMetadataRegistry()`
call. If third-party code inside the process called `setenv()`
between those reads, the registry and the runtime would disagree —
metadata for delegate/spawn appearing while the tools themselves
aren't registered, or vice versa. Not realistic in nullalis today
(we don't setenv) but a latent trap.

Disposition: **fixed inline on PR #17**. Cache the result in a
module-scoped atomic `u8` (0 = unread, 1 = false, 2 = true) so the
first reader wins and subsequent reads are lock-free.

### LOW

**LOW-1 — S5.4 anytype causes two function instantiations.**
The `buildToolsSection(w, tools: anytype)` signature means Zig
compiles one function body per distinct slice element type. Today
that's `[]const Tool` (production) + `[]const MockTool` (the new
test). Small binary-size cost (~1 KiB); worth the duck-typing
symmetry with `dispatcher.buildToolInstructions` which already does
this. No fix needed.

**LOW-2 — S6.3 FixedBufferAllocator 16-byte cap.** `multiagent
EnabledEnv` uses a 16-byte stack buffer for `getEnvVarOwned`. Values
longer than 16 bytes would OOM the FBA and fall through to
`catch return false`. In practice valid values are "0" / "1" / "true"
/ "false" — all fit. Parity with the `buildDefaultTools` unlimited-
alloc path is preserved because both readers trim-then-compare "1".
No fix needed; documented in the helper's comment.

### INFO (confirmed intentional)

**INFO-1 — S5.3 retry reuses `stream_timing_ctx` across attempts.**
`saw_stream_first_token` and `first_token_ms` accumulate across the
failed attempt + the retry. This reflects the user-observable latency
correctly (the user waited through both) and the comment in the retry
block calls it out.

**INFO-2 — S4.7 health `markComponentError` parity.** Matches the
startup-path pattern already used throughout `daemon.zig` for
scheduler, channels, and gateway. Consistent.

**INFO-3 — S6.1a rag.zig has no consumers.** Pre-delete grep confirmed
the sole reference was the re-export at `src/root.zig:88`. Clean.

**INFO-4 — S4.12/13 `replace_all` behavior in two SSE loops.** The
commit message explicitly notes that the same catch-pair pattern lives
in the initial replay loop and the live subscription loop; the
`replace_all` changes both. Intentional; documented.

## DoD verification (post-review)

- All three inline fixes compile: `zig build` green on Sprint 5 PR and
  Sprint 6 PR branches after the fix commits.
- Full test suite green: `zig build test` exit 0 on both PR tips post-
  fix; no test regressions.
- Review artifact (this file) shipped on the `docs/sprints/` path,
  matching Sprint 2's `sprint-2-review.md` pattern.

## Deferred-but-tracked from review

None. MED-1 / MED-2 / MED-3 all fixed inline; LOW-1 / LOW-2 accepted;
INFO items confirmed correct.

## Process note

This review fires when a sprint batch lands, not before. Production
commits are not held hostage to the review — the shipped work
already passed `zig build`, `zig build test`, and the per-commit
eyeballing in-flight (e.g. the `gateway --help exit 1` bug caught
mid-S3.4 by running the smoke locally). The review pass catches what
in-flight self-critique misses: cross-commit invariants (dangling
pointers, observability parity, env-racy reads) that only become
visible once the full sprint is on paper.
