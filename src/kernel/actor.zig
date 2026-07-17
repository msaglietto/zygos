//! Zygos kernel actor — the composition point wiring S2–S5 behind one thread
//! (decision Z-02; design in docs/specs/actor.md). ALL registry mutation
//! happens on the kernel thread draining the MPSC command inbox. This is the
//! only kernel module allowed to import the others; it still knows nothing of
//! sockets — the net layer posts `Command`s in and implements `Outbound` out.
//!
//! Boundary contracts (spec § "Boundary contracts"):
//! - `post` is thread-safe and blocks when the inbox is full (backpressure,
//!   never drop). Only `run`/`step` pop, and only on the kernel thread.
//! - The actor never reads a clock: frame commands carry poster-stamped
//!   now_ms, `.tick` carries the timer thread's. Tests drive time via ticks.
//!   The actor remembers the largest stamp it has seen (`now_ms`) and uses
//!   it for the channel bridge ops, so every registry timestamp lives in
//!   the one clock domain the sweeps run in.
//! - A `.frame` command owns its `json.Parsed(Message)`; the actor deinits it
//!   after handling (and on shutdown drain).
//! - Outbound frames are serialized to bytes valid only during `send` —
//!   implementations copy.

const std = @import("std");
const json = std.json;
const protocol = @import("protocol.zig");
const catalog_mod = @import("catalog.zig");
const invocation_mod = @import("invocation.zig");
const trigger_mod = @import("trigger.zig");
const channel_mod = @import("channel.zig");
const types = @import("types.zig");
const sync = @import("sync.zig");

const log = std.log.scoped(.actor);

pub const WorkerId = types.WorkerId;

pub const SendError = error{ Disconnected, QueueFull };

/// How finished frames leave the kernel. The net layer backs this with
/// per-connection bounded writer queues (cap 64); tests record the pairs.
/// On error the actor logs and drops — connection teardown is the net
/// layer's job (it posts `worker_disconnected`).
pub const Outbound = struct {
    ctx: *anyopaque,
    sendFn: *const fn (ctx: *anyopaque, to: WorkerId, frame: []const u8) SendError!void,

    fn send(self: Outbound, to: WorkerId, frame: []const u8) SendError!void {
        return self.sendFn(self.ctx, to, frame);
    }
};

pub const Command = union(enum) {
    worker_connected: WorkerId,
    worker_disconnected: WorkerId,
    frame: Frame,
    tick: i64, // now_ms
    shutdown,
    // Channel sync bridge (T1): registry ops must run on the kernel thread,
    // but endpoints are cross-thread objects. The op structs live on the
    // calling thread's stack; the kernel thread fills the slot and sets the
    // event. Callers MUST NOT invoke these from the kernel thread (deadlock).
    channel_create: *ChannelCreateOp,
    channel_take_sender: *ChannelTakeSenderOp,
    channel_take_receiver: *ChannelTakeReceiverOp,

    pub const Frame = struct {
        from: WorkerId,
        parsed: json.Parsed(protocol.Message),
        now_ms: i64,
    };
};

pub const CreatedChannel = struct {
    writer: channel_mod.Ref,
    reader: channel_mod.Ref,
};

pub const ChannelCreateOp = struct {
    capacity: usize,
    owner: WorkerId,
    event: sync.ResetEvent = .{},
    /// null after event.set() means OOM (or kernel shutdown drain).
    /// Ref slices are owned by the channels registry — valid until reap.
    result: ?CreatedChannel = null,
};

pub const ChannelTakeError = error{ NotFound, BadKey, AlreadyTaken, Shutdown };

pub const ChannelTakeSenderOp = struct {
    id: []const u8, // caller-owned; caller blocks, so stack slices are safe
    key: []const u8,
    event: sync.ResetEvent = .{},
    result: union(enum) { pending, ok: channel_mod.Sender, err: ChannelTakeError } = .pending,
};

pub const ChannelTakeReceiverOp = struct {
    id: []const u8,
    key: []const u8,
    event: sync.ResetEvent = .{},
    result: union(enum) { pending, ok: channel_mod.Receiver, err: ChannelTakeError } = .pending,
};

pub const Config = struct {
    invoke_timeout_ms: i64 = 30_000,
    ack_timeout_ms: i64 = 10_000,
    channel_ttl_ms: i64 = 300_000,
    inbox_capacity: usize = 1024,
    /// Per-function deadline policy, matched by function-id prefix (first
    /// match wins; fallback `invoke_timeout_ms`). The embedder supplies the
    /// naming — the kernel stays worker-agnostic. Motivation: one global
    /// timeout cannot serve both a whole-mission blocking call and the
    /// provider calls inside it. Entries must outlive the actor.
    invoke_timeout_overrides: []const TimeoutOverride = &.{},
};

pub const TimeoutOverride = struct {
    prefix: []const u8,
    timeout_ms: i64,
};

// ---------------------------------------------------------------------------
// Inbox — bounded MPSC ring
// ---------------------------------------------------------------------------

const Inbox = struct {
    mutex: sync.Mutex = .{},
    not_empty: sync.Condition = .{},
    not_full: sync.Condition = .{},
    buf: []Command,
    head: usize = 0,
    len: usize = 0,

    fn push(self: *Inbox, cmd: Command) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.len == self.buf.len) self.not_full.wait(&self.mutex);
        self.buf[(self.head + self.len) % self.buf.len] = cmd;
        self.len += 1;
        self.not_empty.signal();
    }

    fn popBlocking(self: *Inbox) Command {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.len == 0) self.not_empty.wait(&self.mutex);
        return self.takeLocked();
    }

    fn tryPop(self: *Inbox) ?Command {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.len == 0) return null;
        return self.takeLocked();
    }

    fn takeLocked(self: *Inbox) Command {
        const cmd = self.buf[self.head];
        self.head = (self.head + 1) % self.buf.len;
        self.len -= 1;
        self.not_full.signal();
        return cmd;
    }
};

// ---------------------------------------------------------------------------
// Actor
// ---------------------------------------------------------------------------

