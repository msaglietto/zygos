//! Offline AG-UI 1.0 projection of a zygos `events.jsonl`, plus the
//! self-contained HTML viewer that inlines it. Pure: text in, text out, no
//! IO, no network. Same input gives byte-identical output.

const std = @import("std");
const json = std.json;
const trace = @import("trace.zig");
const trace_event = @import("trace_event.zig");
const TraceEvent = trace_event.TraceEvent;

pub const Error = error{OutOfMemory};

/// events.jsonl text in, AG-UI JSONL out, one event per `\n`-terminated
/// line. Lines `trace_event.parse` rejects are skipped.
pub fn project(arena: std.mem.Allocator, jsonl: []const u8, thread_id: []const u8) Error![]const u8 {
    var p: Projector = .{
        .arena = arena,
        .thread_id = thread_id,
        .run_id = try std.fmt.allocPrint(arena, "{s}:1", .{thread_id}),
    };
    var lines = std.mem.splitScalar(u8, jsonl, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        const parsed = trace_event.parse(arena, line) orelse continue;
        try p.apply(parsed);
    }
    try p.finish();
    return p.out.items;
}

const Route = struct { provider: []const u8, model: []const u8 };

/// One open role turn, projected as an AG-UI subagent run. `seq` is unique
/// per lane; `id` repeats if a resumed log restarts the same role turn.
const Lane = struct { seq: u32, id: []const u8, name: []const u8, route: ?Route = null };

const PendingCall = struct { id: []const u8, lane: ?u32, tool: []const u8 };

const PlanItem = struct { index: i64, desc: []const u8, done: bool, attempts: i64 };

const Bucket = struct { route: Route, input: i64 = 0, output: i64 = 0 };

const Extra = struct { lane: ?[]const u8 = null, meta: ?[]const u8 = null };

