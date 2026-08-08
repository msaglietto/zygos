//! Wire frame serialization (docs/PROTOCOL.md, S1): `Message` -> minified
//! JSON text. Field order mirrors the documented examples.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const types = @import("types.zig");
const ProtocolError = types.ProtocolError;
const ErrorBody = types.ErrorBody;
const TriggerAction = types.TriggerAction;
const HttpInvocationRef = types.HttpInvocationRef;
const StreamChannelRef = types.StreamChannelRef;
const Message = types.Message;

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
