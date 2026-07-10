//! Tessera capture worker (W4, docs/specs/tessera-capture.md). Taxonomy-
//! routed capture: one classification turn (`step_id:"tessera-capture"`)
//! routes raw input into a vault note. Taxonomy (destinations + tags) is
//! injected from ZON config (ADR-004). A capture is never lost — any
//! classifier malfunction falls back to the configured ideas destination
//! tagged `#needs-review`.

const std = @import("std");
const c = std.c;
const json = std.json;
const actor_mod = @import("../kernel/actor.zig");
const inproc = @import("../kernel/inproc.zig");
const turn_mod = @import("turn.zig");
const sync = @import("../kernel/sync.zig");

// ---------------------------------------------------------------------------
// Taxonomy (ZON config, router.zig parse idiom — text in, no file I/O)
// ---------------------------------------------------------------------------

pub const Destination = struct {
    name: []const u8,
    path: []const u8,
    description: []const u8,
};

const TaxonomyData = struct {
    destinations: []const Destination = &.{},
    tags: []const []const u8 = &.{},
    fallback: []const u8 = "",
};

pub const Taxonomy = struct {
    gpa: std.mem.Allocator,
    data: TaxonomyData,

    pub fn parse(gpa: std.mem.Allocator, zon_text: [:0]const u8) error{ OutOfMemory, ParseZon, BadTaxonomy }!Taxonomy {
        const data = try std.zon.parse.fromSliceAlloc(TaxonomyData, gpa, zon_text, null, .{});
        errdefer std.zon.parse.free(gpa, data);

        if (data.destinations.len == 0) return error.BadTaxonomy;
        var fallback_ok = false;
        for (data.destinations) |d| {
            if (std.mem.eql(u8, d.name, data.fallback)) {
                fallback_ok = true;
                break;
            }
        }
        if (!fallback_ok) return error.BadTaxonomy;

        return .{ .gpa = gpa, .data = data };
    }

    pub fn deinit(self: *Taxonomy) void {
        std.zon.parse.free(self.gpa, self.data);
        self.* = undefined;
    }

    pub fn find(self: *const Taxonomy, name: []const u8) ?Destination {
        for (self.data.destinations) |d| {
            if (std.mem.eql(u8, d.name, name)) return d;
        }
        return null;
    }

    fn tagAllowed(self: *const Taxonomy, tag: []const u8) bool {
        for (self.data.tags) |t| {
            if (std.mem.eql(u8, t, tag)) return true;
        }
        return false;
    }
};

// ---------------------------------------------------------------------------
// Worker
// ---------------------------------------------------------------------------

pub const Config = struct {
    root: []const u8,
    /// Parsed at startup; owned by the caller (not freed on worker stop).
    taxonomy: Taxonomy,
    turn_function: []const u8 = "zygos::turns::run",
    provider_function: ?[]const u8 = null,
    router_function: ?[]const u8 = null,
    checkpoint_function: ?[]const u8 = null,
};

