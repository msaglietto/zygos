//! Trial record for one headless task run, and the scorer that refuses a
//! dishonest arm. Pure: arena in, no bus, no process.
//!
//! Cache counts live on this record only. The trace usage line
//! (`trace_event.zig` `body`) stays `input_tokens` and `output_tokens` —
//! that line is byte-stable and is not a place to grow fields.
//!
//! A trim-on arm with no snapshot, zero compress calls, or a recorded
//! reduction of zero is a scorer error. That is the M8 failure mode (the
//! seam shipped and never ran) and a flat pass rate must not hide it.
//! A trim-off arm is allowed to record zero.

const std = @import("std");
const json = std.json;
const jsonx = @import("jsonx.zig");
const ops = @import("tools_ops.zig");
const trace_event = @import("trace_event.zig");

pub const adapter_version = "0.1.0";

pub const ParseError = error{ MalformedTrial, MissingBuildIdentity, OutOfMemory };
pub const ScoreError = error{ MissingBuildIdentity, MissingPrice, TrimEvidenceMissing, TrimOnZeroReduction, UnknownVariable };

pub const TrimSnap = struct {
    calls: u64,
    filtered: u64,
    deduped: u64,
    raw_bytes: u64,
    sent_bytes: u64,
    reduction: u64,
};

pub const Identity = struct {
    git_sha: []const u8,
    target_triple: []const u8,
    optimize: []const u8,
    adapter_version: []const u8,
};

pub const Trial = struct {
    task_id: []const u8,
    dataset: []const u8,
    model_id: []const u8,
    /// "trim-on" or "trim-off". One harness variable per record.
    variable: []const u8,
    step_cap: u64,
    git_sha: []const u8,
    target_triple: []const u8,
    optimize: []const u8,
    adapter_version: []const u8,
    source_lines_read: u64,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_tokens: ?u64 = null,
    cache_creation_tokens: ?u64 = null,
    trim: ?TrimSnap = null,
};

pub const Price = struct {
    model_id: []const u8,
    cents_per_mtok: u64,
};

pub const Scored = struct {
    cents: u64,
    source_lines_read: u64,
    reduction: u64,
};

/// Read-file bytes only. `bash` and `grep` (and every other name) are zero,
/// including a shell command whose text is a search.
pub fn sourceLinesRead(tool_name: []const u8, content: []const u8) u64 {
    if (!std.mem.eql(u8, tool_name, "read_file") and
        !std.mem.eql(u8, tool_name, "zygos::tools::read_file"))
        return 0;
    return ops.countLines(content);
}

pub fn reductionOf(raw_bytes: u64, sent_bytes: u64) u64 {
    if (raw_bytes == 0 or sent_bytes >= raw_bytes) return 0;
    return (raw_bytes - sent_bytes) * 100 / raw_bytes;
}

pub fn identityComplete(id: Identity) bool {
    return id.git_sha.len > 0 and id.target_triple.len > 0 and id.optimize.len > 0 and id.adapter_version.len > 0;
}

fn requireId(s: []const u8) ParseError!void {
    if (s.len == 0) return error.MissingBuildIdentity;
}

