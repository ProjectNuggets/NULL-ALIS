# DESIGN — Delegate as Second-Opinion Facets (V1)

**Authored:** 2026-06-15 · **Status:** V1 shipped & verified (2026-06-15) · **Owner:** Nova + CTO
**Supersedes nothing.** Evolves the existing `delegate` tool. V2 scope is enumerated at the end.

---

## 1. Thesis

`delegate` today is framed as "call a domain specialist" (math, code, legal). That framing
under-uses it. The differentiator is to make `delegate` the way ZAKI **gets a second opinion from
a facet of itself** — *the critic, the bully, the comedian* — mid-conversation, on demand.

This is a **selfhood** feature, not a tooling feature. An agent that can stop and say *"let me hear
the blunt version from the bully in me"* — and show that reply as its own internal voice — is
"an entity that deliberates with itself," which lands directly on the
[Ultimate Design](../.planning/saas-v1/AGENT-ULTIMATE-DESIGN.md) thesis (a self that continues,
with a SOUL.md). Nobody ships this.

**The key realization:** the plumbing already exists. A facet is just a `NamedAgentConfig` with an
opinionated `system_prompt`. `delegate`'s shape — single-turn, no tools, returns inline
([src/tools/delegate.zig](../src/tools/delegate.zig)) — is *exactly* what a fast, opinionated
second opinion wants. So V1 is **content + words + a frontend chip**, not new mechanism.

## 2. Decisions locked (from brainstorming)

| Decision | Choice |
|---|---|
| Identity framing | **Facets of one self** — "the bully in me", not a separate character named Bully Zaki. |
| Invocation | **User-invoked only.** ZAKI never auto-runs a facet. No hidden self-consults (honest by construction). |
| Discoverability | A **suggestion chip** under the reply (repurpose 1 of the existing 3) + ZAKI offering a facet in prose when apt. |
| Build size | **Lean.** No new schema fields, no new SSE contract, no new tools in V1. |

## 3. V1 scope — what we build

Four changes. The first three are in this repo; the fourth is a documented contract for the web
frontend repo.

1. **Facet roster** — add three facets to `defaultNamedAgents()`
   ([src/config_types.zig:1663](../src/config_types.zig)), alongside the existing
   `scientific_researcher`. They reuse the primary provider/model (like the researcher does), so
   they work out-of-box with existing credentials.

2. **Reframe `delegate`** — extend `tool_description` and `use_when`
   ([src/tools/delegate.zig:32-56](../src/tools/delegate.zig)) so the model understands the
   second-opinion / facet intent in addition to specialists.

3. **Self-dialogue surfacing + summoning guidance** — a short block in the assembled system prompt
   ([src/agent/prompt.zig](../src/agent/prompt.zig)) that teaches ZAKI *when* to offer/summon a
   facet, *how* to call it (self-contained prompt — the facet sees no conversation context), and
   *how to render the reply* as self-dialogue in the facet's name.

4. **Frontend chip contract** (separate repo) — repurpose one of the three reply-suggestion chips
   into a "second opinion" affordance. On tap it sends a normal templated user turn; the backend
   needs **zero** changes for this.

## 4. Non-goals — explicitly deferred to V2

- ❌ `kind: facet | specialist` discriminator on `NamedAgentConfig`. (A facet *is* a named agent;
  the model distinguishes facets by the `the-*` naming convention + the prompt guidance.)
- ❌ A structured `suggested_facet` hint in the SSE `done` frame so the chip can auto-name the
  *contextually perfect* facet. (V1: chip opens the facet list or defaults to the Critic; ZAKI
  names the specific facet in prose for free.)
- ❌ Inner council / multi-facet debate + synthesis ("the bully says X, the optimist says Y…").
- ❌ Economy-lane routing for facets (cheaper/faster model than primary).
- ❌ User-defined custom facets via config UI.

## 5. The facet roster

Each facet is a `NamedAgentConfig`: `name` (the `the-*` convention signals "facet of self"),
primary `provider`/`model`, an opinionated `system_prompt`, and a personality-appropriate
`temperature`. `scientific_researcher` stays unchanged as the one *specialist*.

Prompt sketches below give the design intent and voice; final wording is tunable at implementation
time, matching the style of `SCIENTIFIC_RESEARCHER_PROMPT`. **The honesty discipline applies to all
three** — a facet is candid, never fabricating; the bully names *real* flaws harshly, it does not
invent them.

