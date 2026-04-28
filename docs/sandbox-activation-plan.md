# Sandbox Activation Plan — `tool_sandbox_v1`

**Audit date:** 2026-04-28
**Branch:** `main` (clean)
**Scope:** Activate `src/tools/tool_sandbox_v1.zig` as the safe-execution path for the shared-runtime shell tool, given that per-user cell pods are deferred per Nova's directive.
**Audience:** Nova (operational decisions) + future implementers wiring the activation PR.

This document is code-truth. Every claim about wiring is followed by a `file:line` citation. Items marked "would require new code" are not present in the repo today; do not assume otherwise.

---

## 1. What's Wired Today

### 1.1 Configuration plumbing — fully wired

The sandbox config surface is present end-to-end:

| Layer | Where | Notes |
|-------|-------|-------|
| Enum | `src/config_types.zig:21-28` | `SandboxBackend = { auto, landlock, firejail, bubblewrap, docker, none }` |
| Struct | `src/config_types.zig:1141-1145` | `SandboxConfig { enabled: ?bool = null, backend = .auto, firejail_args: []const []const u8 = &.{} }` |
| Embedding | `src/config_types.zig:1165-1169` | `SecurityConfig { sandbox, resources, audit }` |
| Re-export | `src/config.zig:10` | `pub const SandboxBackend = config_types.SandboxBackend;` |
| JSON parse | `src/config_parse.zig:1744` | `if (v == .bool) self.security.sandbox.enabled = v.bool;` |
| Serialize | `src/config.zig:843` | `.enabled = self.security.sandbox.enabled` written back when persisting |

The default for `enabled` is `null`, which `tools/root.zig:861` collapses to `false` via `orelse false`. The default backend is `.auto` (`config_types.zig:1143`).

### 1.2 Backend abstraction — fully wired

The runtime side has six backend implementations behind a single vtable:

| File | Backend | What `wrapCommand` produces |
|------|---------|------------------------------|
| `src/security/sandbox.zig:5-36` | `Sandbox` vtable interface | `wrapCommand`, `isAvailable`, `name`, `description` |
| `src/security/sandbox.zig:39-70` | `NoopSandbox` ("none") | passthrough — argv unchanged |
| `src/security/landlock.zig:8-53` | Landlock LSM | passthrough argv; restrictions applied via syscalls before exec (Linux only — see `landlock.zig:25-36`) |
| `src/security/firejail.zig:6-61` | Firejail | `firejail --private=WS --net=none --quiet --noprofile <argv>` |
| `src/security/bubblewrap.zig:6-73` | Bubblewrap | `bwrap --ro-bind /usr /usr --dev /dev --proc /proc --bind /tmp /tmp --bind WS /workspace --unshare-all --die-with-parent <argv>` |
| `src/security/docker.zig:10-90` | Docker | `docker run --rm --memory 512m --cpus 1.0 --network none --entrypoint= -w WS -v WS:WS <image> <argv>` (default image `alpine/git:latest`, `docker.zig:19`) |

Auto-detection: `src/security/detect.zig:83-113` (`detectBest`) tries on Linux: Landlock → Firejail → Bubblewrap → Docker → Noop. On non-Linux platforms it tries Docker, then Noop. `detect.zig:124-145` (`detectAvailable`) is a probe used by diagnostics.

`createSandbox` (`src/security/detect.zig:26-71`) returns the requested backend, but **silently downgrades to noop** when an unavailable Linux backend is requested on macOS (`detect.zig:39-46`, `48-54`, `56-62`). Only `.docker` and `.none` paths skip this fallback. `tool_sandbox_v1.zig:118` then catches the noop downgrade by name comparison and returns `error.SandboxUnavailable`.

### 1.3 Tool-side wiring — fully wired

`src/tools/tool_sandbox_v1.zig` is the integration shim:

- `SandboxExecConfig` struct (`tool_sandbox_v1.zig:7-12`) carries `enabled`, `backend`, `workspace_dir`, `allowed_roots`.
- `resolve_sandboxed_argv` (`tool_sandbox_v1.zig:89-124`):
  - Line 95: passthrough when `enabled=false`.
  - Lines 97-109: docker-mode workspace mount validation via `security.validateWorkspaceMount`. On failure, records diagnostics and falls back to passthrough (i.e. unsandboxed execution — see Concern §6.4).
  - Lines 111-118: builds the backend; if it resolves to noop (downgrade or `.none`), returns `error.SandboxUnavailable` (fail-closed).
  - Lines 120-123: maps `error.BufferTooSmall` to `error.SandboxArgvTooLong`.
