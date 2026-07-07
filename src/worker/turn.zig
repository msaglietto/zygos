//! Turn orchestrator (T2, T4 — docs/specs/turn.md). One turn = one agentic
//! loop: assemble context → stream a model response → dispatch tool calls →
//! repeat until the model stops or the step budget runs out.
//!
//! Split hard: `Fsm` is a pure table-driven state machine (exhaustively
//! tested, no I/O); `TurnOrchestrator` is bus glue over an inproc worker —
//! provider and tools are ordinary bus functions named in the request, so
//! fakes and the real provider are interchangeable peers.
//!
//! Deviation from the spec's failure line (flagged): turn failures reply as
//! `{"stop":"failed",...}` result payloads — the inproc Handler contract
//! carries no custom ErrorBody codes, and callers want the transcript anyway.

const std = @import("std");
const json = std.json;
const actor_mod = @import("../kernel/actor.zig");
const inproc = @import("../kernel/inproc.zig");
const sync = @import("../kernel/sync.zig");
const channel_mod = @import("../kernel/channel.zig");

const log = std.log.scoped(.turn);

// ---------------------------------------------------------------------------
// FSM (pure)
// ---------------------------------------------------------------------------

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
};

const Transition = struct { from: State, event: Event, to: State };

/// The complete legal-transition table (docs/specs/turn.md). Everything not
/// listed is IllegalTransition; terminal states accept nothing.
pub const transitions = [_]Transition{
    .{ .from = .provisioning, .event = .provider_started, .to = .streaming },
    .{ .from = .provisioning, .event = .step_budget_exhausted, .to = .stopped },
    .{ .from = .provisioning, .event = .abort, .to = .stopped },
    .{ .from = .streaming, .event = .provider_end_turn, .to = .stopped },
    .{ .from = .streaming, .event = .provider_tool_use, .to = .dispatching },
    .{ .from = .streaming, .event = .provider_error, .to = .failed },
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

// ---------------------------------------------------------------------------
// Driver
// ---------------------------------------------------------------------------

pub const TurnOrchestrator = struct {
    gpa: std.mem.Allocator,
    actor: *actor_mod.Actor,
    worker: *inproc.Worker,

    pub fn start(
        gpa: std.mem.Allocator,
        actor: *actor_mod.Actor,
        registry: *inproc.Registry,
    ) !*TurnOrchestrator {
        const self = try gpa.create(TurnOrchestrator);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .actor = actor,
            .worker = try inproc.Worker.spawn(gpa, actor, registry, "turn-orchestrator"),
        };
        errdefer self.worker.stop();
        try self.worker.registerFunction("zygos::turns::run", self, &runTurnHandler);
        return self;
    }

    pub fn stop(self: *TurnOrchestrator) void {
        self.worker.stop();
        const gpa = self.gpa;
        gpa.destroy(self);
    }
};

/// Per-turn tool table entry, resolved from the request's `tools` array.
const ToolRoute = struct {
    function_id: []const u8,
    requires_approval: bool,
};

/// Collects streamed deltas across the turn; the drain thread appends while
/// the driver blocks on the provider call. gpa-backed on purpose: the turn
/// arena is NOT thread-safe and must never be touched from the drain thread;
/// pipe items were duped with the registry gpa and are freed with it.
const DeltaLog = struct {
    mutex: sync.Mutex = .{},
    buf: std.ArrayList(u8) = .empty,

    fn drain(self: *DeltaLog, gpa: std.mem.Allocator, receiver: *channel_mod.Receiver) void {
        while (receiver.pop()) |item| {
            defer item.deinit(gpa);
            self.mutex.lock();
            defer self.mutex.unlock();
            self.buf.appendSlice(gpa, item.bytes()) catch {};
        } else |_| {} // EndOfStream
    }
};