pub const CaptureWorker = struct {
    gpa: std.mem.Allocator,
    worker: *inproc.Worker,
    config: Config,

    pub fn start(
        gpa: std.mem.Allocator,
        actor: *actor_mod.Actor,
        registry: *inproc.Registry,
        config: Config,
    ) !*CaptureWorker {
        const self = try gpa.create(CaptureWorker);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .worker = try inproc.Worker.spawn(gpa, actor, registry, "tessera-capture"),
            .config = config,
        };
        errdefer self.worker.stop();
        try self.worker.registerFunction("zygos::tessera::capture", self, &captureHandler);
        return self;
    }

    pub fn stop(self: *CaptureWorker) void {
        self.worker.stop();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn captureHandler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *CaptureWorker = @ptrCast(@alignCast(ctx.?));
        const root = json.parseFromSliceLeaky(json.Value, arena, request_json, .{}) catch return error.Failed;
        if (root != .object) return error.Failed;
        const obj = root.object;

        const input_raw = strField(obj, "input") orelse return error.Failed;
        const date = strField(obj, "date") orelse return error.Failed;
        if (std.mem.trim(u8, date, " \t\r\n").len == 0) return error.Failed;
        const input = std.mem.trim(u8, input_raw, " \t\r\n");
        if (input.len == 0) return error.Failed;

        // 1–2. Classify; any imperfection → full fallback (never lose a capture).
        const classified = try self.classify(arena, input);

        // 3. Checkpoint seam (W5): fail closed before any write.
        if (self.config.checkpoint_function) |fn_id| {
            try self.callCheckpoint(arena, fn_id, classified.destination.name);
        }

        // 4. Append capture block (create parents + atomic tmp+rename).
        const abs = try std.fmt.allocPrint(arena, "{s}/{s}", .{
            self.config.root,
            classified.destination.path,
        });
        const existing = try readFileOrEmpty(arena, abs);
        const tags_line = try joinTags(arena, classified.tags);
        const block = try std.fmt.allocPrint(arena, "\n## Capture — {s}\n{s}\n\n{s}\n", .{
            date,
            tags_line,
            input,
        });
        const out_bytes = try std.fmt.allocPrint(arena, "{s}{s}", .{ existing, block });
        try writeAtomic(self.gpa, abs, out_bytes);

        // 5. Reply.
        return try replyJson(arena, classified.destination.name, classified.destination.path, classified.tags, classified.fallback);
    }

    const Classified = struct {
        destination: Destination,
        tags: []const []const u8,
        fallback: bool,
    };

    fn classify(self: *CaptureWorker, arena: std.mem.Allocator, input: []const u8) error{ OutOfMemory, Failed }!Classified {
        const fallback_dest = self.config.taxonomy.find(self.config.taxonomy.data.fallback) orelse
            return error.Failed; // parse already enforces this; belt-and-braces
        const fallback_tags = try arena.dupe([]const u8, &[_][]const u8{"#needs-review"});
        const fallback_result = Classified{
            .destination = fallback_dest,
            .tags = fallback_tags,
            .fallback = true,
        };

        const system = try buildSystemPrompt(arena, &self.config.taxonomy);

        var req: std.Io.Writer.Allocating = .init(arena);
        errdefer req.deinit();
        const w = &req.writer;
        w.print("{{\"system\":{f},\"step_id\":\"tessera-capture\",\"max_steps\":1," ++
            "\"messages\":[{{\"role\":\"user\",\"content\":{f}}}]", .{
            json.fmt(system, .{}),
            json.fmt(input, .{}),
        }) catch return error.OutOfMemory;
        if (self.config.provider_function) |v|
            w.print(",\"provider_function\":{f}", .{json.fmt(v, .{})}) catch return error.OutOfMemory;
        if (self.config.router_function) |v|
            w.print(",\"router_function\":{f}", .{json.fmt(v, .{})}) catch return error.OutOfMemory;
        w.writeAll("}") catch return error.OutOfMemory;

        const res = self.worker.call(self.config.turn_function, req.written()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Shutdown => return fallback_result,
        };
        switch (res) {
            .err => |code| {
                defer self.gpa.free(code);
                return fallback_result;
            },
            .ok => |payload| {
                defer self.gpa.free(payload);
                return (try self.parseClassifierReply(arena, payload)) orelse fallback_result;
            },
        }
    }

    /// Full-trust parse: any imperfection returns null (caller falls back).
    fn parseClassifierReply(self: *CaptureWorker, arena: std.mem.Allocator, payload: []const u8) error{OutOfMemory}!?Classified {
        const reply = json.parseFromSliceLeaky(json.Value, arena, payload, .{}) catch return null;
        if (reply != .object) return null;
        const stop_reason = strField(reply.object, "stop") orelse return null;
        if (!std.mem.eql(u8, stop_reason, "end_turn")) return null;

        const transcript = reply.object.get("transcript") orelse return null;
        if (transcript != .array) return null;
        var i = transcript.array.items.len;
        var assistant_text: ?[]const u8 = null;
        while (i > 0) {
            i -= 1;
            const msg = transcript.array.items[i];
            if (msg != .object) continue;
            const mrole = strField(msg.object, "role") orelse continue;
            if (!std.mem.eql(u8, mrole, "assistant")) continue;
            assistant_text = try assistantText(arena, msg.object);
            break;
        }
        const text = assistant_text orelse return null;
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) return null;

        const body = json.parseFromSliceLeaky(json.Value, arena, text, .{}) catch return null;
        if (body != .object) return null;

        const dest_name = strField(body.object, "destination") orelse return null;
        const dest = self.config.taxonomy.find(dest_name) orelse return null;

        const tags_val = body.object.get("tags") orelse return null;
        if (tags_val != .array) return null;
        var tags: std.ArrayList([]const u8) = .empty;
        for (tags_val.array.items) |tv| {
            if (tv != .string) return null;
            if (!self.config.taxonomy.tagAllowed(tv.string)) return null;
            try tags.append(arena, tv.string);
        }
        return .{
            .destination = dest,
            .tags = try tags.toOwnedSlice(arena),
            .fallback = false,
        };
    }

    fn callCheckpoint(self: *CaptureWorker, arena: std.mem.Allocator, fn_id: []const u8, label: []const u8) error{ Failed, OutOfMemory }!void {
        const req = std.fmt.allocPrint(arena, "{{\"label\":{f}}}", .{json.fmt(label, .{})}) catch
            return error.OutOfMemory;
        const res = self.worker.call(fn_id, req) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Shutdown => return error.Failed,
        };
        switch (res) {
            .ok => |payload| self.gpa.free(payload),
            .err => |code| {
                defer self.gpa.free(code);
                return error.Failed;
            },
        }
    }
};

