//! Pure turn state machine (docs/specs/turn.md). No I/O, no allocator: the
//! orchestrator drives the bus and the provider; this table is the single
//! source of legality for transitions.

const std = @import("std");

pub const State = enum {
    provisioning,
    streaming,
    dispatching,
    awaiting_approval,
    steering,
    stopped,
    failed,
};

pub const Event = enum {
    provider_started,
    provider_end_turn,
    provider_tool_use,
    provider_error,
    tools_done,
    needs_approval,
    approved,
    denied,
    steer,
    steer_applied,
    abort,
    step_budget_exhausted,
    provider_retry,
    budget_exhausted,
};

pub const Transition = struct { from: State, event: Event, to: State };

/// The complete legal-transition table (docs/specs/turn.md). Everything not
/// listed is IllegalTransition; terminal states accept nothing.
pub const transitions = [_]Transition{
    .{ .from = .provisioning, .event = .provider_started, .to = .streaming },
    // Provisioning that cannot resolve a provider (routes exhausted, router
    // down) is a provider_error before any stream exists.
    .{ .from = .provisioning, .event = .provider_error, .to = .failed },
    .{ .from = .provisioning, .event = .step_budget_exhausted, .to = .stopped },
    .{ .from = .provisioning, .event = .budget_exhausted, .to = .stopped },
    .{ .from = .provisioning, .event = .abort, .to = .stopped },
    .{ .from = .streaming, .event = .provider_end_turn, .to = .stopped },
    .{ .from = .streaming, .event = .provider_tool_use, .to = .dispatching },
    .{ .from = .streaming, .event = .provider_error, .to = .failed },
    .{ .from = .streaming, .event = .provider_retry, .to = .provisioning },
    .{ .from = .streaming, .event = .steer, .to = .steering },
    .{ .from = .streaming, .event = .abort, .to = .stopped },
    .{ .from = .dispatching, .event = .needs_approval, .to = .awaiting_approval },
    .{ .from = .dispatching, .event = .tools_done, .to = .provisioning },
    .{ .from = .dispatching, .event = .steer, .to = .steering },
    .{ .from = .dispatching, .event = .abort, .to = .stopped },
    .{ .from = .awaiting_approval, .event = .approved, .to = .dispatching },
    .{ .from = .awaiting_approval, .event = .denied, .to = .dispatching },
    .{ .from = .awaiting_approval, .event = .abort, .to = .stopped },
    .{ .from = .steering, .event = .steer_applied, .to = .provisioning },
    .{ .from = .steering, .event = .abort, .to = .stopped },
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
        try testing.expectError(error.IllegalTransition, Fsm.apply(.stopped, e));
        try testing.expectError(error.IllegalTransition, Fsm.apply(.failed, e));
    }
}

test "step budget: provisioning + step_budget_exhausted stops" {
    try testing.expectEqual(State.stopped, try Fsm.apply(.provisioning, .step_budget_exhausted));
}
