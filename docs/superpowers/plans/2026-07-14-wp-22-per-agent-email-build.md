# WP-22 — Per-Agent Email Build Plan

> **Status:** Ready for owner review; implementation not started
>
> **Input:** WP-07 decision-only spike, 2026-07-14
>
> **Decision:** Mailgun EU catch-all inbound webhook; operator-provisioned per-agent address identity
>
> **Risk:** High — gateway, secrets, routing, persistent state, and untrusted inbound content

## Goal

Give each agent a stable `local_part@agents.chatzaki.com` identity that can receive and send mail without connecting a user's personal inbox. Provisioning and revocation are operator-controlled, recipient routing uses Mailgun's SMTP envelope value only after request authentication, and unknown or stale addresses fail closed.

## Non-goals

- No generic multi-provider inbound-email abstraction in V1.
- No user-managed mailbox credentials or OAuth flow.
- No full MIME attachment ingestion in the first slice.
- No Stalwart/JMAP service deployment.
- No migration of path A personal-mail integrations.

## Architecture contract

1. Mailgun owns inbound MX for the dedicated subdomain and posts one signed HTTPS request to nullalis.
2. A thin Mailgun-specific adapter authenticates the request before parsing content, enforces size/time bounds, and extracts the SMTP envelope `recipient`.
3. An operator-owned address registry resolves the normalized recipient to exactly one active tenant/user/agent binding.
4. The adapter durably claims a dedupe key before publishing a normal inbound email event. It returns success only after durable acceptance.
5. Outbound mail resolves `From` from that registry and uses an operator-held domain credential. Callers cannot supply an arbitrary sender identity.

`To`, `Delivered-To`, and `X-Original-To` are not webhook routing authority. For the optional IMAP pilot, a parsed recipient may be used only when it matches the configured dedicated domain and resolves unambiguously; otherwise the message is quarantined/rejected.

## Plan shape

### Task 1 — Correct the control-plane contract

**Read first:** `src/channel_control.zig`, `src/user_settings.zig`, `src/gateway.zig`, `docs/ui-handoff.md`, and their git history.

- Write a RED test proving email cannot be presented as a tenant-managed password connection when runtime activation is operator-owned.
- Remove or reclassify the generic email password descriptor. Expose operator-managed provisioning state as read-only to tenant settings.
- Document the distinction between the agent-owned address and path A personal mailbox access.
- Do not delete the existing IMAP/SMTP channel; it remains the pilot/fallback transport.

**Acceptance:** the settings/control API cannot imply that storing IMAP/SMTP secrets activates an agent mailbox.

### Task 2 — Add the durable address registry

**Likely files:** `src/zaki_state.zig`, its stub manager, the existing migration surface, and focused state tests. Confirm exact ownership during recon.

Store at minimum:

- canonical full address and normalized local part;
- tenant ID, user ID, agent ID, and binding/account identity;
- lifecycle state (`pending`, `active`, `suspended`, `retired`);
- provider/domain reference, created/updated timestamps, and retirement timestamp;
- no plaintext provider secret.

Enforce unique active addresses, reserved-name denial, canonical domain matching, and no address reuse in V1. Delayed mail must not cross agent identities; any future reuse policy is a separate decision and change.

Add matching methods to the non-Postgres stub. Because this touches the real PG/state body, both the default and canonical Postgres-enabled profiles are mandatory.

**Acceptance:** unknown, inactive, malformed, ambiguous, and retired recipients return explicit non-routing outcomes; no default-agent fallback exists.

### Task 3 — Implement bounded Mailgun verification and parsing

**Likely files:** a focused module under `src/channels/`, the gateway route registration, and focused unit tests. Do not embed provider logic throughout `src/gateway.zig`.

RED-first cases:

- valid HMAC-SHA256 signature;
- invalid signature;
- expired timestamp;
- replayed token;
- missing or foreign-domain recipient;
- unknown/inactive recipient;
- oversized request/body and too many fields/attachments;
- multiple agent recipients;
- malformed MIME/content fields;
- duplicate provider delivery.

Use constant-time comparison. Apply the timestamp window and replay claim before expensive body work. Bound request bytes at the gateway. Ignore attachments in V1 after enforcing aggregate limits. Do not log signatures, tokens, bodies, credentials, or full sensitive payloads.

**Acceptance:** unauthenticated input cannot reach routing or state mutation; valid redelivery is idempotent.

### Task 4 — Bridge accepted mail into normal routing

Create one typed inbound envelope containing provider delivery ID, authenticated recipient, sender, subject/body, and the resolved binding. Preserve the recipient through event metadata and session routing rather than borrowing the mailbox's fixed `account_id`.

Publish only after durable dedupe/acceptance. Use the existing channel event/session path and least-privilege entitlement checks; do not create a parallel agent loop. Treat message content and sender claims as untrusted input.

