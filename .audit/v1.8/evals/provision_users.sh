#!/usr/bin/env bash
# V1.9-8 — provision per-corpus eval users (idempotent).
#
# The eval suite v2 runs each corpus against an isolated user_id to
# eliminate cross-corpus coreference contamination that noise-floored
# F1 measurements in v1. Gateway requires users to exist in BOTH:
#   - public.zaki_users      — canonical identity (FK source)
#   - zaki_bot.users         — cell-pod row + workspace path
#
# Run this BEFORE the first v2 baseline:
#   ./provision_users.sh
#
# Re-running is safe (ON CONFLICT DO NOTHING).

set -euo pipefail

PSQL="/opt/homebrew/opt/libpq/bin/psql"
PG="postgresql://zaki:zaki@127.0.0.1:5433/zaki"

# user_id → (corpus name, workspace path)
declare -a USER_IDS=(7771 7772 7773 7775)
declare -a USER_LABELS=(
  "identity_writes"
  "preference_changes"
  "multi_entity+rel_queries"
  "long_context_pass_c"
)

# Ensure workspace dirs exist (gateway expects them on first /chat/stream).
for uid in "${USER_IDS[@]}"; do
  mkdir -p "/tmp/nullalis-eval/user-${uid}"
done

# Insert into zaki_users (canonical identity).
for i in "${!USER_IDS[@]}"; do
  uid="${USER_IDS[$i]}"
  label="${USER_LABELS[$i]}"
  $PSQL "$PG" -At -c "
    INSERT INTO zaki_users
      (id, email, password_hash, full_name, verified, created_at, updated_at, plan_tier, plan_status)
    VALUES
      ($uid, 'eval-${uid}@nullalis.local', 'eval-only-no-login', 'V1.9-8 Eval User ${label}', true, NOW(), NOW(), 'free', 'inactive')
    ON CONFLICT (id) DO NOTHING;
  " > /dev/null
done

# Insert into zaki_bot.users (cell-pod row).
for i in "${!USER_IDS[@]}"; do
  uid="${USER_IDS[$i]}"
  $PSQL "$PG" -At -c "
    INSERT INTO zaki_bot.users (user_id, workspace_path, status)
    VALUES ($uid, '/tmp/nullalis-eval/user-${uid}', 'active')
    ON CONFLICT (user_id) DO NOTHING;
  " > /dev/null
done

# Report final state.
echo "=== Eval user provisioning state ==="
$PSQL "$PG" -c "
  SELECT
    u.id AS zaki_user,
    b.user_id AS bot_user,
    u.full_name
  FROM zaki_users u
  FULL OUTER JOIN zaki_bot.users b ON b.user_id = u.id
  WHERE u.id IN (7771, 7772, 7773, 7775, 7777)
  ORDER BY u.id;
"

echo ""
echo "Users 7771-7775 ready for V1.9-8 per-corpus eval."
echo "Each is FK-linked between zaki_users and zaki_bot.users."
echo "Running run_eval.sh against expected.json v2 will use them."
