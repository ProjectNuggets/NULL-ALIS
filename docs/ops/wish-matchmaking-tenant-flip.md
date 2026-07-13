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