fn buildSystemPrompt(arena: std.mem.Allocator, taxonomy: *const Taxonomy) error{OutOfMemory}![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    errdefer out.deinit();
    const w = &out.writer;
    w.writeAll(
        \\Classify the user's note. Reply with ONLY a JSON object of the form
        \\{"destination":"<name>","tags":["#tag",...]} — no prose, no markdown.
        \\
        \\Destinations:
        \\
    ) catch return error.OutOfMemory;
    for (taxonomy.data.destinations) |d| {
        w.print("- {s}: {s}\n", .{ d.name, d.description }) catch return error.OutOfMemory;
    }
    w.writeAll("\nAllowed tags (use only these, including the leading '#'):\n") catch return error.OutOfMemory;
    for (taxonomy.data.tags, 0..) |t, i| {
        if (i > 0) w.writeAll(" ") catch return error.OutOfMemory;
        w.writeAll(t) catch return error.OutOfMemory;
    }
    w.writeAll("\n") catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

/// Concatenated text blocks of an assistant message (mission.zig idiom).
fn assistantText(arena: std.mem.Allocator, msg: json.ObjectMap) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const content = msg.get("content") orelse return out.toOwnedSlice(arena);
    switch (content) {
        .string => |s| try out.appendSlice(arena, s),
        .array => |blocks| for (blocks.items) |b| {
            if (b != .object) continue;
            const btype = strField(b.object, "type") orelse continue;
            if (!std.mem.eql(u8, btype, "text")) continue;
            if (strField(b.object, "text")) |t| try out.appendSlice(arena, t);
        },
        else => {},
    }
    return out.toOwnedSlice(arena);
}

fn joinTags(arena: std.mem.Allocator, tags: []const []const u8) error{OutOfMemory}![]const u8 {
    if (tags.len == 0) return try arena.dupe(u8, "");
    return std.mem.join(arena, " ", tags) catch return error.OutOfMemory;
}

fn replyJson(
    arena: std.mem.Allocator,
    destination: []const u8,
    path: []const u8,
    tags: []const []const u8,
    fallback: bool,
) error{OutOfMemory}![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    errdefer out.deinit();
    const w = &out.writer;
    w.print("{{\"destination\":{f},\"path\":{f},\"tags\":[", .{
        json.fmt(destination, .{}),
        json.fmt(path, .{}),
    }) catch return error.OutOfMemory;
    for (tags, 0..) |t, i| {
        if (i > 0) w.writeAll(",") catch return error.OutOfMemory;
        w.print("{f}", .{json.fmt(t, .{})}) catch return error.OutOfMemory;
    }
    w.print("],\"fallback\":{}}}", .{fallback}) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn strField(obj: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// Missing file ⇒ empty owned text. Other open failures also empty.
fn readFileOrEmpty(allocator: std.mem.Allocator, path: []const u8) error{OutOfMemory}![]const u8 {
    const path_z = std.fmt.allocPrintSentinel(allocator, "{s}", .{path}, 0) catch return error.OutOfMemory;
    const fd = c.open(path_z, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return try allocator.dupe(u8, "");
    defer _ = c.close(fd);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = c.read(fd, &chunk, chunk.len);
        if (n < 0) {
            buf.deinit(allocator);
            return try allocator.dupe(u8, "");
        }
        if (n == 0) break;
        buf.appendSlice(allocator, chunk[0..@intCast(n)]) catch return error.OutOfMemory;
    }
    return buf.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

/// mkdir -p over every prefix of an absolute path (EEXIST is fine).
fn mkdirP(gpa: std.mem.Allocator, abs: []const u8) error{ Failed, OutOfMemory }!void {
    var end: usize = 1;
    while (end <= abs.len) : (end += 1) {
        if (end == abs.len or abs[end] == '/') {
            const dir_z = gpa.dupeZ(u8, abs[0..end]) catch return error.OutOfMemory;
            defer gpa.free(dir_z);
            _ = c.mkdir(dir_z, 0o755);
        }
    }
}

/// Atomic tmp+rename write (mission_store idiom). Creates parent directories.
fn writeAtomic(gpa: std.mem.Allocator, path: []const u8, bytes: []const u8) error{ Failed, OutOfMemory }!void {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
        try mkdirP(gpa, path[0..slash]);
    }

    const tmp_z = std.fmt.allocPrintSentinel(gpa, "{s}.tmp", .{path}, 0) catch return error.OutOfMemory;
    defer gpa.free(tmp_z);
    const final_z = gpa.dupeZ(u8, path) catch return error.OutOfMemory;
    defer gpa.free(final_z);

    const fd = c.open(tmp_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o644));
    if (fd < 0) return error.Failed;
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n <= 0) {
            _ = c.close(fd);
            return error.Failed;
        }
        off += @intCast(n);
    }
    if (c.close(fd) != 0) return error.Failed;
    if (c.rename(tmp_z, final_z) != 0) return error.Failed;
}