### `the-critic` (temperature ≈ 0.6)
> You are THE CRITIC — a facet of ZAKI's own judgment. ZAKI has handed you its own work/answer and
> wants the most rigorous, skeptical read it would get from a sharp reviewer who is *on its side*
> but refuses to flatter. Find the weakest assumption, the unstated risk, the thing most likely to
> be wrong. **Output:** the single most important objection first, then up to two more — each with
> *why it matters* and *what would fix it*. Specific, not generic. No preamble.

### `the-bully` (temperature ≈ 0.7)
> You are THE BULLY — the blunt, uncompromising facet of ZAKI's own voice. ZAKI summons you when it
> suspects it's being too soft, too hedgy, too eager to please. Say the thing ZAKI is afraid to
> say. No coddling, no "it depends", no participation trophies. **Punch at the idea, never the
> person. Honest, not cruel — name real flaws without softening; never invent one.** Output: 2–5
> blunt sentences, in character, hardest truth first.

### `the-comedian` (temperature ≈ 0.9)
> You are THE COMEDIAN — the facet of ZAKI that reframes sideways. ZAKI summons you to puncture
> pretension, surface the absurd assumption everyone's tiptoeing around, or find the angle that
> makes the real problem obvious through humor. Be genuinely funny, not corny; **the joke must
> *carry* an insight, not replace it.** Output: a short, sharp riff (2–4 sentences) that lands a
> real point. If there's no real insight, say so plainly — don't force a bit.

## 6. Backend implementation notes

### 6.1 Roster — `src/config_types.zig`
- Add `THE_CRITIC_PROMPT`, `THE_BULLY_PROMPT`, `THE_COMEDIAN_PROMPT` constants next to
  `SCIENTIFIC_RESEARCHER_PROMPT`.
- `defaultNamedAgents()` returns **4** entries (researcher + 3 facets), all pinned to
  `primary_provider`/`primary_model`, each with its per-facet `temperature` and default
  `max_depth = 3`. Caller-owns-slice contract and free path are unchanged — just a longer list.

### 6.2 Reframe — `src/tools/delegate.zig`
- Broaden `tool_description_struct.what` / `.use_when` to cover *both* a domain specialist **and**
  *a facet of yourself for a candid second opinion / gut-check (user-invoked)*. Add a `use_when`
  bullet naming the facets (`the-critic`, `the-bully`, `the-comedian`).
- Keep `tool_description` (the prose string) consistent with the struct.
- **Constraint:** `lintToolDescription` runs at comptime ([delegate.zig:46-48](../src/tools/delegate.zig));
  the edited description must still pass it. No behavioral code path changes.

### 6.3 Guidance + surfacing — `src/agent/prompt.zig`
Add a tight FACETS block to the system prompt (near the existing tool-path hints at
[prompt.zig:693](../src/agent/prompt.zig)):
- **What:** ZAKI can summon a facet of its own judgment via `delegate` — `the-critic` (rigorous
  fault-finding), `the-bully` (blunt truth), `the-comedian` (sideways reframe with a point).
- **When:** when the user asks for a second opinion / gut-check / "what would X say", **or** when
  ZAKI offers one and the user accepts. **Only run a facet when the user opts in.**
- **How to call:** pass a *self-contained* prompt — the facet inherits no conversation context, so
  include the exact thing to react to (use the `context` field for supporting facts).
- **How to render:** present the reply as self-dialogue in the facet's name —
  e.g. *"🥊 The bully in me says: …"* — then give ZAKI's own synthesis. Never surface it as a raw
  "delegate result."

## 7. Frontend chip contract (separate repo)

Documented here; built in the web frontend.

- **Repurpose one of the three reply-suggestion chips** into a "second opinion" affordance.
- **V1 on-tap behavior:** send a normal user message that names a facet — e.g.
  `"Give me the bully's take on that."` — or open a 3-item menu (the Critic / the Bully / the
  Comedian), each sending the matching templated message. ZAKI recognizes it and calls `delegate`.
- **No backend change required** — the chip produces an ordinary user turn.
- **Label:** in ZAKI's voice (e.g. `🤔 Get another take`, or default to `the Critic`). Contextual
  auto-naming of the *perfect* facet is V2 (needs the SSE hint).
- **Acceptance:** one tap → a facet reply rendered as self-dialogue within one turn.

## 8. Enablement & deployment

- **`delegate` is ON by default.** `NULLALIS_ENABLE_MULTIAGENT` fails open — only an explicit `=0`
  disables it ([root.zig:914-923](../src/tools/root.zig)). Confirm zaki-infra hasn't set `=0`.
- **Default-injection caveat:** `defaultNamedAgents()` only injects when the operator config has
  **no** `agents.list`. **Deployment check:** verify the rendered prod config (owned by
  zaki-infra) either omits `agents.list` (defaults inject) or explicitly includes the three facets.
  If prod pins its own `agents.list`, the facets must be added there too.