const Projector = struct {
    arena: std.mem.Allocator,
    thread_id: []const u8,
    run_id: []const u8,
    out: std.ArrayList(u8) = .empty,
    started: bool = false,
    last_ts: i64 = 0,
    lanes: std.ArrayList(Lane) = .empty,
    lane_seq: u32 = 0,
    pending: std.ArrayList(PendingCall) = .empty,
    calls: u32 = 0,
    orphans: u32 = 0,
    steers: u32 = 0,
    plan: std.ArrayList(PlanItem) = .empty,
    plan_total: i64 = 0,
    step: ?[]const u8 = null,
    /// Non-null once any `mission` event is seen: the log is a mission log
    /// and this is the latest state.
    mission_state: ?[]const u8 = null,
    failed_reason: ?[]const u8 = null,
    run_route: ?Route = null,
    buckets: std.ArrayList(Bucket) = .empty,
    input_total: i64 = 0,
    output_total: i64 = 0,
    turn_end: ?TraceEvent.TurnEnd = null,

    fn apply(p: *Projector, parsed: trace_event.Parsed) Error!void {
        const a = p.arena;
        const ts = parsed.ts;
        if (!p.started) try p.runStarted(ts);
        p.last_ts = ts;
        switch (parsed.event) {
            .mission => |m| {
                if (p.step) |open| if (std.mem.eql(u8, open, m.from))
                    try p.emit("STEP_FINISHED", ts, ",\"stepName\":{f}", .{jstr(m.from)}, .{});
                try p.emit("STEP_STARTED", ts, ",\"stepName\":{f}", .{jstr(m.to)}, .{});
                p.step = m.to;
                p.mission_state = m.to;
                try p.emit(
                    "ACTIVITY_SNAPSHOT",
                    ts,
                    ",\"messageId\":\"zygos.mission\",\"activityType\":\"zygos.mission\",\"content\":{{\"state\":{f},\"from\":{f},\"role_turns\":{d},\"tasks_done\":{d},\"tasks\":{d}}},\"replace\":true",
                    .{ jstr(m.to), jstr(m.from), m.role_turns, m.tasks_done, m.tasks },
                    .{},
                );
                if (std.mem.eql(u8, m.to, "planning")) {
                    p.plan.clearRetainingCapacity();
                    p.plan_total = 0;
                }
            },
            .role_start => |r| {
                const id = try std.fmt.allocPrint(a, "{s}:{d}", .{ r.role, r.role_turn });
                try p.emit(
                    "SUBAGENT_STARTED",
                    ts,
                    ",\"subagentRunId\":{f},\"name\":{f},\"description\":{f}",
                    .{ jstr(id), jstr(r.role), jstr(try redact(a, r.content)) },
                    .{ .meta = try std.fmt.allocPrint(a, "\"role_turn\":{d},\"tools\":{}", .{ r.role_turn, r.tools }) },
                );
                p.lane_seq += 1;
                try p.lanes.append(a, .{ .seq = p.lane_seq, .id = id, .name = r.role });
            },
            .role_end => |r| {
                const at = p.laneNamed(r.role) orelse return;
                const lane = p.lanes.items[at];
                const reason = if (r.reason) |s| try redact(a, s) else null;
                if (std.mem.eql(u8, r.outcome, "failed")) {
                    p.failed_reason = reason;
                    try p.emit(
                        "SUBAGENT_ERROR",
                        ts,
                        ",\"subagentRunId\":{f},\"message\":{f}",
                        .{ jstr(lane.id), jstr(reason orelse r.outcome) },
                        .{ .meta = "\"outcome\":\"failed\"" },
                    );
                } else {
                    const meta = if (reason) |why|
                        try std.fmt.allocPrint(a, "\"outcome\":{f},\"reason\":{f}", .{ jstr(r.outcome), jstr(why) })
                    else
                        try std.fmt.allocPrint(a, "\"outcome\":{f}", .{jstr(r.outcome)});
                    try p.emit("SUBAGENT_FINISHED", ts, ",\"subagentRunId\":{f}", .{jstr(lane.id)}, .{ .meta = meta });
                }
                _ = p.lanes.orderedRemove(at);
                var i: usize = 0;
                while (i < p.pending.items.len) {
                    if (p.pending.items[i].lane == lane.seq) _ = p.pending.orderedRemove(i) else i += 1;
                }
            },
            .task_start => |t| try p.planEvent(ts, t, false),
            .task_done => |t| try p.planEvent(ts, t, true),
            .step => |s| {
                try p.emit(
                    "CUSTOM",
                    ts,
                    ",\"name\":\"zygos.route\",\"value\":{{\"step\":{d},\"provider\":{f},\"model\":{f},\"attempt\":{d}}}",
                    .{ s.step, jstr(s.provider), jstr(s.model), s.attempt },
                    .{ .lane = p.laneId() },
                );
                const route: Route = .{ .provider = s.provider, .model = s.model };
                if (p.top()) |lane| lane.route = route else p.run_route = route;
            },
            .tool_call => |tc| {
                p.calls += 1;
                const id = try std.fmt.allocPrint(a, "call-{d}", .{p.calls});
                const lane = p.laneId();
                try p.emit(
                    "TOOL_CALL_START",
                    ts,
                    ",\"toolCallId\":{f},\"toolCallName\":{f}",
                    .{ jstr(id), jstr(tc.tool) },
                    .{ .lane = lane, .meta = try std.fmt.allocPrint(a, "\"step\":{d},\"clipped\":{}", .{ tc.step, endsWithClipSuffix(tc.input) }) },
                );
                try p.emit("TOOL_CALL_ARGS", ts, ",\"toolCallId\":{f},\"delta\":{f}", .{ jstr(id), jstr(try redact(a, tc.input)) }, .{ .lane = lane });
                try p.emit("TOOL_CALL_END", ts, ",\"toolCallId\":{f}", .{jstr(id)}, .{ .lane = lane });
                try p.pending.append(a, .{ .id = id, .lane = p.laneSeq(), .tool = tc.tool });
            },
            .tool_result => |tr| {
                const id = p.claimCall(tr.tool) orelse blk: {
                    p.orphans += 1;
                    break :blk try std.fmt.allocPrint(a, "result-{d}", .{p.orphans});
                };
                const clipped = tr.bytes > trace.max_field_bytes or endsWithClipSuffix(tr.output);
                var meta = try std.fmt.allocPrint(a, "\"step\":{d},\"is_error\":{},\"bytes\":{d},\"clipped\":{}", .{ tr.step, tr.is_error, tr.bytes, clipped });
                if (denial(tr)) |by| meta = try std.fmt.allocPrint(a, "{s},\"denied\":\"{s}\"", .{ meta, by });
                try p.emit(
                    "TOOL_CALL_RESULT",
                    ts,
                    ",\"messageId\":\"{s}:result\",\"toolCallId\":{f},\"content\":{f},\"role\":\"tool\"",
                    .{ id, jstr(id), jstr(try redact(a, tr.output)) },
                    .{ .lane = p.laneId(), .meta = meta },
                );
            },
            .usage => |u| {
                p.input_total += u.input_tokens;
                p.output_total += u.output_tokens;
                const bucket = try p.bucketFor(p.currentRoute());
                bucket.input += u.input_tokens;
                bucket.output += u.output_tokens;
                try p.emit(
                    "STATE_SNAPSHOT",
                    ts,
                    ",\"snapshot\":{{\"usage\":{{\"input_tokens\":{d},\"output_tokens\":{d}}}}}",
                    .{ p.input_total, p.output_total },
                    .{ .lane = p.laneId(), .meta = try std.fmt.allocPrint(a, "\"step\":{d},\"input_tokens\":{d},\"output_tokens\":{d}", .{ u.step, u.input_tokens, u.output_tokens }) },
                );
            },
            .turn_end => |te| {
                const err = if (te.err) |e| try redact(a, e) else null;
                const err_field = if (err) |e| try std.fmt.allocPrint(a, ",\"error\":{f}", .{jstr(e)}) else "";
                try p.emit(
                    "CUSTOM",
                    ts,
                    ",\"name\":\"zygos.turn_end\",\"value\":{{\"stop\":{f},\"steps\":{d}{s}}}",
                    .{ jstr(te.stop), te.steps, err_field },
                    .{ .lane = p.laneId() },
                );
                p.turn_end = .{ .turn_id = te.turn_id, .stop = te.stop, .steps = te.steps, .err = err };
            },
            .steer => |st| {
                p.steers += 1;
                const id = try std.fmt.allocPrint(a, "steer-{d}", .{p.steers});
                try p.emit("TEXT_MESSAGE_START", ts, ",\"messageId\":{f},\"role\":\"user\"", .{jstr(id)}, .{});
                try p.emit("TEXT_MESSAGE_CONTENT", ts, ",\"messageId\":{f},\"delta\":{f}", .{ jstr(id), jstr(try redact(a, st.text)) }, .{});
                try p.emit("TEXT_MESSAGE_END", ts, ",\"messageId\":{f}", .{jstr(id)}, .{});
            },
        }
    }

    /// AG-UI forbids inventing a finish: a live or truncated log ends
    /// without RUN_FINISHED or RUN_ERROR.
    fn finish(p: *Projector) Error!void {
        if (!p.started) try p.runStarted(0);
        const ts = p.last_ts;
        const usage = try p.usageField();
        if (p.mission_state) |state| {
            if (std.mem.eql(u8, state, "done")) {
                try p.emit("STEP_FINISHED", ts, ",\"stepName\":\"done\"", .{}, .{});
                try p.emit(
                    "RUN_FINISHED",
                    ts,
                    ",\"threadId\":{f},\"runId\":{f},\"outcome\":{{\"type\":\"success\"}},\"result\":{{\"state\":\"done\"}}{s}",
                    .{ jstr(p.thread_id), jstr(p.run_id), usage },
                    .{},
                );
            } else if (std.mem.eql(u8, state, "failed")) {
                try p.emit("STEP_FINISHED", ts, ",\"stepName\":\"failed\"", .{}, .{});
                try p.emit(
                    "RUN_ERROR",
                    ts,
                    ",\"message\":{f},\"code\":\"mission_failed\"{s}",
                    .{ jstr(p.failed_reason orelse "mission failed"), usage },
                    .{},
                );
            }
            return;
        }
        const te = p.turn_end orelse return;
        if (p.lanes.items.len != 0) return;
        if (te.err != null or std.mem.eql(u8, te.stop, "failed")) {
            try p.emit("RUN_ERROR", ts, ",\"message\":{f},\"code\":{f}{s}", .{ jstr(te.err orelse te.stop), jstr(te.stop), usage }, .{});
        } else {
            try p.emit(
                "RUN_FINISHED",
                ts,
                ",\"threadId\":{f},\"runId\":{f},\"outcome\":{{\"type\":\"success\"}},\"result\":{{\"stop\":{f},\"steps\":{d}}}{s}",
                .{ jstr(p.thread_id), jstr(p.run_id), jstr(te.stop), te.steps, usage },
                .{},
            );
        }
    }

    fn runStarted(p: *Projector, ts: i64) Error!void {
        p.started = true;
        try p.emit(
            "RUN_STARTED",
            ts,
            ",\"threadId\":{f},\"runId\":{f},\"protocolVersion\":\"1.0\"",
            .{ jstr(p.thread_id), jstr(p.run_id) },
            .{},
        );
    }

    /// Key order is part of the output contract: type, timestamp, the
    /// type's own fields, subagentRunId, metadata.
    fn emit(p: *Projector, comptime ty: []const u8, ts: i64, comptime fields: []const u8, args: anytype, extra: Extra) Error!void {
        const a = p.arena;
        try p.out.appendSlice(a, "{\"type\":\"" ++ ty ++ "\"");
        if (ts != 0) try p.out.print(a, ",\"timestamp\":{d}", .{ts});
        try p.out.print(a, fields, args);
        if (extra.lane) |id| try p.out.print(a, ",\"subagentRunId\":{f}", .{jstr(id)});
        if (extra.meta) |m| try p.out.print(a, ",\"metadata\":{{\"zygos\":{{{s}}}}}", .{m});
        try p.out.appendSlice(a, "}\n");
    }

    fn top(p: *Projector) ?*Lane {
        if (p.lanes.items.len == 0) return null;
        return &p.lanes.items[p.lanes.items.len - 1];
    }

    fn laneId(p: *Projector) ?[]const u8 {
        return if (p.top()) |lane| lane.id else null;
    }

    fn laneSeq(p: *Projector) ?u32 {
        return if (p.top()) |lane| lane.seq else null;
    }

    /// Innermost open lane named `role`, else the stack top.
    fn laneNamed(p: *Projector, role: []const u8) ?usize {
        var i = p.lanes.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, p.lanes.items[i].name, role)) return i;
        }
        return if (p.lanes.items.len == 0) null else p.lanes.items.len - 1;
    }

    /// Results can arrive in any order within a step, so match by tool
    /// before falling back to FIFO within the lane.
    fn claimCall(p: *Projector, tool: []const u8) ?[]const u8 {
        const lane = p.laneSeq();
        var fallback: ?usize = null;
        for (p.pending.items, 0..) |call, i| {
            if (call.lane != lane) continue;
            if (std.mem.eql(u8, call.tool, tool)) return p.pending.orderedRemove(i).id;
            if (fallback == null) fallback = i;
        }
        return if (fallback) |i| p.pending.orderedRemove(i).id else null;
    }

    fn currentRoute(p: *Projector) Route {
        const lane_route = if (p.top()) |lane| lane.route else null;
        return lane_route orelse p.run_route orelse .{ .provider = "?", .model = "?" };
    }

    fn bucketFor(p: *Projector, route: Route) Error!*Bucket {
        for (p.buckets.items) |*b| {
            if (std.mem.eql(u8, b.route.provider, route.provider) and std.mem.eql(u8, b.route.model, route.model)) return b;
        }
        try p.buckets.append(p.arena, .{ .route = route });
        return &p.buckets.items[p.buckets.items.len - 1];
    }

    fn usageField(p: *Projector) Error![]const u8 {
        if (p.buckets.items.len == 0) return "";
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(p.arena, ",\"usage\":[");
        for (p.buckets.items, 0..) |b, i| {
            if (i > 0) try buf.append(p.arena, ',');
            try buf.print(
                p.arena,
                "{{\"provider\":{f},\"model\":{f},\"inputTokens\":{d},\"outputTokens\":{d},\"totalTokens\":{d}}}",
                .{ jstr(b.route.provider), jstr(b.route.model), b.input, b.output, b.input + b.output },
            );
        }
        try buf.append(p.arena, ']');
        return buf.items;
    }

    fn planEvent(p: *Projector, ts: i64, t: TraceEvent.Task, done: bool) Error!void {
        const a = p.arena;
        p.plan_total = t.total;
        const desc = try redact(a, t.desc);
        var at: usize = 0;
        while (at < p.plan.items.len and p.plan.items[at].index < t.index) at += 1;
        if (at < p.plan.items.len and p.plan.items[at].index == t.index) {
            const item = &p.plan.items[at];
            item.desc = desc;
            if (done) item.done = true else {
                item.done = false;
                item.attempts += 1;
            }
        } else {
            try p.plan.insert(a, at, .{ .index = t.index, .desc = desc, .done = done, .attempts = if (done) 0 else 1 });
        }
        var items: std.ArrayList(u8) = .empty;
        for (p.plan.items, 0..) |item, i| {
            if (i > 0) try items.append(a, ',');
            try items.print(a, "{{\"index\":{d},\"desc\":{f},\"status\":\"{s}\",\"attempts\":{d}}}", .{
                item.index, jstr(item.desc), if (item.done) "done" else "active", item.attempts,
            });
        }
        try p.emit(
            "ACTIVITY_SNAPSHOT",
            ts,
            ",\"messageId\":\"zygos.plan\",\"activityType\":\"zygos.plan\",\"content\":{{\"total\":{d},\"items\":[{s}]}},\"replace\":true",
            .{ p.plan_total, items.items },
            .{},
        );
    }
};

