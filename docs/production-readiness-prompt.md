# Nullalis Production-Readiness Prompt

Status: **SUPERSEDED 2026-07-12** — this May-era dispatch prompt executed; do not work from it.
Current backlog + launch blockers: `zaki-infra/docs/superpowers/ROADMAP-2026-07-11.md`; live
multi-agent board: `zaki-infra/docs/COORDINATION.md`. Retained for audit context.
Date: 2026-05-28.

Use this document when assigning backend work to a Nullalis implementation
agent. The goal is not to maintain a deferred list; the goal is to burn
down every production-critical gap before ZAKI exposes the Agent surface
as a paid product.

## Operating Rule

The deferred register is a visibility ledger, not a launch waiver.
Anything that affects user trust, data durability, memory correctness,
privacy, browser control, artifacts, approvals, metering, or session
lifecycle is a production gate unless the product surface is explicitly
hidden from V1.

## Prompt To Backend Agent

```text
You are the Nullalis backend owner for the ZAKI commercial V1 production
readiness push.

Goal:
Close the backend contract gaps that block a production-grade ZAKI Agent
surface. Do not treat deferred-register entries as acceptable backlog if
they affect exposed V1 user trust, data, memory, artifacts, browser
control, approvals, metering, or session lifecycle.

First principles:
- Code truth wins over stale docs.
- Any UI-visible feature must have a real backend contract.
- Do not ship phantom endpoints in docs.
- Do not let the frontend simulate backend-owned state such as active
  run cancellation, durable trace history, artifact export, or approvals.
- Every production-critical change needs tests and an honest failure mode.

P0 launch blockers:

1. Artifact export bridge  **[SHIPPED 2026-05-28 — Wave 2A]**
- Replace any 501/stub export path with a production bridge:
  artifact ownership check -> latest/requested version -> produce_document
  -> generated file metadata/download path.
- Support pdf, docx, pptx, xlsx, and html, or reject unsupported formats
  with a named 400 error.
- Add authenticated file-serving for produced exports if not already
  present.
- Add success, invalid format, missing artifact, state unavailable,
  renderer failure, and cross-user isolation tests.

  Closure: `handleArtifactExport` in `src/gateway.zig` calls
  `ProduceDocumentTool.execute()` with the safe `default` theme; the
  companion `GET /api/v1/users/:id/exports/:filename` route streams the
  produced file. Renderer-missing failures surface as `502
  renderer_unavailable`. Covered by 6 handler-level tests + a live-PG
  cross-user isolation test.

2. Backend-owned active turn cancel/resume
- Implement a stable run/session-scoped cancel route for active chat
  turns, or explicitly document the supported route if it already exists.
- Cancellation must be idempotent.
- A cancelled run must produce a clear SSE terminal state.
- If resume/replay is supported, document the exact semantics. If not,
  remove all `chat/resume` claims from handoff docs and make reconnect
  behavior explicit.

3. Contract sync
- Reconcile docs/ui-handoff.md, docs/online-agent-contract.md, and
  docs/openapi-v1.yaml with actual gateway routes.
- No phantom `/api/v1/chat/approve`, `/api/v1/chat/cancel`, or
  `/api/v1/chat/resume` claims unless the routes exist.
- Ensure `/api/v1/users/{user_id}/sessions/{session_key}/approve` and
  `/mode` are documented and tested.
- Add OpenAPI coverage for artifact CRUD/share/export/download,
  attachments, trace sharing, and any lifecycle routes the UI needs.

4. Attachment idempotency
- Apply `Idempotency-Key` dedupe to
  `POST /api/v1/users/{user_id}/attachments`.
- Retried uploads with the same key must return the same result.
- Avoid unsafe overwrite behavior on retry/name collision.
- Add duplicate/retry tests.

5. Memory production closeout
- Verify user-scoped memory write/read/delete/export behavior end to end.
- Confirm `memory_store(valid_at)` and temporal-anchor paths work in
  direct tool writes and extraction writes.
- Confirm memory_doctor returns actionable readiness state.
- Close or explicitly gate PII tagging/purge/export behavior so users can
  inspect and delete personal memory.

P1 production hardening:

6. Approval model consolidation
- Consolidate legacy approval paths into the canonical pending-tool
  approval model.
- Provide stable enough identifiers for UI approval cards.
- Preserve supervised/full/read-only semantics.
- Add tests for approve, deny, expiry/collision, and irreversible actions.

7. Durable traces and share records
- Persist user-visible trace metadata/events and share records, or mark
  the surface ephemeral and hide durable-history UX.
- Sanitization must remain server-side.
- Trace/share links should survive restart if presented as permanent.

8. Extension browser readiness
- Confirm per-user token auth is the only accepted model.
- Pair/disconnect/timeout states must be observable.
- Extension command failures must produce useful tool_result/error state.
- Add live or mocked E2E coverage for navigate, click/type, screenshot,
  DOM/text, and disconnected extension behavior.

9. Observability and SLOs
- Emit chartable signals for run_id, session_id, tool latency, approvals,
  artifact export, extension commands, memory writes, trace sharing, and
  meter receipt correlation.
- Update readiness/health checks so production does not silently run with
  missing Postgres state for surfaces that require it.

10. Production verification matrix
- Add or document smoke tests for:
  chat stream, mode switching, approvals, cancel, attachments, artifact
  create/update/share/export, trace share, extension browser, memory_store,
  memory_recall, memory_forget, memory_doctor, and Postgres GDPR cascade.
- Run the default suite and any Postgres-gated suite required for touched
  code.

Deliverables:
- Code changes with focused tests.
- Updated docs/openapi-v1.yaml where routes changed.
- Updated docs/ui-handoff.md and docs/online-agent-contract.md where
  contracts changed.
- Updated docs/deferred-register.md: mark closed items shipped, promote
  production-critical open items to P0/P1, and leave true post-launch
  items as P2.
- Final report listing what is production-ready, what remains hidden, and
  exact commands/tests run.
```

## Acceptance Bar

A backend item is not done until all of these are true:

- The route/tool exists and is reachable from the production path.
- The behavior is documented in OpenAPI or the event contract.
- The ZAKI UI can bind it without guessing.
- Failure states are named and user-safe.
- Cross-user isolation is tested where user data is involved.
- Restart/pod-loss behavior is either durable or explicitly documented
  as ephemeral and hidden from permanent-history UX.
- `zig build test` passes, plus any relevant Postgres/live-gated tests.

