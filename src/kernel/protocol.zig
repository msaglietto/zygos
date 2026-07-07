//! Zygos wire protocol (iii-compatible). Parse and serialize the tagged-union
//! JSON message envelope defined in docs/PROTOCOL.md — the single source of truth
//! for frames. This module knows nothing of sockets or the catalog; it only turns
//! bytes into `Message` values and back.
//!
//! PART 1 scope: invokefunction, invocationresult, ping, pong, workerregistered,
//! plus the shared `ErrorBody` and `TriggerAction` (enqueue/void) sub-types. The
//! `parseMessage`/`serialize` dispatch is a flat switch over the lowercased
//! `"type"` tag, so PART 2 appends registration messages by adding cases — no
//! restructuring of the union or the entry points.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const json = std.json;

/// Errors raised while parsing or serializing wire messages.
/// No `anyerror` in any public signature (repo convention).
pub const ProtocolError = error{
    /// Input was not valid JSON, the root was not an object, or `"type"` was missing.
    MalformedJson,
    /// The `"type"` tag names a message this build does not recognise.
    UnknownMessageType,
    /// A required field is absent.
    MissingField,
    /// A field is present but its JSON value is the wrong type for the schema.
    InvalidFieldType,
    OutOfMemory,
    WriteFailed,
};

/// `{"code":"...","message":"...","stacktrace":null}` — rides inside several messages.
pub const ErrorBody = struct {
    code: []const u8,
    message: []const u8,
    stacktrace: ?[]const u8 = null,
};

/// The `action` sub-type on `invokefunction`. Redirects call semantics. The wire
/// tag is the lowercased variant name, matching the envelope rule from PROTOCOL.md.
pub const TriggerAction = union(enum) {
    enqueue: struct { queue: []const u8 },
    void,
};

/// Every wire frame is one of these. Owned strings/values live in the arena of the
/// `std.json.Parsed(Message)` returned by `parseMessage` and are freed on `.deinit()`.
/// Field order in each payload mirrors docs/PROTOCOL.md so the serializer emits keys
/// in the documented order.
pub const Message = union(enum) {
    invokefunction: InvokeFunction,
    invocationresult: InvocationResult,
    ping,
    pong,
    workerregistered: WorkerRegistered,

    pub const InvokeFunction = struct {
        function_id: []const u8,
        data: json.Value,
        invocation_id: ?[]const u8 = null,
        traceparent: ?[]const u8 = null,
        baggage: ?[]const u8 = null,
        action: ?TriggerAction = null,
        metadata: ?json.Value = null,
    };

    pub const InvocationResult = struct {
        invocation_id: []const u8,
        function_id: []const u8,
        // `result` and `error` are mutually exclusive on the wire (success vs
        // failure); both are optional here so either variant round-trips. The
        // payload field is `err` because `error` is a Zig keyword; the wire key
        // stays `"error"`.
        result: ?json.Value = null,
        err: ?ErrorBody = null,
        traceparent: ?[]const u8 = null,
        baggage: ?[]const u8 = null,
    };

    pub const WorkerRegistered = struct {
        worker_id: []const u8,
    };
};

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

/// Parse one JSON text frame into a `Message`.
///
/// All parsed strings are copied into the returned arena (`.alloc_always`), so the
/// `Message` is fully owned by the `Parsed` and safe to use until `.deinit()` is
/// called — it never aliases the caller's input buffer. Callers must `defer p.deinit()`.
pub fn parseMessage(allocator: Allocator, bytes: []const u8) ProtocolError!std.json.Parsed(Message) {
    const arena_ptr = allocator.create(ArenaAllocator) catch return error.OutOfMemory;
    errdefer allocator.destroy(arena_ptr);
    arena_ptr.* = ArenaAllocator.init(allocator);
    errdefer arena_ptr.deinit();
    const arena = arena_ptr.allocator();

    // `.alloc_always` forces every string into the arena so the returned `Message`
    // owns all of its bytes; no slice reaches back into `bytes`.
    const root = json.parseFromSliceLeaky(json.Value, arena, bytes, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedJson,
    };

    const msg = try parseFromValue(root);
    return .{ .arena = arena_ptr, .value = msg };
}

