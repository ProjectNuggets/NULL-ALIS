# DTaaS Evolution Ledger (Post-v0.7)

## Purpose
Single strategic list for what nullALIS should become after `v0.7` is complete.
This is not the active sprint queue; it is the future-development ledger.

## North-Star
Build nullALIS into a production-grade **Digital Twin as a Service** runtime:
1. persistent user memory
2. proactive behavior (not only reactive turns)
3. cross-channel continuity
4. real tool execution
5. strict tenant isolation and safety

## External Landscape (What to Learn, Not Copy Blindly)
1. LettaBot:
- strongest signal: memory-first and cross-channel continuity.
- adopt: memory architecture patterns and recall ergonomics.
- avoid: provider/runtime coupling that weakens portability.

2. HKUDS nanobot:
- strongest signal: agent-network/delegation ideas.
- adopt: explicit A2A delegation contracts and identity boundaries.
- avoid: loose autonomy without tenant safety gates.

3. Autobot:
- strongest signal: hardened sandbox/security posture.
- adopt: kernel/container isolation depth and secret isolation rigor.
- avoid: large security surface without operator diagnostics.

4. AstrBot:
- strongest signal: platformization and plugin ecosystem model.
- adopt: plugin lifecycle governance and extension packaging.
- avoid: uncontrolled plugin blast radius in shared tenancy.

5. Moltis and related Rust infrastructure projects:
- strongest signal: single-binary operational discipline plus security docs.
- adopt: explicit operational runbooks and hard failure semantics.

## Strategic Themes and Planned Work

## Theme A — Twin Memory Architecture
1. Evolve from message-history-centric state to structured memory graph.
2. Add temporal memory compaction policy with auditable snapshots.
3. Enforce tenant+user scoped recall in all memory backends (including vector paths).
4. Add memory quality metrics: recall precision, stale-memory rate, correction rate.

## Theme B — Proactive Runtime (Controlled Autonomy)
1. Keep scheduled proactive as baseline.
2. Add policy-gated autonomous triggers (`proactive` origin) with cooldowns, quotas, and explainability.
3. Add user-facing controls for proactive mode, frequency, and quiet windows.
4. Add kill-switch + audit trail for all proactive actions.

## Theme C — Cross-Channel Twin Continuity
1. Keep canonical identity mapping as authority.
2. Ensure identical user/twin state across Telegram, Web, and future channels.
3. Add channel-aware rendering layer (format/chunk/preview policies per channel).
4. Add channel parity acceptance tests (same user intent across channels yields consistent outcomes).

## Theme D — Isolation and Safety Hardening
1. Keep V1 shell/git sandbox fail-closed when enabled.
2. Add per-tenant workspace jail policy and staging proofs for cross-tenant denial.
3. Add deeper runtime isolation profile (`shared-host` vs `dedicated-tenant`).
4. Add security regression suite for file/tool/memory boundary violations.

## Theme E — Agent Networking (A2A Delegation)
1. Introduce explicit inter-agent delegation protocol:
- identity
- capability
- authorization
- auditability
2. Start with same-tenant delegation only.
3. Add budget and timeout controls per delegation hop.
4. Delay cross-tenant federation until policy and trust model are complete.

## Theme F — Productization Control Plane
1. Keep user-facing settings as presets, not raw runtime knobs.
2. Maintain deterministic mapping from product settings -> runtime config.
3. Add integration health UX (Telegram connected, webhook status, STT/vision readiness).
4. Add usage/metering with soft limits and clear warnings.

## Theme G — Performance and SLO Discipline
1. Maintain canary-based GO/HOLD/ROLLBACK with hard thresholds.
2. Track provider latency/error classes separately from runtime saturation.
3. Add multi-cell staging validation as mandatory pre-prod gate.
4. Keep cost/capacity model tied to measured artifacts, not assumptions.

## Release-Level Roadmap (After v0.7)
1. `v0.8`:
- memory isolation proofs
- channel rendering parity (Telegram-first)
- provider capability gates for vision/STT/TTS

2. `v0.9`:
- controlled proactive autonomy (`proactive` origin with policy)
- richer user controls and observability
- isolation profile hardening in staging

3. `v1.0`:
- stable multi-user DTaaS baseline
- deterministic onboarding/settings/usage flow
- audited SLO and rollback governance

4. `v1.1+`:
- A2A delegation (same-tenant)
- premium isolation tiers
- hard entitlements and billing enforcement

## Decision Rules
1. Steal patterns, not architecture lock-in.
2. No feature merges without tests and operator evidence.
3. No autonomy expansion without safety controls and auditability.
4. No new channel declared production-ready without channel-specific canary evidence.

## Current Status
This ledger is deferred until `v0.7` backlog completion.
