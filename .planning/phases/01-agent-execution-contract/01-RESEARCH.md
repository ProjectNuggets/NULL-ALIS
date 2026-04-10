# Phase 1: Agent Execution Contract - Research

**Researched:** 2026-04-10
**Domain:** Zig agent runtime -- execution modes, tool metadata, approval policy, reflection, abort/interrupt
**Confidence:** HIGH

## Summary

Phase 1 makes the nullalis agent's execution model explicit, inspectable, and policy-aware. The codebase already has foundational pieces: a Tool vtable interface (42 tool files, ~30 active tools), a SecurityPolicy with AutonomyLevel (read_only/supervised/full), a preflightToolPolicy gate, an Observer vtable for events, and a /stop + /approve slash command pair. The work is to layer structured metadata, execution modes, and approval contracts BESIDE these existing interfaces without breaking the 4949-passing test suite.

The critical architectural constraint is the Tool vtable interface stability. The VTable has 5 function pointers (execute, name, description, parameters_json, deinit). Tool metadata must be a parallel lookup table keyed by tool name -- not an expansion of the VTable. The ToolVTable comptime generator and assertToolInterface checker validate the VTable shape at compile time, so adding fields there would require touching all 42 tool files. The "layer beside" approach creates a `ToolMetadata` struct resolved by name at the dispatch site, which is both safer and more extensible.

**Primary recommendation:** Build five new files (metadata.zig, execution_mode.zig, approval_modes.zig, abort.zig, control.zig) that compose into existing Agent/dispatcher/security call sites via thin integration points. Each sprint adds one concern; each concern is testable in isolation with Zig inline tests before wiring into agent/root.zig.

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| REQ-001 | Explicit execution modes: plan, execute, review, background | Sprint 01-02: execution_mode.zig defines the enum + mode-aware behavior in turn loop; existing ExecHost/ExecAsk enums in agent/root.zig show established pattern |
| REQ-002 | Structured tool metadata: read_only, mutating, background_safe, operator_only, concurrency_safe | Sprint 01-01: metadata.zig with comptime lookup table; ToolVTable pattern shows how to add comptime-resolved per-tool data without touching vtable |
| REQ-003 | Approval contract for tools and actions with explainable reasons | Sprint 01-03: approval_modes.zig replaces current ad-hoc pending_exec_command with structured policy; existing SecurityPolicy.validateCommandExecution and preflightToolPolicy show current approval points |
| REQ-010 | Abort and interrupt propagation from API/CLI/channel to active work | Sprint 01-05: abort.zig + control.zig with cooperative cancellation token pattern; existing /stop command is minimal -- needs propagation to active tool execution and subagent threads |
</phase_requirements>

## Standard Stack

### Core

This is a Zig-native project. No external package dependencies for this phase -- all work is pure Zig with the existing build system.

| Component | Version | Purpose | Why Standard |
|-----------|---------|---------|--------------|
| Zig | 0.15.2 | Language/compiler | Already in use, verified on machine [VERIFIED: `zig version`] |
| std.json | 0.15.2 stdlib | JSON parsing for tool args | Already used throughout tools/root.zig [VERIFIED: codebase] |
| std.Thread | 0.15.2 stdlib | Thread coordination for abort | Already used in subagent.zig, session.zig [VERIFIED: codebase] |
| std.atomic | 0.15.2 stdlib | Atomic bool for cancellation tokens | Part of Zig stdlib; needed for lock-free abort signaling [VERIFIED: codebase uses std.Thread.Mutex already] |

### Supporting

No external libraries needed. This phase is pure internal architecture.

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Comptime name-keyed metadata table | Expand Tool.VTable with metadata fn ptr | Would require touching all 42 tool files; violates vtable stability constraint |
| Atomic bool cancellation token | Mutex-guarded flag | Atomic is lower overhead for poll-based cooperative cancellation in hot loop |
| Enum-based execution modes | String-tagged modes | Enum is type-safe at comptime, matches existing patterns (ExecHost, ExecAsk, VerboseLevel) |

## Architecture Patterns

### Recommended Project Structure (new files)