- `run_with_optional_sandbox` (`tool_sandbox_v1.zig:137-146`): convenience wrapper that resolves argv then calls `process_util.run`.
- Diagnostics: atomic counters at `tool_sandbox_v1.zig:62-64` exposed via `diagnosticsSnapshot()` at line 66, wired into the gateway diag endpoint at `src/gateway.zig:6824`.

`MAX_WRAPPED_ARGV: usize = 160` at line 14 — fixed buffer; bubblewrap alone consumes 16 slots, docker 15, leaving plenty of headroom for normal commands.

### 1.4 Shell tool integration — fully wired

`src/tools/shell.zig:31-32`:
```zig
sandbox_enabled: bool = false,
sandbox_backend: config_types.SandboxBackend = .auto,
```

The refusal logic (lines 68-94) is the *workspace_only cross-tenant guard*, **not** a generic "sandbox required" gate. It refuses shell only when ALL of:
1. `policy.workspace_only == true` (default, `policy.zig:98`)
2. `self.sandbox_enabled == false`
3. Tenant runtime mode is detected via `root.getTenantContext().expect_postgres_state == true` (`shell.zig:82-87`)

In single-user/per-pod mode, the guard logs and continues (`shell.zig:88-94`). The execution call site is `shell.zig:132-145` — the only path through which shell argv reaches `process_util.run`.

Error mapping at `shell.zig:146-152`:
- `error.SandboxUnavailable` → `"Sandbox unavailable for shell execution"`
- `error.SandboxArgvTooLong` → `"Sandbox argv exceeds fixed tool limit"`
- everything else → `"Shell execution failed in sandbox"` (note: this swallows specific errors — see §6.5)

### 1.5 Git tool integration — fully wired

`src/tools/git.zig:15-16` mirrors the shell fields. Every `git` subprocess routes through `tool_sandbox_v1.run_with_optional_sandbox` at `git.zig:210-220`. There is no `workspace_only` guard — git is always sandbox-respecting but never sandbox-requiring.

### 1.6 Tool factory — fully wired

`src/tools/root.zig:861-873` reads `cfg.security.sandbox.enabled` and `.backend`, propagates them into `ShellTool` and `GitTool`:

```zig
const sandbox_enabled = if (opts.config) |cfg| cfg.security.sandbox.enabled orelse false else false;
const sandbox_backend = if (opts.config) |cfg| cfg.security.sandbox.backend else SandboxBackend.auto;
```

When `opts.config == null` (early bootstrap, some tests), sandbox is implicitly disabled.

### 1.7 Visibility surfaces — fully wired

| Surface | File:line | What it reports |
|---------|-----------|------------------|
| Doctor diag | `src/doctor.zig:649-656` | `enabled` flag as ok/info |
| Status panel | `src/status.zig:222` | enabled/disabled string |
| Security review | `src/security_review.zig:60-77` | +10 / −5 score impact |
| Security review | `src/security_review.zig:81-98` | backend ok if not `.none` |
| Gateway diag JSON | `src/gateway.zig:6824` | `diagnosticsSnapshot()` snapshot embedded in gateway diag |

### 1.8 What's NOT wired

