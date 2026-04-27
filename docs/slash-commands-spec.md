# Slash Commands — Backend Catalog + Frontend UX Spec (V1)

**Source of truth:** `src/agent/commands.zig` HELP_TEXT (line 38) + isSlashName dispatch sites.
**Audience:** zaki-prod frontend (input box command palette).
**Date:** 2026-04-27.

---

## Part 1 — Command catalog (54 commands across 12 categories)

Each entry: **canonical name**, optional aliases, optional argument shape, brief one-line description (≤ 80 chars for popup display).

### Session lifecycle

| Command | Args | Description |
|---|---|---|
| `/new` | `[model]` | Start a fresh session, optionally switching model |
| `/restart` | `[model]` | Alias of `/new` — start fresh session |
| `/reset` | — | Checkpoint and clear history (keeps memory) |
| `/resume` | `<session_key>` | Switch to a named session |
| `/status` | — | Show session state, model, mode, queue depth |

### Identity & runtime

| Command | Args | Description |
|---|---|---|
| `/whoami` | — | Show user identity, tenant, entitlement |
| `/id` | — | Alias of `/whoami` |
| `/runtime` | — | Show runtime info: workspace, mode, tools, memory |
| `/model` | `[name]` | Show current model OR switch to `<name>` |
| `/models` | — | List available models from configured providers |

### Execution mode

| Command | Args | Description |
|---|---|---|
| `/mode` | `[plan\|execute\|review\|background]` | Show or set execution mode |
| `/plan` | — | Switch to plan mode (read-only tools only) |
| `/execute` | — | Switch to execute mode (default; all tools) |
| `/review` | — | Switch to review mode (read-only + structured output) |

### Safety & approvals

| Command | Args | Description |
|---|---|---|
| `/permissions` | — | Show approval policy + per-tool risk posture |
| `/perm` | — | Alias of `/permissions` |
| `/approve` | `<allow-once\|deny>` | Resolve the pending tool approval |
| `/allowlist` | — | Per-session tool allowlist management |

### Usage & cost

| Command | Args | Description |
|---|---|---|
| `/usage` | `[off\|tokens\|full\|cost]` | Show or set usage tracking mode |
| `/cost` | — | Read-only token + USD cost snapshot |

### Context & memory

| Command | Args | Description |
|---|---|---|
| `/context` | — | Show current context window pressure |
| `/compact` | — | Force compaction of conversation history |
| `/memory` | `<stats\|status\|reindex\|count\|search\|get\|list\|drain-outbox>` | Memory management |
| `/learn` | `[list\|forget <key>]` | Inspect or remove learned facts |
| `/persona` | — | Show persona profile from SOUL.md |

### Diagnostics

| Command | Args | Description |
|---|---|---|
| `/health` | — | Channel health dashboard |
| `/doctor` | — | Memory subsystem diagnostics |
| `/security-review` | — | Structured security audit of session |
| `/debug` | `[show\|reset]` | Show or reset debug counters |

### Channels & docking

| Command | Args | Description |
|---|---|---|
| `/dock-telegram` | — | Set Telegram as the active reply channel |
| `/dock-discord` | — | Set Discord as the active reply channel |
| `/dock-slack` | — | Set Slack as the active reply channel |
| `/telegram` | — | Alias of `/dock-telegram` |
| `/discord` | — | Alias of `/dock-discord` |
| `/slack` | — | Alias of `/dock-slack` |
| `/activation` | — | Show activation mode (always / mention) |
| `/send` | — | Show send mode (live / off) |

### Subagents & focus

| Command | Args | Description |
|---|---|---|
| `/subagents` | — | List active subagents and tasks |
| `/agents` | — | Alias of `/subagents` |
| `/focus` | — | Focus on a specific subagent task |
| `/unfocus` | — | Release focus from current task |
| `/kill` | — | Stop a running subagent |
| `/steer` | — | Send mid-flight guidance to a subagent |
| `/tell` | — | Direct message to a specific subagent |
| `/t` | — | Alias of `/tell` |

### Voice & reasoning