// ===========================================================================
// Tests (docs/specs/tessera-capture.md contract, RED first)
// ===========================================================================

const testing = std.testing;

extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;

fn escJson(comptime s: []const u8) []const u8 {
    comptime var out: []const u8 = "";
    inline for (s) |ch| {
        out = out ++ switch (ch) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            else => &[_]u8{ch},
        };
    }
    return out;
}

/// Provider terminal message whose single text block is `inner`.
fn roleText(comptime inner: []const u8) []const u8 {
    return "{\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"text\",\"text\":\"" ++
        comptime escJson(inner) ++ "\"}]}";
}

const test_taxonomy_zon: [:0]const u8 =
    \\.{
    \\    .destinations = .{
    \\        .{ .name = "ideas", .path = "Rumbles/Fleetings.md", .description = "fleeting thoughts" },
    \\        .{ .name = "decisions", .path = "Decisions/Log.md", .description = "decisions made" },
    \\    },
    \\    .tags = .{ "#needs-review", "#idea", "#decision" },
    \\    .fallback = "ideas",
    \\}
;

const valid_decisions = roleText("{\"destination\":\"decisions\",\"tags\":[\"#decision\"]}");
const valid_ideas = roleText("{\"destination\":\"ideas\",\"tags\":[\"#idea\"]}");
const malformed_json = roleText("not json at all");
const unknown_dest = roleText("{\"destination\":\"nope\",\"tags\":[\"#idea\"]}");
const bad_tag = roleText("{\"destination\":\"decisions\",\"tags\":[\"#evil\"]}");
const non_end_turn =
    \\{"stop_reason":"max_tokens","content":[{"type":"text","text":"{\"destination\":\"decisions\",\"tags\":[\"#decision\"]}"}]}
;

/// Scripted provider that records every request (mission.zig RecProvider pattern).
const RecProvider = struct {
    gpa: std.mem.Allocator,
    worker: *inproc.Worker,
    mutex: sync.Mutex = .{},
    script: []const []const u8,
    calls: usize = 0,
    requests: std.ArrayList([]u8) = .empty,

    fn start(gpa: std.mem.Allocator, actor: *actor_mod.Actor, registry: *inproc.Registry, script: []const []const u8) !*RecProvider {
        const self = try gpa.create(RecProvider);
        self.* = .{
            .gpa = gpa,
            .worker = try inproc.Worker.spawn(gpa, actor, registry, "rec-provider"),
            .script = script,
        };
        try self.worker.registerFunction("zygos::provider::rec::messages", self, &handler);
        return self;
    }

    fn stop(self: *RecProvider) void {
        self.worker.stop();
        for (self.requests.items) |r| self.gpa.free(r);
        self.requests.deinit(self.gpa);
        self.mutex.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn handler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *RecProvider = @ptrCast(@alignCast(ctx.?));
        const n = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            const dup = try self.gpa.dupe(u8, request_json);
            self.requests.append(self.gpa, dup) catch return error.OutOfMemory;
            const n = self.calls;
            self.calls += 1;
            break :blk n;
        };
        if (self.script.len == 0) return error.Failed;
        const msg = self.script[@min(n, self.script.len - 1)];
        if (std.mem.eql(u8, msg, "ERR")) return error.Failed;
        return arena.dupe(u8, msg);
    }
};

