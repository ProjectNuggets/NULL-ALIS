# Sandbox deployment guide (V1.5)

**Audience:** operators deploying nullalis to production Linux hosts.
**Status:** ready as of `4f27487` + sandbox-finish ACE commit.

## TL;DR

- **Default behavior is now AUTO.** When no `sandbox` block is in `config.json`, nullalis probes the host once at boot for available backends (firejail, bwrap, docker) and enables the best one it finds. If none are present, sandbox stays off.
- **Production hosts MUST install bubblewrap** (or firejail or docker) before deploy. Without one of them and with `sandbox.enabled=true` (or `null` + a real backend NOT detected), shell tool will refuse to run with `error.SandboxUnavailable`.
- **Dev hosts can flip the safety release.** Set `sandbox.fail_open_on_dev = true` to log-warn-and-pass-through when no backend is found, so dev work continues without bwrap installed.

## Resolution rules (config → runtime)

| `sandbox.enabled` | `sandbox.fail_open_on_dev` | Real backend? | Effective behavior |
|---|---|---|---|
| `null` (default) | `false` (default) | yes | **Sandbox ON, strict.** Detected backend used. Shell isolated. |
| `null` (default) | `false` (default) | no | **Sandbox OFF.** Shell runs unsandboxed; protected only by `policy.workspace_only` + tenant-mode refusal. |
| `null` (default) | `true` | no | **Sandbox OFF + warn.** Same as above but with a log.warn surface. |
| `true` | `false` (default) | yes | **Sandbox ON, strict.** Same as auto-on. |
| `true` | `false` (default) | no | **FAIL-CLOSED.** Shell tool refuses with `SandboxUnavailable`. **Production-correct.** |
| `true` | `true` | no | **Sandbox OFF + warn.** Same warn-and-pass behavior as auto-with-no-backend + dev opt-in. |
| `false` | (any) | (any) | **Sandbox OFF.** No probe, no warn. Use only in single-tenant pods where the pod itself isolates. |

## Recommended config per environment

### Production (Linux shared-runtime, multi-tenant)

```json
{
  "security": {
    "sandbox": {
      "enabled": true,
      "fail_open_on_dev": false
    }
  }
}
```

**Plus on the host:** `apt install bubblewrap` (Debian/Ubuntu) or `dnf install bubblewrap` (Fedora) or `apk add bubblewrap` (Alpine). Verify with `bwrap --version` returning exit 0.

This config is strict-by-design: any deploy to a host without bwrap surfaces immediately at first shell invocation rather than silently shipping unsandboxed shell to paying users.

### Dev macOS (with Docker Desktop running)

No config needed — `auto` mode detects docker and uses it. If you want explicit:

```json
{
  "security": {
    "sandbox": {
      "enabled": null,
      "backend": "docker"
    }
  }
}
```

Docker isolation costs ~100-300ms per shell call. Acceptable for dev.

### Dev macOS or Linux (no bwrap, no Docker, accept reduced isolation)

```json
{
  "security": {
    "sandbox": {
      "fail_open_on_dev": true
    }
  }
}
```

Sandbox auto-disabled at boot (no real backend found); shell runs unsandboxed; you see one `[sandbox] (warn): no real backend available` line per shell call so the trust boundary is visible in logs.

### Single-tenant per-user pod (deferred per Nova directive)

```json
{
  "security": {
    "sandbox": {
      "enabled": false
    },
    "policy": {
      "autonomy": {
        "workspace_only": false
      }
    }
  }
}
```

Pod itself provides the isolation boundary; in-process sandbox is redundant.

## Backend selection priority

When `backend = "auto"` (default), detection order on each platform:

- **Linux:** firejail → bubblewrap → docker → noop
  - Note: landlock variant exists in the enum but is **fail-closed** until the syscall layer ships (`security/landlock.zig`). Auto-detect skips it.
- **macOS:** docker → noop
  - bwrap and firejail are Linux-only.

Explicit `backend` selection (e.g., `"backend": "bubblewrap"`) skips the priority ladder but still runs the per-binary `--version` probe; if the probe fails, falls back to noop and then per the resolution table above.

## Operational verification

1. **Confirm boot log line.** After starting the gateway, search logs for `[sandbox] (info)`:

   ```
   [sandbox] (info): sandbox: enabled=true backend=bubblewrap fail_open_on_dev=false workspace=/var/zaki/<user> avail={firejail:false bubblewrap:true docker:false}
   ```

   This is the operator's truth check on what was selected. If `enabled=true backend=auto` shows up, the auto-resolve fell through (no real backend) — install one and restart.

2. **Test shell isolation.** Send the agent a shell command like `cat /etc/passwd` (read of a host file outside the workspace). With sandbox active, bwrap binds only `/usr` (read-only), `/dev`, `/proc`, `/tmp`, and `<workspace> → /workspace`. `/etc` is NOT mounted, so the cat fails with ENOENT. Compare with sandbox disabled (succeeds, leaks host data).

3. **Test cross-tenant FS read.** With multi-tenant runtime active, send agent a command like `cat /var/zaki/<other-user-id>/secrets.txt`. Without sandbox: succeeds (process UID matches). With sandbox: fails with ENOENT (path not bound). This is the cross-tenant read vector the sandbox closes.

4. **Test escape via env.** Send `env | grep -i key` — sandbox should show only the safe-listed env vars (TERM, PATH, etc. from `SAFE_ENV_VARS` in `shell.zig`). API keys are not present.

## Performance

- **Boot probe:** 1-3 fork+execve+wait cycles. ~30ms on Linux per probe; ~200-500ms total on macOS through Docker Desktop daemon. **Once per agent init**, cached for the lifetime of that agent.
- **Per-shell-call overhead** (after boot probe):
  - bwrap: ~5-10ms (namespace setup)
  - firejail: ~50-150ms (full profile evaluation)
  - docker: ~100-300ms (container start; image must be local)
  - noop: 0ms

The boot probe was the latency surprise from blocker 3; it now runs once instead of per-call. If you see per-shell-call overhead matching docker numbers on a Linux production host, your deployment is missing bwrap and falling through to docker — install bwrap.

## What this does NOT cover

- **Network isolation:** bwrap with `--unshare-all` removes network namespaces; commands inside the sandbox cannot make outbound connections. If you need *some* network (e.g., agent runs `curl api.openai.com`), today the answer is: don't sandbox shell, use the dedicated `web_fetch`/`http_request` tools that go through the runtime's HTTP layer (proxy-aware, audit-logged). Mixed network is a V1.5 follow-up.
- **CPU/memory limits:** the sandbox layer doesn't apply cgroups. Use k8s pod limits or systemd slice limits for resource caps. See `config.security.resources` for the (currently advisory-only) hint fields.
- **Per-tool wrapping beyond shell+git:** see `docs/sandbox-tool-coverage.md`.
- **Landlock LSM-based filesystem ACLs:** stub-only as of `4f27487`. See follow-up tracker.

## Follow-ups (not in scope here)

- Sub-cwd translation in bwrap (host `workspace_dir/sub` → sandbox `/workspace/sub`)
- Landlock syscall layer implementation
- gVisor / CubeSandbox / SmolVM (Firecracker) backends — see `docs/sandbox-activation-plan.md`
- Per-tenant sandbox-resource caps (cgroup integration)

— ACE shipped 2026-04-28 as part of V1.5 sandbox-finish.