/// Serialize in a fixed key order so two runs of the same arm match byte
/// for byte. Null cache counts are omitted. `trim` is omitted when null
/// (that omission is what the scorer calls missing evidence).
pub fn write(allocator: std.mem.Allocator, trial: Trial) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator,
        \\{{"task_id":{f},"dataset":{f},"model_id":{f},"variable":{f},"step_cap":{d},"git_sha":{f},"target_triple":{f},"optimize":{f},"adapter_version":{f},"source_lines_read":{d},"input_tokens":{d},"output_tokens":{d}
    , .{
        json.fmt(trial.task_id, .{}),
        json.fmt(trial.dataset, .{}),
        json.fmt(trial.model_id, .{}),
        json.fmt(trial.variable, .{}),
        trial.step_cap,
        json.fmt(trial.git_sha, .{}),
        json.fmt(trial.target_triple, .{}),
        json.fmt(trial.optimize, .{}),
        json.fmt(trial.adapter_version, .{}),
        trial.source_lines_read,
        trial.input_tokens,
        trial.output_tokens,
    });
    if (trial.cache_read_tokens) |n| try out.print(allocator, ",\"cache_read_tokens\":{d}", .{n});
    if (trial.cache_creation_tokens) |n| try out.print(allocator, ",\"cache_creation_tokens\":{d}", .{n});
    if (trial.trim) |t| {
        try out.print(allocator,
            \\,"trim":{{"calls":{d},"filtered":{d},"deduped":{d},"raw_bytes":{d},"sent_bytes":{d},"reduction":{d}}}
        , .{ t.calls, t.filtered, t.deduped, t.raw_bytes, t.sent_bytes, t.reduction });
    }
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

pub fn parse(arena: std.mem.Allocator, text: []const u8) ParseError!Trial {
    const root = json.parseFromSliceLeaky(json.Value, arena, text, .{}) catch return error.MalformedTrial;
    if (root != .object) return error.MalformedTrial;
    const o = root.object;
    const trial: Trial = .{
        .task_id = try dupeReq(arena, o, "task_id"),
        .dataset = try dupeReq(arena, o, "dataset"),
        .model_id = try dupeReq(arena, o, "model_id"),
        .variable = try dupeReq(arena, o, "variable"),
        .step_cap = uintReq(o, "step_cap") orelse return error.MalformedTrial,
        .git_sha = try dupeReq(arena, o, "git_sha"),
        .target_triple = try dupeReq(arena, o, "target_triple"),
        .optimize = try dupeReq(arena, o, "optimize"),
        .adapter_version = try dupeReq(arena, o, "adapter_version"),
        .source_lines_read = uintReq(o, "source_lines_read") orelse return error.MalformedTrial,
        .input_tokens = uintReq(o, "input_tokens") orelse return error.MalformedTrial,
        .output_tokens = uintReq(o, "output_tokens") orelse return error.MalformedTrial,
        .cache_read_tokens = uintOpt(o, "cache_read_tokens"),
        .cache_creation_tokens = uintOpt(o, "cache_creation_tokens"),
        .trim = try parseTrim(o),
    };
    try requireId(trial.git_sha);
    try requireId(trial.target_triple);
    try requireId(trial.optimize);
    try requireId(trial.adapter_version);
    if (trial.variable.len == 0) return error.MalformedTrial;
    return trial;
}

fn parseTrim(o: json.ObjectMap) ParseError!?TrimSnap {
    const v = o.get("trim") orelse return null;
    if (v != .object) return error.MalformedTrial;
    const t = v.object;
    return .{
        .calls = uintReq(t, "calls") orelse return error.MalformedTrial,
        .filtered = uintReq(t, "filtered") orelse return error.MalformedTrial,
        .deduped = uintReq(t, "deduped") orelse return error.MalformedTrial,
        .raw_bytes = uintReq(t, "raw_bytes") orelse return error.MalformedTrial,
        .sent_bytes = uintReq(t, "sent_bytes") orelse return error.MalformedTrial,
        .reduction = uintReq(t, "reduction") orelse return error.MalformedTrial,
    };
}

/// One price row per line: `<model_id> <cents_per_mtok>`. `#` comments and
/// blank lines are ignored. A model id has no spaces.
pub fn parsePrices(arena: std.mem.Allocator, text: []const u8) ParseError![]Price {
    var list: std.ArrayList(Price) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const sp = std.mem.indexOfAny(u8, line, " \t") orelse return error.MalformedTrial;
        const id = std.mem.trim(u8, line[0..sp], " \t");
        const rest = std.mem.trim(u8, line[sp + 1 ..], " \t");
        if (id.len == 0 or rest.len == 0) return error.MalformedTrial;
        const cents = std.fmt.parseInt(u64, rest, 10) catch return error.MalformedTrial;
        try list.append(arena, .{
            .model_id = try arena.dupe(u8, id),
            .cents_per_mtok = cents,
        });
    }
    return list.toOwnedSlice(arena);
}

pub fn score(trial: Trial, prices: []const Price) ScoreError!Scored {
    if (trial.git_sha.len == 0 or trial.target_triple.len == 0 or trial.optimize.len == 0 or trial.adapter_version.len == 0)
        return error.MissingBuildIdentity;
    const price = findPrice(prices, trial.model_id) orelse return error.MissingPrice;
    const reduction = trim_reduction: {
        if (std.mem.eql(u8, trial.variable, "trim-on")) {
            const snap = trial.trim orelse return error.TrimEvidenceMissing;
            if (snap.calls == 0) return error.TrimEvidenceMissing;
            if (snap.reduction == 0) return error.TrimOnZeroReduction;
            break :trim_reduction snap.reduction;
        } else if (std.mem.eql(u8, trial.variable, "trim-off")) {
            break :trim_reduction if (trial.trim) |s| s.reduction else 0;
        } else return error.UnknownVariable;
    };
    const tokens = trial.input_tokens + trial.output_tokens;
    return .{
        .cents = tokens * price.cents_per_mtok / 1_000_000,
        .source_lines_read = trial.source_lines_read,
        .reduction = reduction,
    };
}

fn findPrice(prices: []const Price, model_id: []const u8) ?Price {
    for (prices) |p| if (std.mem.eql(u8, p.model_id, model_id)) return p;
    return null;
}

fn dupeReq(arena: std.mem.Allocator, o: json.ObjectMap, key: []const u8) ParseError![]const u8 {
    const s = jsonx.strField(o, key) orelse return error.MalformedTrial;
    return arena.dupe(u8, s) catch error.OutOfMemory;
}

fn uintReq(o: json.ObjectMap, key: []const u8) ?u64 {
    return jsonx.uintField(o, key);
}