pub const Actor = struct {
    gpa: std.mem.Allocator,
    config: Config,
    outbound: Outbound,
    inbox: Inbox,
    catalog: catalog_mod.Catalog,
    services: catalog_mod.ServiceRegistry,
    invocations: invocation_mod.Invocations,
    triggers: trigger_mod.Triggers,
    channels: channel_mod.Channels,
    /// The kernel's observed clock: the largest poster-stamped time seen on
    /// any `.tick` or `.frame`. Never read from a syscall — time only enters
    /// as message data. Channel bridge ops are stamped with this so callers
    /// cannot put a channel into a different clock domain than the sweeps
    /// (a caller-passed 0 once made every stream channel look decades idle).
    now_ms: i64,

    pub fn init(gpa: std.mem.Allocator, config: Config, outbound: Outbound) error{OutOfMemory}!Actor {
        const buf = try gpa.alloc(Command, config.inbox_capacity);
        return .{
            .gpa = gpa,
            .config = config,
            .outbound = outbound,
            .inbox = .{ .buf = buf },
            .catalog = catalog_mod.Catalog.init(gpa),
            .services = catalog_mod.ServiceRegistry.init(gpa),
            .invocations = invocation_mod.Invocations.init(gpa),
            .triggers = trigger_mod.Triggers.init(gpa),
            .channels = channel_mod.Channels.init(gpa, config.channel_ttl_ms),
            .now_ms = 0,
        };
    }

    pub fn deinit(self: *Actor) void {
        // Drain unprocessed commands — frames own memory; never leak them
        // (spec: shutdown drains-and-deinitializes without processing).
        while (self.inbox.tryPop()) |cmd| freeCommand(cmd);
        self.inbox.not_full.deinit();
        self.inbox.not_empty.deinit();
        self.inbox.mutex.deinit();
        self.gpa.free(self.inbox.buf);
        self.channels.deinit();
        self.triggers.deinit();
        self.invocations.deinit();
        self.services.deinit();
        self.catalog.deinit();
    }

    /// Thread-safe; blocks when the inbox is full.
    pub fn post(self: *Actor, cmd: Command) void {
        self.inbox.push(cmd);
    }

    /// Kernel-thread loop: drain until `shutdown`.
    pub fn run(self: *Actor) void {
        while (self.handleCommand(self.inbox.popBlocking())) {}
    }

    /// Test seam: process exactly one queued command (kernel thread only).
    /// Returns false when it processed `shutdown` or the inbox was empty.
    pub fn step(self: *Actor) bool {
        const cmd = self.inbox.tryPop() orelse return false;
        return self.handleCommand(cmd);
    }

    /// Register an in-process built-in function, owned by KERNEL_WORKER and
    /// therefore never removed by any disconnect path. Kernel thread (or
    /// pre-`run` wiring) only. `ctx` reaches the builtin on every call.
    pub fn registerBuiltin(
        self: *Actor,
        id: []const u8,
        description: []const u8,
        ctx: ?*anyopaque,
        f: *const catalog_mod.BuiltinFn,
    ) error{OutOfMemory}!void {
        _ = try self.catalog.register(id, catalog_mod.KERNEL_WORKER, .{
            .handler = .{ .builtin = .{ .ctx = ctx, .f = f } },
            .description = description,
        });
    }

    // -- channel sync bridge (worker threads; NEVER the kernel thread) ------

    /// Create a channel through the kernel thread. Blocking; the returned
    /// Refs' slices are owned by the channels registry (valid until reap).
    /// The kernel stamps the op with its own observed time — callers never
    /// supply a clock here (in-proc callers have none the sweeps would trust).
    pub fn channelCreate(
        self: *Actor,
        capacity: usize,
        owner: WorkerId,
    ) error{ OutOfMemory, Shutdown }!CreatedChannel {
        var op: ChannelCreateOp = .{ .capacity = capacity, .owner = owner };
        defer op.event.deinit();
        self.post(.{ .channel_create = &op });
        op.event.wait();
        return op.result orelse error.OutOfMemory;
    }

    /// Take the sender endpoint through the kernel thread. Blocking.
    pub fn channelTakeSender(
        self: *Actor,
        id: []const u8,
        key: []const u8,
    ) ChannelTakeError!channel_mod.Sender {
        var op: ChannelTakeSenderOp = .{ .id = id, .key = key };
        defer op.event.deinit();
        self.post(.{ .channel_take_sender = &op });
        op.event.wait();
        return switch (op.result) {
            .ok => |s| s,
            .err => |err| err,
            .pending => unreachable,
        };
    }

    /// Take the receiver endpoint through the kernel thread. Blocking.
    pub fn channelTakeReceiver(
        self: *Actor,
        id: []const u8,
        key: []const u8,
    ) ChannelTakeError!channel_mod.Receiver {
        var op: ChannelTakeReceiverOp = .{ .id = id, .key = key };
        defer op.event.deinit();
        self.post(.{ .channel_take_receiver = &op });
        op.event.wait();
        return switch (op.result) {
            .ok => |r| r,
            .err => |err| err,
            .pending => unreachable,
        };
    }

    // -- command handling ---------------------------------------------------

    fn handleCommand(self: *Actor, cmd: Command) bool {
        switch (cmd) {
            .shutdown => return false,
            .worker_connected => |w| self.onConnected(w),
            .worker_disconnected => |w| self.onDisconnected(w),
            .tick => |now_ms| {
                self.now_ms = @max(self.now_ms, now_ms);
                self.onTick(now_ms);
            },
            .frame => |f| {
                defer f.parsed.deinit();
                self.now_ms = @max(self.now_ms, f.now_ms);
                self.onFrame(f.from, f.parsed.value, f.now_ms);
            },
            .channel_create => |op| {
                if (self.channels.create(op.capacity, op.owner, self.now_ms)) |refs| {
                    op.result = .{ .writer = refs.writer, .reader = refs.reader };
                } else |_| {}
                op.event.set();
            },
            .channel_take_sender => |op| {
                op.result = if (self.channels.takeSender(op.id, op.key, self.now_ms)) |s|
                    .{ .ok = s }
                else |err|
                    .{ .err = err };
                op.event.set();
            },
            .channel_take_receiver => |op| {
                op.result = if (self.channels.takeReceiver(op.id, op.key, self.now_ms)) |r|
                    .{ .ok = r }
                else |err|
                    .{ .err = err };
                op.event.set();
            },
        }
        return true;
    }

    fn onConnected(self: *Actor, w: WorkerId) void {
        var buf: [36]u8 = undefined;
        self.sendMsg(w, .{ .workerregistered = .{ .worker_id = types.formatUuid(w, &buf) } });
    }

    /// Disconnect GC — order per spec: pendings first (errors still carry
    /// context), then registries (CAS-gated inside), then channels.
    fn onDisconnected(self: *Actor, w: WorkerId) void {
        _ = self.invocations.failAllForCallee(w, self, onCalleeDied);
        _ = self.invocations.dropAllForCaller(w);
        _ = self.catalog.removeAllOwnedBy(w);
        _ = self.services.removeAllOwnedBy(w);
        _ = self.triggers.unregisterWorker(w);
        _ = self.channels.reapOwner(w);
    }

    fn onTick(self: *Actor, now_ms: i64) void {
        _ = self.invocations.sweepExpired(now_ms, self, onInvokeTimeout);
        _ = self.triggers.sweepExpiredAcks(now_ms, self, onAckExpired);
        _ = self.channels.sweepIdle(now_ms);
    }

    fn onFrame(self: *Actor, from: WorkerId, msg: protocol.Message, now_ms: i64) void {
        switch (msg) {
            .registerfunction => |m| self.onRegisterFunction(from, m),
            .unregisterfunction => |m| {
                if (!self.catalog.unregister(m.id, from))
                    log.warn("unregisterfunction {s}: not the owner or unknown", .{m.id});
            },
            .registerservice => |m| {
                _ = self.services.register(m.id, from, .{
                    .name = m.name,
                    .description = m.description orelse "",
                    .parent_service_id = m.parent_service_id,
                }) catch |err| log.warn("registerservice {s}: {t}", .{ m.id, err });
            },
            .registertriggertype => |m| self.onRegisterTriggerType(from, m),
            .registertrigger => |m| self.onRegisterTrigger(from, m),
            .unregistertrigger => |m| {
                if (!self.triggers.unregisterBinding(m.id, m.trigger_type))
                    log.warn("unregistertrigger {s}: unknown or type mismatch", .{m.id});
            },
            .triggerregistrationresult => |m| self.onTriggerRegistrationResult(m),
            .invokefunction => |m| self.onInvoke(from, m, now_ms),
            .invocationresult => |m| self.onInvocationResult(m),
            .ping => self.sendMsg(from, .pong),
            // Engine→worker frames arriving from a worker are protocol misuse.
            .pong => {},
            .workerregistered => log.warn("dropped engine-direction frame from worker", .{}),
        }
    }

    // -- registration -------------------------------------------------------

    fn onRegisterFunction(self: *Actor, from: WorkerId, m: protocol.Message.RegisterFunction) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const scratch = arena.allocator();

        const handler: catalog_mod.Handler = if (m.invocation) |ref| .{
            .external_http = .{
                .url = ref.url,
                .method = ref.method,
                .raw = rawJsonOf(scratch, ref) catch return logOom("registerfunction"),
            },
        } else .{ .worker = from };

        const result = self.catalog.register(m.id, from, .{
            .handler = handler,
            .description = m.description orelse "",
            .request_format = optRawJson(scratch, m.request_format) catch return logOom("registerfunction"),
            .response_format = optRawJson(scratch, m.response_format) catch return logOom("registerfunction"),
            .metadata = optRawJson(scratch, m.metadata) catch return logOom("registerfunction"),
        }) catch return logOom("registerfunction");
        if (result == .overwrote)
            log.warn("registerfunction {s}: overwrote existing registration (last wins)", .{m.id});
    }

    fn onRegisterTriggerType(self: *Actor, from: WorkerId, m: protocol.Message.RegisterTriggerType) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const scratch = arena.allocator();

        var replay: std.ArrayList([]const u8) = .empty;
        defer replay.deinit(self.gpa);

        _ = self.triggers.registerType(m.id, .{
            .owner = from,
            .description = m.description,
            .trigger_request_format = optRawJson(scratch, m.trigger_request_format) catch return logOom("registertriggertype"),
            .call_request_format = optRawJson(scratch, m.call_request_format) catch return logOom("registertriggertype"),
        }, &replay) catch return logOom("registertriggertype");

        // Re-forward every existing binding of this type to the new owner
        // (PROTOCOL.md §4 — provider-reconnect support).
        for (replay.items) |binding_id| self.replayBinding(binding_id, from);
    }

    fn replayBinding(self: *Actor, binding_id: []const u8, to: WorkerId) void {
        const b = self.triggers.binding(binding_id) orelse return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const scratch = arena.allocator();

        const config_value = json.parseFromSliceLeaky(json.Value, scratch, b.config, .{}) catch {
            log.warn("replay {s}: stored config unparseable", .{binding_id});
            return;
        };
        const metadata_value: ?json.Value = if (b.metadata) |raw|
            json.parseFromSliceLeaky(json.Value, scratch, raw, .{}) catch null
        else
            null;

        self.sendMsg(to, .{ .registertrigger = .{
            .id = binding_id,
            .trigger_type = b.trigger_type,
            .function_id = b.function_id,
            .config = config_value,
            .metadata = metadata_value,
        } });
    }

    fn onRegisterTrigger(self: *Actor, from: WorkerId, m: protocol.Message.RegisterTrigger) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const scratch = arena.allocator();

        // Wire-path bindings are connection-owned (owner = registrant): no
        // ack entry — awaiting inline would deadlock the read loop
        // (PROTOCOL.md §6). Durable/function-path bindings arrive in M1.
        const type_owner = self.triggers.registerBinding(m.id, .{
            .trigger_type = m.trigger_type,
            .function_id = m.function_id,
            .config = rawJsonOf(scratch, m.config) catch return logOom("registertrigger"),
            .owner = from,
            .metadata = optRawJson(scratch, m.metadata) catch return logOom("registertrigger"),
        }, null) catch |err| switch (err) {
            error.UnknownTriggerType => return self.sendTriggerError(from, m, "unknown_trigger_type", "no such trigger type"),
            error.DuplicateId => return self.sendTriggerError(from, m, "duplicate_trigger", "trigger id already registered"),
            error.OutOfMemory => return logOom("registertrigger"),
        };

        // Forward the binding to the type owner, which does the real wiring.
        self.sendMsg(type_owner, .{ .registertrigger = m });
    }

    fn sendTriggerError(
        self: *Actor,
        to: WorkerId,
        m: protocol.Message.RegisterTrigger,
        code: []const u8,
        message: []const u8,
    ) void {
        self.sendMsg(to, .{ .triggerregistrationresult = .{
            .id = m.id,
            .trigger_type = m.trigger_type,
            .function_id = m.function_id,
            .err = .{ .code = code, .message = message },
        } });
    }

    fn onTriggerRegistrationResult(self: *Actor, m: protocol.Message.TriggerRegistrationResult) void {
        // Capture the registrant before completeAck — a failed ack removes
        // the binding. Connection-owned bindings forward the result to their
        // registrant; durable ones have nobody connected to tell.
        const registrant: ?WorkerId = if (self.triggers.binding(m.id)) |b| b.owner else null;
        _ = self.triggers.completeAck(m.id, m.err != null);
        if (registrant) |r| self.sendMsg(r, .{ .triggerregistrationresult = m });
    }

    // -- invocation ---------------------------------------------------------

    fn onInvoke(self: *Actor, from: WorkerId, m: protocol.Message.InvokeFunction, now_ms: i64) void {
        const entry = self.catalog.get(m.function_id) orelse {
            if (m.invocation_id) |iid|
                self.sendErrorResult(from, iid, m, "function_not_found", "no such function");
            return;
        };

        // TriggerAction semantics in M0: no queue worker yet, enqueue
        // degrades to direct dispatch (warn); void forces fire-and-forget.
        var fire_and_forget = m.invocation_id == null;
        if (m.action) |action| switch (action) {
            .enqueue => log.warn("invoke {s}: enqueue action degraded to direct dispatch (M0)", .{m.function_id}),
            .void => fire_and_forget = true,
        };

        switch (entry.handler) {
            .worker => |callee| {
                if (!fire_and_forget) {
                    const uuid = types.parseUuid(m.invocation_id.?) catch {
                        // Mirrors iii's deserialization rejection of bad UUIDs.
                        log.warn("invoke {s}: invalid invocation_id, frame dropped", .{m.function_id});
                        return;
                    };
                    self.invocations.add(
                        uuid,
                        callee,
                        m.function_id,
                        .{ .connection = from },
                        now_ms + self.invokeTimeoutFor(m.function_id),
                    ) catch |err| {
                        log.warn("invoke {s}: {t}, frame dropped", .{ m.function_id, err });
                        return;
                    };
                }
                self.sendMsg(callee, .{ .invokefunction = m });
            },
            .builtin => |b| self.callBuiltin(from, b, m),
            .external_http => {
                if (m.invocation_id) |iid|
                    self.sendErrorResult(from, iid, m, "external_http_unsupported", "external HTTP dispatch lands after M0");
            },
        }
    }

    fn callBuiltin(
        self: *Actor,
        from: WorkerId,
        b: catalog_mod.Builtin,
        m: protocol.Message.InvokeFunction,
    ) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const scratch = arena.allocator();

        const request_json = rawJsonOf(scratch, m.data) catch return logOom("builtin");
        const out = b.f(b.ctx, scratch, request_json) catch |err| {
            if (m.invocation_id) |iid| switch (err) {
                error.OutOfMemory => self.sendErrorResult(from, iid, m, "builtin_failed", "out of memory"),
                error.Failed => self.sendErrorResult(from, iid, m, "builtin_failed", "builtin reported failure"),
            };
            return;
        };
        const iid = m.invocation_id orelse return; // fire-and-forget builtin

        const result_value = json.parseFromSliceLeaky(json.Value, scratch, out, .{}) catch {
            self.sendErrorResult(from, iid, m, "builtin_failed", "builtin returned invalid JSON");
            return;
        };
        self.sendMsg(from, .{ .invocationresult = .{
            .invocation_id = iid,
            .function_id = m.function_id,
            .result = result_value,
            .traceparent = m.traceparent,
            .baggage = m.baggage,
        } });
    }

    fn onInvocationResult(self: *Actor, m: protocol.Message.InvocationResult) void {
        const uuid = types.parseUuid(m.invocation_id) catch {
            log.warn("invocationresult: invalid invocation_id, dropped", .{});
            return;
        };
        // Unknown/duplicate ids are logged and dropped, never crash
        // (PROTOCOL.md §1).
        const reply = self.invocations.complete(uuid) orelse {
            log.warn("invocationresult {s}: unknown or already completed, dropped", .{m.invocation_id});
            return;
        };
        switch (reply) {
            .connection => |caller| self.sendMsg(caller, .{ .invocationresult = m }),
            .waiter => |w| {
                // Real payloads (T1): the parsed frame dies with this command,
                // so the outcome is duped into gpa — Outcome slices are
                // owned-by-recipient; the waiter side frees with the actor's
                // gpa after waking. OOM → result stays null (unknown error).
                if (m.err) |e| {
                    if (self.gpa.dupe(u8, e.code)) |code| {
                        w.result = .{ .err = code };
                    } else |_| {}
                } else if (m.result) |value| {
                    if (rawJsonOf(self.gpa, value)) |payload| {
                        w.result = .{ .ok = payload };
                    } else |_| {}
                } else {
                    if (self.gpa.dupe(u8, "null")) |payload| {
                        w.result = .{ .ok = payload };
                    } else |_| {}
                }
                w.event.set();
            },
            .none => {},
        }
    }

    // -- invocation callbacks (sweeps / disconnects) -------------------------

    fn invokeTimeoutFor(self: *const Actor, function_id: []const u8) i64 {
        for (self.config.invoke_timeout_overrides) |o|
            if (std.mem.startsWith(u8, function_id, o.prefix)) return o.timeout_ms;
        return self.config.invoke_timeout_ms;
    }

    fn onInvokeTimeout(self: *Actor, id: types.Uuid, reply: invocation_mod.ReplyTarget, function_id: []const u8) void {
        self.completeExceptionally(id, reply, function_id, "timeout", "invocation deadline exceeded");
    }

    fn onCalleeDied(self: *Actor, id: types.Uuid, reply: invocation_mod.ReplyTarget, function_id: []const u8) void {
        self.completeExceptionally(id, reply, function_id, "worker_disconnected", "callee disconnected before completing");
    }

    fn onAckExpired(self: *Actor, binding_id: []const u8) void {
        _ = self; // nothing to send in M0 — durable acks arrive via bus functions in M1
        log.warn("trigger ack {s}: deadline expired, binding removed", .{binding_id});
    }

    fn completeExceptionally(
        self: *Actor,
        id: types.Uuid,
        reply: invocation_mod.ReplyTarget,
        function_id: []const u8,
        code: []const u8,
        message: []const u8,
    ) void {
        switch (reply) {
            .connection => |caller| {
                var buf: [36]u8 = undefined;
                self.sendMsg(caller, .{ .invocationresult = .{
                    .invocation_id = types.formatUuid(id, &buf),
                    .function_id = function_id,
                    .err = .{ .code = code, .message = message },
                } });
            },
            .waiter => |w| {
                // Same owned-by-recipient convention as result routing; OOM
                // leaves the slot null (unknown error).
                if (self.gpa.dupe(u8, code)) |owned| {
                    w.result = .{ .err = owned };
                } else |_| {}
                w.event.set();
            },
            .none => {},
        }
    }

    // -- outbound helpers -----------------------------------------------------

    fn sendMsg(self: *Actor, to: WorkerId, msg: protocol.Message) void {
        const bytes = protocol.serializeAlloc(self.gpa, msg) catch return logOom("serialize");
        defer self.gpa.free(bytes);
        self.outbound.send(to, bytes) catch |err|
            log.warn("outbound send failed ({t}), frame dropped", .{err});
    }

    fn sendErrorResult(
        self: *Actor,
        to: WorkerId,
        invocation_id: []const u8,
        m: protocol.Message.InvokeFunction,
        code: []const u8,
        message: []const u8,
    ) void {
        self.sendMsg(to, .{ .invocationresult = .{
            .invocation_id = invocation_id,
            .function_id = m.function_id,
            .err = .{ .code = code, .message = message },
            .traceparent = m.traceparent,
            .baggage = m.baggage,
        } });
    }
};

