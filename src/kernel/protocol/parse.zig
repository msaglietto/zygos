//! Wire frame parsing (docs/PROTOCOL.md, S1): JSON text -> `Message`.
//! The dispatch is a flat switch over the lowercased `"type"` tag.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const json = std.json;
const types = @import("types.zig");
const ProtocolError = types.ProtocolError;
const ErrorBody = types.ErrorBody;
const TriggerAction = types.TriggerAction;
const HttpInvocationRef = types.HttpInvocationRef;
const StreamChannelRef = types.StreamChannelRef;
const Message = types.Message;

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
