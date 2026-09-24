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
const json = std.json;

const types = @import("protocol/types.zig");
const parse_mod = @import("protocol/parse.zig");
const serialize_mod = @import("protocol/serialize.zig");

pub const ProtocolError = types.ProtocolError;
pub const ErrorBody = types.ErrorBody;
pub const TriggerAction = types.TriggerAction;
pub const HttpInvocationRef = types.HttpInvocationRef;
pub const StreamChannelRef = types.StreamChannelRef;
pub const Message = types.Message;

pub const parseMessage = parse_mod.parseMessage;
pub const parseChannelRef = parse_mod.parseChannelRef;
pub const serialize = serialize_mod.serialize;
pub const serializeAlloc = serialize_mod.serializeAlloc;
pub const writeChannelRef = serialize_mod.writeChannelRef;

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

fn expectOptHttpInvocationRefEq(a: ?HttpInvocationRef, b: ?HttpInvocationRef) !void {
    if (a == null or b == null) {
        try testing.expect(a == null and b == null);
        return;
    }
    try testing.expectEqualStrings(a.?.url, b.?.url);
    try testing.expectEqualStrings(a.?.method, b.?.method);
    try testing.expectEqual(a.?.timeout_ms, b.?.timeout_ms);
    try expectOptValueEq(a.?.headers, b.?.headers);
    try expectOptValueEq(a.?.auth, b.?.auth);
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

        // PART 2 — registration messages.
        .registerservice => |x| {
            const y = b.registerservice;
            try testing.expectEqualStrings(x.id, y.id);
            try testing.expectEqualStrings(x.name, y.name);
            try expectOptStringEq(x.description, y.description);
            try expectOptStringEq(x.parent_service_id, y.parent_service_id);
        },
        .registerfunction => |x| {
            const y = b.registerfunction;
            try testing.expectEqualStrings(x.id, y.id);
            try expectOptStringEq(x.description, y.description);
            try expectOptValueEq(x.request_format, y.request_format);
            try expectOptValueEq(x.response_format, y.response_format);
            try expectOptValueEq(x.metadata, y.metadata);
            try expectOptHttpInvocationRefEq(x.invocation, y.invocation);
        },
        .unregisterfunction => |x| {
            try testing.expectEqualStrings(x.id, b.unregisterfunction.id);
        },
        .registertriggertype => |x| {
            const y = b.registertriggertype;
            try testing.expectEqualStrings(x.id, y.id);
            try testing.expectEqualStrings(x.description, y.description);
            try expectOptValueEq(x.trigger_request_format, y.trigger_request_format);
            try expectOptValueEq(x.call_request_format, y.call_request_format);
        },
        .registertrigger => |x| {
            const y = b.registertrigger;
            try testing.expectEqualStrings(x.id, y.id);
            try testing.expectEqualStrings(x.trigger_type, y.trigger_type);
            try testing.expectEqualStrings(x.function_id, y.function_id);
            try testing.expect(jsonEql(x.config, y.config));
            try expectOptValueEq(x.metadata, y.metadata);
        },
        .unregistertrigger => |x| {
            const y = b.unregistertrigger;
            try testing.expectEqualStrings(x.id, y.id);
            try expectOptStringEq(x.trigger_type, y.trigger_type);
        },
        .triggerregistrationresult => |x| {
            const y = b.triggerregistrationresult;
            try testing.expectEqualStrings(x.id, y.id);
            try testing.expectEqualStrings(x.trigger_type, y.trigger_type);
            try testing.expectEqualStrings(x.function_id, y.function_id);
            try expectOptErrorEq(x.err, y.err);
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
    // A genuinely unknown tag must be rejected even though every iii type this
    // build understands (now including the registration messages) is accepted.
    try testing.expectError(error.UnknownMessageType, parseMessage(testing.allocator, "{\"type\":\"bogusmessage\",\"id\":\"svc-1\"}"));
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

// ===========================================================================
// PART 2 — registration messages
// ===========================================================================

// --- round-trip: registerservice ------------------------------------------

test "registerservice minimal round-trip (id, name, description only)" {
    const input =
        \\{"type":"registerservice","id":"svc-1","name":"my-svc","description":"does stuff"}
    ;
    var p = try parseMessage(testing.allocator, input);
    defer p.deinit();
    const m = p.value.registerservice;
    try testing.expectEqualStrings("svc-1", m.id);
    try testing.expectEqualStrings("my-svc", m.name);
    try testing.expectEqualStrings("does stuff", m.description.?);
    try testing.expect(m.parent_service_id == null);
    try roundTrip(testing.allocator, input);
}

test "registerservice full round-trip (parent_service_id populated)" {
    const input =
        \\{"type":"registerservice","id":"svc-2","name":"child","description":"nested","parent_service_id":"svc-1"}
    ;
    var p = try parseMessage(testing.allocator, input);
    defer p.deinit();
    try testing.expectEqualStrings("svc-1", p.value.registerservice.parent_service_id.?);
    try roundTrip(testing.allocator, input);
}

// --- round-trip: registerfunction -----------------------------------------

test "registerfunction minimal round-trip (id + description only)" {
    const input =
        \\{"type":"registerfunction","id":"content::classify","description":"classifies content"}
    ;
    var p = try parseMessage(testing.allocator, input);
    defer p.deinit();
    const m = p.value.registerfunction;
    try testing.expectEqualStrings("content::classify", m.id);
    try testing.expectEqualStrings("classifies content", m.description.?);
    try testing.expect(m.request_format == null);
    try testing.expect(m.response_format == null);
    try testing.expect(m.metadata == null);
    try testing.expect(m.invocation == null);
    try roundTrip(testing.allocator, input);
}

test "registerfunction full round-trip (formats, metadata, http invocation ref)" {
    const input =
        \\{"type":"registerfunction","id":"content::classify","description":"classifies content",
        \\ "request_format":{"type":"object"},
        \\ "response_format":{"type":"string"},
        \\ "metadata":{"version":"2"},
        \\ "invocation":{"url":"https://example.com/invoke","method":"POST","timeout_ms":30000,"headers":{"Authorization":"Bearer x"},"auth":null}}
    ;
    var p = try parseMessage(testing.allocator, input);
    defer p.deinit();
    const m = p.value.registerfunction;
    try testing.expect(m.request_format != null);
    try testing.expect(m.response_format != null);
    try testing.expect(m.metadata != null);
    try testing.expect(m.invocation != null);
    try testing.expectEqualStrings("https://example.com/invoke", m.invocation.?.url);
    try testing.expectEqualStrings("POST", m.invocation.?.method);
    try testing.expectEqual(@as(?i64, 30000), m.invocation.?.timeout_ms);
    try testing.expect(m.invocation.?.headers != null);
    try testing.expect(m.invocation.?.auth == null);
    try roundTrip(testing.allocator, input);
}

// --- round-trip: unregisterfunction ---------------------------------------

test "unregisterfunction round-trip" {
    const input =
        \\{"type":"unregisterfunction","id":"content::classify"}
    ;
    var p = try parseMessage(testing.allocator, input);
    defer p.deinit();
    try testing.expectEqualStrings("content::classify", p.value.unregisterfunction.id);
    try roundTrip(testing.allocator, input);
}

// --- round-trip: registertriggertype --------------------------------------

test "registertriggertype minimal round-trip (id + description only)" {
    const input =
        \\{"type":"registertriggertype","id":"cron","description":"cron schedules"}
    ;
    var p = try parseMessage(testing.allocator, input);
    defer p.deinit();
    const m = p.value.registertriggertype;
    try testing.expectEqualStrings("cron", m.id);
    try testing.expectEqualStrings("cron schedules", m.description);
    try testing.expect(m.trigger_request_format == null);
    try testing.expect(m.call_request_format == null);
    try roundTrip(testing.allocator, input);
}

test "registertriggertype full round-trip (formats populated)" {
    const input =
        \\{"type":"registertriggertype","id":"cron","description":"cron schedules",
        \\ "trigger_request_format":{"type":"object"},
        \\ "call_request_format":{"type":"object"}}
    ;
    var p = try parseMessage(testing.allocator, input);
    defer p.deinit();
    const m = p.value.registertriggertype;
    try testing.expect(m.trigger_request_format != null);
    try testing.expect(m.call_request_format != null);
    try roundTrip(testing.allocator, input);
}

// --- round-trip: registertrigger ------------------------------------------

test "registertrigger minimal round-trip (metadata omitted)" {
    const input =
        \\{"type":"registertrigger","id":"t-1","trigger_type":"cron",
        \\ "function_id":"jobs::nightly","config":{"schedule":"0 3 * * *"}}
    ;
    var p = try parseMessage(testing.allocator, input);
    defer p.deinit();
    const m = p.value.registertrigger;
    try testing.expectEqualStrings("t-1", m.id);
    try testing.expectEqualStrings("cron", m.trigger_type);
    try testing.expectEqualStrings("jobs::nightly", m.function_id);
    try testing.expect(m.config == .object);
    try testing.expect(m.metadata == null);
    try roundTrip(testing.allocator, input);
}

test "registertrigger full round-trip (metadata populated)" {
    const input =
        \\{"type":"registertrigger","id":"t-1","trigger_type":"cron",
        \\ "function_id":"jobs::nightly","config":{"schedule":"0 3 * * *"},
        \\ "metadata":{"owner":"ops"}}
    ;
    var p = try parseMessage(testing.allocator, input);
    defer p.deinit();
    try testing.expect(p.value.registertrigger.metadata != null);
    try roundTrip(testing.allocator, input);
}

// --- round-trip: unregistertrigger ----------------------------------------

test "unregistertrigger minimal round-trip (trigger_type omitted -> null)" {
    const input =
        \\{"type":"unregistertrigger","id":"t-1"}
    ;
    var p = try parseMessage(testing.allocator, input);
    defer p.deinit();
    const m = p.value.unregistertrigger;
    try testing.expectEqualStrings("t-1", m.id);
    try testing.expect(m.trigger_type == null);
    try roundTrip(testing.allocator, input);
}

test "unregistertrigger full round-trip (trigger_type populated)" {
    const input =
        \\{"type":"unregistertrigger","id":"t-1","trigger_type":"cron"}
    ;
    var p = try parseMessage(testing.allocator, input);
    defer p.deinit();
    try testing.expectEqualStrings("cron", p.value.unregistertrigger.trigger_type.?);
    try roundTrip(testing.allocator, input);
}

// --- round-trip: triggerregistrationresult --------------------------------

test "triggerregistrationresult success round-trip (error null)" {
    const input =
        \\{"type":"triggerregistrationresult","id":"t-1","trigger_type":"cron",
        \\ "function_id":"jobs::nightly","error":null}
    ;
    var p = try parseMessage(testing.allocator, input);
    defer p.deinit();
    const m = p.value.triggerregistrationresult;
    try testing.expectEqualStrings("t-1", m.id);
    try testing.expectEqualStrings("cron", m.trigger_type);
    try testing.expectEqualStrings("jobs::nightly", m.function_id);
    try testing.expect(m.err == null);
    try roundTrip(testing.allocator, input);
}

test "triggerregistrationresult error variant round-trip" {
    const input =
        \\{"type":"triggerregistrationresult","id":"t-1","trigger_type":"cron",
        \\ "function_id":"jobs::nightly",
        \\ "error":{"code":"bad_config","message":"invalid schedule","stacktrace":null}}
    ;
    var p = try parseMessage(testing.allocator, input);
    defer p.deinit();
    const m = p.value.triggerregistrationresult;
    try testing.expect(m.err != null);
    try testing.expectEqualStrings("bad_config", m.err.?.code);
    try testing.expectEqualStrings("invalid schedule", m.err.?.message);
    try testing.expect(m.err.?.stacktrace == null);
    try roundTrip(testing.allocator, input);
}

// --- exact wire shape (pins type tag + field order + null emission) --------

test "unregisterfunction serializes exact wire shape" {
    const msg = Message{ .unregisterfunction = .{ .id = "content::classify" } };
    const bytes = try serializeAlloc(testing.allocator, msg);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings(
        "{\"type\":\"unregisterfunction\",\"id\":\"content::classify\"}",
        bytes,
    );
}

test "registertrigger serializes exact wire shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Build the `config` object via parse (same path the kernel uses), then pin
    // the exact serialized wire shape: type tag, field order, null metadata.
    const config = try json.parseFromSliceLeaky(json.Value, arena.allocator(),
        \\{"schedule":"0 3 * * *"}
    , .{ .allocate = .alloc_always });
    const msg = Message{ .registertrigger = .{
        .id = "t-1",
        .trigger_type = "cron",
        .function_id = "jobs::nightly",
        .config = config,
        .metadata = null,
    } };
    const bytes = try serializeAlloc(testing.allocator, msg);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings(
        "{\"type\":\"registertrigger\",\"id\":\"t-1\",\"trigger_type\":\"cron\",\"function_id\":\"jobs::nightly\",\"config\":{\"schedule\":\"0 3 * * *\"},\"metadata\":null}",
        bytes,
    );
}

// --- error paths: registration --------------------------------------------

test "registerfunction without id is rejected" {
    try testing.expectError(error.MissingField, parseMessage(testing.allocator, "{\"type\":\"registerfunction\",\"description\":\"no id\"}"));
}

test "registertrigger without function_id is rejected" {
    try testing.expectError(error.MissingField, parseMessage(testing.allocator, "{\"type\":\"registertrigger\",\"id\":\"t-1\",\"trigger_type\":\"cron\",\"config\":{}}"));
}

// --- StreamChannelRef (sub-type, rides inside payloads, not a Message) -----

test "StreamChannelRef parses both read and write directions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const read_v = try json.parseFromSliceLeaky(json.Value, a,
        \\{"channel_id":"ch-1","access_key":"secret","direction":"read"}
    , .{ .allocate = .alloc_always });
    const read_ref = try parseChannelRef(read_v.object);
    try testing.expectEqualStrings("ch-1", read_ref.channel_id);
    try testing.expectEqualStrings("secret", read_ref.access_key);
    try testing.expect(read_ref.direction == .read);

    const write_v = try json.parseFromSliceLeaky(json.Value, a,
        \\{"channel_id":"ch-2","access_key":"k","direction":"write"}
    , .{ .allocate = .alloc_always });
    const write_ref = try parseChannelRef(write_v.object);
    try testing.expect(write_ref.direction == .write);
}