fn jstr(s: []const u8) @TypeOf(json.fmt(s, .{})) {
    return json.fmt(s, .{});
}

/// turn.zig traces the tool_call before the policy check, so a refusal
/// arrives as an error tool_result with one of these outputs.
fn denial(tr: TraceEvent.ToolResult) ?[]const u8 {
    if (!tr.is_error) return null;
    if (std.mem.startsWith(u8, tr.output, "policy_denied: ")) return "policy";
    if (std.mem.eql(u8, tr.output, "approval_denied")) return "approval";
    return null;
}

/// The tail `trace.clip` appends: `…[<digits> bytes total]`.
fn endsWithClipSuffix(s: []const u8) bool {
    const tail = " bytes total]";
    if (!std.mem.endsWith(u8, s, tail)) return false;
    const digits_end = s.len - tail.len;
    var i = digits_end;
    while (i > 0 and std.ascii.isDigit(s[i - 1])) i -= 1;
    return i < digits_end and std.mem.endsWith(u8, s[0..i], "…[");
}

// ---------------------------------------------------------------------------
// redaction
// ---------------------------------------------------------------------------

const redacted = "[REDACTED]";

const Span = struct { start: usize, end: usize };

/// Secret scrub for every free-text field the projector copies out of the
/// log. A name rule (`*KEY*=value` and kin) and a shape rule (bearer
/// tokens, vendor key prefixes) each replace only the secret bytes.
pub fn redact(arena: std.mem.Allocator, s: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (namedValue(s, i) orelse shapedSecret(s, i)) |span| {
            try out.appendSlice(arena, s[i..span.start]);
            try out.appendSlice(arena, redacted);
            i = span.end;
        } else {
            try out.append(arena, s[i]);
            i += 1;
        }
    }
    return out.items;
}