/// Drain-path cleanup: frames own memory; bridge ops have a blocked caller
/// that must be woken (with a shutdown-shaped result) or it hangs forever.
fn freeCommand(cmd: Command) void {
    switch (cmd) {
        .frame => |f| f.parsed.deinit(),
        .channel_create => |op| op.event.set(), // result stays null
        .channel_take_sender => |op| {
            op.result = .{ .err = error.Shutdown };
            op.event.set();
        },
        .channel_take_receiver => |op| {
            op.result = .{ .err = error.Shutdown };
            op.event.set();
        },
        else => {},
    }
}

fn logOom(what: []const u8) void {
    log.err("{s}: out of memory, dropped", .{what});
}

/// Serialize any value (json.Value or reflected struct) to minified JSON
/// text in `alloc`. Used to store schemas/configs as raw text (the
/// registries never interpret them) and to build builtin request payloads.
fn rawJsonOf(alloc: std.mem.Allocator, value: anytype) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var ws: json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    ws.write(value) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn optRawJson(alloc: std.mem.Allocator, value: ?json.Value) error{OutOfMemory}!?[]u8 {
    const v = value orelse return null;
    return try rawJsonOf(alloc, v);
}

// ===========================================================================
// Tests (docs/specs/actor.md test contract, named exactly)
// ===========================================================================