test "StreamChannelRef rejects unknown direction string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try json.parseFromSliceLeaky(json.Value, arena.allocator(),
        \\{"channel_id":"ch-1","access_key":"secret","direction":"sideways"}
    , .{ .allocate = .alloc_always });
    try testing.expectError(error.InvalidFieldType, parseChannelRef(v.object));
}

test "StreamChannelRef rejects missing access_key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try json.parseFromSliceLeaky(json.Value, arena.allocator(),
        \\{"channel_id":"ch-1","direction":"read"}
    , .{ .allocate = .alloc_always });
    try testing.expectError(error.MissingField, parseChannelRef(v.object));
}

test "StreamChannelRef round-trips via parse/write helpers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\{"channel_id":"ch-7","access_key":"topsecret","direction":"write"}
    ;
    const v1 = try json.parseFromSliceLeaky(json.Value, a, input, .{ .allocate = .alloc_always });
    const ref1 = try parseChannelRef(v1.object);

    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var ws: json.Stringify = .{ .writer = &w, .options = .{ .whitespace = .minified } };
    try writeChannelRef(&ws, ref1);

    // re-parse the serialized bytes and compare structurally
    const v2 = try json.parseFromSliceLeaky(json.Value, a, w.buffered(), .{ .allocate = .alloc_always });
    const ref2 = try parseChannelRef(v2.object);
    try testing.expectEqualStrings(ref1.channel_id, ref2.channel_id);
    try testing.expectEqualStrings(ref1.access_key, ref2.access_key);
    try testing.expect(ref1.direction == ref2.direction);
}

