# Self-Improvement Loops for nullalis
## Research & Implementation Strategy
*Based on: Hyperagents (Meta AI), MemPO (arXiv:2603.00680), ACE Pattern (Aegis Memory), MetaCognition (Zylos Research)*

---

## Overview

nullalis already has the **architecture** for self-improvement:
- ✅ Task execution loop (actor)
- ✅ Security policy engine (evaluator)
- ✅ Hybrid memory system (storage)
- ✅ Audit logging (observation)
- ✅ Tool selection (action space)

What's missing: **the meta-level loop** that observes outcomes and modifies the system.

---

## The Two-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  META LEVEL (The Observer/Improver)                        │
│                                                             │
│  • Monitors task agent behavior                            │
│  • Evaluates outcomes (success/failure)                   │
│  • Generates reflections on failures                       │
│  • Modifies task agent rules, memory, policies            │
│  • Accumulates learning over time                         │
└─────────────────────────────────────────────────────────────┘
                              ↕ Monitoring + Control
┌─────────────────────────────────────────────────────────────┐
│  OBJECT LEVEL (The Task Executor)                          │
│                                                             │
│  • Executes tasks                                          │
│  • Calls tools                                             │
│  • Reads/writes memory                                     │
│  • Enforces security policies                              │
│  • Emits events to meta level                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 5 Self-Improvement Loops for nullalis

---

### Loop 1: Memory Quality Voting
**Based on:** ACE Pattern - Memory Voting

**Problem:** Memory accumulates without quality signal. Good memories sink, bad memories linger.

**How it works:**
```
After each task completion:
1. Agent queries memory for relevant entries
2. Agent uses memory to complete task
3. Agent votes: Was this memory helpful or harmful?
   helpful_votes++ or harmful_votes++
4. effectiveness = (helpful - harmful) / (total + 1)
5. Memories ranked by effectiveness on future queries
```

**Implementation for nullalis:**
```zig
// Pseudocode for memory voting
const effectiveness = (memory.helpful_votes - memory.harmful_votes) 
                      / (memory.total_votes + 1);

// Query results sorted by effectiveness
// Memories below threshold filtered out
// High-effectiveness memories boosted in retrieval
```

**Where stored:** Extended memory metadata in Postgres

**Expected outcome:** Memory precision improves from ~60% → 90%+

---

### Loop 2: Security Policy Self-Tuning
**Based on:** MetaCognition - Self-Regulation

**Problem:** Security policies are static. False positives create friction; false negatives create risk.

**How it works:**
```
Each security event:
1. Event logged with context (who, what, blocked/allowed)
2. Meta agent reviews: Was this the right call?
3. If false positive: relax rule slightly
4. If false negative: tighten rule
5. Track pattern: does this user/tool combo often trigger?
6. Auto-tune thresholds based on context
```

**Implementation for nullalis:**
```zig
// Security policy adaptation
const event = audit_log.latest();
if (event.blocked and event.was_false_positive) {
    // Rule was too strict
    policy.relax(event.pattern);
} else if (event.allowed and event.was_security_issue) {
    // Rule was too permissive
    policy.tighten(event.pattern);
}
```

**Expected outcome:** Fewer friction events, fewer breaches over time

---

### Loop 3: Tool Reliability Tracking
**Based on:** Voyager - Skill Library Learning

**Problem:** Some tools fail more than others. Agent doesn't know which to trust.

**How it works:**
```
After each tool call:
1. Log: tool_id, success/failure, latency, error_type
2. Calculate per-tool reliability score
3. When selecting tools, weight by reliability
4. If tool reliability drops below threshold → warn or disable
5. Learn: which tool combinations succeed together
```

**Implementation for nullalis:**
```zig
const tool_reliability = tool.call_history
    .filter(e => e.timestamp > now - 7 days)
    .reduce((acc, e) => {
        acc.calls++;
        acc.success += e.success ? 1 : 0;
        acc.avg_latency = (acc.avg_latency * (acc.calls-1) + e.latency) / acc.calls;
        return acc;
    }, { calls: 0, success: 0, avg_latency: 0 });

// Reliability score: success_rate * speed_factor
// Prefer reliable tools, warn on unreliable
```

**Expected outcome:** Faster task completion, fewer failed attempts

---

### Loop 4: Reflection Capture
**Based on:** Reflexion + ACE Reflections

**Problem:** When agent fails or succeeds in an interesting way, the lesson is lost.

**How it works:**
```
After interesting outcomes:
1. Meta agent captures: What happened? What was the error pattern?
2. What approach worked? When does this apply?
3. Store as structured reflection in memory
4. Before similar tasks, consult reflection playbook
5. Apply lessons proactively, not just reactively
```

**Reflection structure:**
```zig
const reflection = .{
    .error_pattern = "HTTPS tool blocked by security policy",
    .correct_approach = "Use http_request with explicit domain allowlist",
    .applicable_contexts = &[_][]const u8{ "web_fetch", "security", "external_api" },
    .effectiveness_score = 0.85,
    .learned_at = timestamp,
    .times_applied = 12,
};
```

**Expected outcome:** Agent improves at avoiding repeated mistakes

---

### Loop 5: Session Recovery Intelligence
**Based on:** ACE - Session Progress

**Problem:** Sessions crash, context is lost, agent restarts from scratch.

