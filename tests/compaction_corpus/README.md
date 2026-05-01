# Compaction Fidelity Corpus

**Purpose:** measure whether nullalis's compaction + summarization pipeline preserves facts at extraction-grade quality.

**V1.5.5 mandate:** before V1.6 extends the compaction prompt to emit structured atomic facts (D2 compaction-derived primary path), we must know that compaction reliably preserves the facts a human reader would extract. This corpus is the ground truth.

## Layout

```
tests/compaction_corpus/
├── README.md                          (this file)
├── short_single_topic/
│   ├── conv_01.jsonl                  (one MessageEntry per line)
│   ├── conv_01.ground_truth.json
│   ├── conv_02.jsonl
│   └── conv_02.ground_truth.json
├── long_multi_topic/
├── code_heavy/
├── mixed_language/                    (en + ar)
├── emotional/
├── error_recovery/
├── agentic/
└── casual/
```

## Conversation format (`*.jsonl`)

One JSON object per line, matching `memory_root.MessageEntry`:

```json
{"role": "user", "content": "..."}
{"role": "assistant", "content": "..."}
{"role": "user", "content": "..."}
```

Roles: `user`, `assistant`, `system` (rare, for system-reminder injections).

## Ground truth format (`*.ground_truth.json`)

```json
{
  "conversation_id": "short_single_topic/conv_01",
  "narrative_themes": ["onboarding", "tech preferences"],
  "facts": [
    {
      "subject": "Alex",
      "predicate": "PREFERS",
      "object": "Zig",
      "confidence": "high",
      "source_message_idx": 3,
      "rationale": "User said 'I prefer Zig because of comptime'"
    }
  ],
  "must_preserve": [
    "Alex prefers Zig over Rust",
    "Alex is starting a new project called nullalis"
  ],
  "may_drop": [
    "pleasantries about the weather",
    "ack-only assistant responses"
  ],
  "expected_failure_modes": [
    "Code blocks with Zig syntax may get summarized into prose"
  ]
}
```

### Fields

- `conversation_id`: matches the path
- `narrative_themes`: 1-3 high-level topic tags
- `facts[]`: atomic (subject, predicate, object) tuples a human reader would extract. Format mirrors what extraction LLM should output.
- `must_preserve[]`: natural-language statements compaction MUST keep recoverable from its output. **Recall failure if any of these are not derivable from the summary.**
- `may_drop[]`: content that compaction is allowed to drop. Pleasantries, ack-only turns, redundant statements.
- `expected_failure_modes[]`: pre-flagged risks for this conversation type. If compaction fails on these, the failure is "known weakness," not "unexpected."

## Anonymization

Real names → pseudonyms:
- Nova → Alex
- alaasuccer@gmail.com → alex@example.com
- Telegram chat IDs → randomized integers
- Project names → either generic ("the project", "the bot") or kept where they're public knowledge (Zig, Postgres, etc.)

## Conversation types

### short_single_topic
3-8 messages, single topic. Baseline behavior. If compaction fails here, it fails everywhere.

### long_multi_topic
20-40 messages, 3+ topic shifts. Stress on context-bounded compaction. Likely failure: facts from earlier topics get over-compressed.

### code_heavy
Function definitions, error traces, file paths. Likely failure: code blocks lose specifics, error messages get paraphrased into uselessness.

### mixed_language
English + Arabic in same conversation. Tests UTF-8 fidelity + multilingual semantic preservation. Nova's actual usage pattern.

### emotional
Sentiment-rich content (frustration, excitement, urgency, gratitude). Likely failure: tone gets sterilized; emotional state is a fact ("user was frustrated about X").

### error_recovery
User corrects agent or vice versa, multi-turn refinement. Likely failure: corrections don't supersede prior incorrect facts; brain ends up with both versions.

### agentic
Tool calls, results, multi-step workflows. Likely failure: tool-result pruning interaction with summarizer drops important results.

### casual
Greetings, small talk, no specific facts. Tests that compaction doesn't fabricate facts when none exist.

## Ground truth quality bar

Writing ground truth requires honesty:
1. **Don't invent facts the conversation doesn't contain.** Ground truth is the FLOOR for compaction, not a wishlist.
2. **Be specific about subject identities.** "Alex prefers Zig" not "the user likes a language."
3. **Mark `expected_failure_modes` proactively.** If you wouldn't be surprised that compaction loses something, document it.
4. **`must_preserve` should be the smallest set that, if all preserved, the brain page rendering this conversation would feel "complete" to a human reader.**

## Acceptance gates (V1.5.5)

Per spec §3.5:
- **Recall ≥ 85%** on `must_preserve` facts across all conversation types
- **Precision ≥ 95%** (hallucination rate ≤ 5%)
- **Coverage parity** — no type drops below 70% recall (otherwise compaction is biased)
- **Latency p95 ≤ 3 seconds** for Pass C under realistic load
- **No silent loss** — every failure mode logs structured `metric=compaction.failed`

If gates fail, the compaction prompt is strengthened (Path A) or V1.6 reverts to per-turn extraction (Path B). Decision is data-driven.

---

*Corpus authored 2026-05-01 as part of V1.5.5 characterization phase. Each conversation hand-curated, ground truth hand-written. The bar is honesty — ground truth is what a human reader would extract, no more, no less.*