const testing = std.testing;

fn widOf(n: u8) WorkerId {
    return [_]u8{n} ** 16;
}

const FakeOutbound = struct {
    gpa: std.mem.Allocator,
    sent: std.ArrayList(Sent) = .empty,

    const Sent = struct { to: WorkerId, bytes: []u8 };

    fn sendFn(ctx: *anyopaque, to: WorkerId, frame: []const u8) SendError!void {
        const self: *FakeOutbound = @ptrCast(@alignCast(ctx));
        const copy = self.gpa.dupe(u8, frame) catch return error.QueueFull;
        self.sent.append(self.gpa, .{ .to = to, .bytes = copy }) catch {
            self.gpa.free(copy);
            return error.QueueFull;
        };
    }

    fn outbound(self: *FakeOutbound) Outbound {
        return .{ .ctx = self, .sendFn = &sendFn };
    }

    fn deinit(self: *FakeOutbound) void {
        for (self.sent.items) |s| self.gpa.free(s.bytes);
        self.sent.deinit(self.gpa);
    }

    fn parseAt(self: *FakeOutbound, i: usize) !json.Parsed(protocol.Message) {
        return protocol.parseMessage(self.gpa, self.sent.items[i].bytes);
    }
};

const Harness = struct {
    fake: FakeOutbound,
    actor: Actor,

    fn init(gpa: std.mem.Allocator) !*Harness {
        return initWith(gpa, .{});
    }

    fn initWith(gpa: std.mem.Allocator, config: Config) !*Harness {
        const self = try gpa.create(Harness);
        self.fake = .{ .gpa = gpa };
        self.actor = try Actor.init(gpa, config, self.fake.outbound());
        return self;
    }

    fn deinit(self: *Harness) void {
        const gpa = self.actor.gpa;
        self.actor.deinit();
        self.fake.deinit();
        gpa.destroy(self);
    }

    /// Post one frame command and step it through the actor.
    fn frame(self: *Harness, from: WorkerId, text: []const u8, now_ms: i64) !void {
        const parsed = try protocol.parseMessage(self.actor.gpa, text);
        self.actor.post(.{ .frame = .{ .from = from, .parsed = parsed, .now_ms = now_ms } });
        try testing.expect(self.actor.step());
    }
};