const secret_names = [_][]const u8{ "KEY", "SECRET", "TOKEN", "PASSWORD", "PASSWD", "CREDENTIAL" };

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-';
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isValueEnd(c: u8) bool {
    return std.ascii.isWhitespace(c) or std.mem.indexOfScalar(u8, "\"'\\,;&})]<>", c) != null;
}

fn skipQuote(s: []const u8, j: usize) usize {
    if (std.mem.startsWith(u8, s[j..], "\\\"")) return j + 2;
    if (j < s.len and (s[j] == '"' or s[j] == '\'')) return j + 1;
    return j;
}

fn skipSpaces(s: []const u8, j: usize) usize {
    var k = j;
    while (k < s.len and (s[k] == ' ' or s[k] == '\t')) k += 1;
    return k;
}

/// The value span of `NAME<sep>value` when an identifier starts at `i`,
/// its name looks secret, and the value is long enough to be one. All-digit
/// values (`max_tokens=4096`) are counts, not secrets.
fn namedValue(s: []const u8, i: usize) ?Span {
    if (!isIdent(s[i]) or (i > 0 and isIdent(s[i - 1]))) return null;
    var name_end = i;
    while (name_end < s.len and isIdent(s[name_end])) name_end += 1;
    const name = s[i..name_end];
    for (secret_names) |kw| {
        if (std.ascii.indexOfIgnoreCase(name, kw) != null) break;
    } else return null;

    var j = skipSpaces(s, skipQuote(s, name_end));
    if (j >= s.len or (s[j] != '=' and s[j] != ':')) return null;
    j = skipQuote(s, skipSpaces(s, j + 1));
    var end = j;
    var all_digits = true;
    while (end < s.len and !isValueEnd(s[end])) : (end += 1) {
        if (!std.ascii.isDigit(s[end])) all_digits = false;
    }
    if (end - j < 8 or all_digits) return null;
    return .{ .start = j, .end = end };
}

