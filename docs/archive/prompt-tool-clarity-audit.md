---
tags: [prose, prose/docs]
---

# Prompt and Tool-Clarity Audit

Date: 2026-03-30
Execution branch: `feat/kernel-ux-v1`

## Summary

This audit is the tightening spec for the next prompt/tool-clarity branch.

Goal:
- preserve personality and relationship quality
- centralize operational truth
- reduce prompt drift and tool-choice ambiguity
- avoid turning the agent into a sterile operator

This is an audit/spec milestone, not a broad implementation rewrite.

It now serves as the working contract for the first execution branch.

## Prompt Surface Ownership

| Surface | Primary Job | Status | Action | Notes |
|---|---|---:|---|---|
| `src/agent/prompt.zig` | Canonical operational contract | good | `tighten` | Keep as the main authority for runtime rules, precedence, and compact tool-choice guidance. |
| `src/capabilities.zig` | Runtime summary | noisy | `trim` | It duplicates too much scheduling policy that already belongs in the main prompt. |
| `src/daemon.zig` heartbeat prompt | Wake-specific contract | mostly good | `tighten` | Keep wake/heartbeat rules here only; align exactly with background enforcement. |
| `src/workspace_templates/AGENTS.md` | Local working norms | stale | `tighten` | Biggest source of old heartbeat/background instructions. |
| `src/workspace_templates/SOUL.md` | Personality / voice | good | `keep as-is` | This is where warmth, opinions, and non-corporate tone should continue to live. |
| `src/workspace_templates/IDENTITY.md` | Identity / self-concept | good | `keep as-is` | Good onboarding/personality shape; not an operational policy layer. |
| `src/workspace_templates/USER.md` | Relationship context | good | `keep as-is` | Good user model; should stay contextual, not operational. |
| `src/workspace_templates/TOOLS.md` | Environment-specific notes | good | `keep as-is` | Local notes only; should not become a second tool-policy layer. |
| `src/workspace_templates/HEARTBEAT.md` | Wake policy file | good | `tighten lightly` | Repo template is close; keep it a pure wake-policy file. |
| `src/workspace_templates/BOOTSTRAP.md` | Onboarding / transitional context | good | `keep as-is` | Temporary by design; do not overload it with runtime policy. |
| Live user workspace `AGENTS.md` | User-customized working norms | stale | `move toward repo contract` | Active copy still uses the old heartbeat model and should not be treated as authoritative for runtime behavior. |
| Live user workspace `HEARTBEAT.md` | User wake policy | good | `keep as-is` | Current live file already reflects the newer wake/reconcile model. |
| Live user workspace `SOUL.md`, `IDENTITY.md`, `USER.md`, `TOOLS.md` | User-specific persona/context | good | `keep as-is` | These are customized and should not be normalized back to the templates. |

## Prompt Contradictions and Drift

### 1. `AGENTS.md` still teaches blocked heartbeat behavior

Current repo template still says heartbeat can:
- track checks in `memory/heartbeat-state.json`
- check projects via git
- update documentation
- commit and push changes
- perform `MEMORY.md` maintenance as if background write tools are always available

These claims are stale relative to current background tool policy and wake contract.

Why this matters:
- `AGENTS.md` is injected into the system prompt
- stale workspace guidance can overpower newer runtime rules
- this causes the model to reach for actions the runtime now blocks

Required tightening:
- remove blocked/overpowered heartbeat claims
- keep heartbeat-driven `MEMORY.md` maintenance, but phrase it truthfully:
  - wake may review, decide maintenance is needed, and perform it only when that turn has the required allowed tools

### 2. `capabilities.zig` is acting like a second policy engine

It currently repeats the detailed scheduling/wake contract in both summary and prompt-section builders.

Why this matters:
- duplicates are already starting to drift
- the main prompt should own policy; capabilities should summarize runtime shape

Required tightening:
- keep only compact scheduling/runtime bullets
- move detailed rule wording back to `src/agent/prompt.zig`

### 3. Heartbeat prompt and enforcement are still not perfectly aligned

Current heartbeat prompt says:
- do not use shell, composio, message, or exploratory discovery