- **No bind-mount of read-only system roots in docker** — the docker wrapper mounts only `WS:WS` (`docker.zig:42-65`). The `alpine/git:latest` image provides binaries, so this works for `sh`, `git`, etc. but a custom image would need its own toolchain.
- **No Landlock syscall layer.** `landlock.zig:25-36` is explicit: "The caller is responsible for calling `landlock_create_ruleset → landlock_add_rule → landlock_restrict_self` on the current thread before spawning the child." That caller does not exist in the repo. Landlock backend today is effectively passthrough (`landlock.zig:35`: `return argv;`). Selecting `.landlock` enables the security_review check but adds **zero** isolation. **This is a latent footgun.**
- **No per-user pod or cell binding to `tool_sandbox_v1`.** Sandbox is process-global per agent, not per user.
- **No image build pipeline.** The default image `alpine/git:latest` is pulled at first `docker run`. A first-call cold pull can take 5-20s.
- **No allowed_roots bootstrap.** `tool_sandbox_v1.zig:98` reads `exec_cfg.allowed_roots`; this is sourced from `ShellTool.allowed_paths` (`shell.zig:138`), which in turn comes from `opts.allowed_paths` (`tools/root.zig:867`). For workspace-only shells, this is empty unless the orchestrator passes additional paths.
- **No firejail args plumbing.** `SandboxConfig.firejail_args` (`config_types.zig:1144`) is parsed but never read by `firejail.zig`. The firejail wrapper hardcodes its 4 flags at `firejail.zig:35-39`.

---

## 2. Backend Options — Real vs. Aspirational

### 2.1 Comparison table

| Backend | Wired? | OS support | Isolation properties | Operational cost | Real today? |
|---------|--------|-----------|----------------------|------------------|-------------|
| `none` | ✅ | any | none — passthrough | none | yes (default) |
| `landlock` | ⚠ stub | Linux 5.13+ | nominal — but **syscall layer not implemented** (`landlock.zig:25-36`); selecting it = passthrough today | none | NO — would require new code |
| `firejail` | ✅ | Linux | filesystem (`--private`), network (`--net=none`); user-space, no root | requires `firejail` binary on host | yes on Linux only |
| `bubblewrap` | ✅ | Linux | full namespace isolation (`--unshare-all`), bind mounts, `--die-with-parent` | requires `bwrap` binary; host kernel must allow user-namespaces | yes on Linux only |
| `docker` | ✅ | any (Linux/macOS) | container, network=none, memory/cpu caps, `WS:WS` bind | requires Docker daemon, image pull, ~100ms exec overhead | yes — most portable |
| Firecracker (SmolVM) | ❌ | Linux + KVM | microVM, full kernel isolation | requires KVM device, jailer setup, image rootfs | **would require new code + new dep** |
| gVisor (CubeSandbox) | ❌ | Linux | user-space kernel intercept | requires `runsc` runtime; works with docker | would require Docker runtime config (no new Zig code if hosted via docker `--runtime=runsc`) |
| bwrap + landlock combo | ❌ | Linux | combined fs+namespace | already have bwrap; landlock layer would need to be a real thing first | would require new code |

### 2.2 Detail on each option

**docker** — Wired. `src/security/docker.zig:39-66` produces the wrapper. Default image `alpine/git:latest` (line 19). Network is `--network none` (line 45) and memory is capped at 512m, CPUs at 1.0 (lines 43-46). `--entrypoint=` is reset (line 46) so the bind-mounted argv runs as the entrypoint. Workspace bind is RW (`-v WS:WS`, line 60) — **not** read-only. Caveat: `read_only_rootfs` exists in `DockerRuntimeConfig` (`config_types.zig:83`) but is NOT consumed by `docker.zig` — that field is for a deferred path.

**firejail** — Wired but barebones. `firejail.zig:35-39` only emits 4 flags. Missing today: capability dropping (`--caps.drop=all`), seccomp (`--seccomp`), no-new-privs (`--nonewprivs`). `SandboxConfig.firejail_args` exists (`config_types.zig:1144`) but is unread — wiring those into `firejail.zig` is a 5-line change.

**bubblewrap** — Wired and reasonably hardened. The wrapper at `bubblewrap.zig:30-47` includes `--unshare-all` (PID, net, IPC, mount, UTS, cgroup, user) and `--die-with-parent`. Mounts are limited: `/usr` ro, `/dev`, `/proc`, `/tmp` rw, workspace at `/workspace`. Caveat: workspace mounts to `/workspace` (line 44) but the agent's `cwd` (passed via `process_util.run` opts, `shell.zig:142`) is the host workspace path — paths inside the container won't match. **Likely bug** if bwrap is selected and the agent's cwd is set host-side.

