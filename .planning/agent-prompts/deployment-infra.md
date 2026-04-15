# Deployment Agent — Phase 3.9 Release

Copy this prompt to the deployment/infra agent:

---

You are deploying Phase 3.9 (Release Readiness) of the nullalis agent runtime to production on DigitalOcean Kubernetes. You have access to all three repos (nullalis, zaki-prod, zaki-infra) and the DO cluster.

## What Changed

The nullalis runtime has significant changes across context engineering, agent modes, narration, and lifecycle safety. All changes are tested (5,400+ tests, EXIT:0) and code-reviewed.

### New Environment Variables Required

These must be added to the Helm chart secrets and K8s secrets:

| Variable | Purpose | Value Source |
|----------|---------|-------------|
| `GROQ_API_KEY` | Sidecar (narration, compaction), STT/Whisper transcription, fast LLM inference | Groq console — free tier |
| `OPENROUTER_API_KEY` | Deep mode LLM (z-ai/glm-5.1) | OpenRouter dashboard |
| `TOGETHER_API_KEY` | Already exists — Fast mode (google/gemma-4-31b-it) + Balanced mode (moonshotai/Kimi-K2.5) | Already configured |

### Files to Scan for Changes

**nullalis repo** (`/Users/nova/Desktop/nullalis`):
- `deploy/k8s/zaki-bot/01-secrets-template.yaml` — Updated with GROQ_API_KEY and OPENROUTER_API_KEY entries
- `deploy/k8s/zaki-bot/05-deployment.yaml` — May need updating to inject new env vars into the runtime config init-container
- `config.example.json` — Reference config (unchanged but verify sidecar config is documented)

**zaki-infra repo** (`/Users/nova/Desktop/zaki-infra`):
- `charts/nullalis/templates/configmap-runtime-config.yaml` — Must add GROQ_API_KEY and OPENROUTER_API_KEY to the config generation script, similar to how TOGETHER_API_KEY is already handled
- `charts/nullalis/README.md` — Document new required secrets
- K8s sealed secrets or external secrets — add the actual API key values

### What the Runtime Expects

The nullalis binary reads API keys via `std.process.getEnvVarOwned`:
- `GROQ_API_KEY` → resolved by `src/providers/api_key.zig` for provider "groq"
- `OPENROUTER_API_KEY` → resolved for provider "openrouter"
- `TOGETHER_API_KEY` → resolved for provider "together" (already exists)

The new `SidecarConfig` in `config_types.zig` defaults to:
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

This means the runtime will attempt to resolve `GROQ_API_KEY` on startup. If missing, the sidecar degrades gracefully (narration skipped, compaction uses main model — functional but more expensive).

### Per-Mode Model Routing

The runtime now routes different models per assistant mode:

| Mode | Model | Provider | Required Key |
|------|-------|----------|-------------|
| Fast | `google/gemma-4-31b-it` | together | TOGETHER_API_KEY |
| Balanced | `moonshotai/Kimi-K2.5` | together | TOGETHER_API_KEY |
| Deep | `z-ai/glm-5.1` | openrouter | OPENROUTER_API_KEY |
| Sidecar | `llama-3.1-8b-instant` | groq | GROQ_API_KEY |

### Deployment Steps

1. **Scan** both repos for changes since last deploy
2. **Update Helm chart** in zaki-infra to inject GROQ_API_KEY and OPENROUTER_API_KEY
3. **Add secrets** to K8s (GROQ_API_KEY value, OPENROUTER_API_KEY value)
4. **Build** new nullalis binary (immutable image)
5. **Deploy** via ArgoCD
6. **Verify** — check logs for:
   - `sidecar` provider initialization (should show groq)
   - `tenant.runtime` creation with correct mode/model
   - No errors on GROQ_API_KEY resolution

### Rollback

ArgoCD immutable images. Previous deployment is the rollback target. No database migrations in this release.