Current background tool gate still allows:
- `message`
- `web_search`
- `web_fetch`
- limited read-only `composio`

Why this matters:
- prompt says one thing, policy allows another
- the model may still avoid useful tools or incorrectly assume stronger restrictions than the runtime actually enforces

Required tightening:
- choose one background contract
- make `src/daemon.zig` and `src/tools/root.zig` say the same thing

### 4. Main prompt is missing two compact but important control rules

It currently has strong scheduler guidance, but it still lacks:
- an explicit precedence rule
- a compact blessed-path tool-choice matrix

Why this matters:
- workspace docs are injected first and are highly influential
- the agent still has to infer too much when multiple tools could work

Required tightening:
- add one short precedence rule
- add one compact blessed-path matrix

### 5. Live workspace drift matters

Active user workspace findings:
- live `AGENTS.md` is still on the older heartbeat model
- live `HEARTBEAT.md` is already on the newer wake/reconcile model
- live `SOUL.md`, `IDENTITY.md`, `USER.md`, and `TOOLS.md` are customized and healthy

Why this matters:
- not all prompt issues are repo-template issues
- implementation should distinguish:
  - repo cleanup
  - runtime prompt tightening
  - optional live workspace cleanup

## Personality Preservation List

These elements are valuable and should survive the tightening pass:

### Keep from `SOUL.md`
- "Be genuinely helpful, not performatively helpful."
- "Have opinions."
- "Be resourceful before asking."
- "Earn trust through competence."
- "Not a corporate drone. Not a sycophant."

Why:
- these lines create the current warmth and sharpness
- they make the agent feel like a capable collaborator rather than a bland assistant

### Keep from live user persona
- "warm, sharp, proactive"
- "personal operator" framing
- continuity across app, Telegram, memory, and scheduled work

Why:
- this is the strongest current product personality
- it aligns with the user's preferred relationship to the agent

### Preserve in the final system
- warmth without filler
- opinions without ego
- initiative without overreach
- competence without flattening voice

### Do not do
- do not rewrite the agent into purely compliance-style prose
- do not move personality into `capabilities.zig`
- do not let `AGENTS.md` become the main personality file

## High-Impact Tool Audit

All tools should be reviewed. Only the high-impact set below needs tightening in the next milestone unless a low-priority tool is actively misleading.

| Tool / Group | Current Description Shape | Observed Ambiguity | Tightening Intent | Fix Layer |
|---|---|---|---|---|
| `schedule` | Strong but broad | Covers many job types but does not explicitly say it is the default answer for any user time/date/recurrence request | Make it the clearly blessed path for user-facing scheduling | tool + main prompt |
| `cron_*` | Raw/low-level in some files, too generic in others | `cron_remove` and `cron_update` read like normal tools instead of operator/debug tools | Make all `cron_*` descriptions consistently low-level/operator-only | tool |
| `runtime_info` | Structured runtime status | Good, but could more clearly say "use this to verify runtime/session/scheduler truth before claiming status" | Make it the verification/ground-truth tool | tool + main prompt |
| `shell` | Too generic | Does not say when to prefer shell vs file tools vs `http_request`; easy for model to overuse | Clarify shell as high-leverage execution tool when policy allows and no more specific tool is better | tool + main prompt |
| `http_request` | Capability-focused | Does not say it is the preferred path for known external APIs vs shell/curl | Make it the default for known external endpoints | tool + blessed path |
| `message` | Clear mechanics, unclear policy role | Can look like a generic delivery tool even when background lanes should not use it | Clarify that it is an explicit send tool, not a heartbeat default | tool + background policy text |
| `composio` | Capability-heavy | The model still lacks a crisp “when to use this vs native tools vs ask first” rule | Position as app-integration fallback/native-gap tool, with reads safer than writes | tool + main prompt |
| `web_search` / `web_fetch` | Mechanically clear | Missing the contrast with `http_request`, `runtime_info`, and shell | Clarify research vs direct API vs runtime verification | tool + blessed path |
| file tools | Generic CRUD wording | The model still has to infer when to use `file_read` vs shell vs memory tools | Clarify they are the default workspace-editing path | tool |
| memory tools | Individually decent, collectively fuzzy | The line between `memory_recall`, `memory_list`, `memory_timeline`, and file-based memory maintenance is not explicit | Tighten the role of each memory surface | tool + prompt |
| `spawn` | Good mechanics | Still easy to confuse with `schedule` for future work | Clarify: async now, not durable timed jobs | tool + blessed path |
| `delegate` | Good mechanics | Still easy to confuse with `spawn` and direct handling | Clarify: use only when specialization materially helps | tool + blessed path |

