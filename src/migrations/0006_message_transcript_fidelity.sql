-- Migration 0006 — transcript fidelity: persist the assistant turn's
-- tool_calls + reasoning (P1-5, Wave C C4, 2026-06-12).
--
-- Before this, `{schema}.messages` stored only role + content
-- (saveSessionMessage / loadSessionMessages, src/zaki_state.zig). A
-- reloaded transcript therefore lost the assistant turn's tool-call and
-- reasoning STRUCTURE — loadHistory rebuilt a flat text message. On a
-- pod restart / session eviction the agent's in-RAM OwnedMessage
-- (.tool_calls, .reasoning) was gone, so the rehydrated assistant turn
-- could no longer replay its native tool-call transcript to the provider
-- (Moonshot `thinking.keep:"all"` cross-turn CoT, OpenAI-compat
-- `tool_calls` shape).
--
-- This migration adds two NULLABLE columns so the snapshot can ride
-- alongside the existing row:
--
--   * tool_calls  JSONB  — the assistant turn's native tool calls,
--                          serialized as a JSON array of
--                          {"id","name","arguments"} objects (matches
--                          providers.ToolCall). NULL for user/system/tool
--                          rows and for assistant turns with no tool calls.
--                          Distinct from the vestigial singular `tool_call`
--                          column in 0001 (never written/read by any path).
--   * reasoning   TEXT   — the model's reasoning/CoT trace for the turn
--                          (Kimi native `reasoning_content`). NULL when the
--                          model emitted none.
--
-- ── Backward-compatibility contract (rolling update + rollback) ──────
--
--   * Strictly ADDITIVE + NULLABLE. An OLDER-schema pod running
--     concurrently during a rolling update is unaffected: its INSERTs
--     name an explicit column list that omits these two (the new columns
--     default to NULL), and its SELECTs name explicit columns and never
--     `SELECT *`, so the new columns are invisible to it.
--   * The NEW code reading OLD rows (written before this migration, so
--     both columns NULL) loads exactly as before — flat text, no
--     tool_calls/reasoning. The reload path treats NULL as "none".
--   * ROLLBACK-safe: these columns may remain in place after a rollback
--     to older code without breaking anything — old code never references
--     them. No down-migration / column drop is required or wanted.
--
-- ── Idempotency contract (re-apply / double-apply is a clean no-op) ──
--
--   * Both adds use `ADD COLUMN IF NOT EXISTS`, so re-applying the full
--     migration set against a database where these columns already exist
--     is a no-op. (The migration framework also version-tracks in
--     `{schema}.schema_migrations` and skips an already-applied version;
--     the `IF NOT EXISTS` guards are the belt-and-suspenders second layer
--     that also covers the legacy dual-path window.)
--   * Applies in a single BEGIN/COMMIT transaction (only two ALTER ADD
--     COLUMN statements, no concurrent index build), so the runner wraps
--     it transactionally and a mid-migration failure rolls back cleanly.

ALTER TABLE {schema}.messages
    ADD COLUMN IF NOT EXISTS tool_calls JSONB;

ALTER TABLE {schema}.messages
    ADD COLUMN IF NOT EXISTS reasoning TEXT;