**How it works:**
```
During task execution:
1. Checkpoint progress at key milestones
2. On crash: analyze where failures happened
3. Learn: which steps are crash-prone?
4. Adjust checkpoint frequency + granularity
5. On restart: resume from last stable checkpoint
```

**Implementation for nullalis:**
```zig
// Checkpoint after each tool call
session.checkpoint(.{
    .completed_steps = completed_items,
    .in_progress = current_task,
    .pending_items = next_items,
    .memory_state = memory.last_checkpoint(),
    .policy_state = security.current_ruleset(),
});

// On crash, meta agent analyzes failure point
const failure_point = analyze_crash(session.history);
if (failure_point.type == STUCK_IN_LOOP) {
    session.checkpoint_frequency = .more_frequent;
}
```

**Expected outcome:** Resilient long-running tasks, less wasted work

---

## Implementation Priority

| Loop | Impact | Effort | Start With? |
|------|--------|--------|-------------|
| Memory Quality Voting | 🔥 High | Medium | ✅ YES |
| Reflection Capture | 🔥 High | Medium | ✅ YES |
| Tool Reliability Tracking | 🔥 High | Low | ✅ YES |
| Security Self-Tuning | 🟡 Medium | High | Later |
| Session Recovery | 🟡 Medium | High | Later |

**Recommended order:** 1 → 2 → 3 → 4 → 5

---

## Architecture Changes Needed

### 1. Meta Agent Component
```zig
// src/meta/meta_agent.zig
pub const MetaAgent = struct {
    allocator: std.mem.Allocator,
    memory_votes: std.StringHashMap(*VoteStore),
    reflections: std.StringArrayQueue(*Reflection),
    tool_reliability: std.StringHashMap(*ToolStats),
    
    // Main loop
    pub fn process(self: *MetaAgent, event: *const AuditEvent) void {
        switch (event.kind) {
            .task_complete => self.vote_on_memory(event),
            .tool_failure => self.update_tool_stats(event),
            .policy_violation => self.analyze_security(event),
            .session_end => self.capture_reflections(event),
        }
    }
};
```

### 2. Event Emission from Task Agent
```zig
// Task agent emits events that meta agent consumes
const event = AuditEvent{
    .kind = .tool_called,
    .tool_id = tool.id,
    .success = result.ok,
    .latency_ms = elapsed_ms,
    .timestamp = std.time.timestamp(),
};
emit_to_meta(event);
```

### 3. Memory Store Enhancement
```sql
ALTER TABLE memories ADD COLUMN helpful_votes INTEGER DEFAULT 0;
ALTER TABLE memories ADD COLUMN harmful_votes INTEGER DEFAULT 0;
ALTER TABLE memories ADD COLUMN effectiveness_score FLOAT DEFAULT 0.0;
ALTER TABLE memories ADD COLUMN reflection_type VARCHAR(50); -- 'lesson', 'error', 'pattern'
```

---

## Safety Considerations

### Human-in-the-Loop for Policy Changes
```
Security policy modifications require approval:
1. Meta agent proposes: "Relax http_request block for api.stripe.com?"
2. Log proposal with reasoning
3. Wait for human approval (or automatic after N confirmations)
4. Apply change with rollback capability
```

### Rollback Mechanism
```
Every meta-level modification is logged:
- What changed
- Why
- Expected outcome
- Rollback command

If outcomes degrade → auto-rollback
```

### Audit Trail
```
All meta agent decisions logged:
- Timestamp
- Input (what was observed)
- Decision (what was changed)
- Outcome (was it correct?)

Reviewable by humans
```

---

## Comparison: nullalis vs Hyperagents

| Hyperagents | nullalis Equivalent | Status |
|-------------|-------------------|--------|
| Task Agent | nullalis agent loop | ✅ Exists |
| Meta Agent | Meta agent (NEW) | ❌ Missing |
| Task memory | Memory system | ✅ Exists |
| Meta-level modification | Policy/rules modification | 🟡 Partial |
| Self-referential | Self-improvement loop | ❌ Missing |
| Open-ended learning | Structured learning loops | ❌ Missing |

nullalis has the **object level** (task execution). Hyperagents shows we need an **explicit meta level** that observes and modifies the task agent.

---

## Next Steps

### Phase 1: Observation Layer (This Week)
- [ ] Add event emission to task agent
- [ ] Create audit event bus
- [ ] Build basic meta agent that logs everything

### Phase 2: Quality Signals (Week 2)
- [ ] Implement memory voting
- [ ] Implement tool reliability tracking
- [ ] Create reflection capture

### Phase 3: Closed Loop (Week 3-4)
- [ ] Connect meta agent decisions back to task agent
- [ ] Add safety rails and rollback
- [ ] Test on real workloads

---

## References

- **Hyperagents** (Meta AI, 2026) - Self-referential self-improving agents
- **MemPO** (arXiv:2603.00680) - Self-Memory Policy Optimization  
- **ACE Pattern** (Aegis Memory) - Memory voting, reflections, session progress
- **MetaCognition** (Zylos Research) - Dual observation, confidence calibration
- **Reflexion** (Shinn et al., 2023) - Verbal self-critique into episodic memory
- **Self-Refine** (Madaan et al., 2023) - Iterative self-critique loop
- **Voyager** (Wang et al., 2023) - Skill library with metacognitive curriculum

---

*nullalis going to the world.*
*Self-improving.*
