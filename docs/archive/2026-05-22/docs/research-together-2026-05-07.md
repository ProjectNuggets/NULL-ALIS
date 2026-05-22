# Together.ai Model Research — 2026-05-07

Scope: confirm whether nullalis' current Fast/Balanced/Deep lineup is best-in-class on Together.ai as of May 2026, and identify gaps. Code-truth from Together model/pricing pages plus Artificial Analysis, vendor blogs, and aggregator listings. Where a number isn't on Together's own page, the source is called out inline.

---

## 1. Together's current premium catalog (May 2026)

Together advertises 200+ models, but the headline chat/reasoning tier surfaced on the models and pricing pages is small:

| Model | Context | $/M in | $/M cached | $/M out | Multimodal | Reasoning effort |
|---|---|---|---|---|---|---|
| `deepseek-ai/DeepSeek-V4-Pro` | 512K (model max 1M) | 2.10 | 0.20 | 4.40 | Text-only | Non-think / Think-High / Think-Max |
| `deepseek-ai/DeepSeek-V4-Flash` | 1M (model); Together status "coming soon" / freshly listed | unconfirmed on Together | — | — | Text-only | Same 3-mode scheme |
| `deepseek-ai/DeepSeek-R1-0528` | 128K | 3.00 | — | 7.00 | Text-only | Reasoning baked in (no effort knob) |
| `moonshotai/Kimi-K2.6` | 256K (262,144 in tech blog) | 1.20 | 0.20 | 4.50 | Vision | Yes (think on/off) |
| `moonshotai/Kimi-K2.5` | 256K | 0.50 | — | 2.80 | Vision (limited) | No effort flag |
| `zai-org/GLM-5.1` | 200K | 1.40 | — | 4.40 | Text-only | Yes (think on/off) |
| `zai-org/GLM-5` | 128K | 1.00 | — | 3.20 | Text-only | Yes |
| `Qwen/Qwen3.6-Plus` | 1M | 0.50 | — | 3.00 | Vision + video | Yes |
| `Qwen/Qwen3.5-397B-A17B` | 256K | 0.60 | — | 3.60 | Text-only | No |
| `meta-llama/Llama-4-Maverick` | 10M (model); Together page does not confirm full window | ~0.27 blended (Meta's number; Together not explicit) | — | — | Native vision | No effort knob |
| `gpt-oss-120B` | 128K | 0.15 | — | 0.60 | Text-only | Yes |

Notes on coverage gaps: Together's pricing page does not publish per-model context windows in one place; values above are pulled from the dedicated model pages and Artificial Analysis. **DeepSeek V4-Flash on Together is freshly listed but pricing was not yet published on the consolidated pricing page at fetch time** — flag, don't quote.

There is no "DeepSeek V5" or "Kimi K3" on Together yet. K3 is forecast by Moonshot for late May / June 2026 with multimodal as the headline feature; treat as a roadmap item, not a current option.

---

## 2. DeepSeek family — what changed

- **V4-Pro (released 2026-04-24)** is the current flagship: 1.6T total / 49B active MoE, hybrid attention, three reasoning modes. Together exposes it at 512K context; full 1M is supported at the model level but not enabled on Together's serverless tier as of fetch. Tool/function calling and prompt caching both supported. **Text-only — no vision, no audio.**
- **V4-Flash** is the cheap sibling — 284B total / 13B active, 1M context at the model level. Direct DeepSeek pricing is $0.14 in / $0.28 out per M (api-docs.deepseek.com). Together has announced it but the consolidated pricing page hadn't surfaced the numbers at the time of this research.
- **R1-0528** is still in the catalog at $3.00 / $7.00 — strictly worse than V4-Pro on price and capability for nullalis' agentic workloads. Skip.
- DeepSeek **multimodal**: still text-only across V4-Pro and V4-Flash. No public roadmap for vision on Together.

---

## 3. Kimi family — what changed

- **K2.6 (April 2026)** is now the Moonshot flagship on Together: 80.2 % SWE-Bench Verified (Moonshot self-report), 256K context, native multimodal (vision), reasoning toggle, $1.20/$4.50, 0.20 cached. Cheaper than V4-Pro on input.
- **K2.5** is still listed cheaper ($0.50/$2.80) but is a generation behind on agentic tool use and lacks the reasoning_effort knob.
- **K3** — not on Together. Manifold prediction markets give a ~74% chance of release before end of May 2026; Moonshot has teased multimodal as the K3 differentiator. Treat as 30-90 day horizon, not a current dependency.

Important correction to the brief: **the model nullalis labels "Kimi-K2.5" as Fast is not actually the best-in-class Kimi on Together anymore.** K2.6 supersedes it on intelligence (#1 on Together by Artificial Analysis Intelligence Index = 54), is multimodal, and has a reasoning_effort toggle K2.5 does not. K2.5 is still cheaper and lower-latency, so it's a defensible "Fast" pick — but only if cost is the binding constraint.

---

## 4. Other candidates

- **GLM-5.1** (Zhipu / Z.ai, 2026-04-07): 744B MoE / 40B active, 200K context, reportedly tops SWE-Bench Pro at 58.4 (self-reported). MIT-licensed weights. **Text-only** — no vision/audio. On Together at $1.40/$4.40. Strong agentic/coding fit; weaker on long-context vs. V4-Pro and Qwen3.6-Plus.
- **Qwen3.6-Plus** (2026-03-31): 1M native context, vision + video, agentic coding tuned, 78.8 SWE-Bench Verified (self-reported). On Together at $0.50/$3.00. **This is the most interesting "didn't realize this existed" option.** It's multimodal, has the longest context on Together, and undercuts both V4-Pro and Kimi K2.6 on input price.
- **Llama 4 Maverick**: native multimodal, advertised 10M context (Together does not surface that explicitly). Agentic benchmarks are weaker than DeepSeek V4 / Kimi K2.6 / GLM-5.1 / Qwen3.6-Plus. Llama 5 has not shipped; Behemoth is still a teacher model only.
- **gpt-oss-120B**: cheap reasoning-capable text model at $0.15/$0.60. Worth a look as a budget Fast tier if Kimi feels overkill.

---

## 5. Together API caveats

From `docs.together.ai/docs/inference-faqs` and the Promptfoo provider docs:
- Streaming via `stream: true` is supported across the catalog.
- Function/tool calling supported on the premium tier (DeepSeek V4-Pro, Kimi K2.6, GLM-5.1, Qwen3.6-Plus). Not uniformly on older/smaller models — verify per-model.
- Prompt caching: documented for DeepSeek V4-Pro and Kimi K2.6 with `$0.20/M` cached input pricing (a 90% / 83% discount). Not advertised for GLM/Qwen on the pricing page.
- Rate limits: standard 429 with dashboard self-serve raise; >100 RPS workloads route to dedicated.
- Regional availability: not explicitly broken out on the pricing page. **Unclear from public docs** — if EU residency matters for the booth demo, ask sales.
- Deprecations: nothing announced for May 2026. R1-0528 is the most likely de-emphasis candidate given V4-Pro's price-performance, but no formal sunset.

---

## 6. Multimodal (booth demo) recommendation

Three credible options:

| Model | $/M in | $/M out | Context | Notes |
|---|---|---|---|---|
| **Kimi K2.6** | 1.20 | 4.50 | 256K | Native vision, reasoning toggle, agentic tool use #1 |
| **Qwen3.6-Plus** | 0.50 | 3.00 | 1M | Vision + video, cheapest, longest context |
| **Llama 4 Maverick** | ~0.27 blended | — | 10M (model) | Cheapest, but weaker agentic and Together's exposed window unclear |

Recommendation: **Qwen3.6-Plus** for the booth demo. Cheapest, longest context, vision + video, agentic-tuned. Kimi K2.6 is the safer choice if you want a single model that also handles your reasoning-heavy paths well — pay 2.4× input but get the better reasoning baseline.

---

## 7. Mode upgrade recommendation

Current lineup audit:
- **Fast = Kimi K2.5**: outdated. Not multimodal, no reasoning_effort. Either stay (cost-pinned) or upgrade.
- **Balanced = DeepSeek V4-Pro (medium)**: current best-in-class for text reasoning on Together. Keep.
- **Deep = DeepSeek V4-Pro (high)**: same model, higher effort. Cache-shared with Balanced — keep.

Concrete proposal:

1. **Promote Fast → `Qwen3.6-Plus` at low/no reasoning effort.** Cheaper input than K2.5 ($0.50 vs 0.50 — wash), cheaper output than K2.6 ($3.00 vs 4.50), gets you 1M context and vision for free. This single change gives the booth demo its visual capability without adding a fourth mode.
2. **Keep Balanced/Deep on V4-Pro.** Add V4-Flash as an explicit `cheap-balanced` option once Together publishes pricing — likely 5-10× cheaper than V4-Pro for workloads that don't need maximum reasoning.
3. **Defer GLM-5.1.** Strong on coding/agentic, but text-only and no clear advantage over V4-Pro on Together's price curve.
4. **Defer Kimi K3 / DeepSeek V5.** Neither shipped. Re-check in 30 days.
5. **Skip a 4th vision mode.** Folding vision into Fast (via Qwen3.6-Plus) is cleaner than another preset.

Caveat: the brief described Balanced and Deep as "cache-shared" because they're the same model. Routing both to V4-Pro is correct *if* Together honors prompt-cache hits across reasoning_effort levels. Their docs don't confirm this either way — worth a one-call test before the booth.

---

## Sources

- [Together AI — Models](https://www.together.ai/models)
- [Together AI — Pricing](https://www.together.ai/pricing)
- [Together AI — DeepSeek V4 Pro model page](https://www.together.ai/models/deepseek-v4-pro)
- [Together AI — DeepSeek V4 Flash model page](https://www.together.ai/models/deepseek-v4-flash)
- [Together AI — Inference FAQs (docs)](https://docs.together.ai/docs/inference-faqs)
- [Together AI blog — DeepSeek-V4 Pro now available](https://www.together.ai/blog/deepseek-v4-pro-now-available-on-together-ai)
- [Artificial Analysis — Together.ai provider page](https://artificialanalysis.ai/providers/togetherai)
- [Artificial Analysis — DeepSeek V4 Pro](https://artificialanalysis.ai/models/deepseek-v4-pro)
- [Artificial Analysis — DeepSeek V4 Flash](https://artificialanalysis.ai/models/deepseek-v4-flash)
- [Artificial Analysis — Kimi K2.6 providers](https://artificialanalysis.ai/models/kimi-k2-6/providers)
- [DeepSeek API docs — pricing](https://api-docs.deepseek.com/quick_start/pricing)
- [DeepSeek V4 Preview release notes](https://api-docs.deepseek.com/news/news260424)
- [Moonshot — Kimi K2.6 tech blog](https://www.kimi.com/blog/kimi-k2-6)
- [Moonshot — Kimi K2.6 model page](https://www.kimi.com/ai-models/kimi-k2-6)
- [Z.ai — GLM-5.1 docs](https://docs.z.ai/guides/llm/glm-5.1)
- [Qwen3.6-Plus blog](https://qwen.ai/blog?id=qwen3.6)
- [TokenMix — Kimi K3 integration guide](https://tokenmix.ai/blog/kimi-k3-developer-integration-guide-2026)
- [Manifold — Kimi K3 release date market](https://manifold.markets/Bayesian/when-will-moonshot-release-kimi-k3)
- [Promptfoo — Together AI provider notes](https://www.promptfoo.dev/docs/providers/togetherai/)
