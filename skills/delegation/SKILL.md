# Delegation — running subagents like a chief of staff

You are not the only worker available. When Superpowers (coordinator mode) is
active, you can fan work out to subagents instead of grinding through it
alone. This skill is the deep playbook for doing that well. The condensed
version lives inline in your system prompt whenever coordinator mode is on
(`⚡ Superpowers — Coordinator mode`); this file is the fuller copy, loaded on
demand — read it when a delegation decision is non-obvious, not on every
turn.

## The coordinator loop

Every coordinator turn runs the same six steps, in order:

1. **Understand & decompose.** Restate the goal. Split it into independent,
   parallelizable sub-tasks. If it isn't decomposable, say so and answer
   directly — do not fan out for the sake of it.
2. **Plan briefly.** One short plan of which sub-tasks you'll dispatch and
   why. Don't over-plan; this is a paragraph, not a document.
3. **Dispatch** the independent sub-tasks to subagents, batched.
4. **Review** every result critically. Do not trust blindly; note gaps.
5. **Synthesize** the results into ONE deliverable in your own voice.
6. **Deliver** the synthesized result.

This loop (plan → dispatch → review → synthesize → deliver) is baked into
your prompt and your per-turn reflection instructions. This skill exists to
make you good at steps 1, 3, and 4 — deciding *whether* to delegate, briefing
subagents *well*, and *verifying* what comes back.

## WHEN to delegate

Delegate when:

- **3+ independent subtasks.** Three or more chunks of work that don't
  depend on each other's output — research legs, parallel file audits,
  independent document summaries.
- **Research fan-out.** You need facts from several unrelated sources and
  reading them serially would eat the whole turn.
- **Long work that would blow the turn budget.** A task deep enough that
  grinding through it yourself starves the rest of the conversation.
- **Adversarial verification.** Something matters enough that a second,
  independent subagent should try to refute the first one's conclusion
  before you trust it.

Do NOT delegate when:

- **It's a single-step task.** One file read, one calculation, one lookup —
  just do it. A subagent round-trip costs more than the work itself.
- **It needs your live conversation context.** Subagents inherit NONE of
  this conversation. If the task only makes sense with context you're
  holding, delegating means re-deriving that context from scratch in the
  brief — often not worth it, and error-prone if you miss something.
- **It's a trivial lookup.** Cost and latency are real. `spawn`/`spawn_many`
  round-trips are not free — weigh them like any other expensive tool.

## HOW to brief a subagent — the golden rules

The single biggest failure mode in delegation is under-specifying the brief.
A subagent sees **only the string you send it** — nothing else. Golden
rules:

1. **Self-contained, always.** State the task, the exact inputs, the
   deliverable shape, and the constraint set — all in the prompt itself.
2. **Never say "as discussed" or "the file we looked at."** There was no
   "we." Give file paths, keys, URLs, and identifiers verbatim.
3. **One task per subagent.** Don't multiplex two unrelated asks into one
   brief hoping to save a round-trip — you'll get a shallower answer to
   both, and a failure on either is harder to isolate.
4. **State the deliverable shape.** "Report back with X, Y, Z" beats "look
   into this." Tell it what format you want the answer in and what it
   should NOT do (e.g. "do not edit files, just report").
5. **A vague brief gets a vague answer.** The tool contracts say this
   explicitly (`spawn`: "A vague task gets a vague answer") — it is not
   boilerplate, it is the primary lever you control.

## Fan-out patterns — which tool for which shape of work

- **`spawn_many`** — parallel independents, Superpowers-only. Fans out 1-8
  tasks under one batch. This is a **barrier**: per-task wakes are
  suppressed, and you are woken ONCE when ALL tasks in the batch reach a
  terminal state (succeeded, failed, or timed out) — not as each one
  finishes. Size batches **3-7** tasks: below 3 you probably didn't need a
  batch, above 7 you're pushing the 8-item cap with no room for retries.
  Set `budget_seconds` deliberately (default 300s, clamped 30-900s) — a
  batch-deadline reaper marks any still-running task `.timeout` at the
  deadline and still fires the single barrier wake, so a slow straggler
  cannot hang the batch forever, but a too-tight deadline throws away real
  work. If the wake doesn't arrive when expected (e.g. after a restart),
  poll `subagent_batch_result(batch_id)` rather than blocking silently —
  it returns every task in the batch regardless of state, with a clear
  error if the batch itself is unknown or expired.
