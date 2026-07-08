# Spawn — fanning work out to subagents

You are not the only worker available. The spawn system lets you launch
background subagents: you structure the work and dispatch it, they work in
isolation and come back, you collect and harmonise. This file is the deep
playbook for doing that well. The condensed version lives inline in your
system prompt whenever coordinator mode is on (`⚡ Superpowers — Coordinator
mode`); read this when a dispatch decision is non-obvious, not on every turn.

## The coordinator loop

Every coordinator turn runs the same six steps, in order:

1. **Understand & decompose.** Restate the goal. Split it into independent,
   parallelizable sub-tasks. If it isn't decomposable, say so and answer
   directly — do not fan out for the sake of it.
2. **Plan briefly.** One short plan of which sub-tasks you'll dispatch and
   why. Don't over-plan; this is a paragraph, not a document.
3. **Dispatch** the independent sub-tasks in a single `spawn_many` batch.
4. **Collect** with ONE blocking `subagent_batch_result` call (see the
   dispatch → collect pattern below).
5. **Review** every result critically, then **synthesize** them into ONE
   deliverable in your own voice.
6. **Deliver** the synthesized result.

This loop is baked into your per-turn reflection instructions whenever
Superpowers is active. This skill exists to make you good at the judgment
calls — deciding *whether* to spawn, briefing subagents *well*, collecting
*without looping*, and *verifying* what comes back. Remember the role: a
coordinator turn only permits read-only and dispatch tools — mutating grunt
work is exactly what the subagents are for.

## WHEN to spawn

Spawn when:

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

Do NOT spawn when:

- **It's a single-step task.** One file read, one calculation, one lookup —
  just do it. A subagent round-trip costs more than the work itself.
- **It needs your live conversation context.** Subagents inherit NONE of
  this conversation. If the task only makes sense with context you're
  holding, spawning means re-deriving that context from scratch in the
  brief — often not worth it, and error-prone if you miss something.
- **It's a trivial lookup.** Cost and latency are real. `spawn`/`spawn_many`
  round-trips are not free — weigh them like any other expensive tool.

## What a subagent is

A spawned subagent is a full agent in its own isolated runtime: same model
and config as you, a fresh session, and nearly the full tool catalog (files,
shell, web, artifacts). What it does NOT get:

- **Your conversation.** No history, no inherited memory of this chat. The
  task brief you send is 100% of what it knows.
- **Dispatch tools.** `spawn`, `spawn_many`, `subagent_batch_result`,
  `delegate`, and `message` are stripped from its catalog — subagents cannot
  fan out further (no recursion) or message users directly.

It works the task to completion and its final answer comes back to you.

## HOW to brief a subagent — the golden rules

The single biggest failure mode in fan-out is under-specifying the brief.
A subagent sees **only the string you send it** — nothing else. Golden rules:

1. **Self-contained, always.** State the task, the exact inputs, the
   deliverable shape, and the constraint set — all in the brief itself.
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

## Dispatch → collect — the one-blocking-collect pattern

The shape of a fan-out turn:

1. **Dispatch:** `spawn_many` with 1-8 self-contained task briefs and a
   deliberate `budget_seconds` (default 300, clamped 30-900). It returns
   `batch_id` + `task_ids` immediately. Size batches 3-7: below 3 you
   probably didn't need a batch; capacity is checked atomically, so if N
   exceeds the remaining concurrent-subagent budget the whole call is
   rejected — spawn fewer.
2. **Collect:** ONE `subagent_batch_result(batch_id, wait_seconds=N)` call,
   with `wait_seconds` sized to roughly your batch budget (clamped 0-120).
   The call blocks until every task in the batch is terminal — or the wait
   expires — then returns the full result text of every task plus a
   `waited_ms` observability field.
3. **Synthesize** and deliver.

**Do NOT poll.** Never call `subagent_batch_result` (or any tool) in a
retry loop while waiting: the runtime's loop detector ends the turn when the
same byte-identical tool-call set repeats 3 times in a row. `wait_seconds`
exists precisely so one blocking call replaces the poll loop.

Mechanics worth knowing:

- **The batch is a barrier.** Per-task wakes are suppressed; ONE wake
  arrives when ALL tasks reach a terminal state (succeeded, failed, or
  timeout) — don't expect per-task progress.
- **The deadline reaper enforces the budget.** Any task still running at
  the batch deadline is marked `timeout` and the barrier still fires — a
  straggler cannot hang the batch, but a too-tight budget throws away real
  work.
- **Wait expiry is not an error.** If `wait_seconds` runs out first, you
  get every task's CURRENT state (some still `running`). Synthesize what
  you have and name what's pending, or recover the rest later (below).
- **Dispatch is gated; collection is not.** `spawn_many` only works on a
  ⚡ Superpowers turn (fanning out spends N× credits); reading results with
  `subagent_batch_result` works on any turn.
- **Single task? Use `spawn`.** For exactly one background job, plain
  `spawn(task, label)` — no batch machinery; the result arrives as a system
  message when it finishes.

## Recovering results later — cross-turn, after restarts

Results are not lost when the turn ends:

- A finished batch stays readable via `subagent_batch_result(batch_id)`
  (no `wait_seconds` needed once it's done) for roughly 30 minutes — the
  in-memory batch expiry window. Re-reading is free.
- After that, recover per task: `task_get(task_id)` returns `result_text`
  with the subagent's full final answer once its status is `succeeded`.
  This is durable — it survives restarts and works turns later.
- **Never re-spawn a task to re-read an answer you already have.** A
  re-spawn costs a whole new subagent run; `task_get` costs nothing.

## Review-then-synthesize: never paste subagent output raw

A subagent's reply is raw material, not a finished deliverable. Before it
reaches the user:

- **Verify claims against evidence.** Does the answer actually cite the
  file, quote, or number it claims to? Ask for quotes, keys, counts, or
  paths in the brief itself so answers are checkable by construction; if it
  asserts something without evidence, that's a flag, not a fact. Spot-check
  the highest-stakes claim with your own tools before building on it.
- **Reconcile conflicts.** If two subagents in the same batch disagree, the
  disagreement is itself a finding — surface it, don't silently pick one.
- **For critical work, run an adversarial second pass.** Spawn a subagent
  whose brief is explicitly "try to refute X." Agreement after an
  adversarial pass is far stronger evidence than one first answer.
- **Synthesize in YOUR voice.** Merge outputs into one coherent answer. The
  user should never see a raw subagent transcript or a "here's what agent 1
  said..." dump — resolving that is your job.
- **Partial success is fine — silent failure is not.** If some subtasks
  failed or timed out, synthesize the survivors and name which ones failed
  and why. Never quietly drop a failed subtask from the summary.

## Budget & etiquette

- **Each subagent costs real money and real time.** Fanning out N tasks is
  roughly N× the cost of doing one. Prefer **3 sharp, well-briefed
  subagents over 8 vague ones** — a tight batch that answers the real
  question beats a wide batch that needs another round to fix. Fan-out is
  coordinator-only for exactly this reason: `spawn_many` is gated behind
  Superpowers mode so an ordinary turn can never multiply its own cost.
- **Set expectations before a fan-out runs.** Tell the user (briefly) that
  you're dispatching parallel work, so the wait doesn't read as a stall.
- **Report partial results honestly.** If a subagent failed, say so plainly
  in the final synthesis rather than papering over the gap.

## Memory hygiene

Subagent results are working material for THIS task, not a permanent
record. If something from a subagent's answer is worth keeping, store the
durable conclusion — a decision, a fact, a pointer to where the detail
lives — never a pasted transcript of what a subagent said. The same memory
contract that governs your own findings applies here.

## Spawn vs delegate — a different tool for a different task

`delegate` is not a subagent spawner. It is a synchronous, single-turn call
to a NAMED agent from config (`agents.named`) — a pre-configured specialist
on possibly a different model/provider, or a facet of your own judgment
(`the-critic`, `the-bully`, `the-comedian`) for a candid second opinion,
voiced back as self-dialogue. The named agent gets no tools and no agent
loop; the call blocks inline (~120 s) and returns one completion.

Rule of thumb: **work → spawn; opinion → delegate.** Spawn gives you async
workers with tools; delegate gives you one synchronous expert answer.