```
src/
  tools/
    metadata.zig        # [NEW] ToolMetadata struct + comptime registry
    root.zig            # [MODIFY] re-export metadata module
  agent/
    execution_mode.zig  # [NEW] ExecutionMode enum + mode-aware dispatch helpers
    abort.zig           # [NEW] CancellationToken + abort coordination
    root.zig            # [MODIFY] wire execution mode + abort into turn loop
    prompt.zig          # [MODIFY] mode-aware prompt sections
    dispatcher.zig      # [MODIFY] metadata-aware tool result formatting
    commands.zig        # [MODIFY] /mode, /abort slash commands
  security/
    approval_modes.zig  # [NEW] ApprovalPolicy + ApprovalDecision types
    policy.zig          # [MODIFY] wire approval modes into validateCommandExecution
    root.zig            # [MODIFY] re-export approval_modes
  tasks/
    control.zig         # [NEW] TaskControl for subagent abort propagation
  capabilities.zig      # [MODIFY] expose execution mode in capability manifest
  gateway.zig           # [MODIFY] wire abort signal from HTTP layer
  session.zig           # [MODIFY] pass cancellation token through session turn
  subagent.zig          # [MODIFY] wire abort into spawned threads
  observability.zig     # [MODIFY] add execution_mode and approval events
```

### Pattern 1: Comptime Tool Metadata Registry

**What:** A compile-time lookup table mapping tool names to metadata structs, resolved by the dispatcher at tool execution time.
**When to use:** When you need per-tool attributes without modifying the Tool vtable.
**Why this pattern:** The existing `ToolVTable(comptime T: type)` generator already uses comptime reflection to extract `tool_name`, `tool_description`, `tool_params` from tool structs. The metadata registry follows the same pattern: each tool struct declares `pub const tool_metadata: ToolMetadata = .{ ... }` and the registry collects these at comptime.

```zig
// Source: Pattern derived from existing ToolVTable in src/tools/root.zig [VERIFIED: codebase]
pub const ToolFlags = packed struct {
    read_only: bool = false,
    mutating: bool = false,
    background_safe: bool = false,
    operator_only: bool = false,
    concurrency_safe: bool = false,
};

pub const ToolMetadata = struct {
    name: []const u8,
    flags: ToolFlags,
    risk_level: RiskLevel = .low,
    approval_hint: []const u8 = "",
};

/// Comptime registry — called from root.zig to build the lookup table.
/// Each tool type T must declare `pub const tool_metadata: ToolMetadata`.
pub fn metadataFor(comptime T: type) ToolMetadata {
    if (@hasDecl(T, "tool_metadata")) return T.tool_metadata;
    // Default: conservative -- treat as mutating, not background-safe
    return .{ .name = T.tool_name, .flags = .{ .mutating = true } };
}

/// Runtime lookup by name (linear scan over comptime-generated slice).
pub fn lookupMetadata(name: []const u8) ?ToolMetadata {
    for (all_metadata) |m| {
        if (std.mem.eql(u8, m.name, name)) return m;
    }
    return null;
}
```

**Key insight:** The default for unknown tools is conservative (mutating, not background-safe). This is a safe fallback that prevents accidental policy bypass for MCP tools or dynamically registered tools that lack metadata. [ASSUMED]

### Pattern 2: Execution Mode Enum + Mode-Aware Turn Behavior

**What:** An enum {plan, execute, review, background} that gates which tool categories are available and how reflection works.
**When to use:** At the start of each turn, resolved from session/request context.

```zig
// Matches existing enum patterns in agent/root.zig (ExecHost, ExecAsk, VerboseLevel)
// [VERIFIED: codebase]
pub const ExecutionMode = enum {
    plan,      // Read-only tools, no mutations, returns structured plan
    execute,   // Full tool access within policy bounds
    review,    // Read-only + analysis tools, structured review output
    background,// Background-safe tools only, no user interaction

    pub fn toSlice(self: ExecutionMode) []const u8 {
        return switch (self) {
            .plan => "plan",
            .execute => "execute",
            .review => "review",
            .background => "background",
        };
    }

    pub fn allowsTool(self: ExecutionMode, meta: ToolMetadata) bool {
        return switch (self) {
            .plan, .review => meta.flags.read_only,
            .execute => true,
            .background => meta.flags.background_safe,
        };
    }
};
```

### Pattern 3: Cooperative Cancellation Token

**What:** An atomic boolean that signals abort to the active turn loop and spawned tool executions.
**When to use:** For abort/interrupt propagation without killing threads.