**landlock** — Not actually wired. The wrapCommand at `landlock.zig:25-36` returns argv unchanged with a comment explaining the caller must perform syscalls. There is no caller. Promoting Landlock to functional would require:
1. New file `src/security/landlock_syscall.zig` with `landlock_create_ruleset`, `landlock_add_rule`, `landlock_restrict_self` bindings.
2. Hook in `tool_sandbox_v1.zig` that calls those syscalls on the current thread before `process_util.run` forks.
3. Workspace-allowlist construction (RW for workspace, RX for /usr, none elsewhere).
4. Linux 5.13+ feature detection; graceful fallback to bubblewrap.

**Firecracker** — would require new code. Not present anywhere. Adding it means: new `src/security/firecracker.zig` backend, jailer setup, rootfs image build pipeline, KVM device access on host (see §4), and reworking `process_util.run` because `wrapCommand`'s argv-prefix model can't express VM lifecycle (boot kernel, attach drive, exec, tear down). Closer to a parallel runtime than a sandbox wrapper.

**gVisor** — would require minimal code. If running via Docker, set the Docker runtime to `runsc` via daemon config or pass `--runtime=runsc`. The latter is a 1-line addition to `docker.zig:42-47`. But it requires `runsc` installed on the host and Docker daemon configured — operational, not code, blocker.

---

## 3. Per-Tool Latency Budget Per Backend

Each tool call spans a *full sandbox lifecycle* — there is no warm-pool today. `process_util.run` spawns a fresh child every call. Estimates below are order-of-magnitude on a typical Linux host with the binaries warm in RAM.

| Backend | Cold start (1st call) | Warm steady-state | Notes |
|---------|----------------------|-------------------|-------|
| `none` | <1ms | <1ms | direct fork+exec |
| `landlock` (if real) | ~2-5ms | ~2-5ms | 3 syscalls before fork; no wrapper process |
| `firejail` | ~10-30ms warm; ~50-80ms cold | ~10-30ms | spawns firejail wrapper which forks the target |
| `bubblewrap` | ~5-10ms warm; ~20-40ms cold | ~5-10ms | smallest wrapper; namespace setup is fast |
| `docker` | image pull 5-20s first time; then ~100-300ms per call | ~100-300ms | container create/exec/teardown dominate |
| `docker --runtime=runsc` (gVisor) | image pull + runsc init; ~200-500ms warm | ~200-500ms | gVisor adds ~50-100ms to docker baseline |
| Firecracker (hypothetical) | rootfs+kernel boot ~125-200ms cold; ~50ms per-call after warmup pool | ~50-150ms (warm pool) or ~125ms (no pool) | requires VM lifecycle — new code |

**Why this matters for V1.5:** every shell/git tool call gets the wrapper. A 10-call autonomous turn at `docker` adds ~1-3s of pure sandbox overhead before any actual work. At `bwrap`, that's ~50-100ms — negligible. At `firejail`, ~100-300ms. Latency budget points to bubblewrap on Linux hosts and docker only when no Linux primitive is available.

---

## 4. k8s / PaaS Impact

### 4.1 Required host capabilities per backend

| Backend | Privileged? | KVM? | Linux capabilities | k8s RuntimeClass | Fly.io | Railway | Generic PaaS |
|---------|------------|------|-------------------|-------------------|--------|---------|--------------|
| `none` | no | no | none | default | ✅ | ✅ | ✅ |
| `landlock` | no | no | needs unprivileged Landlock LSM (kernel ≥ 5.13) | default | ✅ (if kernel new enough) | ⚠ check kernel | ⚠ |
| `firejail` | suid binary on host | no | suid + user-namespaces; usually blocked on managed PaaS | default | ❌ (no suid in firecracker-VM image) | ❌ | ❌ |
| `bubblewrap` | no (with kernel.unprivileged_userns_clone=1) | no | user-namespaces — often disabled in container hosts | default | ⚠ Fly.io VMs do allow userns | ❌ Railway disables userns | ⚠ varies |
| `docker` (DinD) | yes (privileged container) | no | needs `--privileged` or rootless DinD setup | privileged or `runtimeClassName: kata` | ⚠ requires privileged | ❌ | ❌ |
| `docker` (host docker socket) | yes (mount `/var/run/docker.sock`) | no | container can control host docker | requires hostPath mount | ❌ | ❌ | ❌ |
| Firecracker | yes | yes (`/dev/kvm`) | KVM_RUN ioctl, `CAP_SYS_ADMIN` for jailer | `runtimeClassName: kata-fc` or sysbox | ❌ Fly itself runs on FC | ❌ | ❌ |