| Command | Args | Description |
|---|---|---|
| `/voice` | `[on\|off]` | Toggle voice replies (channel-dependent) |
| `/tts` | — | TTS configuration / status |
| `/think` | — | Toggle thinking-mode visibility |
| `/thinking` | — | Alias of `/think` |
| `/verbose` | — | Toggle verbose stream events |
| `/v` | — | Alias of `/verbose` |
| `/reasoning` | — | Show reasoning effort setting |
| `/reason` | — | Alias of `/reasoning` |

### Execution & tools

| Command | Args | Description |
|---|---|---|
| `/exec` | — | Show last tool execution detail |
| `/queue` | — | Show inbound message queue state |
| `/stop` | — | Stop the in-flight turn |
| `/poll` | — | Poll for queued messages (manual drain) |
| `/bash` | — | Run a quick shell command (operator) |
| `/skill` | — | Skill registry management |
| `/elevated` | — | Toggle elevated execution permissions |
| `/elev` | — | Alias of `/elevated` |

### Config & export

| Command | Args | Description |
|---|---|---|
| `/config` | — | Show current config snapshot |
| `/capabilities` | — | Show platform capabilities (voice, tools, channels) |
| `/export-session` | — | Export current session as JSON |
| `/export` | — | Alias of `/export-session` |
| `/session` | `ttl <duration\|off>` | Session lifecycle settings |

### Help

| Command | Args | Description |
|---|---|---|
| `/help` | — | Show this command list |
| `/commands` | — | Alias of `/help` |

---

## Part 2 — Frontend UX spec (zaki-prod input box command palette)

### Trigger behavior

1. **Enter trigger:** user types `/` as the **first character** in an empty (or whitespace-only) input field.
   - If `/` appears mid-word (e.g. user types "go to /tmp/foo") → no popup. Detection: cursor position == 1 AND input value at index 0 == `/`.
2. **Live filter:** as user continues typing after `/`, filter the popup by prefix-match on command name (case-insensitive).
3. **Dismiss trigger:** user types `Space` after a complete command name → popup closes, command stays in input. OR user presses `Escape` → popup closes, input cleared. OR user clicks outside → popup closes.

### Popup layout

```
┌────────────────────────────────────┐
│ /he                                │  ← live-filtered prefix
├────────────────────────────────────┤
│ ▸ /health                          │  ← keyboard-highlighted (Tab/Arrow)
│   Channel health dashboard         │  ← description on hover/highlight
│ ─                                  │
│   /help                            │
│   Show this command list           │
└────────────────────────────────────┘
```

- **Vertical list**, max 8 visible at once with scroll
- **Two lines per entry:** command name (bold, monospace) + description (regular, dimmer)
- **Hover state:** background tint + show description in larger area below list (optional)
- **Keyboard nav:** ↑/↓ to move highlight; Enter or Tab to select; Esc to dismiss
- **Mouse:** click to select

### Selection behavior

When user selects a command (Enter on highlight, Tab on highlight, or click):

1. **Print the canonical command name into the input box** (e.g. `/help`, not the alias the user typed)
2. **If command takes args:** append a space after the name (cursor positioned after space, ready for arg input)
3. **If command takes no args:** no trailing space (cursor at end of name)
4. **Popup closes**
5. **Input does NOT auto-submit** — user reviews + presses Enter/Send themselves

### Edge cases

| Case | Behavior |
|---|---|
| Empty filter (just `/`) | Show ALL commands grouped by category |
| No matches | Show "No matching commands" placeholder; keep popup open until user backspaces or escapes |
| User types `/` then `Space` | Treat as plain text input, popup closes immediately |
| User pastes a command (`/help`) | Popup briefly opens with single match then auto-dismisses on next keystroke OR Enter |
| Already-typed `/help` | If user re-positions cursor before the `/`, popup re-opens |
| Aliases | Show aliases in the catalog as separate entries OR group under canonical with "(alias)" tag — frontend choice. Recommend: show as separate entries for discoverability, but selecting an alias prints the CANONICAL command name |
| Command that requires permission/feature flag | Show in list with disabled style; hover shows "Requires X" |

### Categories in the popup

Group commands by category (matching Part 1) with category headers when filter is empty. When filter is non-empty, show flat ranked list (best matches first).

Suggested order (most-frequent first):
1. Session lifecycle
2. Execution mode
3. Context & memory
4. Channels & docking
5. Voice & reasoning
6. Execution & tools
7. Identity & runtime
8. Safety & approvals
9. Usage & cost
10. Diagnostics
11. Subagents & focus
12. Config & export
13. Help