```zig
// [VERIFIED: discord.zig, slack.zig use identical std.atomic.Value(bool) pattern]
pub const CancellationToken = struct {
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn cancel(self: *CancellationToken) void {
        self.cancelled.store(true, .release);
    }

    pub fn isCancelled(self: *const CancellationToken) bool {
        return self.cancelled.load(.acquire);
    }

    pub fn reset(self: *CancellationToken) void {
        self.cancelled.store(false, .release);
    }
};
```

### Pattern 4: Approval Policy as Structured Type

**What:** Replace the current ad-hoc `pending_exec_command` + `/approve` pattern with a first-class ApprovalPolicy type.
**When to use:** When tool execution is gated by policy and needs structured decision logging.

```zig
// Upgrade from current implicit approval in preflightToolPolicy [VERIFIED: codebase]
pub const ApprovalPolicy = enum {
    auto_approve,   // Tool executes without user confirmation (read-only, low risk)
    confirm_once,   // Ask once per session for this tool class
    confirm_always, // Ask every invocation
    deny,           // Never allow

    pub fn forTool(meta: ToolMetadata, autonomy: AutonomyLevel) ApprovalPolicy {
        if (autonomy == .full) return .auto_approve;
        if (autonomy == .read_only) return .deny;
        // supervised mode:
        if (meta.flags.read_only) return .auto_approve;
        if (meta.flags.operator_only) return .deny;
        if (meta.flags.mutating) return .confirm_once;
        return .auto_approve;
    }
};

pub const ApprovalDecision = struct {
    policy: ApprovalPolicy,
    tool_name: []const u8,
    reason: []const u8,
    decided_at: i64,
    decided_by: DecisionSource,

    pub const DecisionSource = enum { auto_policy, user_approve, user_deny, session_cache };
};
```

### Anti-Patterns to Avoid

- **Expanding Tool.VTable:** Adding metadata function pointers to VTable would break compile for all 42 tool files and violate the architecture lock. Layer metadata BESIDE the vtable.
- **String-based mode tracking:** Using `[]const u8` for execution modes instead of enums. The codebase consistently uses enums with `toSlice()` methods. Follow this pattern.
- **Blocking abort:** Using thread cancellation or `pthread_cancel` semantics. Zig's stdlib doesn't support thread cancellation; use cooperative polling of an atomic flag instead.
- **Global mutable state for cancellation:** Cancellation tokens must be per-session (per-Session.agent), not global. Multiple sessions run concurrently via SessionManager.
- **Modifying reflection prompt for all modes equally:** The current hardcoded reflection string in turn() should become mode-aware. Plan mode should not get "retry up to 2 times" instructions.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Tool classification (read-only vs mutating) | Runtime heuristic from tool name strings | Comptime metadata declarations per tool | Name-based heuristics are fragile; metadata is auditable and testable |
| Approval state machine | Ad-hoc `pending_exec_command` + bool flags | Structured ApprovalDecision type with enum states | Current pattern doesn't track who approved, why, or when; doesn't extend to non-shell tools |
| Thread-safe cancellation | Manual mutex-guarded booleans | std.atomic.Value(bool) | Atomic is zero-overhead, correct by construction, no deadlock risk |
| Mode-aware prompt building | Multiple `if mode == X` branches inline in prompt.zig | Prompt section builder with mode parameter | Keeps prompt.zig readable; mode logic in one place |

**Key insight:** The existing codebase has strong patterns for vtable interfaces, enums with `toSlice()`, and observer events. Every new type should follow these existing conventions exactly.

## Common Pitfalls

### Pitfall 1: Breaking the Tool VTable at Compile Time

**What goes wrong:** Adding a new fn pointer to VTable causes compile errors in all 42 tool files.
**Why it happens:** `ToolVTable(comptime T: type)` generates vtable entries by reflecting on T. If VTable gains a new required field, all T types must implement it.
**How to avoid:** Metadata is a SEPARATE lookup, not a VTable extension. The VTable interface stays exactly as-is: {execute, name, description, parameters_json, deinit}.
**Warning signs:** Any diff that touches `pub const VTable = struct {` in tools/root.zig.

### Pitfall 2: Metadata Defaults for MCP/Dynamic Tools

**What goes wrong:** MCP tools and dynamically registered tools won't have compile-time metadata declarations.
**Why it happens:** Only Zig-native tool structs can declare `pub const tool_metadata`. External tools arrive at runtime.
**How to avoid:** The `lookupMetadata()` function returns `?ToolMetadata` (nullable). The dispatch site must handle `null` with a conservative default (mutating=true, background_safe=false).
**Warning signs:** A `lookupMetadata()` that returns non-optional or panics on miss.