const key_prefixes = [_][]const u8{ "sk-", "ghp_", "gho_", "github_pat_", "xoxb-", "xoxp-" };

fn isBearerChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-._~+/=", c) != null;
}

fn isKeyChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

fn runLen(s: []const u8, from: usize, comptime pred: fn (u8) bool) usize {
    var k = from;
    while (k < s.len and pred(s[k])) k += 1;
    return k - from;
}

/// A token whose shape gives it away, at a word boundary. `Bearer ` stays
/// so the reader still sees the header's scheme.
fn shapedSecret(s: []const u8, i: usize) ?Span {
    if (i > 0 and isWord(s[i - 1])) return null;
    const rest = s[i..];
    if (std.mem.startsWith(u8, rest, "Bearer ")) {
        const from = i + "Bearer ".len;
        const n = runLen(s, from, isBearerChar);
        return if (n >= 8) .{ .start = from, .end = from + n } else null;
    }
    for (key_prefixes) |prefix| {
        if (!std.mem.startsWith(u8, rest, prefix)) continue;
        const n = runLen(s, i + prefix.len, isKeyChar);
        if (n >= 16) return .{ .start = i, .end = i + prefix.len + n };
    }
    if (std.mem.startsWith(u8, rest, "AKIA") and rest.len >= 20) {
        for (rest[4..20]) |c| if (!(std.ascii.isUpper(c) or std.ascii.isDigit(c))) return null;
        return .{ .start = i, .end = i + 20 };
    }
    return null;
}

// ---------------------------------------------------------------------------
// HTML
// ---------------------------------------------------------------------------

const viewer = @embedFile("agui_viewer.html");
const placeholder = "@@ZYGOS_EVENTS@@";
const placeholder_at = blk: {
    @setEvalBranchQuota(10_000_000);
    const at = std.mem.indexOf(u8, viewer, placeholder) orelse
        @compileError("agui_viewer.html lacks the " ++ placeholder ++ " placeholder");
    if (std.mem.lastIndexOf(u8, viewer, placeholder) != at)
        @compileError("agui_viewer.html holds more than one " ++ placeholder ++ " placeholder");
    break :blk at;
};

/// The embedded viewer with `agui_jsonl` inlined at the placeholder. Every
/// `<` becomes `<`, legal only inside JSON strings, which is the only
/// place AG-UI JSONL holds one. The data block then cannot contain
/// `</script` or `<!--`.
pub fn html(arena: std.mem.Allocator, agui_jsonl: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, viewer.len + agui_jsonl.len);
    try out.appendSlice(arena, viewer[0..placeholder_at]);
    for (agui_jsonl) |c| {
        if (c == '<') try out.appendSlice(arena, "\\u003c") else try out.append(arena, c);
    }
    try out.appendSlice(arena, viewer[placeholder_at + placeholder.len ..]);
    return out.items;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn expectProjection(thread_id: []const u8, input: []const u8, expected: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings(expected, try project(arena_state.allocator(), input, thread_id));
}

