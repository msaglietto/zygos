//! Wire message types (docs/PROTOCOL.md, S1). Pure data — parsing lives in
//! protocol/parse.zig, serialization in protocol/serialize.zig.

const std = @import("std");
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