/// Dispatch on the lowercased `"type"` tag. Flat if/else so PART 2 appends
/// registration cases without touching the union or the entry point above.
fn parseFromValue(root: json.Value) ProtocolError!Message {
    const obj = switch (root) {
        .object => |o| o,
        else => return error.MalformedJson,
    };
    const type_val = obj.get("type") orelse return error.MalformedJson;
    const tag = switch (type_val) {
        .string => |s| s,
        else => return error.MalformedJson,
    };

    if (std.mem.eql(u8, tag, "invokefunction")) {
        return .{ .invokefunction = try parseInvokeFunction(obj) };
    } else if (std.mem.eql(u8, tag, "invocationresult")) {
        return .{ .invocationresult = try parseInvocationResult(obj) };
    } else if (std.mem.eql(u8, tag, "workerregistered")) {
        return .{ .workerregistered = try parseWorkerRegistered(obj) };
    } else if (std.mem.eql(u8, tag, "ping")) {
        return .ping;
    } else if (std.mem.eql(u8, tag, "pong")) {
        return .pong;
    } else {
        return error.UnknownMessageType;
    }
}

fn parseInvokeFunction(obj: json.ObjectMap) ProtocolError!Message.InvokeFunction {
    return .{
        .function_id = try reqString(obj, "function_id"),
        .data = try reqValue(obj, "data"),
        .invocation_id = try optString(obj, "invocation_id"),
        .traceparent = try optString(obj, "traceparent"),
        .baggage = try optString(obj, "baggage"),
        .action = try optAction(obj, "action"),
        .metadata = optValue(obj, "metadata"),
    };
}

fn parseInvocationResult(obj: json.ObjectMap) ProtocolError!Message.InvocationResult {
    return .{
        .invocation_id = try reqString(obj, "invocation_id"),
        .function_id = try reqString(obj, "function_id"),
        .result = optValue(obj, "result"),
        .err = try optErrorBody(obj, "error"),
        .traceparent = try optString(obj, "traceparent"),
        .baggage = try optString(obj, "baggage"),
    };
}

fn parseWorkerRegistered(obj: json.ObjectMap) ProtocolError!Message.WorkerRegistered {
    return .{ .worker_id = try reqString(obj, "worker_id") };
}

fn parseTriggerAction(o: json.ObjectMap) ProtocolError!TriggerAction {
    const tag = try reqString(o, "type");
    if (std.mem.eql(u8, tag, "enqueue")) {
        return .{ .enqueue = .{ .queue = try reqString(o, "queue") } };
    } else if (std.mem.eql(u8, tag, "void")) {
        return .void;
    } else {
        return error.UnknownMessageType;
    }
}

fn parseErrorBody(o: json.ObjectMap) ProtocolError!ErrorBody {
    return .{
        .code = try reqString(o, "code"),
        .message = try reqString(o, "message"),
        .stacktrace = try optString(o, "stacktrace"),
    };
}

// --- field accessors ------------------------------------------------------
// `obj.get` returns `?Value`; a JSON `null` value is a present `.null` variant.
// For optionals, "field omitted" and "explicit null" both yield Zig `null`
// (PROTOCOL.md semantics the kernel must honor).

fn reqValue(obj: json.ObjectMap, key: []const u8) ProtocolError!json.Value {
    return obj.get(key) orelse error.MissingField;
}

fn reqString(obj: json.ObjectMap, key: []const u8) ProtocolError![]const u8 {
    const v = obj.get(key) orelse return error.MissingField;
    return switch (v) {
        .string => |s| s,
        else => error.InvalidFieldType,
    };
}

fn optString(obj: json.ObjectMap, key: []const u8) ProtocolError!?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .null => null,
        .string => |s| s,
        else => error.InvalidFieldType,
    };
}

fn optValue(obj: json.ObjectMap, key: []const u8) ?json.Value {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .null => null,
        else => v,
    };
}