### Low-priority tools

Audit but do not rewrite unless misleading:
- hardware tools
- browser tools
- `pushover`
- `skill_registry`
- screenshot/image utilities

## Blessed-Path Matrix for the Main Prompt

This should be added in compact form to the canonical prompt layer.

| Need | Preferred Tool |
|---|---|
| time/date/recurrence | `schedule` |
| raw scheduler inspection / operator work | `cron_*` |
| runtime/session/scheduler truth | `runtime_info` |
| external API with known endpoint | `http_request` |
| web research / open-web facts | `web_search`, `web_fetch` |
| async work that should start now | `spawn` |
| specialist subtask | `delegate` |
| explicit outbound send | `message` |
| shell-level execution | `shell` only when policy allows and no more specific tool is better |

## Tightening Spec for the Next Implementation Branch

### Step 1: Fix prompt ownership and precedence
- keep `src/agent/prompt.zig` as the canonical operational contract
- trim `src/capabilities.zig` into summary-only guidance
- keep `src/daemon.zig` heartbeat prompt specific to wake/heartbeat behavior
- add one explicit precedence rule:
  - verified runtime/tool truth overrides workspace docs, memory, and inference

### Step 2: Clean `AGENTS.md`
- remove stale heartbeat-state tracking
- remove git/project checks from heartbeat
- remove generic doc update and commit/push claims from heartbeat
- preserve heartbeat-driven memory maintenance, but reframe it truthfully

### Step 3: Align background policy and heartbeat wording
- decide whether wake/background should keep `web_search`, `web_fetch`, `message`, and read-only `composio`
- make prompt and enforcement identical

### Step 4: Tighten the high-impact tool set
- rewrite only the targeted tools above
- keep descriptions short
- do not rewrite the full catalog in depth

### Step 5: Add a compact turn-mode hint
- `chat`
- `execute`
- `wake`
- `repair`
- `operator`

The hint should sharpen execution style without adding a second framework.

## Testing and Validation for the Next Milestone

When implementation starts, add:
- prompt-section string tests for the tightened canonical rules
- targeted tests proving no contradiction between:
  - `prompt.zig`
  - `capabilities.zig`
  - `daemon.zig`
  - `AGENTS.md`
  - `HEARTBEAT.md`
- tool-description regression checks for the rewritten set
- background-policy wording alignment tests

## Implementation Defaults

- Preserve and clarify personality; do not flatten it.
- Tighten operations; do not duplicate them.
- Audit all tools, rewrite only the high-impact set.
- Treat live workspace drift as a separate cleanup choice, not a reason to weaken the repo templates.

## Follow-Up Note: Mirror and Import

Current working assumption for the memory/runtime branch:

- startup markdown import is treated as a feature
- runtime truth still lives in the primary DB-backed memory path
- markdown should mirror DB records accurately enough for:
  - human inspection
  - export/debugging
  - restart-time import when needed

What is now true:

- runtime markdown parsing supports both:
  - one-line structured entries: `- **key**: value`
  - multiline block-form entries:
    - `- **key**:`
    - indented content lines below it
- multiline continuity artifacts are mirrored in a more readable block form
- graceful shutdown now flushes active sessions before teardown, reducing loss on normal restarts

Known compatibility note:

- repo runtime parsing is aligned with the new block-form mirror
- migration/import helpers still mostly assume the older one-line structured form
- if migration tooling is later used against mirrored continuity artifacts, it should be upgraded to parse block-form entries too

Testing stance:

- keep the current mirror/import design
- soak test over time across:
  - normal `/new` boundaries
  - auto-compaction boundaries
  - graceful restarts
  - channel hops
  - next-day recall