/// In-test fake for the checkpoint seam. `fail` ⇒ handler returns error.Failed.
const FakeCheckpoint = struct {
    gpa: std.mem.Allocator,
    worker: *inproc.Worker,
    fail: bool,
    calls: usize = 0,

    fn start(gpa: std.mem.Allocator, actor: *actor_mod.Actor, registry: *inproc.Registry, fail: bool) !*FakeCheckpoint {
        const self = try gpa.create(FakeCheckpoint);
        self.* = .{
            .gpa = gpa,
            .worker = try inproc.Worker.spawn(gpa, actor, registry, if (fail) "fake-cp-fail" else "fake-cp-ok"),
            .fail = fail,
        };
        try self.worker.registerFunction("test::checkpoint", self, &handler);
        return self;
    }

    fn stop(self: *FakeCheckpoint) void {
        self.worker.stop();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn handler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *FakeCheckpoint = @ptrCast(@alignCast(ctx.?));
        _ = request_json;
        self.calls += 1;
        if (self.fail) return error.Failed;
        return arena.dupe(u8, "{\"checkpoint_id\":\"fake\"}");
    }
};

const Harness = struct {
    registry: inproc.Registry,
    actor: actor_mod.Actor,
    kernel: std.Thread,
    turns: *turn_mod.TurnOrchestrator,
    capture: *CaptureWorker,
    provider: *RecProvider,
    caller: *inproc.Worker,
    taxonomy: Taxonomy,
    tmp: std.testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8 = undefined,
    root: []const u8 = undefined,

    fn init(gpa: std.mem.Allocator, script: []const []const u8, checkpoint_function: ?[]const u8) !*Harness {
        const self = try gpa.create(Harness);
        errdefer gpa.destroy(self);
        self.tmp = std.testing.tmpDir(.{});
        var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
        const rel = try std.fmt.bufPrintZ(&rel_buf, ".zig-cache/tmp/{s}", .{self.tmp.sub_path});
        const resolved = realpath(rel, &self.root_buf) orelse return error.RealpathFailed;
        self.root = std.mem.span(resolved);

        self.taxonomy = try Taxonomy.parse(gpa, test_taxonomy_zon);

        self.registry = inproc.Registry.init(gpa, null);
        self.actor = try actor_mod.Actor.init(gpa, .{}, self.registry.outbound());
        self.kernel = try std.Thread.spawn(.{}, actor_mod.Actor.run, .{&self.actor});
        self.turns = try turn_mod.TurnOrchestrator.start(gpa, &self.actor, &self.registry);
        self.provider = try RecProvider.start(gpa, &self.actor, &self.registry, script);
        self.capture = try CaptureWorker.start(gpa, &self.actor, &self.registry, .{
            .root = self.root,
            .taxonomy = self.taxonomy,
            .provider_function = "zygos::provider::rec::messages",
            .checkpoint_function = checkpoint_function,
        });
        self.caller = try inproc.Worker.spawn(gpa, &self.actor, &self.registry, "test-caller");
        return self;
    }

    fn deinit(self: *Harness) void {
        const gpa = self.actor.gpa;
        self.caller.stop();
        self.capture.stop();
        self.provider.stop();
        self.turns.stop();
        self.actor.post(.shutdown);
        self.kernel.join();
        self.actor.deinit();
        self.registry.deinit();
        self.taxonomy.deinit();
        self.tmp.cleanup();
        gpa.destroy(self);
    }

    fn vaultPath(self: *Harness, rel: []const u8) ![]u8 {
        return std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ self.root, rel });
    }

    fn readAbs(self: *Harness, abs: []const u8) ![]u8 {
        _ = self;
        var a = std.heap.ArenaAllocator.init(testing.allocator);
        defer a.deinit();
        const text = try readFileOrEmpty(a.allocator(), abs);
        return testing.allocator.dupe(u8, text);
    }

    fn fileExistsAbs(self: *Harness, abs: []const u8) bool {
        _ = self;
        var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        if (abs.len >= path_buf.len) return false;
        @memcpy(path_buf[0..abs.len], abs);
        path_buf[abs.len] = 0;
        const fd = c.open(@ptrCast(path_buf[0..abs.len :0]), .{ .ACCMODE = .RDONLY });
        if (fd < 0) return false;
        _ = c.close(fd);
        return true;
    }
};

const Parsed = struct {
    parsed: json.Parsed(json.Value),
    fn deinit(self: *Parsed) void {
        self.parsed.deinit();
    }
    fn root(self: *Parsed) json.Value {
        return self.parsed.value;
    }
};

fn parseOk(payload: []const u8) !Parsed {
    return .{ .parsed = try json.parseFromSlice(json.Value, testing.allocator, payload, .{}) };
}

fn captureReq(comptime input: []const u8, comptime date: []const u8) []const u8 {
    return "{\"input\":\"" ++ input ++ "\",\"date\":\"" ++ date ++ "\"}";
}