fn optAction(obj: json.ObjectMap, key: []const u8) ProtocolError!?TriggerAction {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .null => null,
        .object => |o| try parseTriggerAction(o),
        else => error.InvalidFieldType,
    };
}

fn optErrorBody(obj: json.ObjectMap, key: []const u8) ProtocolError!?ErrorBody {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .null => null,
        .object => |o| try parseErrorBody(o),
        else => error.InvalidFieldType,
    };
}

// ---------------------------------------------------------------------------
// Serialization
// ---------------------------------------------------------------------------

/// Serialize a `Message` to the minified JSON text frame defined in PROTOCOL.md.
/// The `"type"` tag is the lowercased, concatenated variant name. Field order
/// mirrors the documented examples. Optional fields absent from the `Message`
/// are emitted as JSON `null`, matching the wire examples.
pub fn serialize(message: Message, writer: *std.Io.Writer) ProtocolError!void {
    var ws: json.Stringify = .{ .writer = writer, .options = .{ .whitespace = .minified } };
    try serializeInto(&ws, message);
}

/// Convenience wrapper that serializes into a freshly allocated byte slice the
/// caller owns and must free.
pub fn serializeAlloc(allocator: Allocator, message: Message) ProtocolError![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try serialize(message, &out.writer);
    const bytes = out.toOwnedSlice() catch return error.OutOfMemory;
    return bytes;
}

fn serializeInto(ws: *json.Stringify, message: Message) json.Stringify.Error!void {
    try ws.beginObject();
    try ws.objectField("type");
    switch (message) {
        .invokefunction => |m| {
            try ws.write("invokefunction");
            try ws.objectField("invocation_id");
            try writeOptString(ws, m.invocation_id);
            try ws.objectField("function_id");
            try ws.write(m.function_id);
            try ws.objectField("data");
            try ws.write(m.data);
            try ws.objectField("traceparent");
            try writeOptString(ws, m.traceparent);
            try ws.objectField("baggage");
            try writeOptString(ws, m.baggage);
            try ws.objectField("action");
            try writeAction(ws, m.action);
            try ws.objectField("metadata");
            try writeOptValue(ws, m.metadata);
        },
        .invocationresult => |m| {
            try ws.write("invocationresult");
            try ws.objectField("invocation_id");
            try ws.write(m.invocation_id);
            try ws.objectField("function_id");
            try ws.write(m.function_id);
            try ws.objectField("result");
            try writeOptValue(ws, m.result);
            try ws.objectField("error");
            try writeOptErrorBody(ws, m.err);
            try ws.objectField("traceparent");
            try writeOptString(ws, m.traceparent);
            try ws.objectField("baggage");
            try writeOptString(ws, m.baggage);
        },
        .ping => try ws.write("ping"),
        .pong => try ws.write("pong"),
        .workerregistered => |m| {
            try ws.write("workerregistered");
            try ws.objectField("worker_id");
            try ws.write(m.worker_id);
        },
    }
    try ws.endObject();
}

fn writeOptString(ws: *json.Stringify, opt: ?[]const u8) json.Stringify.Error!void {
    if (opt) |s| try ws.write(s) else try ws.write(@as(?[]const u8, null));
}

fn writeOptValue(ws: *json.Stringify, opt: ?json.Value) json.Stringify.Error!void {
    if (opt) |v| try ws.write(v) else try ws.write(@as(?[]const u8, null));
}

fn writeOptErrorBody(ws: *json.Stringify, opt: ?ErrorBody) json.Stringify.Error!void {
    if (opt) |e| {
        try ws.beginObject();
        try ws.objectField("code");
        try ws.write(e.code);
        try ws.objectField("message");
        try ws.write(e.message);
        try ws.objectField("stacktrace");
        try writeOptString(ws, e.stacktrace);
        try ws.endObject();
    } else try ws.write(@as(?[]const u8, null));
}