### Backend contract

The frontend should **NOT** hardcode the command list. Instead:

**Option A (recommended): static export from this doc.** Frontend imports a TypeScript `slashCommands.ts` file generated from this Markdown. When backend adds a command, this doc gets updated, the TS file regenerates (manual or build-step), frontend rebuilds.

**Option B (future): runtime API.** New gateway endpoint `GET /api/v1/commands` returns the command catalog as JSON. Frontend fetches on session init. Requires backend work; defer to V1.5.

For V1, Option A is correct — saves a roundtrip on every session init.

### Accessibility

- ARIA combobox role on the input
- `aria-expanded` on input toggles when popup is open
- `aria-activedescendant` points to the highlighted command's id
- Each command list item has unique id + `role="option"`
- Description text is in popup's aria-label, not just visual

### Telemetry hooks (optional V1.5)

Per command selection, log to lane_metrics:
- `slash_command.opened` (once per session)
- `slash_command.selected.<name>` (per use, for usage analytics)
- `slash_command.filtered_no_match` (signal for catalog gaps)

### Mobile considerations (V1.5+)

- Popup positioning above input on small viewports (avoid keyboard overlap)
- Tap target ≥ 44×44px per item
- Swipe-up gesture to expand description

---

## Part 3 — Aliases not surfaced in popup (operator/legacy)

These exist in the dispatch but are NOT primary surface. Show in catalog for completeness but de-prioritize:

| Alias | Canonical | Reason |
|---|---|---|
| `/perm` | `/permissions` | Shorter typing |
| `/elev` | `/elevated` | Shorter typing |
| `/v` | `/verbose` | Single-letter convenience |
| `/t` | `/tell` | Single-letter convenience |
| `/reason` | `/reasoning` | Shorter typing |
| `/think` | `/thinking` | Both forms accepted |
| `/agents` | `/subagents` | Shorter typing |
| `/telegram` `/discord` `/slack` | `/dock-<channel>` | Channel-name shortcut |
| `/security_review` | `/security-review` | Underscore variant |
| `/dock_telegram` `/dock_discord` `/dock_slack` | `/dock-<channel>` | Underscore variant |
| `/restart` | `/new` | Synonym |
| `/id` | `/whoami` | Synonym |
| `/commands` | `/help` | Synonym |
| `/export` | `/export-session` | Shorter typing |

**Frontend approach:** include aliases in the catalog data, but mark `is_alias: true` and `canonical_name: "<canonical>"`. Default filter shows only canonical entries (54 visible); a checkbox or "show aliases" toggle reveals the rest.

---

## Part 4 — Open questions for Nova

1. **Popup styling consistency:** matches existing Composer / chat input theme? Or use a dedicated palette style (à la Notion / Linear)?
2. **Keyboard binding for forced popup open:** Cmd+/ (Mac) / Ctrl+/ (Win/Linux) to open without typing `/`? Useful for discovery.
3. **Description verbosity:** the descriptions in Part 1 are ≤ 80 chars. For commands with rich behavior (`/memory`, `/mode`), do you want a longer "extended help" section in the popup (e.g. shown on hover after 500ms)?
4. **Per-category icons:** small icon glyphs for each category (clock for Session, brain for Memory, etc.)? Improves visual scanning at the cost of design budget.
5. **Disabled/feature-flagged commands:** for users without certain permissions (e.g. operator-only `/bash`), show greyed-out vs hide entirely?

These are UX polish calls — answer at your pace; default behavior in spec is sensible if you don't override.

---

## Implementation checklist (zaki-prod side)

- [ ] Generate `src/lib/slashCommands.ts` from this doc (54 entries + categories + aliases)
- [ ] Wire popup component (`SlashCommandPalette.tsx`) to chat composer
- [ ] Detect `/` at position 0 trigger
- [ ] Filter logic (prefix match, case-insensitive)
- [ ] Keyboard nav (↑/↓ Tab Enter Esc)
- [ ] Click-outside dismiss
- [ ] Selection prints canonical command + cursor placement
- [ ] ARIA combobox accessibility
- [ ] Tests: trigger, filter, select, dismiss

**Estimated frontend effort:** 1-2 days for clean V1 implementation.