test "taxonomy parse rejects empty destinations and unknown fallback (BadTaxonomy)" {
    try testing.expectError(error.BadTaxonomy, Taxonomy.parse(testing.allocator,
        \\.{ .destinations = .{}, .tags = .{}, .fallback = "ideas" }
    ));
    try testing.expectError(error.BadTaxonomy, Taxonomy.parse(testing.allocator,
        \\.{
        \\    .destinations = .{
        \\        .{ .name = "ideas", .path = "x.md", .description = "d" },
        \\    },
        \\    .tags = .{},
        \\    .fallback = "missing",
        \\}
    ));

    var ok = try Taxonomy.parse(testing.allocator, test_taxonomy_zon);
    defer ok.deinit();
    try testing.expectEqual(@as(usize, 2), ok.data.destinations.len);
    try testing.expect(ok.find("ideas") != null);
    try testing.expect(ok.find("nope") == null);
}

test "classifier's valid destination+tags routes the note there; file contains input verbatim" {
    var h = try Harness.init(testing.allocator, &.{valid_decisions}, null);
    defer h.deinit();

    const input = "Ship the gizmo by Friday — no half measures.";
    const req = try std.fmt.allocPrint(testing.allocator, "{{\"input\":{f},\"date\":\"2024-06-01 14:00\"}}", .{json.fmt(input, .{})});
    defer testing.allocator.free(req);

    const res = try h.caller.call("zygos::tessera::capture", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    var p = try parseOk(res.ok);
    defer p.deinit();
    try testing.expectEqualStrings("decisions", p.root().object.get("destination").?.string);
    try testing.expectEqualStrings("Decisions/Log.md", p.root().object.get("path").?.string);
    try testing.expectEqual(false, p.root().object.get("fallback").?.bool);
    try testing.expectEqual(@as(usize, 1), p.root().object.get("tags").?.array.items.len);
    try testing.expectEqualStrings("#decision", p.root().object.get("tags").?.array.items[0].string);

    const path = try h.vaultPath("Decisions/Log.md");
    defer testing.allocator.free(path);
    const text = try h.readAbs(path);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, input) != null);
    try testing.expect(std.mem.indexOf(u8, text, "## Capture — 2024-06-01 14:00") != null);
    try testing.expect(std.mem.indexOf(u8, text, "#decision") != null);
}

test "capture creates the destination file and parents on first write" {
    var h = try Harness.init(testing.allocator, &.{valid_decisions}, null);
    defer h.deinit();

    const path = try h.vaultPath("Decisions/Log.md");
    defer testing.allocator.free(path);
    try testing.expect(!h.fileExistsAbs(path));

    const res = try h.caller.call("zygos::tessera::capture", captureReq("first note ever", "2024-06-02 09:00"));
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try testing.expect(h.fileExistsAbs(path));

    const text = try h.readAbs(path);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "first note ever") != null);
}

test "malformed classifier JSON falls back to ideas + #needs-review; input not lost" {
    var h = try Harness.init(testing.allocator, &.{malformed_json}, null);
    defer h.deinit();

    const input = "orphan thought that must not vanish";
    const req = try std.fmt.allocPrint(testing.allocator, "{{\"input\":{f},\"date\":\"2024-06-03 10:00\"}}", .{json.fmt(input, .{})});
    defer testing.allocator.free(req);

    const res = try h.caller.call("zygos::tessera::capture", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    var p = try parseOk(res.ok);
    defer p.deinit();
    try testing.expectEqualStrings("ideas", p.root().object.get("destination").?.string);
    try testing.expectEqualStrings("Rumbles/Fleetings.md", p.root().object.get("path").?.string);
    try testing.expectEqual(true, p.root().object.get("fallback").?.bool);
    try testing.expectEqual(@as(usize, 1), p.root().object.get("tags").?.array.items.len);
    try testing.expectEqualStrings("#needs-review", p.root().object.get("tags").?.array.items[0].string);

    const path = try h.vaultPath("Rumbles/Fleetings.md");
    defer testing.allocator.free(path);
    const text = try h.readAbs(path);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, input) != null);
    try testing.expect(std.mem.indexOf(u8, text, "#needs-review") != null);
}

test "unknown destination name falls back" {
    var h = try Harness.init(testing.allocator, &.{unknown_dest}, null);
    defer h.deinit();

    const res = try h.caller.call("zygos::tessera::capture", captureReq("where does this go", "2024-06-04 11:00"));
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    var p = try parseOk(res.ok);
    defer p.deinit();
    try testing.expectEqualStrings("ideas", p.root().object.get("destination").?.string);
    try testing.expectEqual(true, p.root().object.get("fallback").?.bool);
}