fn runTurnHandler(
    ctx: ?*anyopaque,
    arena: std.mem.Allocator,
    request_json: []const u8,
) error{ Failed, OutOfMemory }![]const u8 {
    const self: *TurnOrchestrator = @ptrCast(@alignCast(ctx.?));
    return runTurn(self, arena, request_json) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => {
            log.warn("turn failed structurally: {t}", .{err});
            return error.Failed;
        },
    };
}

const TurnError = error{ OutOfMemory, Failed, MalformedRequest, IllegalTransition, Shutdown };

fn runTurn(self: *TurnOrchestrator, arena: std.mem.Allocator, request_json: []const u8) TurnError![]const u8 {
    const root = json.parseFromSliceLeaky(json.Value, arena, request_json, .{}) catch
        return error.MalformedRequest;
    const obj = if (root == .object) root.object else return error.MalformedRequest;

    const model = strField(obj, "model") orelse "unknown";
    const system = strField(obj, "system") orelse "";
    const max_steps: usize = if (obj.get("max_steps")) |v|
        (if (v == .integer and v.integer > 0) @intCast(v.integer) else 8)
    else
        8;
    const provider_fn = strField(obj, "provider_function") orelse return error.MalformedRequest;

    // Tool routing table: name → {function_id, requires_approval}.
    var routes = std.StringHashMap(ToolRoute).init(arena);
    const tools_json = blk: {
        const tools_val = obj.get("tools") orelse break :blk "[]";
        if (tools_val != .array) return error.MalformedRequest;
        for (tools_val.array.items) |tv| {
            if (tv != .object) return error.MalformedRequest;
            const name = strField(tv.object, "name") orelse return error.MalformedRequest;
            const fid = strField(tv.object, "function_id") orelse return error.MalformedRequest;
            const approval = if (tv.object.get("requires_approval")) |a| a == .bool and a.bool else false;
            try routes.put(name, .{ .function_id = fid, .requires_approval = approval });
        }
        break :blk try rawJson(arena, tools_val);
    };

    // Transcript: raw message JSON texts, in order.
    var transcript: std.ArrayList([]const u8) = .empty;
    if (obj.get("messages")) |msgs| {
        if (msgs != .array) return error.MalformedRequest;
        for (msgs.array.items) |m| try transcript.append(arena, try rawJson(arena, m));
    }

    var deltas: DeltaLog = .{};
    defer {
        deltas.buf.deinit(self.gpa);
        deltas.mutex.deinit();
    }

    var state: State = .provisioning;
    var steps: usize = 0;
    var stop: []const u8 = "end_turn";

    turn: while (true) {
        std.debug.assert(state == .provisioning);
        if (steps == max_steps) {
            state = try Fsm.apply(state, .step_budget_exhausted);
            stop = "max_steps";
            break :turn;
        }

        // Stream channel for this step: driver keeps the receiver, the
        // writer ref rides in the provider request (PROTOCOL.md sub-types).
        const ch = self.actor.channelCreate(64, self.worker.id, 0) catch return error.Failed;
        var receiver = self.actor.channelTakeReceiver(
            ch.reader.channel_id,
            ch.reader.access_key,
            0,
        ) catch return error.Failed;

        const provider_request = try std.fmt.allocPrint(arena,
            \\{{"model":{f},"system":{f},"messages":[{s}],"tools":{s},
            \\ "stream_channel":{{"channel_id":{f},"access_key":{f},"direction":"write"}}}}
        , .{
            json.fmt(model, .{}),
            json.fmt(system, .{}),
            try joinComma(arena, transcript.items),
            tools_json,
            json.fmt(ch.writer.channel_id, .{}),
            json.fmt(ch.writer.access_key, .{}),
        });

        state = try Fsm.apply(state, .provider_started); // → streaming
        const drain_thread = std.Thread.spawn(.{}, DeltaLog.drain, .{ &deltas, self.gpa, &receiver }) catch
            return error.Failed;

        const res = self.worker.call(provider_fn, provider_request) catch |err| {
            receiver.close();
            drain_thread.join();
            receiver.deinit();
            return err;
        };
        steps += 1;
        // Unblock the drain even if the provider never took the sender.
        receiver.close();
        drain_thread.join();
        receiver.deinit();

        switch (res) {
            .err => |code| {
                defer self.gpa.free(code);
                state = try Fsm.apply(state, .provider_error); // → failed
                return try std.fmt.allocPrint(
                    arena,
                    "{{\"stop\":\"failed\",\"steps\":{d},\"error\":{f}}}",
                    .{ steps, json.fmt(code, .{}) },
                );
            },
            .ok => |payload| {
                defer self.gpa.free(payload);
                const msg = json.parseFromSliceLeaky(json.Value, arena, payload, .{}) catch
                    return error.Failed;
                if (msg != .object) return error.Failed;
                const stop_reason = strField(msg.object, "stop_reason") orelse "end_turn";
                const content = msg.object.get("content") orelse json.Value{ .array = .init(arena) };

                // Assistant message joins the transcript either way.
                try transcript.append(arena, try std.fmt.allocPrint(
                    arena,
                    "{{\"role\":\"assistant\",\"content\":{s}}}",
                    .{try rawJson(arena, content)},
                ));

                if (!std.mem.eql(u8, stop_reason, "tool_use")) {
                    state = try Fsm.apply(state, .provider_end_turn); // → stopped
                    stop = stop_reason;
                    break :turn;
                }

                state = try Fsm.apply(state, .provider_tool_use); // → dispatching

                // Dispatch every tool_use block over the bus.
                var results: std.ArrayList([]const u8) = .empty;
                if (content == .array) for (content.array.items) |block| {
                    if (block != .object) continue;
                    const btype = strField(block.object, "type") orelse continue;
                    if (!std.mem.eql(u8, btype, "tool_use")) continue;
                    const tool_id = strField(block.object, "id") orelse "unknown";
                    const tool_name = strField(block.object, "name") orelse "";
                    const input = block.object.get("input") orelse json.Value.null;

                    const route = routes.get(tool_name) orelse {
                        try results.append(arena, try toolResult(arena, tool_id, "unknown tool", true));
                        continue;
                    };
                    if (route.requires_approval) {
                        // M2 owns real approval; M1 exercises the states.
                        state = try Fsm.apply(state, .needs_approval); // → awaiting_approval
                        state = try Fsm.apply(state, .approved); // → dispatching
                    }
                    const tool_res = self.worker.call(route.function_id, try rawJson(arena, input)) catch |err|
                        return err;
                    switch (tool_res) {
                        .ok => |out| {
                            defer self.gpa.free(out);
                            try results.append(arena, try toolResult(arena, tool_id, out, false));
                        },
                        .err => |code| {
                            defer self.gpa.free(code);
                            try results.append(arena, try toolResult(arena, tool_id, code, true));
                        },
                    }
                };

                state = try Fsm.apply(state, .tools_done); // → provisioning
                try transcript.append(arena, try std.fmt.allocPrint(
                    arena,
                    "{{\"role\":\"user\",\"content\":[{s}]}}",
                    .{try joinComma(arena, results.items)},
                ));
            },
        }
    }

    std.debug.assert(state == .stopped);
    deltas.mutex.lock();
    const delta_text = deltas.buf.items;
    deltas.mutex.unlock();
    return try std.fmt.allocPrint(
        arena,
        "{{\"stop\":{f},\"steps\":{d},\"deltas\":{f},\"transcript\":[{s}]}}",
        .{ json.fmt(stop, .{}), steps, json.fmt(delta_text, .{}), try joinComma(arena, transcript.items) },
    );
}

