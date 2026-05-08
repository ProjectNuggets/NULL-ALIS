# Kimi Multimodal on Together.ai — Research Report

**Date:** 2026-05-07
**Question:** Vision-capable agent options on Together.ai

## 1. Kimi multimodal status on Together

- **Kimi K2.5** (`moonshotai/Kimi-K2.5`): native multimodal (MoonViT vision encoder, 400M). Hosted on Together. Image input supported. Pricing $0.50 in / $2.80 out per 1M; 256K context. ([Together](https://www.together.ai/models/kimi-k2-5))
- **Kimi K2.6** (`moonshotai/Kimi-K2.6`, released April 20, 2026): native multimodal — text, image, **and video** via MoonViT. **Hosted on Together** with vision enabled. Pricing $1.20 in ($0.20 cached) / $4.50 out per 1M; 256K context. ([Together](https://www.together.ai/models/kimi-k26), [MarkTechPost](https://www.marktechpost.com/2026/04/20/moonshot-ai-releases-kimi-k2-6-with-long-horizon-coding-agent-swarm-scaling-to-300-sub-agents-and-4000-coordinated-steps/))
- No other Kimi vision variants on Together.

## 2. Top vision models on Together (May 2026)

| Model | In/Out $/1M | Context | Vision format |
|---|---|---|---|
| **Kimi K2.6** | $1.20 / $4.50 | 256K | OpenAI-spec `image_url` (Together standard) |
| **Kimi K2.5** | $0.50 / $2.80 | 256K | OpenAI-spec `image_url` |
| **Qwen3.5 397B A17B** (Together's recommended default) | $0.60 / $3.60 | 262K | OpenAI-spec `image_url` |
| **Llama 3.2 90B Vision Instruct** | ~$0.35 / $0.40 | 128K | OpenAI-spec `image_url` |
| **GLM 4.5V** | varies | 128K | OpenAI-spec `image_url` |

Together exposes vision uniformly via OpenAI-compatible `image_url` content blocks in `messages`. ([Together pricing](https://www.together.ai/pricing), [Together models](https://www.together.ai/models))

## 3. Strategic options vs. DeepSeek-V4-Pro (text-only)

- **Option A — switch chat to multimodal:** Kimi K2.6 is the only Together-hosted model that competes with V4-Pro on reasoning (SWE-Bench Verified 80.2, beats Opus 4.6 on SWE-Bench Pro) AND has native vision. You don't lose much; arguably gain agent/coding strength. ([deeplearning.ai](https://www.deeplearning.ai/the-batch/kimi-k2-6-matches-open-qwen3-6-max-anddeepseek-v4-falls-just-behind-top-closed-models/))
- **Option B — route by turn:** keep V4-Pro for text, fall through to Kimi K2.6 (or Qwen3.5 397B) only when an `image_url` block appears. Cleanest behaviorally; adds one router branch. Best if V4-Pro reasoning is measurably ahead in your evals.
- **Option C — hybrid that matches V4-Pro:** Kimi K2.6 is the closest hybrid. Qwen3.5 397B is a tier below on reasoning; Llama 3.2 90B Vision is well below.

**Recommendation for nullalis:** Option B. Keep V4-Pro as primary, route image-bearing turns to Kimi K2.6. Same provider, same auth, one extra model id in the routing table.

## 4. One-line answer

**Kimi K2.6 on Together (`moonshotai/Kimi-K2.6`)** — only Together-hosted model in May 2026 that pairs SWE-bench-class reasoning with native vision (and video).

## Sources

- [Together — Kimi K2.6](https://www.together.ai/models/kimi-k26)
- [Together — Kimi K2.5](https://www.together.ai/models/kimi-k2-5)
- [Together — Pricing](https://www.together.ai/pricing)
- [MarkTechPost — K2.6 release](https://www.marktechpost.com/2026/04/20/moonshot-ai-releases-kimi-k2-6-with-long-horizon-coding-agent-swarm-scaling-to-300-sub-agents-and-4000-coordinated-steps/)
- [DeepLearning.AI — K2.6 vs V4](https://www.deeplearning.ai/the-batch/kimi-k2-6-matches-open-qwen3-6-max-anddeepseek-v4-falls-just-behind-top-closed-models/)
- [Cloudflare changelog — K2.6](https://developers.cloudflare.com/changelog/post/2026-04-20-kimi-k2-6-workers-ai/)