### Pitfall 3: Abort Token Lifetime

**What goes wrong:** CancellationToken is freed while a background tool thread still polls it.
**Why it happens:** Session.deinit runs while SubagentManager threads haven't joined yet.
**How to avoid:** CancellationToken must be heap-allocated with reference counting, or owned by Session with a guaranteed join-before-deinit ordering. The current SubagentManager.deinit already joins all threads before freeing state -- keep this pattern.
**Warning signs:** Use-after-free in abort.zig tests, particularly under `zig build test --summary all`.

### Pitfall 4: Gateway.zig Merge Conflicts

**What goes wrong:** gateway.zig is 15,599 lines. Multiple sprints touching it creates merge conflicts.
**Why it happens:** Sprint 01-03 (approval) and 01-05 (abort) both need gateway integration points.
**How to avoid:** Minimize gateway.zig changes. Add thin wiring -- a few lines importing the new modules and passing tokens through. Keep logic in the new dedicated files.
**Warning signs:** Any sprint that adds >20 lines to gateway.zig.

### Pitfall 5: Test Regression in agent/root.zig

**What goes wrong:** agent/root.zig has 104 inline tests. Modifying the turn loop or executeTool path can break them.
**Why it happens:** Tests create minimal Agent structs with null policy, null mem, etc. Adding required fields or changing function signatures breaks these.
**How to avoid:** New fields on Agent must have defaults (= null, = .execute, etc.). New behavior must be gated by `if (self.cancellation_token) |token|` style optional checks.
**Warning signs:** Any new Agent field without a default value.

### Pitfall 6: Reflection Prompt Regression

**What goes wrong:** The hardcoded reflection prompt ("Reflect on the tool results above...") is currently the only post-tool instruction. Changing it affects all modes.
**Why it happens:** Sprint 01-04 upgrades reflection to be mode-aware, but needs to preserve the existing execute-mode behavior exactly.
**How to avoid:** Extract the current reflection text as a constant, make it the default for execute mode, then add mode-specific variants. Test that execute-mode reflection output is byte-identical to the current version.
**Warning signs:** Any test that checks for specific reflection prompt text failing after 01-04.

## Code Examples

### Example 1: Adding Metadata to an Existing Tool (file_read.zig)

```zig
// In src/tools/file_read.zig -- add one line [VERIFIED: existing pattern in codebase]
const metadata = @import("metadata.zig");

pub const FileReadTool = struct {
    // ... existing fields ...

    pub const tool_name = "file_read";
    pub const tool_description = "Read the contents of a file in the workspace";
    pub const tool_params = \\...;

    // NEW: one-line metadata declaration
    pub const tool_metadata: metadata.ToolMetadata = .{
        .name = tool_name,
        .flags = .{ .read_only = true, .background_safe = true, .concurrency_safe = true },
    };

    // ... rest unchanged ...
};
```

### Example 2: Mode-Gated Tool Filtering in preflightToolPolicy

```zig
// In src/agent/root.zig, extend preflightToolPolicy [VERIFIED: line 902-923]
fn preflightToolPolicy(self: *Agent, call: ParsedToolCall) PolicyPreflightResult {
    // Existing policy checks (unchanged)
    if (self.policy) |pol| {
        if (!pol.canAct()) {
            return .{ .blocked = .{ ... } };
        }
        const allowed = pol.recordAction() catch true;
        if (!allowed) {
            return .{ .blocked = .{ ... } };
        }
    }

    // NEW: execution mode gate
    if (self.execution_mode != .execute) {
        const meta = metadata.lookupMetadata(call.name) orelse
            metadata.ToolMetadata.conservative(call.name);
        if (!self.execution_mode.allowsTool(meta)) {
            return .{ .blocked = .{
                .name = call.name,
                .output = std.fmt.comptimePrint(
                    "Tool '{s}' not available in {s} mode",
                    .{ call.name, self.execution_mode.toSlice() },
                ) // Note: will need runtime fmt in practice
                .success = false,
                .tool_call_id = call.tool_call_id,
            } };
        }
    }

    return .allowed;
}
```

### Example 3: Cooperative Abort Check in Turn Loop