fn uintOpt(o: json.ObjectMap, key: []const u8) ?u64 {
    if (o.get(key) == null) return null;
    return jsonx.uintField(o, key);
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn fixtureIdentity() Identity {
    return .{
        .git_sha = "0123456789abcdef0123456789abcdef01234567",
        .target_triple = "aarch64-macos",
        .optimize = "Debug",
        .adapter_version = adapter_version,
    };
}

fn baseTrial() Trial {
    const id = fixtureIdentity();
    return .{
        .task_id = "offline-fixture",
        .dataset = "offline-fixture",
        .model_id = "fixture",
        .variable = "trim-on",
        .step_cap = 4,
        .git_sha = id.git_sha,
        .target_triple = id.target_triple,
        .optimize = id.optimize,
        .adapter_version = id.adapter_version,
        .source_lines_read = 3,
        .input_tokens = 1_000_000,
        .output_tokens = 0,
        .cache_read_tokens = 9,
        .trim = .{
            .calls = 2,
            .filtered = 0,
            .deduped = 0,
            .raw_bytes = 1000,
            .sent_bytes = 400,
            .reduction = 60,
        },
    };
}

const fixture_prices = [_]Price{.{ .model_id = "fixture", .cents_per_mtok = 250 }};

test "source lines count read_file only; bash and grep are zero" {
    const body = "alpha\nbeta\ngamma\n";
    try testing.expectEqual(@as(u64, 3), sourceLinesRead("read_file", body));
    try testing.expectEqual(@as(u64, 3), sourceLinesRead("zygos::tools::read_file", body));
    try testing.expectEqual(@as(u64, 0), sourceLinesRead("bash", body));
    try testing.expectEqual(@as(u64, 0), sourceLinesRead("grep", "alpha\n"));
    try testing.expectEqual(@as(u64, 0), sourceLinesRead("bash", "grep -n alpha fixture.txt\n"));
}

test "usage trace line stays input and output tokens, with no cache field" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const line = try trace_event.body(arena_state.allocator(), .{ .usage = .{
        .turn_id = "t",
        .step = 1,
        .input_tokens = 3,
        .output_tokens = 4,
    } });
    try testing.expect(std.mem.indexOf(u8, line, "cache") == null);
    try testing.expect(std.mem.indexOf(u8, line, "\"input_tokens\":3") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"output_tokens\":4") != null);
}

test "trial round-trip keeps build identity, trim snapshot, and cache counts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const raw = try write(testing.allocator, baseTrial());
    defer testing.allocator.free(raw);
    const parsed = try parse(arena, raw);
    try testing.expectEqualStrings(fixtureIdentity().git_sha, parsed.git_sha);
    try testing.expectEqualStrings(fixtureIdentity().target_triple, parsed.target_triple);
    try testing.expectEqualStrings("Debug", parsed.optimize);
    try testing.expectEqualStrings(adapter_version, parsed.adapter_version);
    try testing.expectEqual(@as(u64, 3), parsed.source_lines_read);
    try testing.expectEqual(@as(?u64, 9), parsed.cache_read_tokens);
    try testing.expectEqual(@as(u64, 2), parsed.trim.?.calls);
    try testing.expectEqual(@as(u64, 60), parsed.trim.?.reduction);
    try testing.expect(std.mem.indexOf(u8, raw, "\"cache_read_tokens\":9") != null);
}

test "parse rejects an empty build-identity field" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var t = baseTrial();
    t.git_sha = "";
    const raw = try write(testing.allocator, t);
    defer testing.allocator.free(raw);
    try testing.expectError(error.MissingBuildIdentity, parse(arena_state.allocator(), raw));
}

test "score: trim-on zero reduction fails; missing evidence fails; trim-off zero passes" {
    const ok = try score(baseTrial(), &fixture_prices);
    try testing.expectEqual(@as(u64, 250), ok.cents);
    try testing.expectEqual(@as(u64, 60), ok.reduction);

    var zero = baseTrial();
    zero.trim.?.reduction = 0;
    zero.trim.?.sent_bytes = zero.trim.?.raw_bytes;
    try testing.expectError(error.TrimOnZeroReduction, score(zero, &fixture_prices));

    var missing = baseTrial();
    missing.trim = null;
    try testing.expectError(error.TrimEvidenceMissing, score(missing, &fixture_prices));

    var no_calls = baseTrial();
    no_calls.trim.?.calls = 0;
    no_calls.trim.?.reduction = 60;
    try testing.expectError(error.TrimEvidenceMissing, score(no_calls, &fixture_prices));

    var off = baseTrial();
    off.variable = "trim-off";
    off.trim.?.reduction = 0;
    off.trim.?.calls = 0;
    const off_scored = try score(off, &fixture_prices);
    try testing.expectEqual(@as(u64, 0), off_scored.reduction);
}

test "score: missing price or empty build identity fails" {
    var priced = baseTrial();
    priced.model_id = "other-model";
    try testing.expectError(error.MissingPrice, score(priced, &fixture_prices));

    var bare = baseTrial();
    bare.target_triple = "";
    try testing.expectError(error.MissingBuildIdentity, score(bare, &fixture_prices));
}

test "parsePrices reads model rows and ignores comments" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const rows = try parsePrices(arena_state.allocator(),
        \\# cents per million tokens
        \\fixture 250
        \\
        \\other 0
    );
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("fixture", rows[0].model_id);
    try testing.expectEqual(@as(u64, 250), rows[0].cents_per_mtok);
    try testing.expectEqual(@as(u64, 0), rows[1].cents_per_mtok);
}