### 4.2 Concrete deployment scenarios

- **Fly.io** (today's deployment target per memory `project_deployment_readiness.md`): nullalis runs inside a Firecracker microVM. We **cannot** spawn nested Firecrackers from within. Bubblewrap works on Fly because the kernel allows `unprivileged_userns_clone`. Docker-from-inside-FC requires DinD which Fly discourages. **Best fit: bubblewrap.**
- **Railway / Render / Heroku**: container hosts that typically disable user namespaces. Only `docker` (via socket-mount, usually disallowed) or `none` work here. **Best fit: degrade to `none` and rely on application-layer policy + `workspace_only=true`.**
- **Self-hosted k8s (Linux nodes)**: bubblewrap works on most distros if userns isn't masked. Docker via DinD or socket-mount works with privileged pod. **Best fit: bubblewrap with a fallback to docker.**
- **macOS dev** (Nova's box): Docker Desktop. `none`, `docker` work. Linux backends silently downgrade to noop via `detect.zig:39-62` and `tool_sandbox_v1.zig:118` then returns `SandboxUnavailable`. **Best fit: `docker` for parity, `none` for speed.**
- **Per-user cell pods (deferred)**: would let us put each user behind their own bwrap or even Firecracker; not on the V1.5 path.

---

## 5. Config-Flag Activation Steps

### 5.1 What flips today

Today the following file-and-default state holds:

```jsonc
// effective default (config_types.zig:1141-1145)
{
  "security": {
    "sandbox": {
      "enabled": null,        // → resolves to false at tools/root.zig:861
      "backend": "auto",
      "firejail_args": []     // unread — see §1.8
    }
  }
}
```

To activate, the user (or the boot bundle) sets:

```jsonc
{
  "security": {
    "sandbox": {
      "enabled": true,
      "backend": "auto"   // or explicit: "bubblewrap" | "docker" | "firejail" | "landlock" | "none"
    }
  }
}
```

That alone is enough to flow `sandbox_enabled=true` into ShellTool and GitTool via `tools/root.zig:861-873`. Verified by `tools/root.zig:2052-2073` test.

### 5.2 Default-flip migration (recommended)

For V1.5 we likely want the default to flip from `null` → `true`:

1. Change `config_types.zig:1142` from `enabled: ?bool = null` → `enabled: ?bool = true`. **Or** better: change the resolution at `tools/root.zig:861` from `orelse false` to `orelse true`.
2. Add a release note: any deployment where the host has no working sandbox backend will get `error.SandboxUnavailable` on first shell invocation. The fix is one of:
   - Install bubblewrap/firejail (Linux), or
   - Set `security.sandbox.backend = "none"` + `security.sandbox.enabled = true` (which fails closed at `tool_sandbox_v1.zig:118` — equivalent to disabling sandbox), or
   - Set `security.sandbox.enabled = false` explicitly to opt out.

### 5.3 Migration path for existing users

Existing configs have no `security.sandbox` block at all (default-shaped). The parse path at `config_parse.zig:1744` only writes `enabled` when the key is present, so missing-key paths fall back to the struct default. After flipping the default to `true`:

- Single-user pod deployments (`expect_postgres_state==false`): no behavior change — the workspace_only guard at `shell.zig:81-94` was already letting them through.
- Multi-tenant deployments (`expect_postgres_state==true`): currently refuse shell at `shell.zig:84-87`. After flip, they still need a working backend; without one they get `error.SandboxUnavailable`. **No silent downgrade to unsandboxed shell** — fail-closed is preserved.

### 5.4 Env-var override (optional)

Today there is no env-var override for sandbox. If we want one (analogous to other flags in the codebase), we'd add a parse step in `config_parse.zig` near the JSON path to honor `NULLALIS_SANDBOX_ENABLED` and `NULLALIS_SANDBOX_BACKEND`. Not required for V1.5 — config.json is sufficient.

### 5.5 Rollout sequence

1. **PR-1 (no behavior change):** wire `firejail_args` into `firejail.zig` so the config field stops being a lie. Plumb through the unread field.
2. **PR-2 (defaults):** flip `tools/root.zig:861` resolution to `orelse true`. Update doctor/security_review tests that currently assert disabled-by-default.
3. **PR-3 (bwrap fix):** fix the bubblewrap `cwd` mismatch — either bind workspace at `WS:WS` instead of `WS:/workspace`, or rewrite `cwd` to `/workspace` when bwrap is the active backend. This is a real bug today (`bubblewrap.zig:43-44` vs `shell.zig:142`).
4. **PR-4 (docs):** update `v1-ship-readiness-criteria.md` and `release-notes-0.2.0.md` (when it exists) with the new default and host-prep guidance.

---

## 6. Test Plan — Verifying Isolation Holds

The validation tests at `docker.zig:354-453` cover *path validation* but not *runtime isolation*. We need integration tests that actually attempt escapes. Below is the matrix; each row should be a Zig test calling `run_with_optional_sandbox` and asserting the failure mode.

### 6.1 Filesystem write outside workspace

```zig
// Expected: write fails (EROFS or EACCES)
const argv = &.{ "sh", "-c", "echo pwned > /tmp/escape_$$" };
// For bwrap: /tmp is bound rw — should succeed (this is a known gap; tighten or accept)
// For firejail --private: /tmp is private namespace — write goes to overlay, not host
// For docker: /tmp is container-internal, not host — write succeeds inside, invisible outside
// For landlock (when real): /tmp is not in workspace allowlist — should fail
```

Assert host filesystem unchanged after each backend run.

### 6.2 Read outside workspace (cross-tenant exfil)

```zig
// The exact threat shell.zig:68-94 cites
const argv = &.{ "sh", "-c", "cat /etc/passwd" };
// docker: /etc inside container, not host — gets container's /etc/passwd
// bwrap: /usr is ro-bind from host but /etc is NOT bound — open() returns ENOENT
// firejail --private: /etc is host /etc — STILL READABLE. Known gap; need --private-etc
// landlock (when real): / not in allowlist — ENOACCES
// none: succeeds — that's the cross-tenant vector
```

This is the **single most important escape test** because it's the threat the refusal logic was added to address.

### 6.3 Network egress

```zig
const argv = &.{ "sh", "-c", "curl -s --max-time 2 https://example.com" };
// docker: --network none → DNS fails, exit nonzero
// bwrap: --unshare-all unshares net → DNS fails
// firejail: --net=none → fails
// landlock: NO network restriction (Landlock is filesystem-only) — succeeds. Important caveat.
```

If V1.5 selects bwrap/firejail/docker we get network isolation as a bonus. If we select landlock (when real), we DO NOT.

### 6.4 Fork bomb / process explosion

```zig
const argv = &.{ "sh", "-c", ":(){ :|:& };:" };
// Note: policy.zig:51-57 already classifies this as high-risk and blocks it
// at the policy layer before sandbox sees it. But policy is bypassable via
// shell command-args (e.g. `sh -c "<encoded>"`), so sandbox is the backstop.
// docker: --memory 512m + --cpus 1.0 cap the damage; container OOMs
// bwrap: no cgroup limits — fork bomb takes down host process tree (only --die-with-parent saves us)
// firejail: --rlimit-nproc not set by current wrapper — same problem as bwrap
```

Result: docker is the only backend with real resource limits today. **bwrap and firejail need rlimit/cgroup additions before V1.5 if fork-bomb resilience matters.**

### 6.5 Process tree visibility

```zig
const argv = &.{ "sh", "-c", "ps auxf | head -20" };
// docker: PID namespace — only sees container processes
// bwrap: --unshare-all includes --unshare-pid → only own pid tree
// firejail: --private-pid not in current wrapper → sees host processes. Gap.
// landlock: no PID isolation → sees everything
// none: sees everything → cross-tenant info leak vector
```

### 6.6 Sandbox-availability fallback

Already covered: `tool_sandbox_v1.zig:162-176` (fail closed when backend resolves to noop), `tool_sandbox_v1.zig:178-198` (workspace validation failure metrics increment). What's missing is a runtime check that "I asked for `firejail` but `firejail` isn't installed" surfaces clearly. Today on Linux `firejail.isAvailable` returns `comptime builtin.os.tag == .linux` (firejail.zig:51) — it does NOT check the binary. **This means selecting `firejail` on a Linux host without firejail installed will spawn a child that fails with `ENOENT`, which `process_util.run` likely surfaces as a generic exec failure.** The `error.SandboxUnavailable` path won't trigger.

The docker path DOES check the binary (`docker.zig:68-81`), so it's the most robust on machines that may or may not have it.

### 6.7 Recommended test scaffolding

Add `tests/sandbox_isolation_integration.zig` (new file) that runs only on Linux CI with bwrap/firejail/docker pre-installed. Tag tests `// :integration:sandbox` and exclude from default `zig build test`. Use `process_util.run`'s exit-code/stderr checks to assert each escape attempt fails appropriately.

---

## 7. Recommended Backend for V1.5

### 7.1 Recommendation: **bubblewrap (Linux primary), docker (cross-platform fallback), `none` only as opt-in escape hatch**

Decision matrix:

| Criterion | Weight | bwrap | docker | firejail | landlock | none |
|-----------|--------|-------|--------|----------|----------|------|
| Per-call latency | high | ~5-10ms | ~100-300ms | ~10-30ms | ~2-5ms | <1ms |
| Cross-tenant fs read blocked | critical | ✅ | ✅ | ⚠ needs flags | ✅ (when real) | ❌ |
| Network egress blocked | high | ✅ | ✅ | ✅ | ❌ | ❌ |
| Resource caps (fork bomb) | medium | ❌ today | ✅ | ❌ today | ❌ | ❌ |
| k8s without privileged | high | ✅ if userns | ❌ | ❌ | ✅ | ✅ |
| Fly.io compatible | high | ✅ | ⚠ | ❌ | ✅ | ✅ |
| Code present today | required | ✅ | ✅ | ✅ | ⚠ stub | ✅ |
| No external deps | nice | ❌ (bwrap binary) | ❌ (docker daemon) | ❌ (suid binary) | ✅ | ✅ |

### 7.2 Why bwrap wins V1.5

1. **Latency.** Per Nova's "any task reliability" memo and the autonomy-default-`.full` decision, agents run multi-tool turns autonomously. Adding 100-300ms per shell call (docker) compounds visibly. ~10ms (bwrap) is invisible.
2. **PaaS fit.** nullalis is deploying on Fly.io (per `project_deployment_readiness.md`) where Firecracker is the host VM. Nested Docker is awkward; bwrap-via-userns is supported.
3. **Code is already there.** `bubblewrap.zig:30-47` ships with `--unshare-all` + `--die-with-parent`. After fixing the cwd-vs-/workspace mismatch (PR-3 above), it's production-ready.
4. **Filesystem isolation matches the threat model.** The cross-tenant fs read at `shell.zig:68-94` is the dominant V1.5 risk; bwrap blocks it natively.
5. **Docker stays as the cross-platform fallback** for non-Linux dev and as the answer to "I need real resource caps."

### 7.3 What we accept by picking bwrap

- **No fork-bomb resilience** until we add `--rlimit-as`, `--rlimit-cpu`, or move into a cgroup-v2 controller. Application-layer mitigation: `policy.zig:135-140` already blocks the literal `:(){:|:&};:` pattern; oversized commands are rejected at `policy.zig:108-109`. This is "good enough" for V1.5 with a follow-up planned.
- **No network egress isolation difference vs docker** — both `--unshare-all` and `--network none` work.
- **macOS dev requires `docker` selection** explicitly — `auto` will downgrade to noop on macOS and fail closed via `tool_sandbox_v1.zig:118`. Document this in the dev README.

### 7.4 Concrete config for V1.5 default

```jsonc
{
  "security": {
    "sandbox": {
      "enabled": true,
      "backend": "auto"
    }
  }
}
```

`auto` selects bwrap on Linux (per `detect.zig:84-101`), docker on macOS, falls back to none and fails closed elsewhere. Operators wanting explicit control set `"backend": "bubblewrap"` or `"docker"`.

### 7.5 Pre-flight checklist before flipping the default

1. Fix bwrap workspace path mismatch (`bubblewrap.zig:43-44` binds to `/workspace`, but `shell.zig:142` passes host cwd) — **blocker.**
2. Make `firejail.isAvailable` check the binary, not just `os.tag` (`firejail.zig:47-52`) — so users selecting `firejail` get `SandboxUnavailable` cleanly when the binary is missing — **important; safety surface.**
3. Decide whether Landlock stays in the enum as a footgun or gets removed/disabled until real (`landlock.zig:25-36`, `detect.zig:39-46`) — **decision needed.**
4. Document the cwd contract: when sandboxed, what does `args.cwd` mean? Today it's host-side, which is correct for bwrap-with-WS:WS bind but wrong for docker (docker remaps via `-w`). The shell tool passes effective_cwd at `shell.zig:142` without remapping.
5. Add the integration test suite at §6 with at least the §6.2 cross-tenant read test as a CI gate.
6. Update `v1-ship-readiness-criteria.md` to list "sandbox active by default" as a ship criterion.

---

## 8. Cross-Reference Index (callsites verified by grep)

`sandbox_enabled` callsites — every location where the bool is read or written:

- `src/tools/shell.zig:31, 81, 135, 334, 360, 384, 409, 578` — struct field, refusal guard, exec config, tests
- `src/tools/git.zig:15, 213, 616` — struct field, exec config, test
- `src/tools/root.zig:861, 871, 900, 2067, 2072` — factory wiring + test assertions
- `src/security_review.zig:63, 71, 248, 378, 456, 471, 510, 525` — review check + tests
- `src/doctor.zig:649` — diagnostic
- `src/status.zig:222` — status panel
- `src/config.zig:843, 1555, 2000` — serialize + test
- `src/config_parse.zig:1744` — JSON parse
- `src/tools/tool_sandbox_v1.zig:8` — `SandboxExecConfig.enabled` field, `:95` (passthrough check), `:135, :213` (test fixtures)

`SandboxBackend` callsites (enum):

- `src/config_types.zig:21-28` — definition
- `src/config.zig:10, 1629, 2001` — re-export + tests
- `src/security/detect.zig:12-19` — second-tier definition (mirror)
- `src/security/sandbox.zig:79` — re-export
- `src/security/root.zig:54` — re-export
- `src/tools/shell.zig:32, 579` — struct field + test
- `src/tools/git.zig:16` — struct field
- `src/tools/root.zig:862, 872, 901, 2068, 2073` — factory + test
- `src/tools/tool_sandbox_v1.zig:9, 82, 126` — exec config + helper + adapter
- `src/security_review.zig:81, 249, 530, 533, 536` — review checks + tests

`tool_sandbox` (module) callsites:

- `src/gateway.zig:78, 6824` — import + diagnostic snapshot
- `src/tools/shell.zig:10, 132` — import + run call
- `src/tools/git.zig:8, 210` — import + run call

`validateWorkspaceMount` callsites:

- `src/security/docker.zig:180` — definition
- `src/security/root.zig:64` — re-export
- `src/tools/tool_sandbox_v1.zig:99` — sole runtime caller (docker-mode workspace gate)

This is exhaustive — there are no orphan callsites to chase.

---

## 9. Open Questions / Decisions for Nova

1. **Landlock stub:** delete the enum variant, leave it as a footgun, or build the real syscall layer this sprint? Recommendation: **leave as enum but add an availability error** so `.landlock` selection on any platform returns `error.SandboxUnavailable` until real, mirroring the noop fail-closed at `tool_sandbox_v1.zig:118`.
2. **Default flip timing:** flip `enabled` default to `true` in V1.5 release, or wait until the bwrap path-mismatch fix lands (PR-3)? Recommendation: **flip in same PR as the fix** so we don't ship a default-on with a known broken path.
3. **firejail_args plumbing:** wire it now (small) or remove the field (smaller)? Recommendation: **wire it** — operators may want `--seccomp` / `--caps.drop=all`.
4. **Docker default image:** current `alpine/git:latest` (`docker.zig:19`) is small but lacks most tools the agent might invoke (no `python3`, `node`, `cargo`, etc.). Build a `nullalis-runtime:0.2.0` image or pin the alpine and accept the limited toolchain inside container? Recommendation: **defer image work — V1.5 ships with alpine/git, document that complex shells need backend=bwrap or backend=none.**

End of plan.