```zig
// In src/agent/root.zig, inside the while(iteration < max_tool_iterations) loop
// [VERIFIED: line 1402 is the loop start]

// Check cancellation at iteration boundaries (cooperative abort)
if (self.cancellation_token) |token| {
    if (token.isCancelled()) {
        const abort_event = ObserverEvent{ .turn_stage = .{
            .stage = "turn_aborted",
            .iteration = iteration,
        } };
        self.observer.recordEvent(&abort_event);
        return try self.allocator.dupe(u8,
            "[Execution interrupted. Completed " ++
            std.fmt.comptimePrint("{d}", .{iteration}) ++
            " tool iterations before abort.]"
        );
    }
}
```

### Example 4: Adding Slash Commands

```zig
// In src/agent/commands.zig, following existing pattern [VERIFIED: line 3158-3176]
if (isSlashName(cmd, "mode")) return try handleModeCommand(self, cmd.arg);
if (isSlashName(cmd, "abort")) return try handleAbortCommand(self);

fn handleModeCommand(self: anytype, arg: []const u8) ![]const u8 {
    const execution_mode = @import("execution_mode.zig");
    if (arg.len == 0) {
        return try std.fmt.allocPrint(self.allocator, "Current mode: {s}", .{self.execution_mode.toSlice()});
    }
    if (execution_mode.ExecutionMode.fromString(arg)) |mode| {
        self.execution_mode = mode;
        return try std.fmt.allocPrint(self.allocator, "Switched to {s} mode", .{mode.toSlice()});
    }
    return try self.allocator.dupe(u8, "Unknown mode. Options: plan, execute, review, background");
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| No tool metadata | Ad-hoc checks (isExecToolName, tool name string matching) | Current state | Sprint 01-01 replaces with structured metadata |
| Implicit execution mode (always "execute") | ExecHost/ExecSecurity/ExecAsk enums handle some mode concerns | Current state | Sprint 01-02 unifies into explicit ExecutionMode |
| pending_exec_command + /approve for shell only | Single tool approval with no structured tracking | Current state | Sprint 01-03 creates general-purpose approval policy |
| Hardcoded reflection prompt | One reflection string for all tool results | Current state | Sprint 01-04 makes reflection mode-aware |
| /stop clears pending + reports running subagents | No propagation to active tool execution | Current state | Sprint 01-05 adds cooperative cancellation |

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Conservative default (mutating=true) for unknown tools is the right safety posture | Architecture Patterns, Pattern 1 | If too restrictive, MCP tools won't work in background mode; easily adjustable |
| A3 | Per-session CancellationToken is sufficient (no need for per-tool-call tokens) | Common Pitfalls, Pitfall 3 | If individual tool calls need independent abort, need finer granularity |
| A4 | The "layer beside" metadata approach won't require touching allTools() registration | Architecture Patterns, Pattern 1 | If metadata needs to be passed through allTools(), more files change |

## Open Questions

1. **How should execution mode be set for gateway/webhook requests?**
   - What we know: CLI sessions default to `execute`. The gateway processes webhook requests through session.zig.
   - What's unclear: Should webhooks always be `execute`? Should cron-triggered runs use `background` mode automatically?
   - Recommendation: Default to `execute` for user-initiated, `background` for cron/spawn. Make it a Session field with per-request override.

2. **Should approval decisions persist across session restarts?**
   - What we know: Current `pending_exec_command` is ephemeral (session memory only). Sessions can be persisted via session_store.
   - What's unclear: If a user says "always approve file_write for this session", should that survive a session restart?
   - Recommendation: Start ephemeral (in-memory per session). Persistence is a Phase 3 concern (session controls).

3. **How does abort interact with the provider streaming call?**
   - What we know: The turn loop calls `self.provider.streamChat()` which blocks until the provider responds. This is a potentially long-running operation.
   - What's unclear: Can we interrupt a streaming provider call mid-flight?
   - Recommendation: Check cancellation between tool iterations (already proposed). For mid-stream abort, the provider call would need a cancellation-aware variant -- defer to Phase 2 (run events) where streaming is already being reworked.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Zig 0.15.2 built-in test runner |
| Config file | build.zig (test step) |
| Quick run command | `zig build test --summary all` |
| Full suite command | `zig build test --summary all` |

### Phase Requirements to Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| REQ-001 | ExecutionMode enum values and toSlice/fromString | unit | `zig build test --summary all` (inline tests in execution_mode.zig) | Wave 0 |
| REQ-001 | Mode-gated tool filtering blocks mutating tools in plan mode | unit | `zig build test --summary all` (inline tests in execution_mode.zig) | Wave 0 |
| REQ-002 | ToolMetadata flags comptime resolution | unit | `zig build test --summary all` (inline tests in metadata.zig) | Wave 0 |
| REQ-002 | lookupMetadata returns null for unknown, conservative default works | unit | `zig build test --summary all` (inline tests in metadata.zig) | Wave 0 |
| REQ-003 | ApprovalPolicy.forTool returns correct policy per autonomy level | unit | `zig build test --summary all` (inline tests in approval_modes.zig) | Wave 0 |
| REQ-003 | ApprovalDecision tracks source and reason | unit | `zig build test --summary all` (inline tests in approval_modes.zig) | Wave 0 |
| REQ-010 | CancellationToken atomic set/check | unit | `zig build test --summary all` (inline tests in abort.zig) | Wave 0 |
| REQ-010 | Turn loop exits on cancellation | integration | `zig build test --summary all` (inline test in agent/root.zig) | Wave 0 |

### Sampling Rate
- **Per task commit:** `zig build test --summary all` (~7s, cached)
- **Per wave merge:** `zig build test --summary all` (full rebuild)
- **Phase gate:** Full suite green (4949+ tests, 0 failures) before verify

### Wave 0 Gaps
- [ ] `src/tools/metadata.zig` -- new file with inline tests for ToolFlags, ToolMetadata, lookupMetadata
- [ ] `src/agent/execution_mode.zig` -- new file with inline tests for ExecutionMode enum
- [ ] `src/security/approval_modes.zig` -- new file with inline tests for ApprovalPolicy, ApprovalDecision
- [ ] `src/agent/abort.zig` -- new file with inline tests for CancellationToken
- [ ] `src/tasks/control.zig` -- new file with inline tests for TaskControl abort propagation

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | N/A (handled by PairingGuard in gateway) |
| V3 Session Management | no | N/A (session.zig unchanged architecturally) |
| V4 Access Control | yes | ExecutionMode + ApprovalPolicy gate tool access; AutonomyLevel already enforced |
| V5 Input Validation | yes | Tool metadata flags validated at comptime; approval decisions use enum not strings |
| V6 Cryptography | no | N/A (no new crypto in this phase) |

### Known Threat Patterns for Agent Runtime

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Tool metadata bypass via MCP tools that lack declarations | Elevation of Privilege | Conservative default (mutating=true, background_safe=false) for unregistered tools |
| Approval policy bypass by switching to full autonomy mid-session | Elevation of Privilege | AutonomyLevel is set at session creation from config, not changeable by agent |
| Abort token race condition (use-after-free) | Denial of Service | Token owned by Session; join threads before Session.deinit (existing pattern) |
| Execution mode escalation via prompt injection | Tampering | Mode is set by slash command or session config, not by LLM output parsing |

## Sources

### Primary (HIGH confidence)
- Codebase inspection: src/tools/root.zig (Tool vtable, ToolVTable comptime generator, allTools registration)
- Codebase inspection: src/agent/root.zig (Agent struct fields, turn loop, preflightToolPolicy, executeTool, reflection prompt)
- Codebase inspection: src/security/policy.zig (SecurityPolicy, AutonomyLevel, validateCommandExecution)
- Codebase inspection: src/agent/commands.zig (slash command pattern, /stop, /approve)
- Codebase inspection: src/observability.zig (Observer vtable, ObserverEvent union)
- Codebase inspection: src/subagent.zig (SubagentManager, TaskStatus, thread spawning)
- Codebase inspection: src/session.zig (Session struct, SessionManager, mutex patterns)
- Codebase inspection: src/gateway.zig (HTTP gateway, 15599 lines)
- Build verification: `zig build test --summary all` -- 4949 passed, 29 skipped, 0 failed [VERIFIED: test run]

### Secondary (MEDIUM confidence)
- Zig 0.15.2 std.atomic.Value(bool) API [VERIFIED: discord.zig:29, slack.zig:33, imessage.zig:33 all use identical pattern]

### Tertiary (LOW confidence)
- None

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- pure Zig, no external deps, verified build and test suite
- Architecture: HIGH -- patterns derived directly from existing codebase conventions (vtable, enum+toSlice, observer events)
- Pitfalls: HIGH -- identified from actual code structure (42 tool files, 104 agent tests, 15599-line gateway)

**Research date:** 2026-04-10
**Valid until:** 2026-05-10 (stable -- Zig stdlib and internal architecture are unlikely to change within 30 days)