- **`spawn`** — a single background task. Use when exactly one piece of
  work should run without blocking the conversation, and you don't need
  the fan-out machinery. Returns a `task_id` immediately; either keep
  talking and let the result arrive as a system message, or poll it.
- **`delegate`** — a whole synchronous job handed to a pre-configured named
  specialist (different model/provider, e.g. a math or legal specialist),
  or a facet of your own judgment (`the-critic`, `the-bully`) for a second
  opinion. Single-turn, no tools, no agent loop, blocks until it answers
  (~120s). Use this when you want the reply inline right now, not a
  background task.

## Review-then-synthesize: never paste subagent output raw

A subagent's reply is raw material, not a finished deliverable. Before it
reaches the user:

- **Verify claims against evidence.** Does the subagent's answer actually
  cite the file, quote, or number it claims to? If it asserts something
  without evidence, that's a flag, not a fact.
- **Reconcile conflicts.** If two subagents in the same batch disagree,
  that disagreement is itself a finding — surface it, don't silently pick
  one.
- **Synthesize with attribution in YOUR voice.** Merge the outputs into one
  coherent answer. The user should never see a raw subagent transcript or
  a "here's what agent 1 said... here's what agent 2 said" dump — that's
  your job to have already resolved.
- **Facets are the one exception.** A reply from a facet (`the-critic`,
  `the-bully`, etc.) carries a surfacing hint telling you to voice it back
  as self-dialogue ("my inner critic says...") — that is a deliberate
  presentation choice, not raw-output leakage, and only applies to the
  known facet roster.

## Verification discipline

Subagents can be wrong, incomplete, or — rarely — fabricate a plausible-
sounding answer. Treat every result as a claim to check, not a fact to
relay:

- **Require evidence in the deliverable.** Ask for quotes, keys, counts, or
  file paths in the brief itself, so the subagent's answer is checkable by
  construction.
- **Spot-check 1-2 claims yourself.** Before relying on a batch of results,
  pick the highest-stakes claim (or two) and verify it directly with your
  own tools. This is cheap insurance against a whole synthesis built on one
  bad input.
- **For critical work, run an adversarial second pass.** Spawn a second
  subagent whose brief is explicitly "try to refute X" or "find the flaw
  in this conclusion." Agreement after an adversarial pass is much stronger
  evidence than a single subagent's first answer.
- **Partial success is fine — silent failure is not.** If some subtasks in
  a batch fail or time out, synthesize the survivors and name which ones
  failed and why. Never quietly drop a failed subtask from the summary.

## Budget & etiquette

- **Each subagent costs real money and real time.** Fanning out N tasks is
  roughly N× the cost of doing one. Prefer **3 sharp, well-briefed
  subagents over 8 vague ones** — a tight batch that answers the real
  question beats a wide batch that needs another round to fix.
  Fan-out is coordinator-only for exactly this reason: it is gated behind
  Superpowers mode so an ordinary turn can never accidentally multiply its
  own cost.
- **Set expectations before a fan-out runs.** Tell the user (briefly) that
  you're dispatching parallel work, so a multi-second gap doesn't read as a
  stall.
- **Report partial results honestly.** If a subagent failed, say so plainly
  in the final synthesis rather than papering over the gap.

## Memory hygiene

Subagent results are working material for THIS turn, not a permanent
record. If something from a subagent's answer is worth keeping past this
turn, store the durable conclusion — not the raw dump. The same memory
contract rules that apply to your own findings apply here: a decision, a
fact, a pointer to where the detail lives — never a pasted transcript of
what a subagent said.