const caller_uuid_text = "11111111-2222-3333-4444-555555555555";

test "worker_connected sends workerregistered with the uuid text" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    h.actor.post(.{ .worker_connected = widOf(0xab) });
    try testing.expect(h.actor.step());

    try testing.expectEqual(@as(usize, 1), h.fake.sent.items.len);
    try testing.expect(std.mem.eql(u8, &h.fake.sent.items[0].to, &widOf(0xab)));
    var p = try h.fake.parseAt(0);
    defer p.deinit();
    try testing.expectEqualStrings(
        "abababab-abab-abab-abab-abababababab",
        p.value.workerregistered.worker_id,
    );
}

test "register then invoke routes the frame to the callee and the result back to the caller" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const worker_a = widOf(1);
    const worker_b = widOf(2);

    try h.frame(worker_a, "{\"type\":\"registerfunction\",\"id\":\"echo::f\",\"description\":\"echo\"}", 0);
    try h.frame(worker_b,
        \\{"type":"invokefunction","invocation_id":"11111111-2222-3333-4444-555555555555",
        \\ "function_id":"echo::f","data":{"x":1},"traceparent":"00-aa-bb-01","baggage":"k=v"}
    , 1_000);

    // Frame forwarded to the callee with correlation + trace context intact.
    try testing.expectEqual(@as(usize, 1), h.fake.sent.items.len);
    try testing.expect(std.mem.eql(u8, &h.fake.sent.items[0].to, &worker_a));
    {
        var p = try h.fake.parseAt(0);
        defer p.deinit();
        const fwd = p.value.invokefunction;
        try testing.expectEqualStrings(caller_uuid_text, fwd.invocation_id.?);
        try testing.expectEqualStrings("00-aa-bb-01", fwd.traceparent.?);
        try testing.expectEqualStrings("k=v", fwd.baggage.?);
    }

    // Callee answers; the result routes back to the caller, trace preserved.
    try h.frame(worker_a,
        \\{"type":"invocationresult","invocation_id":"11111111-2222-3333-4444-555555555555",
        \\ "function_id":"echo::f","result":{"ok":true},"traceparent":"00-cc-dd-01"}
    , 1_100);
    try testing.expectEqual(@as(usize, 2), h.fake.sent.items.len);
    try testing.expect(std.mem.eql(u8, &h.fake.sent.items[1].to, &worker_b));
    var p = try h.fake.parseAt(1);
    defer p.deinit();
    const res = p.value.invocationresult;
    try testing.expect(res.result != null);
    try testing.expect(res.err == null);
    try testing.expectEqualStrings("00-cc-dd-01", res.traceparent.?);
}

test "invoke unknown function returns function_not_found error result" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.frame(widOf(2),
        \\{"type":"invokefunction","invocation_id":"11111111-2222-3333-4444-555555555555",
        \\ "function_id":"missing::f","data":{}}
    , 0);

    try testing.expectEqual(@as(usize, 1), h.fake.sent.items.len);
    var p = try h.fake.parseAt(0);
    defer p.deinit();
    try testing.expectEqualStrings("function_not_found", p.value.invocationresult.err.?.code);
    try testing.expectEqualStrings(caller_uuid_text, p.value.invocationresult.invocation_id);
}

test "invoke unknown function without invocation_id is dropped silently" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.frame(widOf(2), "{\"type\":\"invokefunction\",\"function_id\":\"missing::f\",\"data\":{}}", 0);
    try testing.expectEqual(@as(usize, 0), h.fake.sent.items.len);
}

test "fire-and-forget invoke forwards without parking a pending" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.frame(widOf(1), "{\"type\":\"registerfunction\",\"id\":\"f\",\"description\":\"\"}", 0);
    try h.frame(widOf(2), "{\"type\":\"invokefunction\",\"function_id\":\"f\",\"data\":{}}", 0);

    try testing.expectEqual(@as(usize, 1), h.fake.sent.items.len);
    try testing.expectEqual(@as(usize, 0), h.actor.invocations.count());
}