test "tag outside the vocabulary falls back (no partial trust)" {
    // Good destination "decisions" + bad tag ⇒ full fallback, not partial.
    var h = try Harness.init(testing.allocator, &.{bad_tag}, null);
    defer h.deinit();

    const res = try h.caller.call("zygos::tessera::capture", captureReq("partial trust trap", "2024-06-05 12:00"));
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    var p = try parseOk(res.ok);
    defer p.deinit();
    try testing.expectEqualStrings("ideas", p.root().object.get("destination").?.string);
    try testing.expectEqual(true, p.root().object.get("fallback").?.bool);
    try testing.expectEqualStrings("#needs-review", p.root().object.get("tags").?.array.items[0].string);

    // Must not have written to decisions.
    const decisions = try h.vaultPath("Decisions/Log.md");
    defer testing.allocator.free(decisions);
    try testing.expect(!h.fileExistsAbs(decisions));

    const ideas = try h.vaultPath("Rumbles/Fleetings.md");
    defer testing.allocator.free(ideas);
    const text = try h.readAbs(ideas);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "partial trust trap") != null);
}

test "provider error / non-end_turn stop falls back (turn ran, capture survived)" {
    // Provider hard-error.
    {
        var h = try Harness.init(testing.allocator, &.{"ERR"}, null);
        defer h.deinit();

        const res = try h.caller.call("zygos::tessera::capture", captureReq("survives provider crash", "2024-06-06 13:00"));
        defer res.deinit(testing.allocator);
        try testing.expect(res == .ok);

        var p = try parseOk(res.ok);
        defer p.deinit();
        try testing.expectEqualStrings("ideas", p.root().object.get("destination").?.string);
        try testing.expectEqual(true, p.root().object.get("fallback").?.bool);

        const path = try h.vaultPath("Rumbles/Fleetings.md");
        defer testing.allocator.free(path);
        const text = try h.readAbs(path);
        defer testing.allocator.free(text);
        try testing.expect(std.mem.indexOf(u8, text, "survives provider crash") != null);
    }

    // Non-end_turn stop (max_tokens) with otherwise-valid body still falls back.
    {
        var h = try Harness.init(testing.allocator, &.{non_end_turn}, null);
        defer h.deinit();

        const res = try h.caller.call("zygos::tessera::capture", captureReq("survives max_tokens", "2024-06-06 13:30"));
        defer res.deinit(testing.allocator);
        try testing.expect(res == .ok);

        var p = try parseOk(res.ok);
        defer p.deinit();
        try testing.expectEqualStrings("ideas", p.root().object.get("destination").?.string);
        try testing.expectEqual(true, p.root().object.get("fallback").?.bool);

        const path = try h.vaultPath("Rumbles/Fleetings.md");
        defer testing.allocator.free(path);
        const text = try h.readAbs(path);
        defer testing.allocator.free(text);
        try testing.expect(std.mem.indexOf(u8, text, "survives max_tokens") != null);
    }
}

test "blank input is error.Failed, nothing written" {
    var h = try Harness.init(testing.allocator, &.{valid_ideas}, null);
    defer h.deinit();

    const res = try h.caller.call("zygos::tessera::capture", captureReq("", "2024-06-07 08:00"));
    defer res.deinit(testing.allocator);
    try testing.expect(res == .err);
    try testing.expectEqualStrings("handler_failed", res.err);

    const res2 = try h.caller.call("zygos::tessera::capture", captureReq("   ", "2024-06-07 08:00"));
    defer res2.deinit(testing.allocator);
    try testing.expect(res2 == .err);

    const ideas = try h.vaultPath("Rumbles/Fleetings.md");
    defer testing.allocator.free(ideas);
    try testing.expect(!h.fileExistsAbs(ideas));
    try testing.expectEqual(@as(usize, 0), h.provider.calls);
}

test "configured checkpoint_function failure blocks the write (fail closed)" {
    // Success path: checkpoint ok, write proceeds.
    {
        var h = try Harness.init(testing.allocator, &.{valid_ideas}, "test::checkpoint");
        defer h.deinit();
        const fake = try FakeCheckpoint.start(testing.allocator, &h.actor, &h.registry, false);
        defer fake.stop();

        const res = try h.caller.call("zygos::tessera::capture", captureReq("after checkpoint", "2024-06-08 09:00"));
        defer res.deinit(testing.allocator);
        try testing.expect(res == .ok);
        try testing.expectEqual(@as(usize, 1), fake.calls);

        const path = try h.vaultPath("Rumbles/Fleetings.md");
        defer testing.allocator.free(path);
        const text = try h.readAbs(path);
        defer testing.allocator.free(text);
        try testing.expect(std.mem.indexOf(u8, text, "after checkpoint") != null);
    }

    // Fail-closed: checkpoint fails ⇒ no write.
    {
        var h = try Harness.init(testing.allocator, &.{valid_ideas}, "test::checkpoint");
        defer h.deinit();
        const fake = try FakeCheckpoint.start(testing.allocator, &h.actor, &h.registry, true);
        defer fake.stop();

        const res = try h.caller.call("zygos::tessera::capture", captureReq("should not appear", "2024-06-08 10:00"));
        defer res.deinit(testing.allocator);
        try testing.expect(res == .err);
        try testing.expectEqual(@as(usize, 1), fake.calls);

        const path = try h.vaultPath("Rumbles/Fleetings.md");
        defer testing.allocator.free(path);
        try testing.expect(!h.fileExistsAbs(path));
    }
}