test "project: mission log projects roles, interleaved results, clip, denials, steer, plan and a failed finish" {
    try expectProjection("m1",
        \\{"ts":100,"event":"mission","from":"defining","to":"planning","role_turns":0,"tasks_done":0,"tasks":0}
        \\{"ts":101,"event":"role_start","role":"planner","role_turn":1,"tools":false,"content":"Plan it"}
        \\{"ts":102,"event":"step","turn_id":"","step":1,"provider":"p1","model":"m-a","attempt":0}
        \\{"ts":103,"event":"usage","turn_id":"","step":1,"input_tokens":100,"output_tokens":10}
        \\{"ts":104,"event":"tool_call","turn_id":"","step":1,"tool":"read_file","input":"{\"path\":\"a\"}"}
        \\{"ts":105,"event":"tool_result","step":1,"tool":"read_file","is_error":false,"bytes":2,"output":"hi"}
        \\{"ts":106,"event":"turn_end","turn_id":"","stop":"end_turn","steps":1}
        \\{"ts":107,"event":"role_end","role":"planner","outcome":"ok"}
        \\not json, a torn write
        \\{"ts":108,"event":"mission","from":"planning","to":"executing","role_turns":1,"tasks_done":0,"tasks":2}
        \\{"ts":109,"event":"task_start","index":1,"total":2,"desc":"build it"}
        \\{"ts":110,"event":"role_start","role":"executor","role_turn":2,"tools":true,"content":"Do task 1"}
        \\{"ts":111,"event":"step","turn_id":"","step":1,"provider":"p2","model":"m-b","attempt":0}
        \\{"ts":112,"event":"usage","turn_id":"","step":1,"input_tokens":200,"output_tokens":20}
        \\{"ts":113,"event":"tool_call","turn_id":"","step":1,"tool":"bash","input":"{\"command\":\"ls\"}"}
        \\{"ts":114,"event":"tool_call","turn_id":"","step":1,"tool":"read_file","input":"{\"path\":\"b\"}"}
        \\{"ts":115,"event":"tool_result","step":1,"tool":"read_file","is_error":false,"bytes":5000,"output":"xx…[5000 bytes total]"}
        \\{"ts":116,"event":"tool_result","step":1,"tool":"bash","is_error":true,"bytes":27,"output":"policy_denied: bash blocked"}
        \\{"ts":117,"event":"steer","text":"use OPENROUTER_API_KEY=sk-or-v1-abcdef0123456789abcdef"}
        \\{"ts":118,"event":"tool_call","turn_id":"","step":2,"tool":"bash","input":"{\"command\":\"rm -rf /\"}"}
        \\{"ts":119,"event":"tool_result","step":2,"tool":"bash","is_error":true,"bytes":15,"output":"approval_denied"}
        \\{"ts":120,"event":"task_done","index":1,"total":2,"desc":"build it"}
        \\{"ts":121,"event":"turn_end","turn_id":"","stop":"max_steps","steps":2}
        \\{"ts":122,"event":"role_end","role":"executor","outcome":"failed","reason":"max_steps"}
        \\{"ts":123,"event":"mission","from":"executing","to":"failed","role_turns":2,"tasks_done":1,"tasks":2}
        \\
    ,
        \\{"type":"RUN_STARTED","timestamp":100,"threadId":"m1","runId":"m1:1","protocolVersion":"1.0"}
        \\{"type":"STEP_STARTED","timestamp":100,"stepName":"planning"}
        \\{"type":"ACTIVITY_SNAPSHOT","timestamp":100,"messageId":"zygos.mission","activityType":"zygos.mission","content":{"state":"planning","from":"defining","role_turns":0,"tasks_done":0,"tasks":0},"replace":true}
        \\{"type":"SUBAGENT_STARTED","timestamp":101,"subagentRunId":"planner:1","name":"planner","description":"Plan it","metadata":{"zygos":{"role_turn":1,"tools":false}}}
        \\{"type":"CUSTOM","timestamp":102,"name":"zygos.route","value":{"step":1,"provider":"p1","model":"m-a","attempt":0},"subagentRunId":"planner:1"}
        \\{"type":"STATE_SNAPSHOT","timestamp":103,"snapshot":{"usage":{"input_tokens":100,"output_tokens":10}},"subagentRunId":"planner:1","metadata":{"zygos":{"step":1,"input_tokens":100,"output_tokens":10}}}
        \\{"type":"TOOL_CALL_START","timestamp":104,"toolCallId":"call-1","toolCallName":"read_file","subagentRunId":"planner:1","metadata":{"zygos":{"step":1,"clipped":false}}}
        \\{"type":"TOOL_CALL_ARGS","timestamp":104,"toolCallId":"call-1","delta":"{\"path\":\"a\"}","subagentRunId":"planner:1"}
        \\{"type":"TOOL_CALL_END","timestamp":104,"toolCallId":"call-1","subagentRunId":"planner:1"}
        \\{"type":"TOOL_CALL_RESULT","timestamp":105,"messageId":"call-1:result","toolCallId":"call-1","content":"hi","role":"tool","subagentRunId":"planner:1","metadata":{"zygos":{"step":1,"is_error":false,"bytes":2,"clipped":false}}}
        \\{"type":"CUSTOM","timestamp":106,"name":"zygos.turn_end","value":{"stop":"end_turn","steps":1},"subagentRunId":"planner:1"}
        \\{"type":"SUBAGENT_FINISHED","timestamp":107,"subagentRunId":"planner:1","metadata":{"zygos":{"outcome":"ok"}}}
        \\{"type":"STEP_FINISHED","timestamp":108,"stepName":"planning"}
        \\{"type":"STEP_STARTED","timestamp":108,"stepName":"executing"}
        \\{"type":"ACTIVITY_SNAPSHOT","timestamp":108,"messageId":"zygos.mission","activityType":"zygos.mission","content":{"state":"executing","from":"planning","role_turns":1,"tasks_done":0,"tasks":2},"replace":true}
        \\{"type":"ACTIVITY_SNAPSHOT","timestamp":109,"messageId":"zygos.plan","activityType":"zygos.plan","content":{"total":2,"items":[{"index":1,"desc":"build it","status":"active","attempts":1}]},"replace":true}
        \\{"type":"SUBAGENT_STARTED","timestamp":110,"subagentRunId":"executor:2","name":"executor","description":"Do task 1","metadata":{"zygos":{"role_turn":2,"tools":true}}}
        \\{"type":"CUSTOM","timestamp":111,"name":"zygos.route","value":{"step":1,"provider":"p2","model":"m-b","attempt":0},"subagentRunId":"executor:2"}
        \\{"type":"STATE_SNAPSHOT","timestamp":112,"snapshot":{"usage":{"input_tokens":300,"output_tokens":30}},"subagentRunId":"executor:2","metadata":{"zygos":{"step":1,"input_tokens":200,"output_tokens":20}}}
        \\{"type":"TOOL_CALL_START","timestamp":113,"toolCallId":"call-2","toolCallName":"bash","subagentRunId":"executor:2","metadata":{"zygos":{"step":1,"clipped":false}}}
        \\{"type":"TOOL_CALL_ARGS","timestamp":113,"toolCallId":"call-2","delta":"{\"command\":\"ls\"}","subagentRunId":"executor:2"}
        \\{"type":"TOOL_CALL_END","timestamp":113,"toolCallId":"call-2","subagentRunId":"executor:2"}
        \\{"type":"TOOL_CALL_START","timestamp":114,"toolCallId":"call-3","toolCallName":"read_file","subagentRunId":"executor:2","metadata":{"zygos":{"step":1,"clipped":false}}}
        \\{"type":"TOOL_CALL_ARGS","timestamp":114,"toolCallId":"call-3","delta":"{\"path\":\"b\"}","subagentRunId":"executor:2"}
        \\{"type":"TOOL_CALL_END","timestamp":114,"toolCallId":"call-3","subagentRunId":"executor:2"}
        \\{"type":"TOOL_CALL_RESULT","timestamp":115,"messageId":"call-3:result","toolCallId":"call-3","content":"xx…[5000 bytes total]","role":"tool","subagentRunId":"executor:2","metadata":{"zygos":{"step":1,"is_error":false,"bytes":5000,"clipped":true}}}
        \\{"type":"TOOL_CALL_RESULT","timestamp":116,"messageId":"call-2:result","toolCallId":"call-2","content":"policy_denied: bash blocked","role":"tool","subagentRunId":"executor:2","metadata":{"zygos":{"step":1,"is_error":true,"bytes":27,"clipped":false,"denied":"policy"}}}
        \\{"type":"TEXT_MESSAGE_START","timestamp":117,"messageId":"steer-1","role":"user"}
        \\{"type":"TEXT_MESSAGE_CONTENT","timestamp":117,"messageId":"steer-1","delta":"use OPENROUTER_API_KEY=[REDACTED]"}
        \\{"type":"TEXT_MESSAGE_END","timestamp":117,"messageId":"steer-1"}
        \\{"type":"TOOL_CALL_START","timestamp":118,"toolCallId":"call-4","toolCallName":"bash","subagentRunId":"executor:2","metadata":{"zygos":{"step":2,"clipped":false}}}
        \\{"type":"TOOL_CALL_ARGS","timestamp":118,"toolCallId":"call-4","delta":"{\"command\":\"rm -rf /\"}","subagentRunId":"executor:2"}
        \\{"type":"TOOL_CALL_END","timestamp":118,"toolCallId":"call-4","subagentRunId":"executor:2"}
        \\{"type":"TOOL_CALL_RESULT","timestamp":119,"messageId":"call-4:result","toolCallId":"call-4","content":"approval_denied","role":"tool","subagentRunId":"executor:2","metadata":{"zygos":{"step":2,"is_error":true,"bytes":15,"clipped":false,"denied":"approval"}}}
        \\{"type":"ACTIVITY_SNAPSHOT","timestamp":120,"messageId":"zygos.plan","activityType":"zygos.plan","content":{"total":2,"items":[{"index":1,"desc":"build it","status":"done","attempts":1}]},"replace":true}
        \\{"type":"CUSTOM","timestamp":121,"name":"zygos.turn_end","value":{"stop":"max_steps","steps":2},"subagentRunId":"executor:2"}
        \\{"type":"SUBAGENT_ERROR","timestamp":122,"subagentRunId":"executor:2","message":"max_steps","metadata":{"zygos":{"outcome":"failed"}}}
        \\{"type":"STEP_FINISHED","timestamp":123,"stepName":"executing"}
        \\{"type":"STEP_STARTED","timestamp":123,"stepName":"failed"}
        \\{"type":"ACTIVITY_SNAPSHOT","timestamp":123,"messageId":"zygos.mission","activityType":"zygos.mission","content":{"state":"failed","from":"executing","role_turns":2,"tasks_done":1,"tasks":2},"replace":true}
        \\{"type":"STEP_FINISHED","timestamp":123,"stepName":"failed"}
        \\{"type":"RUN_ERROR","timestamp":123,"message":"max_steps","code":"mission_failed","usage":[{"provider":"p1","model":"m-a","inputTokens":100,"outputTokens":10,"totalTokens":110},{"provider":"p2","model":"m-b","inputTokens":200,"outputTokens":20,"totalTokens":220}]}
        \\
    );
}