test "timeout tick synthesizes timeout error; late result then dropped" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.frame(widOf(1), "{\"type\":\"registerfunction\",\"id\":\"f\",\"description\":\"\"}", 0);
    try h.frame(widOf(2),
        \\{"type":"invokefunction","invocation_id":"11111111-2222-3333-4444-555555555555",
        \\ "function_id":"f","data":{}}
    , 1_000);
    try testing.expectEqual(@as(usize, 1), h.fake.sent.items.len); // forwarded

    // Tick past deadline (default 30s): caller gets ErrorBody timeout.
    h.actor.post(.{ .tick = 1_000 + 30_000 });
    try testing.expect(h.actor.step());
    try testing.expectEqual(@as(usize, 2), h.fake.sent.items.len);
    {
        var p = try h.fake.parseAt(1);
        defer p.deinit();
        try testing.expect(std.mem.eql(u8, &h.fake.sent.items[1].to, &widOf(2)));
        try testing.expectEqualStrings("timeout", p.value.invocationresult.err.?.code);
        try testing.expectEqualStrings("f", p.value.invocationresult.function_id);
    }

    // Late result after the timeout: dropped, nothing else sent.
    try h.frame(widOf(1),
        \\{"type":"invocationresult","invocation_id":"11111111-2222-3333-4444-555555555555",
        \\ "function_id":"f","result":{}}
    , 40_000);
    try testing.expectEqual(@as(usize, 2), h.fake.sent.items.len);
}

test "invoke timeout overrides: prefixed functions get their own deadline, others keep the default" {
    var h = try Harness.initWith(testing.allocator, .{
        .invoke_timeout_ms = 30_000,
        .invoke_timeout_overrides = &.{
            .{ .prefix = "long::", .timeout_ms = 300_000 },
        },
    });
    defer h.deinit();

    try h.frame(widOf(1), "{\"type\":\"registerfunction\",\"id\":\"long::f\",\"description\":\"\"}", 0);
    try h.frame(widOf(1), "{\"type\":\"registerfunction\",\"id\":\"short::f\",\"description\":\"\"}", 0);
    try h.frame(widOf(2),
        \\{"type":"invokefunction","invocation_id":"11111111-2222-3333-4444-555555555555",
        \\ "function_id":"long::f","data":{}}
    , 1_000);
    try h.frame(widOf(3),
        \\{"type":"invokefunction","invocation_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
        \\ "function_id":"short::f","data":{}}
    , 1_000);
    try testing.expectEqual(@as(usize, 2), h.fake.sent.items.len); // both forwarded
    try testing.expectEqual(@as(usize, 2), h.actor.invocations.count());

    // Past the default deadline: only the non-overridden call times out.
    h.actor.post(.{ .tick = 1_000 + 30_000 });
    try testing.expect(h.actor.step());
    try testing.expectEqual(@as(usize, 3), h.fake.sent.items.len);
    try testing.expectEqual(@as(usize, 1), h.actor.invocations.count());
    {
        var p = try h.fake.parseAt(2);
        defer p.deinit();
        try testing.expect(std.mem.eql(u8, &h.fake.sent.items[2].to, &widOf(3)));
        try testing.expectEqualStrings("timeout", p.value.invocationresult.err.?.code);
        try testing.expectEqualStrings("short::f", p.value.invocationresult.function_id);
    }

    // Past the override deadline: the long call times out too.
    h.actor.post(.{ .tick = 1_000 + 300_000 });
    try testing.expect(h.actor.step());
    try testing.expectEqual(@as(usize, 4), h.fake.sent.items.len);
    try testing.expectEqual(@as(usize, 0), h.actor.invocations.count());
    {
        var p = try h.fake.parseAt(3);
        defer p.deinit();
        try testing.expect(std.mem.eql(u8, &h.fake.sent.items[3].to, &widOf(2)));
        try testing.expectEqualStrings("timeout", p.value.invocationresult.err.?.code);
        try testing.expectEqualStrings("long::f", p.value.invocationresult.function_id);
    }
}

test "callee disconnect fails its pendings with worker_disconnected" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.frame(widOf(1), "{\"type\":\"registerfunction\",\"id\":\"f\",\"description\":\"\"}", 0);
    try h.frame(widOf(2),
        \\{"type":"invokefunction","invocation_id":"11111111-2222-3333-4444-555555555555",
        \\ "function_id":"f","data":{}}
    , 0);

    h.actor.post(.{ .worker_disconnected = widOf(1) });
    try testing.expect(h.actor.step());

    try testing.expectEqual(@as(usize, 2), h.fake.sent.items.len);
    var p = try h.fake.parseAt(1);
    defer p.deinit();
    try testing.expect(std.mem.eql(u8, &h.fake.sent.items[1].to, &widOf(2)));
    try testing.expectEqualStrings("worker_disconnected", p.value.invocationresult.err.?.code);
}

test "caller disconnect drops its pendings silently" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.frame(widOf(1), "{\"type\":\"registerfunction\",\"id\":\"f\",\"description\":\"\"}", 0);
    try h.frame(widOf(2),
        \\{"type":"invokefunction","invocation_id":"11111111-2222-3333-4444-555555555555",
        \\ "function_id":"f","data":{}}
    , 0);
    try testing.expectEqual(@as(usize, 1), h.fake.sent.items.len);

    h.actor.post(.{ .worker_disconnected = widOf(2) });
    try testing.expect(h.actor.step());
    try testing.expectEqual(@as(usize, 1), h.fake.sent.items.len); // nothing new
    try testing.expectEqual(@as(usize, 0), h.actor.invocations.count());

    // The callee's late result finds nobody: logged and dropped.
    try h.frame(widOf(1),
        \\{"type":"invocationresult","invocation_id":"11111111-2222-3333-4444-555555555555",
        \\ "function_id":"f","result":{}}
    , 0);
    try testing.expectEqual(@as(usize, 1), h.fake.sent.items.len);
}

test "stale disconnect after re-registration leaves the fresh owner intact" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const stale = widOf(1);
    const fresh = widOf(3);

    try h.frame(stale, "{\"type\":\"registerfunction\",\"id\":\"f\",\"description\":\"\"}", 0);
    try h.frame(fresh, "{\"type\":\"registerfunction\",\"id\":\"f\",\"description\":\"\"}", 0);

    // The stale connection's cleanup arrives after the fresh registration.
    h.actor.post(.{ .worker_disconnected = stale });
    try testing.expect(h.actor.step());

    // S2 through the actor: the invoke still routes to the fresh owner.
    try h.frame(widOf(2), "{\"type\":\"invokefunction\",\"function_id\":\"f\",\"data\":{}}", 0);
    try testing.expectEqual(@as(usize, 1), h.fake.sent.items.len);
    try testing.expect(std.mem.eql(u8, &h.fake.sent.items[0].to, &fresh));
}

