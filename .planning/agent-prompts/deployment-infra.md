# Deployment Agent — Phase 3.9 Release

Copy this prompt to the deployment/infra agent:

---

You are deploying Phase 3.9 (Release Readiness) of the nullalis agent runtime to production on DigitalOcean Kubernetes. You have access to all three repos (nullalis, zaki-prod, zaki-infra) and the DO cluster.

## Commit

```
d5fbfde feat(phase-3.9): release readiness — context engineering, agent modes, narration, sidecar, lifecycle
```

Pushed to `main` on `https://github.com/ProjectNuggets/NULL-ALIS.git`

## What Changed (Summary)

24 files changed, 2,709 additions, 156 deletions. Major changes:

1. **Three-pass context compression** — agent now compresses at 60% (free dedup), 75% (structured extraction), 85% (LLM summarize)
2. **Per-mode model routing** — each agent mode (fast/balanced/deep) routes to a different model+provider
3. **Sidecar provider** — cheap Groq Llama 8B for narration and compaction (free tier)
4. **Native thinking narration** — model reasoning emitted as narration frames to the user
5. **Prompt caching** — Anthropic cache_control + sorted tools for OpenAI-compat providers
6. **Lifecycle safety** — deferred TenantRuntime destruction prevents use-after-free on settings change
7. **Session list persistence** — session panel now shows both live and evicted sessions from Postgres

## NEW Environment Variables Required

**CRITICAL: These must be added to K8s secrets before deployment.**

| Variable | Purpose | Required? | Where to get it |
|----------|---------|-----------|-----------------|
| `GROQ_API_KEY` | Sidecar (narration, compaction), STT/Whisper, fast inference | **Yes** — sidecar degrades gracefully without it, but narration won't work | https://console.groq.com — free tier |
| `TOGETHER_API_KEY` | All 3 agent modes (Fast=Gemma4, Balanced=K2.5, Deep=GLM5.1) | **Yes** — already exists, verify it's set | https://api.together.xyz/settings/api-keys |
| `OPENROUTER_API_KEY` | Optional fallback provider | No — not used as primary anymore | https://openrouter.ai/keys |

### GROQ_API_KEY value (already obtained):
```
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
```

## Per-Mode Model Routing (new behavior)

The runtime now routes different models per assistant mode. All three use Together.ai as the primary provider:

| Mode | Model ID | Provider | Cost (in/out per M) |
|------|----------|----------|---------------------|
| Fast | `google/gemma-4-31b-it` | together | $0.08 / $0.35 |
| Balanced | `moonshotai/Kimi-K2.5` | together | $0.50 / $2.80 |
| Deep | `zai-org/GLM-5.1` | together | $0.95 / $3.15 |
| Sidecar | `llama-3.1-8b-instant` | groq | Free |

**Model fallback recommendation** (config, not code): Add to runtime config:
```json
{
  "reliability": {
    "model_fallbacks": [
      { "model": "zai-org/GLM-5.1", "fallbacks": ["MiniMaxAI/MiniMax-M2.7"] }
    ]
  }
}
```
This gives deep mode a fallback to MiniMax M2.7 ($0.30/$1.20) if GLM 5.1 is unavailable.

## New SidecarConfig (auto-enabled)

The runtime now has a sidecar configuration that defaults to:
```json
{
  "sidecar": {
    "enabled": true,
    "provider": "groq",
    "model": "llama-3.1-8b-instant",
    "narration_interval": 3
  }
}
```

If `GROQ_API_KEY` is missing, the sidecar degrades gracefully:
- Narration: skipped (user sees tool labels but not thinking narration)
- Compaction: falls back to main model (works, but costs more)
- No crashes, no errors — just silent degradation

## Files to Update in zaki-infra

### 1. Helm chart secrets (`charts/nullalis/templates/`)

Add `GROQ_API_KEY` to the secret template, same pattern as `TOGETHER_API_KEY`:
```yaml
GROQ_API_KEY: {{ .Values.secrets.groqApiKey | quote }}
```

### 2. Runtime config init-container (`configmap-runtime-config.yaml`)

The init-container that builds `config.json` needs to:
- Resolve `GROQ_API_KEY` from env
- Add `"groq"` provider entry alongside `"together-ai"`:
```bash
GROQ_API_KEY_ESC="$(json_escape "${GROQ_API_KEY:-}")"
```
```json
"providers": {
  "together-ai": {
    "api_key": "${TOGETHER_API_KEY_ESC}",
    "base_url": "https://api.together.xyz/v1"
  },
  "groq": {
    "api_key": "${GROQ_API_KEY_ESC}",
    "base_url": "https://api.groq.com/openai"
  }
}
```

Note: The runtime also resolves `GROQ_API_KEY` directly from env var via `std.process.getEnvVarOwned`. The config entry is optional but recommended for explicit provider configuration.

### 3. K8s secrets template (already updated in nullalis repo)

File: `deploy/k8s/zaki-bot/01-secrets-template.yaml` — already updated with GROQ_API_KEY and OPENROUTER_API_KEY entries. This is a reference template; production secrets are in zaki-infra.

### 4. README / Documentation

Update `charts/nullalis/README.md` to document:
- `GROQ_API_KEY` — required for sidecar (narration + compaction) and STT/Whisper
- Per-mode model routing behavior
- SidecarConfig defaults

## Deployment Steps

1. **Update Helm chart** in zaki-infra:
   - Add `GROQ_API_KEY` secret
   - Add groq provider to config init-container
   - Optionally add model_fallbacks for deep mode
2. **Set the actual secret value** in K8s (sealed secret or external secrets)
3. **Build new nullalis image** (immutable, from commit `d5fbfde`)
4. **Deploy via ArgoCD** (standard rollout)
5. **Verify deployment** — check pod logs for:
   ```
   sidecar provider initialization → should show "groq"
   tenant.runtime created → should show correct model per mode
   No GROQ_API_KEY resolution errors
   ```

## Post-Deployment Smoke Test

1. **Mode switching**: Change agent mode in settings → verify logs show different model name
2. **Narration**: Send a multi-step task → verify SSE stream includes narration frames with tool-specific labels
3. **Thinking**: If model returns reasoning_content → verify thinking narration appears
4. **Compaction**: Send enough messages to trigger 60% threshold → verify "cheap pass" log message
5. **Session list**: Open session panel → verify sessions appear (even after waiting 30+ min for eviction)
6. **Settings change**: Change mode while a turn is processing → verify no crash (deferred destroy)

## Rollback

ArgoCD immutable images. Previous deployment (`d257cc4`) is the rollback target. No database migrations — the `sessions` table already exists from Phase 3.5. The new `listUserSessions` query reads existing data.

## Risk Assessment

| Risk | Mitigation |
|------|------------|
| Together.ai model IDs wrong | Verified against live API docs. Model fallback configured. |
| Groq rate limit (14,400/day) | Sidecar degrades gracefully. 500 users × ~5 msgs/day = well within limit. |
| New session list query slow | Correlated subqueries on messages table. Add index `(user_id, session_id)` if needed. |
| Native thinking not returned by model | Sidecar narration kicks in as fallback every 3 tool iterations. |