fn toolResult(arena: std.mem.Allocator, tool_use_id: []const u8, content: []const u8, is_error: bool) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "{{\"type\":\"tool_result\",\"tool_use_id\":{f},\"content\":{f},\"is_error\":{}}}",
        .{ json.fmt(tool_use_id, .{}), json.fmt(content, .{}), is_error },
    );
}

fn strField(obj: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn joinComma(arena: std.mem.Allocator, items: []const []const u8) error{OutOfMemory}![]const u8 {
    return std.mem.join(arena, ",", items);
}

fn rawJson(arena: std.mem.Allocator, value: json.Value) error{OutOfMemory}![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    errdefer out.deinit();
    var ws: json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    ws.write(value) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

// ===========================================================================
// Tests (docs/specs/turn.md contract)
// ===========================================================================

const testing = std.testing;

// -- FSM: exhaustive ---------------------------------------------------------

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

// -- Driver: fake provider + fake tool over the real bus ----------------------

const Harness = struct {
    registry: inproc.Registry,
    actor: actor_mod.Actor,
    kernel: std.Thread,
    orch: *TurnOrchestrator,
    provider: *FakeProvider,
    tool: *FakeTool,
    caller: *inproc.Worker,

    fn init(gpa: std.mem.Allocator, script: []const []const u8) !*Harness {
        const self = try gpa.create(Harness);
        self.registry = inproc.Registry.init(gpa, null);
        self.actor = try actor_mod.Actor.init(gpa, .{}, self.registry.outbound());
        self.kernel = try std.Thread.spawn(.{}, actor_mod.Actor.run, .{&self.actor});
        self.orch = try TurnOrchestrator.start(gpa, &self.actor, &self.registry);
        self.provider = try FakeProvider.start(gpa, &self.actor, &self.registry, script);
        self.tool = try FakeTool.start(gpa, &self.actor, &self.registry);
        self.caller = try inproc.Worker.spawn(gpa, &self.actor, &self.registry, "test-caller");
        return self;
    }

    fn deinit(self: *Harness) void {
        const gpa = self.actor.gpa;
        self.caller.stop();
        self.tool.stop();
        self.provider.stop();
        self.orch.stop();
        self.actor.post(.shutdown);
        self.kernel.join();
        self.actor.deinit();
        self.registry.deinit();
        gpa.destroy(self);
    }

    fn runTurnCall(self: *Harness, request: []const u8) !inproc.CallResult {
        return self.caller.call("zygos::turns::run", request);
    }
};

/// Scripted provider: call N returns script[N] (last entry repeats). Streams
/// two deltas into the request's channel before answering.
const FakeProvider = struct {
    gpa: std.mem.Allocator,
    actor: *actor_mod.Actor,
    worker: *inproc.Worker,
    script: []const []const u8,
    mutex: sync.Mutex = .{},
    calls: usize = 0,
    last_request: ?[]u8 = null,

    fn start(gpa: std.mem.Allocator, actor: *actor_mod.Actor, registry: *inproc.Registry, script: []const []const u8) !*FakeProvider {
        const self = try gpa.create(FakeProvider);
        self.* = .{
            .gpa = gpa,
            .actor = actor,
            .worker = try inproc.Worker.spawn(gpa, actor, registry, "fake-provider"),
            .script = script,
        };
        try self.worker.registerFunction("zygos::provider::fake::messages", self, &handler);
        return self;
    }

    fn stop(self: *FakeProvider) void {
        self.worker.stop();
        if (self.last_request) |r| self.gpa.free(r);
        self.mutex.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn handler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *FakeProvider = @ptrCast(@alignCast(ctx.?));

        const n = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.last_request) |r| self.gpa.free(r);
            self.last_request = self.gpa.dupe(u8, request_json) catch null;
            const n = self.calls;
            self.calls += 1;
            break :blk n;
        };

        // Stream two deltas over the caller-provided channel.
        const root = json.parseFromSliceLeaky(json.Value, arena, request_json, .{}) catch return error.Failed;
        const chan = root.object.get("stream_channel").?.object;
        var sender = self.actor.channelTakeSender(
            chan.get("channel_id").?.string,
            chan.get("access_key").?.string,
            0,
        ) catch return error.Failed;
        var d1 = "hello ".*;
        var d2 = "world".*;
        sender.push(.{ .text = &d1 }) catch {};
        sender.push(.{ .text = &d2 }) catch {};
        sender.deinit();

        const idx = @min(n, self.script.len - 1);
        return arena.dupe(u8, self.script[idx]);
    }
};