test "classification turn carries step_id \"tessera-capture\" (assert on the fake provider's recorded request)" {
    // step_id is not re-serialized into the provider request body (turn.zig
    // only forwards model/system/messages/tools/stream_channel). Prove it
    // the way mission.zig does: a router whose only ladder is
    // step_id "tessera-capture" → rec provider. Wrong step_id ⇒
    // route_exhausted ⇒ fallback, and the rec provider would never see a call.
    // CaptureWorker is started with router_function (not static provider).
    const gpa = testing.allocator;
    var h_tmp = std.testing.tmpDir(.{});
    defer h_tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel = try std.fmt.bufPrintZ(&rel_buf, ".zig-cache/tmp/{s}", .{h_tmp.sub_path});
    const resolved = realpath(rel, &root_buf) orelse return error.RealpathFailed;
    const root = std.mem.span(resolved);

    var taxonomy = try Taxonomy.parse(gpa, test_taxonomy_zon);
    defer taxonomy.deinit();

    var registry = inproc.Registry.init(gpa, null);
    defer registry.deinit();
    var actor = try actor_mod.Actor.init(gpa, .{}, registry.outbound());
    defer actor.deinit();
    const kernel = try std.Thread.spawn(.{}, actor_mod.Actor.run, .{&actor});
    defer {
        actor.post(.shutdown);
        kernel.join();
    }

    const turns = try turn_mod.TurnOrchestrator.start(gpa, &actor, &registry);
    defer turns.stop();
    const provider = try RecProvider.start(gpa, &actor, &registry, &.{valid_ideas});
    defer provider.stop();

    const router_mod = @import("router.zig");
    const zon =
        \\.{ .routes = .{
        \\    .{ .step_id = "tessera-capture", .attempts = .{
        \\        .{ .provider_function = "zygos::provider::rec::messages", .model = "capture-cheap" },
        \\    } },
        \\} }
    ;
    const rcfg = try router_mod.Config.parse(gpa, zon);
    const router = try router_mod.RouterWorker.start(gpa, &actor, &registry, rcfg);
    defer router.stop();

    const capture = try CaptureWorker.start(gpa, &actor, &registry, .{
        .root = root,
        .taxonomy = taxonomy,
        .router_function = "zygos::models::resolve",
        .provider_function = null,
    });
    defer capture.stop();
    const caller = try inproc.Worker.spawn(gpa, &actor, &registry, "test-caller-step");
    defer caller.stop();

    const res = try caller.call("zygos::tessera::capture", captureReq("check step id", "2024-06-09 11:00"));
    defer res.deinit(gpa);
    try testing.expect(res == .ok);

    var p = try parseOk(res.ok);
    defer p.deinit();
    // Non-fallback means the turn resolved a provider — only tessera-capture routes.
    try testing.expectEqual(false, p.root().object.get("fallback").?.bool);

    try testing.expect(provider.requests.items.len >= 1);
    const req = provider.requests.items[0];
    // Model is what the tessera-capture ladder yields — proves step_id matched.
    try testing.expect(std.mem.indexOf(u8, req, "capture-cheap") != null);
    // No tools on the classification turn (tools array is empty, not omitted).
    try testing.expect(std.mem.indexOf(u8, req, "\"tools\":[]") != null);
}

test "no leaks" {
    var h = try Harness.init(testing.allocator, &.{ valid_decisions, valid_ideas, malformed_json }, null);
    defer h.deinit();

    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const a = try h.caller.call("zygos::tessera::capture", captureReq("loop note A", "2024-06-10 12:00"));
        a.deinit(testing.allocator);
        const b = try h.caller.call("zygos::tessera::capture", captureReq("loop note B", "2024-06-10 12:01"));
        b.deinit(testing.allocator);
        const blank = try h.caller.call("zygos::tessera::capture", captureReq("", "2024-06-10 12:02"));
        blank.deinit(testing.allocator);
    }
}