test "trigger type re-registration replays bindings to the new owner" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const provider_v1 = widOf(1);
    const provider_v2 = widOf(4);
    const registrant = widOf(2);

    try h.frame(provider_v1, "{\"type\":\"registertriggertype\",\"id\":\"cron\",\"description\":\"cron\"}", 0);
    try h.frame(registrant,
        \\{"type":"registertrigger","id":"t-1","trigger_type":"cron",
        \\ "function_id":"jobs::nightly","config":{"schedule":"0 3 * * *"}}
    , 0);
    try testing.expectEqual(@as(usize, 1), h.fake.sent.items.len); // forwarded to v1

    // Provider reconnects under a new connection and re-registers the type.
    try h.frame(provider_v2, "{\"type\":\"registertriggertype\",\"id\":\"cron\",\"description\":\"cron\"}", 0);
    try testing.expectEqual(@as(usize, 2), h.fake.sent.items.len);
    try testing.expect(std.mem.eql(u8, &h.fake.sent.items[1].to, &provider_v2));
    var p = try h.fake.parseAt(1);
    defer p.deinit();
    const replayed = p.value.registertrigger;
    try testing.expectEqualStrings("t-1", replayed.id);
    try testing.expectEqualStrings("jobs::nightly", replayed.function_id);
    try testing.expectEqualStrings(
        "0 3 * * *",
        replayed.config.object.get("schedule").?.string,
    );
}

test "registertrigger forwards to type owner; triggerregistrationresult forwarded to registrant" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const provider = widOf(1);
    const registrant = widOf(2);

    try h.frame(provider, "{\"type\":\"registertriggertype\",\"id\":\"cron\",\"description\":\"\"}", 0);
    try h.frame(registrant,
        \\{"type":"registertrigger","id":"t-1","trigger_type":"cron",
        \\ "function_id":"jobs::n","config":{}}
    , 0);
    try testing.expectEqual(@as(usize, 1), h.fake.sent.items.len);
    try testing.expect(std.mem.eql(u8, &h.fake.sent.items[0].to, &provider));

    // The provider acks; the ack is forwarded to the binding's registrant.
    try h.frame(provider,
        \\{"type":"triggerregistrationresult","id":"t-1","trigger_type":"cron",
        \\ "function_id":"jobs::n","error":null}
    , 0);
    try testing.expectEqual(@as(usize, 2), h.fake.sent.items.len);
    try testing.expect(std.mem.eql(u8, &h.fake.sent.items[1].to, &registrant));
    var p = try h.fake.parseAt(1);
    defer p.deinit();
    try testing.expect(p.value.triggerregistrationresult.err == null);
}

test "registertrigger with unknown type answers unknown_trigger_type" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.frame(widOf(2),
        \\{"type":"registertrigger","id":"t-1","trigger_type":"nope",
        \\ "function_id":"f","config":{}}
    , 0);

    try testing.expectEqual(@as(usize, 1), h.fake.sent.items.len);
    var p = try h.fake.parseAt(0);
    defer p.deinit();
    try testing.expectEqualStrings("unknown_trigger_type", p.value.triggerregistrationresult.err.?.code);
}

test "ping answers pong" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.frame(widOf(7), "{\"type\":\"ping\"}", 0);
    try testing.expectEqual(@as(usize, 1), h.fake.sent.items.len);
    try testing.expect(std.mem.eql(u8, &h.fake.sent.items[0].to, &widOf(7)));
    try testing.expectEqualStrings("{\"type\":\"pong\"}", h.fake.sent.items[0].bytes);
}

fn echoBuiltin(_: ?*anyopaque, gpa: std.mem.Allocator, request_json: []const u8) catalog_mod.BuiltinError![]u8 {
    return gpa.dupe(u8, request_json) catch error.OutOfMemory;
}

/// ctx-carrying builtin for the T1 kernel test: replies with its counter and
/// increments it, proving state reaches the call.
fn countingBuiltin(ctx: ?*anyopaque, gpa: std.mem.Allocator, request_json: []const u8) catalog_mod.BuiltinError![]u8 {
    _ = request_json;
    const counter: *u32 = @ptrCast(@alignCast(ctx.?));
    defer counter.* += 1;
    return std.fmt.allocPrint(gpa, "{{\"count\":{d}}}", .{counter.*}) catch error.OutOfMemory;
}

test "builtin dispatch runs in-process and answers on the same tick" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.actor.registerBuiltin("zygos::echo", "echoes the request", null, &echoBuiltin);
    try h.frame(widOf(2),
        \\{"type":"invokefunction","invocation_id":"11111111-2222-3333-4444-555555555555",
        \\ "function_id":"zygos::echo","data":{"n":42}}
    , 0);

    try testing.expectEqual(@as(usize, 1), h.fake.sent.items.len);
    var p = try h.fake.parseAt(0);
    defer p.deinit();
    const res = p.value.invocationresult;
    try testing.expectEqualStrings("zygos::echo", res.function_id);
    try testing.expectEqual(@as(i64, 42), res.result.?.object.get("n").?.integer);
}

test "builtin ctx reaches the call and persists across invocations" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var counter: u32 = 7;
    try h.actor.registerBuiltin("zygos::count", "counts", &counter, &countingBuiltin);

    try h.frame(widOf(2),
        \\{"type":"invokefunction","invocation_id":"11111111-2222-3333-4444-555555555555",
        \\ "function_id":"zygos::count","data":{}}
    , 0);
    try h.frame(widOf(2),
        \\{"type":"invokefunction","invocation_id":"11111111-2222-3333-4444-555555555556",
        \\ "function_id":"zygos::count","data":{}}
    , 0);

    try testing.expectEqual(@as(usize, 2), h.fake.sent.items.len);
    var p1 = try h.fake.parseAt(0);
    defer p1.deinit();
    var p2 = try h.fake.parseAt(1);
    defer p2.deinit();
    try testing.expectEqual(@as(i64, 7), p1.value.invocationresult.result.?.object.get("count").?.integer);
    try testing.expectEqual(@as(i64, 8), p2.value.invocationresult.result.?.object.get("count").?.integer);
}

test "waiter completion carries a real duped payload owned by the recipient" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var w: invocation_mod.Waiter = .{};
    defer w.deinit();
    const uuid = try types.parseUuid(caller_uuid_text);
    // Kernel-internal path: park a waiter-target pending directly (the
    // registry is actor-owned; step-driven tests run on one thread).
    try h.actor.invocations.add(uuid, widOf(1), "f", .{ .waiter = &w }, 10_000);

    try h.frame(widOf(1),
        \\{"type":"invocationresult","invocation_id":"11111111-2222-3333-4444-555555555555",
        \\ "function_id":"f","result":{"x":1}}
    , 0);

    w.event.wait(); // already set; must not block
    const outcome = w.result.?;
    try testing.expect(outcome == .ok);
    try testing.expectEqualStrings("{\"x\":1}", outcome.ok);
    testing.allocator.free(outcome.ok); // owned-by-recipient convention
}

