# Silent-catch policy (D16, post-Sprint-8 codebase)

**Single source of truth for when `catch {}` is acceptable in nullalis,
and when it should be `catch |err| log.warn(...)`.** Established 2026-04-25
during the GitHub-Actions-freeze deferred-debt drain (D16 first-pass).

## Why we have so many of them

307 silent-catch sites across 57 source files as of `main`@6d9a78b. Most
predate the Sprint-1 observability work that established
`captureError`/log.warn discipline. Sprint 4's silent-catch-sweep (S4.1-3,
shipped) cleared the obvious data-loss risks (autosave, learning facts,
session save) — D16 is the residual classification + targeted fix work.

## The classification

Every `catch {}` falls into exactly one of three buckets:

### 1. Noisy-by-design — keep silent

**Acceptable when:** the failure is normal flow control, not an operational
signal. Logging would spam logs without operator value. Examples:

  - **Process cleanup** (`child.kill() catch {}`, `child.wait() catch {}`)
    after a process is being torn down anyway. The "failure" is
    "process already dead" or "OS reaped it first" — by-design.
  - **SSE/WebSocket write to a known-disconnected client.** EPIPE /
    ECONNRESET on a stream the client just closed is normal flow.
  - **Builder-pattern `appendSlice` on local ArrayList** when an
    allocator OOM in the middle of building a log message would
    just cascade more OOM. Better to drop the partial log line
    than to spam OOM warnings about the OOM warning.
  - **Idempotent cleanup that's already-done.** `unlink(path) catch {}`
    where missing-file is the desired end-state.

**Convention:** add a comment naming the by-design reason. Future
maintainers should see WHY the catch is silent, not just that it is.

```zig
// Process is being killed; reap-or-not-reap is by-design.
_ = child.kill() catch {};
```

### 2. Operator-critical — convert to logged catch

**Convert when:** the failure means a real-world surface is broken and
the operator needs to know. Examples:

  - **Tenant workspace scaffolding** (`ensureFileWithDefault` for
    `memory_db_path`, `config_path`, etc.). Failure here means the
    user has no working state; silently continuing produces a
    user-visible bug minutes later, far from the cause.
  - **Filesystem permission errors on protected paths** that should
    succeed (state directory, secret store, etc.).
  - **Database write failures** outside of the autosave/learning-fact
    paths Sprint 4 already covered.
  - **Audit-log write failures** — silently dropping audit entries
    breaks the audit-trail contract.
  - **Metric record failures** that mask production-traffic accounting.

**Convention:** named-error catch with `log.warn` + the original error
name + enough context to grep for the call site:

```zig
ensureFileWithDefault(ctx.config_path, "{}\n") catch |err| {
    log.warn("workspace.config_scaffold_failed user_id={s} path={s} err={s}",
        .{ ctx.user_id, ctx.config_path, @errorName(err) });
};
```

### 3. Bubble-up — replace catch with try

**Convert when:** the failure should propagate to the caller for a real
decision. Examples:

  - **Allocator OOM** in code paths where the caller can recover
    (free a cache, retry with smaller payload, return 500). Hiding
    OOM behind `catch {}` makes the resulting null-pointer crash
    look like an unrelated bug.
  - **Parser failures on operator-supplied input.** The operator
    needs the 400-with-error-detail, not silent fallback to defaults.

**Convention:** replace `catch {}` with `try` and let the error type
flow up. If the caller's signature can't carry it, that's the actual
fix needed — escalate.

## D16 first-pass (2026-04-25)

Converted 5 operator-critical sites in `src/gateway.zig`:
  - 5x `ensureFileWithDefault` calls in tenant workspace scaffolding
    (memory_db_path, config_path, cron_path, heartbeat_path,
    channel_state_path) — failure here breaks every subsequent user
    action with a confusing downstream null.
  - `onboard.scaffoldWorkspace` at the same site.

Tagged 16 process-cleanup sites in `gateway.zig` (lines 2486-2556) as
explicitly noisy-by-design with a single batch comment. The cluster was
already idiomatic; the comment makes the intent permanent.

**302 sites remain.** They split roughly:
  - ~120 in `gateway.zig` (post-conversion residual, mostly
    SSE-write-to-disconnected-client and builder cleanup)
  - ~180 across the other 56 files

Triage them via the three buckets above the next time each surface is
touched. A speculative "convert all 302 in one PR" risks regressing
quiet-by-design sites; an operator-pain-driven sweep ("we lost a
metric, why?") is the right trigger.

## How to add a new silent catch

1. Decide which bucket it belongs in BEFORE writing it.
2. If bucket 1: add the by-design comment above the line.
3. If bucket 2 or 3: don't write `catch {}`. Use `catch |err|
   log.warn(...)` or `try`.

If reviewer can't tell which bucket your `catch {}` is in, the comment
is missing.

## Status disposition

This doc replaces D16's "do a 307-site classification PR" framing
with "establish policy + first-pass + operator-pain trigger for the
rest." Updated in `docs/deferred-register.md` D16 row at the same
commit that ships this doc.
