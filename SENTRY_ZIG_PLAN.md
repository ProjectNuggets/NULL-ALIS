# Sentry Zig Independence Plan

## Goal

Make `nullALIS` independent from the upstream `nullclaw/sentry-zig` repository without breaking the current build, tests, or release flow.

This branch exists to prepare that cutover separately from the active runtime and transport work.

## Current State

The repo currently depends on:

- `https://github.com/nullclaw/sentry-zig/archive/refs/tags/v0.1.0.tar.gz`

in [build.zig.zon](/Users/nova/Desktop/nullclaw/build.zig.zon).

That is technically correct today because:
1. the upstream repo exists
2. the URL is valid
3. the hash is already pinned
4. builds are green

## Why Split This Work

We want two things at once:
1. keep the current codebase stable
2. reduce external dependency ownership risk over time

Those are compatible if we treat Sentry independence as a separate hardening track rather than mixing it into runtime feature work.

## Target End State

`nullALIS` should depend on a dependency source we control.

Preferred order:
1. fork `sentry-zig` into GitHub under our control
2. keep the dependency API identical at first
3. switch `build.zig.zon` to the new source
4. refresh hash
5. validate
6. only then consider any local patches or branding changes inside the dependency

## Options

### Option A: Keep Upstream

Pros:
1. zero work now
2. lowest immediate risk
3. existing hash and URL already work

Cons:
1. external ownership risk remains
2. brand inconsistency remains in dependency source
3. less supply-chain control

### Option B: Fork Upstream

Pros:
1. full dependency ownership
2. better supply-chain control
3. easier future patching
4. cleaner long-term brand alignment

Cons:
1. more maintenance
2. needs hash refresh and validation
3. adds one more repo to own

### Option C: Vendor the Dependency

Pros:
1. maximum control
2. no network dependency at build time after vendoring

Cons:
1. larger repo
2. less clean dependency lifecycle
3. update path becomes heavier

## Recommendation

Use **Option B**:

1. fork upstream as-is
2. switch the dependency source only
3. do not patch behavior in the same step

This preserves stability and creates independence with minimal functional risk.

## Implementation Sequence

### Phase 1: Fork
1. create private or internal repo for `sentry-zig`
2. import upstream history
3. verify the release/tag we currently use exists in the fork

### Phase 2: Dependency Source Switch
1. update `build.zig.zon`
2. replace the upstream URL with the fork URL
3. refresh package hash
4. keep package name usage unchanged unless the dependency itself requires a rename

### Phase 3: Validation
Run:

```bash
zig build test --summary all
zig build -Doptimize=ReleaseSmall
```

Acceptance:
1. no source changes required outside dependency URL and hash
2. test suite remains green
3. release build remains green

### Phase 4: Optional Hardening
Only after the source switch is stable:
1. review the forked dependency code
2. decide whether branding inside the dependency matters
3. decide whether to vendor later

## Risks

### Risk 1: Wrong dependency hash
Mitigation:
1. let Zig compute the correct hash during the first fetch failure
2. update only the provided value

### Risk 2: Upstream tag mismatch
Mitigation:
1. mirror the exact tag or exact commit we currently pin
2. do not “upgrade while forking”

### Risk 3: Hidden behavior change
Mitigation:
1. source switch only
2. no dependency code edits in the same change
3. run full test/build validation

## Acceptance Criteria

This track is complete when:
1. `build.zig.zon` points to a repo we control
2. `zig build test --summary all` passes
3. `zig build -Doptimize=ReleaseSmall` passes
4. no runtime behavior changed as part of the switch

## What Not To Do

1. do not patch runtime behavior and dependency source in one change
2. do not rename package APIs without a real need
3. do not block transport/runtime work on this branch unless the dependency actually becomes unstable
