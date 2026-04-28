# zaki-prod handoff — sandbox + policy relaxation (V1.5)

**Audience:** zaki-prod frontend agent / engineer
**Status:** ready as of `a19d460` (2026-04-28)
**Trigger:** nullalis backend just hardened the sandbox and relaxed the
agent's tool-calling policy. Several frontend changes become possible/needed.

## What changed on the backend

1. **Sandbox is auto-enabled in production** when bwrap (or firejail/docker)
   is installed on the host. `sandbox.enabled = null` (config default) now
   probes the host once at boot and turns on if a real backend exists.
2. **Each user's shell tool runs inside an isolated namespace.** No cross-tenant
   filesystem reads, no network egress from inside shell, no process-tree
   escape. /tmp is a fresh per-call tmpfs (no cross-user leak).
3. **The static allowlist no longer applies in sandboxed mode.** The agent
   can run arbitrary commands (`tar`, `unzip`, `perl`, `bash -c …`, etc.).
   Network commands fail naturally inside the sandbox; the agent learns from
   the natural error.
4. **High-risk commands still blocked** (rm/dd/sudo/mount/etc.) for clean
   error messages.
5. **Medium-risk approval gate still fires** in supervised autonomy mode
   (touch/mkdir/mv/cp/git commit etc.). User sees an approval prompt.

## What this means for zaki-prod

### 1. Approval card is now P0 (was P1)

Backend already emits `approval_required` SSE events with shape:

```json
{
  "type": "approval_required",
  "tool": "shell",
  "command": "git commit -m 'fix bug'",
  "risk_level": "medium",
  "reason": "Medium-risk command in supervised mode"
}
```

There is **no HTTP `/approve` endpoint yet** — approvals work today only
via the user typing `/approve allow-once` (or `/approve deny`) in chat.

**Action:** build the approval card UI (codex-style: inline card, risk
badge, three buttons "Allow once / Allow always / Deny") that listens for
`approval_required` SSE events and posts the user's choice back. Until the
HTTP endpoint exists, post the user's choice as a chat message in the form
`/approve allow-once` etc.

This is the highest-leverage frontend change — it lets `supervised` mode
become the default for new users (currently `full` is the default per
the autonomy UI toggle memory; we want to flip back once the approval UI
exists).

### 2. Autonomy radio surface

Three modes exist: `read_only` / `supervised` / `full`. Today they're
config-only (operator edits config.json). The frontend should expose them
as a settings radio:

- **read_only** — agent observes, never acts. Use for "give me a tour" mode.
- **supervised** — agent acts but asks before medium/high risk. Default
  for paying users once approval card lands.
- **full** — agent acts autonomously within sandbox bounds. Power users.

Wire the radio to PATCH `/api/v1/users/{user_id}/settings` with `autonomy: "<level>"`. The runtime already accepts this field (verified live).

### 3. Cost dashboard is P1 unblocked

Backend exposes `/api/v1/users/{user_id}/usage` returning per-period
token+cost JSON. Build a simple "current period" view in the user's
settings panel. Already documented in `docs/v1-frontend-activation-list.md`.

### 4. UI copy update — sandbox status badge

The new boot log surface:
```
[sandbox] (info): sandbox: enabled=true backend=bubblewrap fail_open_on_dev=false
```

Operators (and the user, in a "trust" sense) want to know shell commands
are sandboxed. Suggested: small "Shell sandboxed (bwrap)" badge in the
UI status bar when an agent thread is active. The runtime exposes the
backend name via the `/api/v1/status` endpoint (verify field name —
likely `sandbox.backend`).

### 5. NO change needed — these were our concerns and they're handled

- Cross-tenant data leak via shared /tmp → fixed (tmpfs)
- Cross-tenant FS read via shell → blocked (workspace-only bind)
- Tokens leaking via shell env → blocked (env cleared, only SAFE_ENV_VARS)
- Network attacks from inside shell → blocked (--unshare-all)

### 6. Deferred — DON'T build yet

- **Self-service MCP server connection.** The MCP child process spawn is
  not yet wrapped in tool_sandbox_v1. If users can connect their own
  MCP servers, they bypass the sandbox. **Wait for V1.X** when we wrap
  MCP. Operator-curated MCP only for now (pre-configured in the runtime).

## Verification

After deploying these frontend changes, end-to-end test:

1. **Sandbox boundary test:**
   - Send agent "list files in /etc"
   - Expected: agent says "I cannot read /etc — outside my workspace" or
     attempts and reports ENOENT
   - Confirms cross-tenant FS read is blocked

2. **Network test:**
   - Send agent "fetch https://example.com via curl"
   - Expected: agent runs curl inside sandbox, gets "Could not resolve
     host" (network unavailable), reports honestly to user
   - Confirms network egress is blocked

3. **Approval flow test:**
   - In supervised mode: send agent "rename file foo.txt to bar.txt"
   - Expected: approval card appears in UI with `mv foo.txt bar.txt` and
     "medium risk" badge; user clicks "Allow once" → command executes
   - Confirms approval round-trip works end-to-end

4. **Allowlist relaxation test:**
   - Send agent "extract this tarball: tar -tf archive.tar.gz"
   - Expected: command runs successfully (tar wasn't in old allowlist;
     now allowed inside sandbox)
   - Confirms relaxation is live

## Reference docs (read these on the backend repo)

- `docs/sandbox-deploy.md` — operator deployment guide
- `docs/sandbox-tool-coverage.md` — per-tool wrap audit
- `docs/sandbox-activation-plan.md` — full backend audit (long, optional)
- `docs/v1-frontend-activation-list.md` — comprehensive gap inventory

## Status snapshot

- Backend: V1 + sandbox hardening + policy relaxation shipped at `a19d460`.
  Tests green (5585/5621 pass).
- Frontend: approval card is the highest-leverage missing piece. Other
  gaps are P1/P2 per `docs/v1-frontend-activation-list.md`.

— handoff drafted 2026-04-28