Decide sender policy explicitly:

- public agent address: accept external senders but keep normal tool/entitlement boundaries; or
- allowlist-only address: deny before agent invocation.

The default must be stated in config/docs and covered by tests. The current empty `allow_from` behavior silently rejects everyone and is not a usable public-mailbox default.

**Acceptance:** two recipients of otherwise identical mail route to different bound agents; an unknown recipient invokes no agent.

### Task 5 — Add operator provisioning and lifecycle reconciliation

Add the smallest concrete operator surface needed by the UI/deploy owner:

- reserve/provision an address in the registry;
- activate only after the Mailgun domain/route is ready;
- suspend inbound and outbound together;
- retire with an audit record and no immediate address reuse;
- report status without exposing provider secrets.

For a catch-all route, provisioning is primarily registry lifecycle; it must not create one Mailgun route or mailbox per agent. Store the Mailgun signing key and SMTP credential in the existing operator secret vault. Make activation/reload explicit—persisting config alone is not success.

**Acceptance:** a provisioned identity becomes routable without process-local hand edits, and suspension takes effect deterministically.

### Task 6 — Bind outbound identity

Reuse the existing SMTP transport where practical, but resolve the sender from the active address binding. Reject arbitrary `From` values, inactive identities, and cross-tenant binding use. Keep one operator-held domain SMTP credential unless Mailgun policy requires narrower credentials.

Add boundary tests for forged sender identity, suspended address, secret lookup failure, and provider rejection. Logs may contain an internal binding ID and coarse provider status, not credentials or full message bodies.

**Acceptance:** the agent sends as its registered address and cannot impersonate another agent.

### Task 7 — Preserve a narrow IMAP pilot fallback

If a pilot is required before Tasks 1–6 land, provision one Fastmail Standard/Professional (or equivalent) mailbox for one agent and use static operator configuration plus restart. Add recipient parsing to `ParsedEmail` only with RED-first tests for folded/case-insensitive headers, missing values, foreign domains, and ambiguous recipients.

Do not configure multiple nullalis accounts against one catch-all IMAP inbox: source-key deduplication intentionally suppresses competing pollers. Do not expose the pilot password to tenants. Record an expiry/removal condition for the pilot.

**Acceptance:** one real mailbox sends and receives for one agent, and the fallback is documented as non-scalable.

## Live-drive acceptance gate

Use a non-production subdomain/account first. Record provider region and plan.

1. Provision agent A and agent B with distinct addresses.
2. Send externally to A; observe one durable inbound claim, one event, and only A's session invocation.
3. Redeliver the same webhook; observe no second invocation.
4. Send to unknown, retired, foreign-domain, and multi-agent recipients; observe zero agent invocations.
5. Replay a valid signed request outside the timestamp window and repeat its token; observe rejection.
6. Send an oversized message/attachment; observe bounded rejection without RSS growth beyond the declared budget.
7. Send from A; verify the envelope/header identity and reply path. Attempt a forged B identity from A; observe rejection.
8. Suspend A; verify both inbound and outbound stop while B remains healthy.

Production DNS cutover requires explicit operator approval and a rollback record. Rollback removes/restores MX as appropriate, disables the webhook secret, and suspends all affected registry bindings before any address reassignment.

## Validation matrix

Run and record exact results:

```bash
zig fmt --check src/
zig build test --summary all
zig build test --summary all -Dengines=base,sqlite,postgres -Dchannels=cli,telegram,email
zig build -Doptimize=ReleaseSmall -Dengines=base,sqlite,postgres -Dchannels=cli,telegram,email
```

For state work, the default suite is insufficient because it compiles the Postgres stub. Add `NULLALIS_POSTGRES_TEST_URL` for the live-PG lane and drive the real binary as described above. Report MaxRSS honestly against the 80 MB target; the known ~99–100 MB canonical baseline is already over budget.

## Review and commit boundaries

This plan crosses high-risk paths. Get owner approval before implementation. Keep one finding/concern per commit:

1. control-plane truth;
2. address registry + migration + stub parity;
3. authenticated inbound adapter;
4. routing bridge;
5. provisioning lifecycle;
6. outbound identity;
7. optional pilot/parser.

Each behavior commit needs RED-first tests, diff review, and its relevant live-drive evidence. Update `docs/ROADMAP.md`, `STATUS.md`, user-facing channel documentation, and the zaki-infra work package/coordination record when the operating surface actually changes.

## Open owner decisions before implementation

- Approve Mailgun EU procurement/DPA and the inbound-routing plan available at that time.
- Choose the public-sender policy for an agent-owned mailbox.
- Approve the local-part naming/reservation policy and whether addresses are ever reusable.
- Choose the non-production subdomain/account used for the live-drive gate.
- Decide whether the one-agent IMAP pilot is needed or WP-22 should go directly to webhook delivery.