test "channel bridge: create and take endpoints stream across threads" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const t = try std.Thread.spawn(.{}, Actor.run, .{&h.actor});

    const refs = try h.actor.channelCreate(4, widOf(1));
    var sender = try h.actor.channelTakeSender(refs.writer.channel_id, refs.writer.access_key);
    var receiver = try h.actor.channelTakeReceiver(refs.reader.channel_id, refs.reader.access_key);
    try testing.expectError(
        error.AlreadyTaken,
        h.actor.channelTakeSender(refs.writer.channel_id, refs.writer.access_key),
    );

    var payload = "delta".*;
    try sender.push(.{ .text = &payload });
    const item = try receiver.pop();
    try testing.expectEqualStrings("delta", item.bytes());
    item.deinit(testing.allocator);

    sender.deinit();
    try testing.expectError(error.EndOfStream, receiver.pop());
    receiver.deinit();

    h.actor.post(.shutdown);
    t.join();
}

test "channel ops are stamped with the kernel's observed time, not caller time" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const t = try std.Thread.spawn(.{}, Actor.run, .{&h.actor});

    // The kernel has already observed wall-clock-scale time (tick pump).
    // Regression guard: callers used to stamp channel ops with now_ms=0,
    // so the first real-time sweep saw every channel as decades idle and
    // reaped it before the provider pushed a single delta (stream 0B).
    const epoch: i64 = 1_700_000_000_000;
    const ttl = h.actor.config.channel_ttl_ms;
    h.actor.post(.{ .tick = epoch });

    const refs = try h.actor.channelCreate(4, widOf(1));

    // One tick short of the TTL: a channel stamped at kernel time survives.
    h.actor.post(.{ .tick = epoch + ttl - 1 });
    var receiver = try h.actor.channelTakeReceiver(refs.reader.channel_id, refs.reader.access_key);

    // Two idle TTLs later the reap must still fire (the first sweep may
    // absorb take-time pipe activity; the second sees true idleness).
    h.actor.post(.{ .tick = epoch + 3 * ttl });
    h.actor.post(.{ .tick = epoch + 5 * ttl });
    try testing.expectError(
        error.NotFound,
        h.actor.channelTakeSender(refs.writer.channel_id, refs.writer.access_key),
    );
    receiver.deinit();

    h.actor.post(.shutdown);
    t.join();
}

test "unknown invocation_id result is dropped without crash" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.frame(widOf(1),
        \\{"type":"invocationresult","invocation_id":"11111111-2222-3333-4444-555555555555",
        \\ "function_id":"f","result":{}}
    , 0);
    try testing.expectEqual(@as(usize, 0), h.fake.sent.items.len);
}

test "disconnect GC reaps catalog, triggers, channels for that worker" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const departing = widOf(1);
    const other = widOf(2);

    try h.frame(departing, "{\"type\":\"registerfunction\",\"id\":\"f\",\"description\":\"\"}", 0);
    try h.frame(departing, "{\"type\":\"registertriggertype\",\"id\":\"cron\",\"description\":\"\"}", 0);
    try h.frame(other,
        \\{"type":"registertrigger","id":"t-1","trigger_type":"cron","function_id":"f","config":{}}
    , 0);
    _ = try h.actor.channels.create(4, departing, 0);
    _ = try h.actor.channels.create(4, other, 0);

    h.actor.post(.{ .worker_disconnected = departing });
    try testing.expect(h.actor.step());

    try testing.expect(h.actor.catalog.get("f") == null); // function reaped
    try testing.expect(h.actor.triggers.typeOwner("cron") != null); // type survives (replayable)
    try testing.expect(h.actor.triggers.binding("t-1") != null); // other's binding survives
    try testing.expectEqual(@as(usize, 1), h.actor.channels.count()); // other's channel survives

    // The other worker's disconnect reaps its connection-owned binding.
    h.actor.post(.{ .worker_disconnected = other });
    try testing.expect(h.actor.step());
    try testing.expect(h.actor.triggers.binding("t-1") == null);
    try testing.expectEqual(@as(usize, 0), h.actor.channels.count());
}

test "enqueue action degrades to direct dispatch (warn) in M0" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.frame(widOf(1), "{\"type\":\"registerfunction\",\"id\":\"f\",\"description\":\"\"}", 0);
    try h.frame(widOf(2),
        \\{"type":"invokefunction","invocation_id":"11111111-2222-3333-4444-555555555555",
        \\ "function_id":"f","data":{},"action":{"type":"enqueue","queue":"orders"}}
    , 0);

    // Dispatched directly to the callee, pending parked as usual.
    try testing.expectEqual(@as(usize, 1), h.fake.sent.items.len);
    try testing.expect(std.mem.eql(u8, &h.fake.sent.items[0].to, &widOf(1)));
    try testing.expectEqual(@as(usize, 1), h.actor.invocations.count());
}

test "shutdown drains and frees queued frames (no leaks)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const first = try protocol.parseMessage(testing.allocator, "{\"type\":\"ping\"}");
    h.actor.post(.{ .frame = .{ .from = widOf(1), .parsed = first, .now_ms = 0 } });
    h.actor.post(.shutdown);
    const queued = try protocol.parseMessage(testing.allocator, "{\"type\":\"ping\"}");
    h.actor.post(.{ .frame = .{ .from = widOf(2), .parsed = queued, .now_ms = 0 } });

    // run() processes the first frame, stops at shutdown; the queued frame
    // is drained-and-freed by deinit (leak-checking allocator proves it).
    h.actor.run();
    try testing.expectEqual(@as(usize, 1), h.fake.sent.items.len); // one pong
}

test "run loop smoke: spawn thread, post, shutdown, join" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const t = try std.Thread.spawn(.{}, Actor.run, .{&h.actor});
    const parsed = try protocol.parseMessage(testing.allocator, "{\"type\":\"ping\"}");
    h.actor.post(.{ .frame = .{ .from = widOf(1), .parsed = parsed, .now_ms = 0 } });
    h.actor.post(.shutdown);
    t.join(); // bounded by shutdown; no sleeps

    try testing.expectEqual(@as(usize, 1), h.fake.sent.items.len);
    try testing.expectEqualStrings("{\"type\":\"pong\"}", h.fake.sent.items[0].bytes);
}

test "no leaks under register/invoke/complete loops" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try h.frame(widOf(1), "{\"type\":\"registerfunction\",\"id\":\"f\",\"description\":\"loop\"}", 0);
        try h.frame(widOf(2),
            \\{"type":"invokefunction","invocation_id":"11111111-2222-3333-4444-555555555555",
            \\ "function_id":"f","data":{"i":1}}
        , 0);
        try h.frame(widOf(1),
            \\{"type":"invocationresult","invocation_id":"11111111-2222-3333-4444-555555555555",
            \\ "function_id":"f","result":{"ok":true}}
        , 0);
    }
    try testing.expectEqual(@as(usize, 0), h.actor.invocations.count());
    // 100 iterations × (forward + result) frames recorded.
    try testing.expectEqual(@as(usize, 200), h.fake.sent.items.len);
}