fn writeAction(ws: *json.Stringify, action: ?TriggerAction) json.Stringify.Error!void {
    if (action) |a| {
        switch (a) {
            .enqueue => |e| {
                try ws.beginObject();
                try ws.objectField("type");
                try ws.write("enqueue");
                try ws.objectField("queue");
                try ws.write(e.queue);
                try ws.endObject();
            },
            .void => {
                try ws.beginObject();
                try ws.objectField("type");
                try ws.write("void");
                try ws.endObject();
            },
        }
    } else try ws.write(@as(?[]const u8, null));
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

/// Recursive deep equality for `json.Value`. `testing.expectEqual` does not
/// deep-compare `ObjectMap`/`Array` (they are hash/list containers), so we walk them.
fn jsonEql(a: json.Value, b: json.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => a.bool == b.bool,
        .integer => a.integer == b.integer,
        .float => a.float == b.float,
        .number_string => std.mem.eql(u8, a.number_string, b.number_string),
        .string => std.mem.eql(u8, a.string, b.string),
        .array => blk: {
            const av = a.array.items;
            const bv = b.array.items;
            if (av.len != bv.len) break :blk false;
            for (av, bv) |x, y| if (!jsonEql(x, y)) break :blk false;
            break :blk true;
        },
        .object => blk: {
            if (a.object.count() != b.object.count()) break :blk false;
            var it = a.object.iterator();
            while (it.next()) |entry| {
                const ov = b.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!jsonEql(entry.value_ptr.*, ov)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn expectOptStringEq(a: ?[]const u8, b: ?[]const u8) !void {
    if (a == null or b == null) {
        try testing.expect(a == null and b == null);
        return;
    }
    try testing.expectEqualStrings(a.?, b.?);
}

fn expectOptValueEq(a: ?json.Value, b: ?json.Value) !void {
    if (a == null or b == null) {
        try testing.expect(a == null and b == null);
        return;
    }
    try testing.expect(jsonEql(a.?, b.?));
}

fn expectOptActionEq(a: ?TriggerAction, b: ?TriggerAction) !void {
    if (a == null or b == null) {
        try testing.expect(a == null and b == null);
        return;
    }
    try testing.expect(std.meta.activeTag(a.?) == std.meta.activeTag(b.?));
    switch (a.?) {
        .enqueue => |ax| try testing.expectEqualStrings(ax.queue, b.?.enqueue.queue),
        .void => {},
    }
}

fn expectOptErrorEq(a: ?ErrorBody, b: ?ErrorBody) !void {
    if (a == null or b == null) {
        try testing.expect(a == null and b == null);
        return;
    }
    try testing.expectEqualStrings(a.?.code, b.?.code);
    try testing.expectEqualStrings(a.?.message, b.?.message);
    try expectOptStringEq(a.?.stacktrace, b.?.stacktrace);
}

/// Asserts two messages are semantically equal (variant + every field), with deep
/// comparison for the arbitrary-JSON (`data`/`result`/`metadata`) fields.
fn expectSemanticEqual(a: Message, b: Message) !void {
    try testing.expect(std.meta.activeTag(a) == std.meta.activeTag(b));
    switch (a) {
        .invokefunction => |x| {
            const y = b.invokefunction;
            try testing.expectEqualStrings(x.function_id, y.function_id);
            try testing.expect(jsonEql(x.data, y.data));
            try expectOptStringEq(x.invocation_id, y.invocation_id);
            try expectOptStringEq(x.traceparent, y.traceparent);
            try expectOptStringEq(x.baggage, y.baggage);
            try expectOptValueEq(x.metadata, y.metadata);
            try expectOptActionEq(x.action, y.action);
        },
        .invocationresult => |x| {
            const y = b.invocationresult;
            try testing.expectEqualStrings(x.invocation_id, y.invocation_id);
            try testing.expectEqualStrings(x.function_id, y.function_id);
            try expectOptValueEq(x.result, y.result);
            try expectOptErrorEq(x.err, y.err);
            try expectOptStringEq(x.traceparent, y.traceparent);
            try expectOptStringEq(x.baggage, y.baggage);
        },
        .ping, .pong => {},
        .workerregistered => |x| {
            try testing.expectEqualStrings(x.worker_id, b.workerregistered.worker_id);
        },
    }
}

/// Parse -> serialize -> parse and assert the two parses are semantically equal.
fn roundTrip(allocator: Allocator, input: []const u8) !void {
    var p1 = try parseMessage(allocator, input);
    defer p1.deinit();
    const bytes = try serializeAlloc(allocator, p1.value);
    defer allocator.free(bytes);
    var p2 = try parseMessage(allocator, bytes);
    defer p2.deinit();
    try expectSemanticEqual(p1.value, p2.value);
}

// --- round-trip: invokefunction -------------------------------------------

test "invokefunction minimal round-trip (function_id + data only)" {
    const input =
        \\{"type":"invokefunction","function_id":"orders::validate","data":{}}
    ;
    var p = try parseMessage(testing.allocator, input);
    defer p.deinit();
    const m = p.value.invokefunction;
    try testing.expectEqualStrings("orders::validate", m.function_id);
    try testing.expect(m.data == .object);
    try testing.expectEqual(@as(usize, 0), m.data.object.count());
    try testing.expect(m.invocation_id == null);
    try testing.expect(m.traceparent == null);
    try testing.expect(m.baggage == null);
    try testing.expect(m.action == null);
    try testing.expect(m.metadata == null);

    try roundTrip(testing.allocator, input);
}

test "invokefunction full round-trip (all optional fields, enqueue action)" {
    const input =
        \\{"type":"invokefunction",
        \\ "invocation_id":"11111111-2222-3333-4444-555555555555",
        \\ "function_id":"orders::validate",
        \\ "data":{"order_id":42,"sku":["A","B"]},
        \\ "traceparent":"00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
        \\ "baggage":"zygos.session.id=abc",
        \\ "action":{"type":"enqueue","queue":"orders"},
        \\ "metadata":{"region":"eu-west-1"}}
    ;
    var p = try parseMessage(testing.allocator, input);
    defer p.deinit();
    const m = p.value.invokefunction;
    try testing.expectEqualStrings("11111111-2222-3333-4444-555555555555", m.invocation_id.?);
    try testing.expectEqualStrings("orders::validate", m.function_id);
    try testing.expectEqualStrings("00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01", m.traceparent.?);
    try testing.expectEqualStrings("zygos.session.id=abc", m.baggage.?);
    try testing.expect(m.action.? == .enqueue);
    try testing.expectEqualStrings("orders", m.action.?.enqueue.queue);
    try testing.expect(m.metadata != null and m.metadata.? == .object);

    try roundTrip(testing.allocator, input);
}

test "invokefunction void action round-trip" {
    const input =
        \\{"type":"invokefunction","function_id":"f","data":{},"action":{"type":"void"}}
    ;
    var p = try parseMessage(testing.allocator, input);
    defer p.deinit();
    try testing.expect(p.value.invokefunction.action.? == .void);
    try roundTrip(testing.allocator, input);
}

// --- round-trip: invocationresult -----------------------------------------

test "invocationresult success round-trip" {
    const input =
        \\{"type":"invocationresult",
        \\ "invocation_id":"11111111-2222-3333-4444-555555555555",
        \\ "function_id":"orders::validate",
        \\ "result":{"ok":true,"count":3},
        \\ "error":null,
        \\ "traceparent":"00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
        \\ "baggage":"k=v"}
    ;
    var p = try parseMessage(testing.allocator, input);
    defer p.deinit();
    const m = p.value.invocationresult;
    try testing.expect(m.result != null);
    try testing.expect(m.err == null);
    try testing.expectEqualStrings("00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01", m.traceparent.?);

    try roundTrip(testing.allocator, input);
}

test "invocationresult error variant round-trip" {
    const input =
        \\{"type":"invocationresult",
        \\ "invocation_id":"11111111-2222-3333-4444-555555555555",
        \\ "function_id":"orders::validate",
        \\ "result":null,
        \\ "error":{"code":"function_not_found","message":"no such function","stacktrace":null}}
    ;
    var p = try parseMessage(testing.allocator, input);
    defer p.deinit();
    const m = p.value.invocationresult;
    try testing.expect(m.result == null);
    try testing.expect(m.err != null);
    try testing.expectEqualStrings("function_not_found", m.err.?.code);
    try testing.expectEqualStrings("no such function", m.err.?.message);
    try testing.expect(m.err.?.stacktrace == null);

    try roundTrip(testing.allocator, input);
}

// --- round-trip: keepalive + workerregistered -----------------------------

test "ping round-trip" {
    try roundTrip(testing.allocator, "{\"type\":\"ping\"}");
}

test "pong round-trip" {
    try roundTrip(testing.allocator, "{\"type\":\"pong\"}");
}

test "workerregistered round-trip" {
    const input =
        \\{"type":"workerregistered","worker_id":"11111111-2222-3333-4444-555555555555"}
    ;
    var p = try parseMessage(testing.allocator, input);
    defer p.deinit();
    try testing.expectEqualStrings("11111111-2222-3333-4444-555555555555", p.value.workerregistered.worker_id);
    try roundTrip(testing.allocator, input);
}

// --- exact wire shape (pins the lowercase concatenated type tag) -----------

test "ping serializes the lowercase type tag exactly" {
    const bytes = try serializeAlloc(testing.allocator, .ping);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("{\"type\":\"ping\"}", bytes);
}

test "pong serializes the lowercase type tag exactly" {
    const bytes = try serializeAlloc(testing.allocator, .pong);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("{\"type\":\"pong\"}", bytes);
}

test "workerregistered serializes exact wire shape" {
    const msg = Message{ .workerregistered = .{ .worker_id = "w-1" } };
    const bytes = try serializeAlloc(testing.allocator, msg);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("{\"type\":\"workerregistered\",\"worker_id\":\"w-1\"}", bytes);
}

test "serialize writes to an arbitrary writer" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try serialize(.ping, &w);
    try testing.expectEqualStrings("{\"type\":\"ping\"}", w.buffered());
}

// --- error paths ----------------------------------------------------------

test "unknown type tag is rejected" {
    // registerservice is a real iii type outside PART 1 scope -> must be unknown here.
    try testing.expectError(error.UnknownMessageType, parseMessage(testing.allocator, "{\"type\":\"registerservice\",\"id\":\"svc-1\"}"));
}

test "malformed JSON is rejected" {
    try testing.expectError(error.MalformedJson, parseMessage(testing.allocator, "{not json"));
}

test "missing type tag is rejected" {
    try testing.expectError(error.MalformedJson, parseMessage(testing.allocator, "{\"foo\":1}"));
}

test "invokefunction without function_id is rejected" {
    try testing.expectError(error.MissingField, parseMessage(testing.allocator, "{\"type\":\"invokefunction\",\"data\":{}}"));
}

test "invokefunction without data is rejected" {
    try testing.expectError(error.MissingField, parseMessage(testing.allocator, "{\"type\":\"invokefunction\",\"function_id\":\"f\"}"));
}

test "object root required (non-object JSON is malformed)" {
    try testing.expectError(error.MalformedJson, parseMessage(testing.allocator, "42"));
}

// --- optional-field semantics: omitted == explicit null == absent ----------

test "optional field omitted vs explicit null both parse as absent" {
    const omitted =
        \\{"type":"invokefunction","function_id":"f","data":{}}
    ;
    const explicit_null =
        \\{"type":"invokefunction","function_id":"f","data":{},
        \\ "invocation_id":null,"traceparent":null,"baggage":null,
        \\ "action":null,"metadata":null}
    ;
    var pa = try parseMessage(testing.allocator, omitted);
    defer pa.deinit();
    var pb = try parseMessage(testing.allocator, explicit_null);
    defer pb.deinit();
    // Both forms must report every optional as absent (null).
    const a = pa.value.invokefunction;
    const b = pb.value.invokefunction;
    try testing.expect(a.invocation_id == null and b.invocation_id == null);
    try testing.expect(a.traceparent == null and b.traceparent == null);
    try testing.expect(a.baggage == null and b.baggage == null);
    try testing.expect(a.action == null and b.action == null);
    try testing.expect(a.metadata == null and b.metadata == null);
    // And the two parses must be semantically equal.
    try expectSemanticEqual(pa.value, pb.value);
}
