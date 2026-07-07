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

/// External-HTTP invocation reference: a function served by HTTP rather than a
/// WebSocket worker. Rides as the optional `invocation` field on `registerfunction`.
/// Wire (PROTOCOL.md): `{"url":"...","method":"POST","timeout_ms":30000,"headers":{},"auth":null}`.
pub const HttpInvocationRef = struct {
    url: []const u8,
    /// iii: `#[serde(default = "default_http_method")]` — omitted means POST.
    method: []const u8 = "POST",
    timeout_ms: ?i64 = null,
    headers: ?json.Value = null,
    auth: ?json.Value = null,
};

/// Capability handle for byte channels. Rides inside payloads — it is NOT a
/// `Message` variant. Wire (PROTOCOL.md "Sub-types"):
/// `{"channel_id":"<id>","access_key":"<secret>","direction":"read"}` (or "write").
/// `direction` must be exactly `"read"`/`"write"`; any other string is rejected.
pub const StreamChannelRef = struct {
    channel_id: []const u8,
    access_key: []const u8,
    direction: Direction,

    pub const Direction = enum { read, write };
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

    // PART 2 — registration messages (PROTOCOL.md "Engine ← Worker (registration)").
    registerservice: RegisterService,
    registerfunction: RegisterFunction,
    unregisterfunction: UnregisterFunction,
    registertriggertype: RegisterTriggerType,
    registertrigger: RegisterTrigger,
    unregistertrigger: UnregisterTrigger,
    triggerregistrationresult: TriggerRegistrationResult,

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

    // --- PART 2 payload structs ------------------------------------------
    // Field order mirrors docs/PROTOCOL.md so the serializer emits documented order.

    pub const RegisterService = struct {
        id: []const u8,
        /// iii: `#[serde(default)] String` — omitted parses as "".
        name: []const u8 = "",
        /// iii: `Option<String>` — the Node SDK may omit it.
        description: ?[]const u8 = null,
        parent_service_id: ?[]const u8 = null,
    };

    pub const RegisterFunction = struct {
        id: []const u8,
        /// iii: `Option<String>` — the Node SDK may omit it.
        description: ?[]const u8 = null,
        request_format: ?json.Value = null,
        response_format: ?json.Value = null,
        metadata: ?json.Value = null,
        invocation: ?HttpInvocationRef = null,
    };

    pub const UnregisterFunction = struct {
        id: []const u8,
    };

    pub const RegisterTriggerType = struct {
        id: []const u8,
        description: []const u8,
        trigger_request_format: ?json.Value = null,
        call_request_format: ?json.Value = null,
    };

    pub const RegisterTrigger = struct {
        id: []const u8,
        trigger_type: []const u8,
        function_id: []const u8,
        config: json.Value,
        metadata: ?json.Value = null,
    };

    pub const UnregisterTrigger = struct {
        id: []const u8,
        trigger_type: ?[]const u8 = null,
    };

    pub const TriggerRegistrationResult = struct {
        id: []const u8,
        trigger_type: []const u8,
        function_id: []const u8,
        // Wire key is "error"; the field is `err` because `error` is a Zig keyword,
        // exactly mirroring the InvocationResult pattern.
        err: ?ErrorBody = null,
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
    } else if (std.mem.eql(u8, tag, "registerservice")) {
        return .{ .registerservice = try parseRegisterService(obj) };
    } else if (std.mem.eql(u8, tag, "registerfunction")) {
        return .{ .registerfunction = try parseRegisterFunction(obj) };
    } else if (std.mem.eql(u8, tag, "unregisterfunction")) {
        return .{ .unregisterfunction = try parseUnregisterFunction(obj) };
    } else if (std.mem.eql(u8, tag, "registertriggertype")) {
        return .{ .registertriggertype = try parseRegisterTriggerType(obj) };
    } else if (std.mem.eql(u8, tag, "registertrigger")) {
        return .{ .registertrigger = try parseRegisterTrigger(obj) };
    } else if (std.mem.eql(u8, tag, "unregistertrigger")) {
        return .{ .unregistertrigger = try parseUnregisterTrigger(obj) };
    } else if (std.mem.eql(u8, tag, "triggerregistrationresult")) {
        return .{ .triggerregistrationresult = try parseTriggerRegistrationResult(obj) };
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

// --- PART 2 registration parsers ------------------------------------------

fn parseRegisterService(obj: json.ObjectMap) ProtocolError!Message.RegisterService {
    return .{
        .id = try reqString(obj, "id"),
        .name = (try optString(obj, "name")) orelse "",
        .description = try optString(obj, "description"),
        .parent_service_id = try optString(obj, "parent_service_id"),
    };
}

fn parseRegisterFunction(obj: json.ObjectMap) ProtocolError!Message.RegisterFunction {
    return .{
        .id = try reqString(obj, "id"),
        .description = try optString(obj, "description"),
        .request_format = optValue(obj, "request_format"),
        .response_format = optValue(obj, "response_format"),
        .metadata = optValue(obj, "metadata"),
        .invocation = try optHttpInvocationRef(obj, "invocation"),
    };
}

fn parseUnregisterFunction(obj: json.ObjectMap) ProtocolError!Message.UnregisterFunction {
    return .{ .id = try reqString(obj, "id") };
}

fn parseRegisterTriggerType(obj: json.ObjectMap) ProtocolError!Message.RegisterTriggerType {
    return .{
        .id = try reqString(obj, "id"),
        .description = try reqString(obj, "description"),
        .trigger_request_format = optValue(obj, "trigger_request_format"),
        .call_request_format = optValue(obj, "call_request_format"),
    };
}

fn parseRegisterTrigger(obj: json.ObjectMap) ProtocolError!Message.RegisterTrigger {
    return .{
        .id = try reqString(obj, "id"),
        .trigger_type = try reqString(obj, "trigger_type"),
        .function_id = try reqString(obj, "function_id"),
        .config = try reqValue(obj, "config"),
        .metadata = optValue(obj, "metadata"),
    };
}

fn parseUnregisterTrigger(obj: json.ObjectMap) ProtocolError!Message.UnregisterTrigger {
    return .{
        .id = try reqString(obj, "id"),
        .trigger_type = try optString(obj, "trigger_type"),
    };
}

fn parseTriggerRegistrationResult(obj: json.ObjectMap) ProtocolError!Message.TriggerRegistrationResult {
    return .{
        .id = try reqString(obj, "id"),
        .trigger_type = try reqString(obj, "trigger_type"),
        .function_id = try reqString(obj, "function_id"),
        .err = try optErrorBody(obj, "error"),
    };
}

fn parseHttpInvocationRef(o: json.ObjectMap) ProtocolError!HttpInvocationRef {
    return .{
        .url = try reqString(o, "url"),
        .method = (try optString(o, "method")) orelse "POST",
        .timeout_ms = try optInt(o, "timeout_ms"),
        .headers = optValue(o, "headers"),
        .auth = optValue(o, "auth"),
    };
}

/// Parse a `StreamChannelRef` from a JSON object. The `"direction"` string must
/// be exactly `"read"` or `"write"`; anything else is `InvalidFieldType`.
pub fn parseChannelRef(obj: json.ObjectMap) ProtocolError!StreamChannelRef {
    const dir = try reqString(obj, "direction");
    const direction: StreamChannelRef.Direction = if (std.mem.eql(u8, dir, "read"))
        .read
    else if (std.mem.eql(u8, dir, "write"))
        .write
    else
        return error.InvalidFieldType;
    return .{
        .channel_id = try reqString(obj, "channel_id"),
        .access_key = try reqString(obj, "access_key"),
        .direction = direction,
    };
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

fn optInt(obj: json.ObjectMap, key: []const u8) ProtocolError!?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .null => null,
        .integer => |i| i,
        else => error.InvalidFieldType,
    };
}

fn optHttpInvocationRef(obj: json.ObjectMap, key: []const u8) ProtocolError!?HttpInvocationRef {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .null => null,
        .object => |o| try parseHttpInvocationRef(o),
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

        // PART 2 — registration messages (field order per docs/PROTOCOL.md).
        .registerservice => |m| {
            try ws.write("registerservice");
            try ws.objectField("id");
            try ws.write(m.id);
            try ws.objectField("name");
            try ws.write(m.name);
            try ws.objectField("description");
            try writeOptString(ws, m.description);
            try ws.objectField("parent_service_id");
            try writeOptString(ws, m.parent_service_id);
        },
        .registerfunction => |m| {
            try ws.write("registerfunction");
            try ws.objectField("id");
            try ws.write(m.id);
            try ws.objectField("description");
            try writeOptString(ws, m.description);
            try ws.objectField("request_format");
            try writeOptValue(ws, m.request_format);
            try ws.objectField("response_format");
            try writeOptValue(ws, m.response_format);
            try ws.objectField("metadata");
            try writeOptValue(ws, m.metadata);
            try ws.objectField("invocation");
            try writeOptHttpInvocationRef(ws, m.invocation);
        },
        .unregisterfunction => |m| {
            try ws.write("unregisterfunction");
            try ws.objectField("id");
            try ws.write(m.id);
        },
        .registertriggertype => |m| {
            try ws.write("registertriggertype");
            try ws.objectField("id");
            try ws.write(m.id);
            try ws.objectField("description");
            try ws.write(m.description);
            try ws.objectField("trigger_request_format");
            try writeOptValue(ws, m.trigger_request_format);
            try ws.objectField("call_request_format");
            try writeOptValue(ws, m.call_request_format);
        },
        .registertrigger => |m| {
            try ws.write("registertrigger");
            try ws.objectField("id");
            try ws.write(m.id);
            try ws.objectField("trigger_type");
            try ws.write(m.trigger_type);
            try ws.objectField("function_id");
            try ws.write(m.function_id);
            try ws.objectField("config");
            try ws.write(m.config);
            try ws.objectField("metadata");
            try writeOptValue(ws, m.metadata);
        },
        .unregistertrigger => |m| {
            try ws.write("unregistertrigger");
            try ws.objectField("id");
            try ws.write(m.id);
            try ws.objectField("trigger_type");
            try writeOptString(ws, m.trigger_type);
        },
        .triggerregistrationresult => |m| {
            try ws.write("triggerregistrationresult");
            try ws.objectField("id");
            try ws.write(m.id);
            try ws.objectField("trigger_type");
            try ws.write(m.trigger_type);
            try ws.objectField("function_id");
            try ws.write(m.function_id);
            try ws.objectField("error");
            try writeOptErrorBody(ws, m.err);
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

fn writeOptInt(ws: *json.Stringify, opt: ?i64) json.Stringify.Error!void {
    if (opt) |i| try ws.write(i) else try ws.write(@as(?[]const u8, null));
}

fn writeOptHttpInvocationRef(ws: *json.Stringify, opt: ?HttpInvocationRef) json.Stringify.Error!void {
    if (opt) |r| {
        try ws.beginObject();
        try ws.objectField("url");
        try ws.write(r.url);
        try ws.objectField("method");
        try ws.write(r.method);
        try ws.objectField("timeout_ms");
        try writeOptInt(ws, r.timeout_ms);
        try ws.objectField("headers");
        try writeOptValue(ws, r.headers);
        try ws.objectField("auth");
        try writeOptValue(ws, r.auth);
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

/// Serialize a `StreamChannelRef` to its wire object. Field order mirrors
/// docs/PROTOCOL.md: `channel_id`, `access_key`, `direction`.
pub fn writeChannelRef(ws: *json.Stringify, ref: StreamChannelRef) json.Stringify.Error!void {
    try ws.beginObject();
    try ws.objectField("channel_id");
    try ws.write(ref.channel_id);
    try ws.objectField("access_key");
    try ws.write(ref.access_key);
    try ws.objectField("direction");
    const dir_str: []const u8 = switch (ref.direction) {
        .read => "read",
        .write => "write",
    };
    try ws.write(dir_str);
    try ws.endObject();
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
