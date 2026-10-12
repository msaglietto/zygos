//! Pure mission state machine (docs/specs/mission.md "States & events"). No
//! I/O, no allocator: the orchestrator owns persistence and side effects;
//! this table is the single source of legality for transitions. Where the
//! pipeline cursor moves is not the FSM's job (mission/pipeline.zig).

const std = @import("std");

pub const State = enum {
    running,
    gating,
    done,
    failed,
};

pub const Event = enum {
    /// An executor task finished; more remain on this step.
    task_done,
    /// The step at the cursor finished; the cursor advances, steps remain.
    step_done,
    /// The cursor passed the last step.
    steps_done,
    /// A verifier said passed:false, threshold not reached → rework.
    verify_failed,
    /// Verify failures or executor exhaustions hit the threshold.
    escalate,
    gate_approved,
    /// Gate denied with feedback, threshold not reached → rework.
    gate_denied,
    /// Gate missing/unreachable/malformed, or denials exhausted.
    gate_failed,
    /// A step turn failed (turn error, bad stop, malformed or empty output).
    role_failed,
    /// max_role_turns reached at a step boundary.
    role_turns_exhausted,
    abort,
};

pub const Transition = struct { from: State, event: Event, to: State };

/// The complete legal-transition table (docs/specs/mission.md). Everything
/// not listed is IllegalTransition; terminal states accept nothing.
pub const transitions = [_]Transition{
    .{ .from = .running, .event = .task_done, .to = .running },
    .{ .from = .running, .event = .step_done, .to = .running },
    .{ .from = .running, .event = .steps_done, .to = .gating },
    .{ .from = .running, .event = .verify_failed, .to = .running },
    .{ .from = .running, .event = .escalate, .to = .failed },
    .{ .from = .running, .event = .role_failed, .to = .failed },
    .{ .from = .running, .event = .role_turns_exhausted, .to = .failed },
    .{ .from = .running, .event = .abort, .to = .failed },
    .{ .from = .gating, .event = .gate_approved, .to = .done },
    .{ .from = .gating, .event = .gate_denied, .to = .running },
    .{ .from = .gating, .event = .gate_failed, .to = .failed },
    .{ .from = .gating, .event = .abort, .to = .failed },
};

pub const Fsm = struct {
    pub fn apply(state: State, event: Event) error{IllegalTransition}!State {
        inline for (transitions) |t| {
            if (t.from == state and t.event == event) return t.to;
        }
        return error.IllegalTransition;
    }
};

const testing = std.testing;

/// The spec table written out independently of `transitions`, so a drifted
/// table cannot vouch for itself.
const spec_table = [_]Transition{
    .{ .from = .running, .event = .task_done, .to = .running },
    .{ .from = .running, .event = .step_done, .to = .running },
    .{ .from = .running, .event = .steps_done, .to = .gating },
    .{ .from = .running, .event = .verify_failed, .to = .running },
    .{ .from = .running, .event = .escalate, .to = .failed },
    .{ .from = .running, .event = .role_failed, .to = .failed },
    .{ .from = .running, .event = .role_turns_exhausted, .to = .failed },
    .{ .from = .running, .event = .abort, .to = .failed },
    .{ .from = .gating, .event = .gate_approved, .to = .done },
    .{ .from = .gating, .event = .gate_denied, .to = .running },
    .{ .from = .gating, .event = .gate_failed, .to = .failed },
    .{ .from = .gating, .event = .abort, .to = .failed },
};

fn specTarget(s: State, e: Event) ?State {
    for (spec_table) |t| {
        if (t.from == s and t.event == e) return t.to;
    }
    return null;
}

test "every legal transition maps to the spec table" {
    try testing.expectEqual(spec_table.len, transitions.len);
    for (spec_table) |t| {
        try testing.expectEqual(t.to, try Fsm.apply(t.from, t.event));
    }
}

test "every (state,event) pair not in the table is IllegalTransition" {
    inline for (@typeInfo(State).@"enum".fields) |sf| {
        inline for (@typeInfo(Event).@"enum".fields) |ef| {
            const s: State = @enumFromInt(sf.value);
            const e: Event = @enumFromInt(ef.value);
            if (specTarget(s, e) == null) {
                try testing.expectError(error.IllegalTransition, Fsm.apply(s, e));
            }
        }
    }
}

test "terminal states reject all events" {
    inline for (@typeInfo(Event).@"enum".fields) |ef| {
        const e: Event = @enumFromInt(ef.value);
        try testing.expectError(error.IllegalTransition, Fsm.apply(.done, e));
        try testing.expectError(error.IllegalTransition, Fsm.apply(.failed, e));
    }
}

test "the happy chain walks running to done" {
    var s: State = .running;
    s = try Fsm.apply(s, .task_done);
    try testing.expectEqual(State.running, s);
    s = try Fsm.apply(s, .step_done);
    try testing.expectEqual(State.running, s);
    s = try Fsm.apply(s, .steps_done);
    try testing.expectEqual(State.gating, s);
    s = try Fsm.apply(s, .gate_approved);
    try testing.expectEqual(State.done, s);
}

test "rework loops re-enter running" {
    try testing.expectEqual(State.running, try Fsm.apply(.running, .verify_failed));
    try testing.expectEqual(State.running, try Fsm.apply(.gating, .gate_denied));
}
