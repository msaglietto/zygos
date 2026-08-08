//! Pure mission state machine (docs/specs/mission.md). No I/O, no allocator:
//! the orchestrator owns persistence and side effects; this table is the
//! single source of legality for transitions.

const std = @import("std");

pub const State = enum {
    defining,
    planning,
    executing,
    verifying,
    gating,
    done,
    failed,
};

pub const Event = enum {
    objective_ready,
    plan_ready,
    task_done,
    tasks_done,
    verify_passed,
    verify_failed,
    escalate,
    gate_approved,
    gate_denied,
    gate_failed,
    role_failed,
    role_turns_exhausted,
    abort,
};

pub const Transition = struct { from: State, event: Event, to: State };

/// The complete legal-transition table (docs/specs/mission.md). Everything
/// not listed is IllegalTransition; terminal states accept nothing.
pub const transitions = [_]Transition{
    .{ .from = .defining, .event = .objective_ready, .to = .planning },
    .{ .from = .defining, .event = .role_failed, .to = .failed },
    .{ .from = .defining, .event = .role_turns_exhausted, .to = .failed },
    .{ .from = .defining, .event = .abort, .to = .failed },
    .{ .from = .planning, .event = .plan_ready, .to = .executing },
    .{ .from = .planning, .event = .role_failed, .to = .failed },
    .{ .from = .planning, .event = .role_turns_exhausted, .to = .failed },
    .{ .from = .planning, .event = .abort, .to = .failed },
    .{ .from = .executing, .event = .task_done, .to = .executing },
    .{ .from = .executing, .event = .tasks_done, .to = .verifying },
    // Executor step-budget exhaustion past fail_threshold (retries happen
    // without a transition — the state loops on .executing).
    .{ .from = .executing, .event = .escalate, .to = .failed },
    .{ .from = .executing, .event = .role_failed, .to = .failed },
    .{ .from = .executing, .event = .role_turns_exhausted, .to = .failed },
    .{ .from = .executing, .event = .abort, .to = .failed },
    .{ .from = .verifying, .event = .verify_passed, .to = .gating },
    .{ .from = .verifying, .event = .verify_failed, .to = .planning },
    .{ .from = .verifying, .event = .escalate, .to = .failed },
    .{ .from = .verifying, .event = .role_failed, .to = .failed },
    .{ .from = .verifying, .event = .role_turns_exhausted, .to = .failed },
    .{ .from = .verifying, .event = .abort, .to = .failed },
    .{ .from = .gating, .event = .gate_approved, .to = .done },
    .{ .from = .gating, .event = .gate_denied, .to = .planning },
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

test "every legal transition maps to the spec table" {
    for (transitions) |t| {
        try testing.expectEqual(t.to, try Fsm.apply(t.from, t.event));
    }
}

test "every state-event pair not in the table is IllegalTransition" {
    inline for (@typeInfo(State).@"enum".fields) |sf| {
        inline for (@typeInfo(Event).@"enum".fields) |ef| {
            const s: State = @enumFromInt(sf.value);
            const e: Event = @enumFromInt(ef.value);
            var legal = false;
            for (transitions) |t| {
                if (t.from == s and t.event == e) legal = true;
            }
            if (!legal) {
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

test "the happy chain walks defining to done" {
    var s: State = .defining;
    s = try Fsm.apply(s, .objective_ready);
    try testing.expectEqual(State.planning, s);
    s = try Fsm.apply(s, .plan_ready);
    try testing.expectEqual(State.executing, s);
    s = try Fsm.apply(s, .task_done);
    try testing.expectEqual(State.executing, s);
    s = try Fsm.apply(s, .tasks_done);
    try testing.expectEqual(State.verifying, s);
    s = try Fsm.apply(s, .verify_passed);
    try testing.expectEqual(State.gating, s);
    s = try Fsm.apply(s, .gate_approved);
    try testing.expectEqual(State.done, s);
}

test "rework loops re-enter planning" {
    try testing.expectEqual(State.planning, try Fsm.apply(.verifying, .verify_failed));
    try testing.expectEqual(State.planning, try Fsm.apply(.gating, .gate_denied));
}