/// Records the last input it was called with; replies {"output":"ran"}.
const FakeTool = struct {
    gpa: std.mem.Allocator,
    worker: *inproc.Worker,
    mutex: sync.Mutex = .{},
    calls: usize = 0,
    last_input: ?[]u8 = null,

    fn start(gpa: std.mem.Allocator, actor: *actor_mod.Actor, registry: *inproc.Registry) !*FakeTool {
        const self = try gpa.create(FakeTool);
        self.* = .{
            .gpa = gpa,
            .worker = try inproc.Worker.spawn(gpa, actor, registry, "fake-tool"),
        };
        try self.worker.registerFunction("test::tool::run", self, &handler);
        return self;
    }

    fn stop(self: *FakeTool) void {
        self.worker.stop();
        if (self.last_input) |r| self.gpa.free(r);
        self.mutex.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn handler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *FakeTool = @ptrCast(@alignCast(ctx.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.last_input) |r| self.gpa.free(r);
        self.last_input = self.gpa.dupe(u8, request_json) catch null;
        self.calls += 1;
        return arena.dupe(u8, "{\"output\":\"ran\"}");
    }
};

const end_turn_msg =
    \\{"stop_reason":"end_turn","content":[{"type":"text","text":"done"}]}
;
const tool_use_msg =
    \\{"stop_reason":"tool_use","content":[{"type":"text","text":"checking"},
    \\ {"type":"tool_use","id":"toolu_1","name":"runner","input":{"command":"echo hi"}}]}
;

fn baseRequest(comptime tools_extra: []const u8) []const u8 {
    return
    \\{"model":"fake-1","system":"you are a test","max_steps":4,
    \\ "provider_function":"zygos::provider::fake::messages",
    \\ "messages":[{"role":"user","content":"go"}],
    \\ "tools":[{"name":"runner","function_id":"test::tool::run"
    ++ tools_extra ++
        \\}]}
    ;
}

test "text-only turn: one step, stops end_turn, transcript has assistant text" {
    var h = try Harness.init(testing.allocator, &.{end_turn_msg});
    defer h.deinit();

    const res = try h.runTurnCall(baseRequest(""));
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    var p = try json.parseFromSlice(json.Value, testing.allocator, res.ok, .{});
    defer p.deinit();
    try testing.expectEqualStrings("end_turn", p.value.object.get("stop").?.string);
    try testing.expectEqual(@as(i64, 1), p.value.object.get("steps").?.integer);
    const transcript = p.value.object.get("transcript").?.array.items;
    try testing.expectEqual(@as(usize, 2), transcript.len); // user + assistant
    try testing.expectEqualStrings("assistant", transcript[1].object.get("role").?.string);
}

test "tool-use turn: tool dispatched over the bus, tool_result in next request, ends end_turn on step 2" {
    var h = try Harness.init(testing.allocator, &.{ tool_use_msg, end_turn_msg });
    defer h.deinit();

    const res = try h.runTurnCall(baseRequest(""));
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    var p = try json.parseFromSlice(json.Value, testing.allocator, res.ok, .{});
    defer p.deinit();
    try testing.expectEqualStrings("end_turn", p.value.object.get("stop").?.string);
    try testing.expectEqual(@as(i64, 2), p.value.object.get("steps").?.integer);

    // The tool ran with the model's input.
    h.tool.mutex.lock();
    try testing.expectEqual(@as(usize, 1), h.tool.calls);
    try testing.expect(std.mem.indexOf(u8, h.tool.last_input.?, "echo hi") != null);
    h.tool.mutex.unlock();

    // The second provider request carried the tool_result (T4 core).
    h.provider.mutex.lock();
    const second_req = h.provider.last_request.?;
    try testing.expect(std.mem.indexOf(u8, second_req, "tool_result") != null);
    try testing.expect(std.mem.indexOf(u8, second_req, "toolu_1") != null);
    try testing.expect(std.mem.indexOf(u8, second_req, "\"is_error\":false") != null);
    h.provider.mutex.unlock();
}

test "unknown tool name yields is_error tool_result and the turn continues" {
    const bad_tool_msg =
        \\{"stop_reason":"tool_use","content":[
        \\ {"type":"tool_use","id":"toolu_9","name":"nonexistent","input":{}}]}
    ;
    var h = try Harness.init(testing.allocator, &.{ bad_tool_msg, end_turn_msg });
    defer h.deinit();

    const res = try h.runTurnCall(baseRequest(""));
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    var p = try json.parseFromSlice(json.Value, testing.allocator, res.ok, .{});
    defer p.deinit();
    try testing.expectEqualStrings("end_turn", p.value.object.get("stop").?.string);

    h.provider.mutex.lock();
    try testing.expect(std.mem.indexOf(u8, h.provider.last_request.?, "\"is_error\":true") != null);
    h.provider.mutex.unlock();
}

test "tool marked requires_approval routes through awaiting_approval and still dispatches" {
    var h = try Harness.init(testing.allocator, &.{ tool_use_msg, end_turn_msg });
    defer h.deinit();

    const res = try h.runTurnCall(baseRequest(",\"requires_approval\":true"));
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    h.tool.mutex.lock();
    try testing.expectEqual(@as(usize, 1), h.tool.calls); // auto-approved through the states
    h.tool.mutex.unlock();
}

test "provider error fails the turn with a failed stop" {
    var h = try Harness.init(testing.allocator, &.{end_turn_msg});
    defer h.deinit();

    const req =
        \\{"model":"fake-1","provider_function":"zygos::provider::missing",
        \\ "messages":[{"role":"user","content":"go"}]}
    ;
    const res = try h.runTurnCall(req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    var p = try json.parseFromSlice(json.Value, testing.allocator, res.ok, .{});
    defer p.deinit();
    try testing.expectEqualStrings("failed", p.value.object.get("stop").?.string);
    try testing.expectEqualStrings("function_not_found", p.value.object.get("error").?.string);
}

test "max_steps exhausts cleanly" {
    // Provider always wants tools → the budget is the only way out.
    var h = try Harness.init(testing.allocator, &.{tool_use_msg});
    defer h.deinit();

    const res = try h.runTurnCall(baseRequest(""));
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    var p = try json.parseFromSlice(json.Value, testing.allocator, res.ok, .{});
    defer p.deinit();
    try testing.expectEqualStrings("max_steps", p.value.object.get("stop").?.string);
    try testing.expectEqual(@as(i64, 4), p.value.object.get("steps").?.integer);
}

test "deltas streamed over the kernel channel are captured in order" {
    var h = try Harness.init(testing.allocator, &.{end_turn_msg});
    defer h.deinit();

    const res = try h.runTurnCall(baseRequest(""));
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    var p = try json.parseFromSlice(json.Value, testing.allocator, res.ok, .{});
    defer p.deinit();
    try testing.expectEqualStrings("hello world", p.value.object.get("deltas").?.string);
}

test "no leaks under a multi-step turn" {
    var h = try Harness.init(testing.allocator, &.{ tool_use_msg, tool_use_msg, end_turn_msg });
    defer h.deinit();

    const res = try h.runTurnCall(baseRequest(""));
    res.deinit(testing.allocator);
}