// --- iii serde leniency (verified against ~/Projects/iii engine/src/protocol.rs) ---
// iii declares these fields Option<_> / #[serde(default)]; the unmodified Node
// SDK may omit them, so S6 requires the lenient parse. PROTOCOL.md examples
// show populated frames and stay accurate; optionality follows the iii source.

test "registerfunction without description parses as absent" {
    const input =
        \\{"type":"registerfunction","id":"f"}
    ;
    var p = try parseMessage(testing.allocator, input);
    defer p.deinit();
    try testing.expect(p.value.registerfunction.description == null);
    try roundTrip(testing.allocator, input);
}

test "registerservice tolerates omitted name and description" {
    const input =
        \\{"type":"registerservice","id":"svc-1"}
    ;
    var p = try parseMessage(testing.allocator, input);
    defer p.deinit();
    try testing.expectEqualStrings("", p.value.registerservice.name);
    try testing.expect(p.value.registerservice.description == null);
    try roundTrip(testing.allocator, input);
}

test "http invocation ref method defaults to POST when omitted" {
    const input =
        \\{"type":"registerfunction","id":"f","invocation":{"url":"https://x.example/fn"}}
    ;
    var p = try parseMessage(testing.allocator, input);
    defer p.deinit();
    try testing.expectEqualStrings("POST", p.value.registerfunction.invocation.?.method);
    try roundTrip(testing.allocator, input);
}
