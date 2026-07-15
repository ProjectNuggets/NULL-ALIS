# Wish matchmaking: one-tenant activation

Wish matchmaking is a privacy-sensitive tenant egress. It is off by default and must not be enabled in the deployment-wide `agent` config for a pilot. The per-tenant source of truth is:

```json
{
  "product_settings": {
    "wish_matchmaking_enabled": true
  }
}
```

At runtime, the tenant config normalizer preserves this allowlisted preference and maps it to `agent.wish_matchmaking_enabled`. Arbitrary per-tenant `agent` blocks remain stripped.

## Enable one tenant

Use the deployment's actual schema and a numeric test/pilot user ID. Preserve the rest of the JSON document:

```sql
UPDATE zaki_bot.user_config
SET config = jsonb_set(
      jsonb_set(
        config,
        '{product_settings}',
        COALESCE(config->'product_settings', '{}'::jsonb),
        true
      ),
      '{product_settings,wish_matchmaking_enabled}',
      'true'::jsonb,
      true
    ),
    updated_at = NOW()
WHERE user_id = <pilot_user_id>;
```

Confirm that exactly one row changed, then invalidate only that tenant's cached runtime:

```bash
curl --fail --silent --show-error \
  -X POST \
  -H "X-Internal-Token: $NULLALIS_INTERNAL_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{"user_id":"<pilot_user_id>"}' \
  "$NULLALIS_INTERNAL_URL/internal/tenant-runtime-cache/invalidate"
```

Do not use `{"all":true}` for a tenant pilot.

## Verify

1. File a neutral test wish for the pilot tenant.
2. Run `/learn list` as that tenant.
3. Confirm the Wishes section still renders and, when the bounded Hub lookup returns a relevant result, includes `possible skill: <org>/<skill>`.
4. Check logs for a Decision Hub request only during the opted-in tenant's command. A control tenant must produce no Hub request.

The lookup is fail-soft: a Hub timeout leaves the Wishes section unchanged. A missing suggestion is not proof that the gate stayed off; use request logs or a deterministic test endpoint to distinguish an enabled timeout from a disabled path.

## Disable / rollback

Set the same JSON path to `false`, invalidate only the pilot tenant's runtime again, and verify `/learn list` makes no Hub request:

```sql
UPDATE zaki_bot.user_config
SET config = jsonb_set(
      jsonb_set(
        config,
        '{product_settings}',
        COALESCE(config->'product_settings', '{}'::jsonb),
        true
      ),
      '{product_settings,wish_matchmaking_enabled}',
      'false'::jsonb,
      true
    ),
    updated_at = NOW()
WHERE user_id = <pilot_user_id>;
```

## Local live-drive evidence

The implementation was exercised with the real Postgres-enabled CLI binary against an isolated schema and one neutral tenant. Before the flip, `/learn list` rendered the wish with no Hub request. After the tenant JSONB flag was set and the process rebuilt from this change, the same command requested the bounded catalog endpoint and rendered:

```text
↳ possible skill: example-org/apple-notes — install with skill_registry action="install" skill_ref="example-org/apple-notes"
```

The deterministic endpoint received the keyword-reduced query, not the raw wish. No shared or fleet config was changed.

## Staging live-drive evidence (2026-07-15)

The runbook was exercised against the explicitly tagged `agentproof` staging fixture (numeric user
ID 148) on image `sha-12d1a1382e4dd050a6c2bfa47ab20a0a16544296`:

1. The fixture started with `wish_matchmaking_enabled=false`. A single neutral, temporary
   `wish/w2-pilot-apple-notes` record was added for the drive.
2. With the gate off, `/learn list` rendered the wish with no install affordance.
3. The JSONB update changed exactly one row; a fleet count confirmed exactly one enabled tenant.
   Tenant-only cache invalidation reported `requested=1`, `removed=1`, `all=false`.
4. With the gate on, `/learn list` rendered a `possible skill` affordance. A Cilium trace from the
   Nullalis endpoint showed the corresponding TLS connection to a current `hub.decision.ai`
   address (`44.217.9.182:443`).
5. The flag was restored to false and the same tenant-only cache invalidation was repeated. A
   matched Cilium observation window around the off-gate `/learn list` showed no connection to any
   currently resolved `hub.decision.ai` address.
6. Final cleanup removed the temporary wish and confirmed zero enabled tenants and zero residual
   pilot records. No production or fleet-wide configuration changed.

This staging drive proves both sides of the privacy gate at the network boundary, not merely the
presence or absence of a rendered suggestion.