test "project: task run without roles finishes on turn_end with the stop, steps and usage" {
    try expectProjection("filter-js",
        \\{"ts":200,"event":"step","turn_id":"task","step":1,"provider":"p","model":"m","attempt":0}
        \\{"ts":201,"event":"usage","turn_id":"task","step":1,"input_tokens":50,"output_tokens":5}
        \\{"ts":202,"event":"tool_call","turn_id":"task","step":1,"tool":"bash","input":"{\"command\":\"ls\"}"}
        \\{"ts":203,"event":"tool_result","step":1,"tool":"bash","is_error":false,"bytes":3,"output":"a b"}
        \\{"ts":203,"event":"tool_result","step":1,"tool":"web_fetch","is_error":false,"bytes":2,"output":"ok"}
        \\{"ts":204,"event":"step","turn_id":"task","step":2,"provider":"p","model":"m","attempt":0}
        \\{"ts":205,"event":"usage","turn_id":"task","step":2,"input_tokens":60,"output_tokens":6}
        \\{"ts":206,"event":"turn_end","turn_id":"task","stop":"max_steps","steps":2}
        \\
    ,
        \\{"type":"RUN_STARTED","timestamp":200,"threadId":"filter-js","runId":"filter-js:1","protocolVersion":"1.0"}
        \\{"type":"CUSTOM","timestamp":200,"name":"zygos.route","value":{"step":1,"provider":"p","model":"m","attempt":0}}
        \\{"type":"STATE_SNAPSHOT","timestamp":201,"snapshot":{"usage":{"input_tokens":50,"output_tokens":5}},"metadata":{"zygos":{"step":1,"input_tokens":50,"output_tokens":5}}}
        \\{"type":"TOOL_CALL_START","timestamp":202,"toolCallId":"call-1","toolCallName":"bash","metadata":{"zygos":{"step":1,"clipped":false}}}
        \\{"type":"TOOL_CALL_ARGS","timestamp":202,"toolCallId":"call-1","delta":"{\"command\":\"ls\"}"}
        \\{"type":"TOOL_CALL_END","timestamp":202,"toolCallId":"call-1"}
        \\{"type":"TOOL_CALL_RESULT","timestamp":203,"messageId":"call-1:result","toolCallId":"call-1","content":"a b","role":"tool","metadata":{"zygos":{"step":1,"is_error":false,"bytes":3,"clipped":false}}}
        \\{"type":"TOOL_CALL_RESULT","timestamp":203,"messageId":"result-1:result","toolCallId":"result-1","content":"ok","role":"tool","metadata":{"zygos":{"step":1,"is_error":false,"bytes":2,"clipped":false}}}
        \\{"type":"CUSTOM","timestamp":204,"name":"zygos.route","value":{"step":2,"provider":"p","model":"m","attempt":0}}
        \\{"type":"STATE_SNAPSHOT","timestamp":205,"snapshot":{"usage":{"input_tokens":110,"output_tokens":11}},"metadata":{"zygos":{"step":2,"input_tokens":60,"output_tokens":6}}}
        \\{"type":"CUSTOM","timestamp":206,"name":"zygos.turn_end","value":{"stop":"max_steps","steps":2}}
        \\{"type":"RUN_FINISHED","timestamp":206,"threadId":"filter-js","runId":"filter-js:1","outcome":{"type":"success"},"result":{"stop":"max_steps","steps":2},"usage":[{"provider":"p","model":"m","inputTokens":110,"outputTokens":11,"totalTokens":121}]}
        \\
    );
}