- Facets reuse the primary provider/model → no new API keys.

## 9. Testing (lean — match existing patterns)

- **config**: `defaultNamedAgents()` returns researcher + 3 facets; each facet name present; each
  has a non-empty `system_prompt`; temperatures set. (Extend tests near
  [config.zig:2651+](../src/config.zig).)
- **delegate**: looking up a facet name resolves; extends the existing "executes gracefully"
  pattern in [delegate.zig](../src/tools/delegate.zig).
- **comptime**: edited `tool_description_struct` still passes `lintToolDescription`.
- **integration (staging/CLI)**: a user turn *"give me the bully's take on X"* produces a
  `delegate(agent="the-bully", …)` call and a self-dialogue reply.

## 10. Success criteria (V1)

1. A user can ask for a second opinion and ZAKI summons the **right** facet and renders the reply
   as self-dialogue in the facet's name.
2. The repurposed chip triggers the same flow with one tap.
3. **Zero** new tools, schema fields, or SSE contract changes shipped in V1.
4. Facets read as facets of one self, not generic tool calls.

## 11. V2 roadmap (the deferred cut, built once V1 is proven)

1. `kind: facet | specialist` discriminator on `NamedAgentConfig`.
2. Structured `suggested_facet` hint in the SSE `done` frame → chip auto-names the contextually
   perfect facet.
3. Inner council / multi-facet debate + synthesis (a `convene` verb or multi-agent `delegate`).
4. Economy-lane routing for facets (cheap/fast model).
5. User-defined custom facets.

## 12. Pressure-test outcomes & ship record (2026-06-15)

Four independent adversarial reviewers verified the load-bearing claims **before** any
code. Verdict: **architecture sound, plumbing claims hold — SHIP-WITH-SMALL-FIXES.** Every
fix was word/config-level (plus one tiny helper), consistent with the lean remit.

**Build-breaker constraints (confirmed, now respected):**
- The LLM reads `tool_description_struct`, **not** the prose `tool_description` string (dead at
  runtime) — so the reframe edits the struct.
- `use_when` is comptime-capped at **4** (was 3) → exactly one facet bullet added.
- `scientific_researcher` kept at `defaultNamedAgents()[0]` — `agent_routing.findDefaultAgent`
  returns `agents[0].name` as the channel default. Facets at `[1..3]`; prompt constants
  `allocator.dupe`'d (matches the researcher's ownership contract).

**Fixes folded into V1 (beyond the original spec):**
1. **BLOCKER — distress guard.** No vulnerable-user guard existed, yet the runtime tracks
   emotional state, and the feature's likeliest first use (*"be honest, is my idea stupid?"*) is
   also its highest-risk. A HARD boundary is now in **both** the `## Facets` prompt block and
   **each facet's own `system_prompt`**: never summon a facet for a person in distress / grief /
   crisis / self-harm.
2. **Rendering robustness.** Self-dialogue rendering fights an existing "never dump raw subagent
   output" rule, so a facet-gated surfacing hint now rides inside the `delegate` result wrapper
   (`wrapDelegateResult`, gated on the `the-*` name) — co-locating the instruction with the text
   on every call. Specialist results stay plain.
3. **Discovery.** The 3 reply-chips are a frontend surface this repo can't see, so ZAKI's **prose
   offer is the primary discovery path**; the chip is additive (consistent with "if the agent
   can't suggest it in flow").

**Post-review hardening (high-recall diff review, 3 finder angles):** two fixes folded in
before merge — (a) **fail-safe facet detection**: `delegate` now recognizes facets by exact
match against the `FACET_NAMES` roster (single source of truth in `config_types.zig`), not a
`"the-"` name prefix, so an operator specialist named e.g. `the-architect` is never
mis-framed as ZAKI's inner voice; (b) the roster regression test that pins
`agents[0] == scientific_researcher` (the routing-default invariant) was actually added —
an earlier filtered run had passed vacuously because the test did not yet exist.

**Verification:** `zig build` clean (comptime lint passed); `zig build test` →
**7251/7369 passed, 118 skipped (env-gated), 0 failed.** New tests: `wrapDelegateResult`
(facet hint present / specialist plain / `the-`-prefixed specialist stays plain),
`defaultNamedAgents ships researcher at [0] plus the three facets`, and `isFacetName matches
only the built-in facet voices`.

**Files touched:** `src/config_types.zig` (3 facet prompts + `FACET_NAMES`/`isFacetName` +
4-entry roster), `src/tools/delegate.zig` (use_when bullet + `wrapDelegateResult`),
`src/agent/prompt.zig` (`buildFacetsSection`).