test "project: a truncated mission emits no finish and no error; a zero ts is omitted" {
    try expectProjection("m2",
        \\{"ts":300,"event":"mission","from":"defining","to":"planning","role_turns":0,"tasks_done":0,"tasks":0}
        \\{"event":"role_start","role":"planner","role_turn":1,"tools":false,"content":"Plan"}
        \\{"ts":302,"event":"turn_end","turn_id":"","stop":"failed","steps":0,"error":"route_exhausted"}
    ,
        \\{"type":"RUN_STARTED","timestamp":300,"threadId":"m2","runId":"m2:1","protocolVersion":"1.0"}
        \\{"type":"STEP_STARTED","timestamp":300,"stepName":"planning"}
        \\{"type":"ACTIVITY_SNAPSHOT","timestamp":300,"messageId":"zygos.mission","activityType":"zygos.mission","content":{"state":"planning","from":"defining","role_turns":0,"tasks_done":0,"tasks":0},"replace":true}
        \\{"type":"SUBAGENT_STARTED","subagentRunId":"planner:1","name":"planner","description":"Plan","metadata":{"zygos":{"role_turn":1,"tools":false}}}
        \\{"type":"CUSTOM","timestamp":302,"name":"zygos.turn_end","value":{"stop":"failed","steps":0,"error":"route_exhausted"},"subagentRunId":"planner:1"}
        \\
    );
}

fn expectRedacted(expected: []const u8, input: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings(expected, try redact(arena_state.allocator(), input));
}

test "redact: named secrets lose their value, the name stays" {
    try expectRedacted(
        "OPENROUTER_API_KEY=[REDACTED]",
        "OPENROUTER_API_KEY=sk-or-v1-abcdef0123456789abcdef",
    );
    try expectRedacted(
        \\{"api_key":"[REDACTED]"}
    ,
        \\{"api_key":"abcd1234efgh"}
    );
    try expectRedacted(
        \\{"exit_code":0,"output":"{\"api_key\":\"[REDACTED]\"}"}
    ,
        \\{"exit_code":0,"output":"{\"api_key\":\"abcd1234efgh\"}"}
    );
}

test "redact: secret shapes are scrubbed without a name" {
    try expectRedacted(
        "Authorization: Bearer [REDACTED]",
        "Authorization: Bearer abcdefgh12345678",
    );
    try expectRedacted(
        "push with [REDACTED] now",
        "push with ghp_abcdefghijklmnopqrstuvwxyz0123456789 now",
    );
    try expectRedacted("aws [REDACTED] done", "aws AKIAABCDEFGHIJKLMNOP done");
}

test "redact: token counts and short values survive, a token value does not" {
    const benign =
        \\"input_tokens":1200,"max_tokens":4096 keyboard=us
    ;
    try expectRedacted(benign, benign);
    try expectRedacted(
        \\"max_tokens":4096,"access_token":"[REDACTED]"
    ,
        \\"max_tokens":4096,"access_token":"abcdefgh1234"
    );
}

test "html: the payload replaces the placeholder and cannot close its script tag" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const page = try html(arena_state.allocator(),
        \\{"type":"CUSTOM","value":"</script><!--"}
        \\
    );
    try testing.expect(std.mem.indexOf(u8, page, "@@ZYGOS_EVENTS@@") == null);
    const open = "<script type=\"application/x-ndjson\" id=\"zygos-events\">";
    const body_start = (std.mem.indexOf(u8, page, open) orelse return error.TestNoDataTag) + open.len;
    const body_end = std.mem.indexOfPos(u8, page, body_start, "</script>") orelse return error.TestNoClose;
    try testing.expectEqualStrings(
        \\{"type":"CUSTOM","value":"\u003c/script>\u003c!--"}
        \\
    , page[body_start..body_end]);
}
