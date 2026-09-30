//! Shared provider catalog (X1, docs/specs/providers.md). Parses the
//! operator's `~/.agents/providers.toml` shape with a minimal in-repo TOML
//! subset parser — `std` only, no dependency. Pure module: `Catalog.parse`
//! takes TOML text and env lookups are injected as pairs; the binary reads
//! the file and the real environment (same Z-02 split as `router.Config`).
//! Validation is fail-closed: an invalid file yields no catalog.

const std = @import("std");

pub const Error = error{ OutOfMemory, ParseToml, InvalidCatalog };

/// Set on error: 1-based line of the offending line (for parse errors) or of
/// the entry's `[[...]]` header (for validation errors), plus a static message.
pub const Diag = struct {
    line: usize = 0,
    message: []const u8 = "",
};

pub const ProviderKind = enum { openai_compatible, anthropic_compatible, google, ollama };

/// Injected environment: tests never touch the real process env.
pub const EnvPair = struct { name: []const u8, value: []const u8 };

fn envGet(env: []const EnvPair, name: []const u8) ?[]const u8 {
    for (env) |p| if (std.mem.eql(u8, p.name, name)) return p.value;
    return null;
}

pub const Provider = struct {
    name: []const u8,
    kind: ProviderKind,
    model: []const u8,
    key_env: ?[]const u8 = null,
    key: ?[]const u8 = null,
    endpoint: ?[]const u8 = null,
    max_tokens: ?u32 = null,
    temperature: ?f64 = null,

    /// key_env's var if present in env, else the inline key, else null
    /// (a local endpoint may need none — X2 decides what null means).
    pub fn resolveKey(self: Provider, env: []const EnvPair) ?[]const u8 {
        if (self.key_env) |ke| if (envGet(env, ke)) |v| return v;
        return self.key;
    }
};

pub const Cli = struct {
    name: []const u8,
    command: []const u8,
    args: []const []const u8 = &.{},
};

/// Bus registration slug for a provider name: lowercase, every run of
/// non-alphanumerics collapses to one `-`, leading/trailing runs dropped.
/// X2 registers `zygos::providers::<slug>`. Caller owns the result.
pub fn slug(gpa: std.mem.Allocator, name: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var pending = false;
    for (name) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (pending and out.items.len > 0) try out.append(gpa, '-');
            pending = false;
            try out.append(gpa, std.ascii.toLower(c));
        } else pending = true;
    }
    return out.toOwnedSlice(gpa);
}

pub const ModelLookupError = error{ OutOfMemory, ModelNotFound, ModelAmbiguous, ModelKind };

/// Bus function for the one catalog row whose `model` equals `model`.
/// Only an anthropic-compatible row is returned. Two rows, an unknown
/// model, or any other backend is a refusal. Caller owns the result.
pub fn functionForModel(gpa: std.mem.Allocator, catalog: *const Catalog, model: []const u8) ModelLookupError![]u8 {
    var found: ?Provider = null;
    for (catalog.providers) |entry| {
        if (!std.mem.eql(u8, entry.model, model)) continue;
        if (found != null) return error.ModelAmbiguous;
        found = entry;
    }
    const entry = found orelse return error.ModelNotFound;
    if (entry.kind != .anthropic_compatible) return error.ModelKind;
    const s = try slug(gpa, entry.name);
    defer gpa.free(s);
    return std.fmt.allocPrint(gpa, "zygos::providers::{s}", .{s}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
}

/// `AI_PROVIDERS_CONFIG` override, else `<HOME>/.agents/providers.toml`.
/// Caller owns the result.
pub fn configPath(gpa: std.mem.Allocator, env: []const EnvPair) error{ OutOfMemory, NoHome }![]u8 {
    if (envGet(env, "AI_PROVIDERS_CONFIG")) |p| return gpa.dupe(u8, p);
    const home = envGet(env, "HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(gpa, "{s}/.agents/providers.toml", .{home});
}

pub const Catalog = struct {
    arena: std.heap.ArenaAllocator,
    providers: []const Provider,
    clis: []const Cli,

    pub fn parse(gpa: std.mem.Allocator, toml_text: []const u8, diag: ?*Diag) Error!Catalog {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        errdefer arena_state.deinit();
        const arena = arena_state.allocator();

        var pbuilds: std.ArrayList(ProviderBuild) = .empty;
        var cbuilds: std.ArrayList(CliBuild) = .empty;
        var section: Section = .none;
        var line_no: usize = 0;
        var it = std.mem.splitScalar(u8, toml_text, '\n');
        while (it.next()) |raw_line| {
            line_no += 1;
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') {
                section = try parseHeader(arena, line, line_no, diag, &pbuilds, &cbuilds);
                continue;
            }
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse
                return fail(diag, line_no, "expected 'key = value'", error.ParseToml);
            const key = std.mem.trim(u8, line[0..eq], " \t");
            if (key.len == 0) return fail(diag, line_no, "empty key", error.ParseToml);
            const value = try parseValue(arena, line[eq + 1 ..], line_no, diag);
            switch (section) {
                .none => return fail(diag, line_no, "key outside a table", error.ParseToml),
                .unknown => {},
                .providers => try assignProvider(&pbuilds.items[pbuilds.items.len - 1], key, value, line_no, diag),
                .clis => try assignCli(&cbuilds.items[cbuilds.items.len - 1], key, value, line_no, diag),
            }
        }

        const providers = try validateProviders(arena, pbuilds.items, diag);
        const clis = try validateClis(arena, cbuilds.items, diag);
        return .{ .arena = arena_state, .providers = providers, .clis = clis };
    }

    pub fn deinit(self: *Catalog) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

// ── parsing internals ────────────────────────────────────────────────────────

const Section = enum { none, providers, clis, unknown };

const ProviderBuild = struct {
    line: usize,
    name: ?[]const u8 = null,
    kind_str: ?[]const u8 = null,
    key_env: ?[]const u8 = null,
    key: ?[]const u8 = null,
    endpoint: ?[]const u8 = null,
    model: ?[]const u8 = null,
    max_tokens: ?i64 = null,
    temperature: ?f64 = null,
};

const CliBuild = struct {
    line: usize,
    name: ?[]const u8 = null,
    command: ?[]const u8 = null,
    args: ?[]const []const u8 = null,
};

const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    string_array: []const []const u8,
};

fn fail(diag: ?*Diag, line: usize, message: []const u8, err: Error) Error {
    if (diag) |d| d.* = .{ .line = line, .message = message };
    return err;
}

fn parseHeader(
    arena: std.mem.Allocator,
    line: []const u8,
    line_no: usize,
    diag: ?*Diag,
    pbuilds: *std.ArrayList(ProviderBuild),
    cbuilds: *std.ArrayList(CliBuild),
) Error!Section {
    if (!std.mem.startsWith(u8, line, "[["))
        return fail(diag, line_no, "only [[array-of-table]] headers are supported", error.ParseToml);
    const end = std.mem.indexOf(u8, line, "]]") orelse
        return fail(diag, line_no, "unterminated table header", error.ParseToml);
    if (!restIsCommentOrWs(line[end + 2 ..]))
        return fail(diag, line_no, "junk after table header", error.ParseToml);
    const name = std.mem.trim(u8, line[2..end], " \t");
    if (std.mem.eql(u8, name, "providers")) {
        try pbuilds.append(arena, .{ .line = line_no });
        return .providers;
    }
    if (std.mem.eql(u8, name, "clis")) {
        try cbuilds.append(arena, .{ .line = line_no });
        return .clis;
    }
    return .unknown; // unknown sections are skipped whole (forward compat)
}

fn restIsCommentOrWs(s: []const u8) bool {
    const trimmed = std.mem.trim(u8, s, " \t\r");
    return trimmed.len == 0 or trimmed[0] == '#';
}

const ParsedString = struct { value: []const u8, consumed: usize };

/// `text` starts at the opening quote. Decodes \" \\ \n \t only.
fn parseString(arena: std.mem.Allocator, text: []const u8, line_no: usize, diag: ?*Diag) Error!ParsedString {
    std.debug.assert(text[0] == '"');
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 1;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        switch (c) {
            '"' => return .{ .value = try out.toOwnedSlice(arena), .consumed = i + 1 },
            '\\' => {
                i += 1;
                if (i >= text.len) return fail(diag, line_no, "unterminated string", error.ParseToml);
                const decoded: u8 = switch (text[i]) {
                    '"' => '"',
                    '\\' => '\\',
                    'n' => '\n',
                    't' => '\t',
                    else => return fail(diag, line_no, "unsupported string escape", error.ParseToml),
                };
                try out.append(arena, decoded);
            },
            else => try out.append(arena, c),
        }
    }
    return fail(diag, line_no, "unterminated string", error.ParseToml);
}

fn parseValue(arena: std.mem.Allocator, text_in: []const u8, line_no: usize, diag: ?*Diag) Error!Value {
    const text = std.mem.trimStart(u8, text_in, " \t");
    if (text.len == 0) return fail(diag, line_no, "missing value", error.ParseToml);
    switch (text[0]) {
        '"' => {
            const s = try parseString(arena, text, line_no, diag);
            if (!restIsCommentOrWs(text[s.consumed..]))
                return fail(diag, line_no, "junk after string value", error.ParseToml);
            return .{ .string = s.value };
        },
        '[' => {
            var items: std.ArrayList([]const u8) = .empty;
            var i: usize = 1;
            while (true) {
                while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
                if (i >= text.len) return fail(diag, line_no, "unterminated array", error.ParseToml);
                if (text[i] == ']') {
                    i += 1;
                    break;
                }
                if (text[i] != '"') return fail(diag, line_no, "arrays may hold only strings", error.ParseToml);
                const s = try parseString(arena, text[i..], line_no, diag);
                try items.append(arena, s.value);
                i += s.consumed;
                while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
                if (i >= text.len) return fail(diag, line_no, "unterminated array", error.ParseToml);
                if (text[i] == ',') {
                    i += 1;
                } else if (text[i] != ']') {
                    return fail(diag, line_no, "expected ',' or ']' in array", error.ParseToml);
                }
            }
            if (!restIsCommentOrWs(text[i..]))
                return fail(diag, line_no, "junk after array value", error.ParseToml);
            return .{ .string_array = try items.toOwnedSlice(arena) };
        },
        else => {
            const end = std.mem.indexOfAny(u8, text, " \t#") orelse text.len;
            const token = text[0..end];
            if (!restIsCommentOrWs(text[end..]))
                return fail(diag, line_no, "junk after value", error.ParseToml);
            const is_float = std.mem.indexOfAny(u8, token, ".eE") != null;
            if (is_float) {
                const f = std.fmt.parseFloat(f64, token) catch
                    return fail(diag, line_no, "invalid number", error.ParseToml);
                return .{ .float = f };
            }
            const n = std.fmt.parseInt(i64, token, 10) catch
                return fail(diag, line_no, "invalid value", error.ParseToml);
            return .{ .integer = n };
        },
    }
}

fn wantString(value: Value, line_no: usize, diag: ?*Diag) Error![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => fail(diag, line_no, "wrong value type for key", error.ParseToml),
    };
}

fn assignProvider(b: *ProviderBuild, key: []const u8, value: Value, line_no: usize, diag: ?*Diag) Error!void {
    if (std.mem.eql(u8, key, "name")) {
        b.name = try wantString(value, line_no, diag);
    } else if (std.mem.eql(u8, key, "type")) {
        b.kind_str = try wantString(value, line_no, diag);
    } else if (std.mem.eql(u8, key, "key_env")) {
        b.key_env = try wantString(value, line_no, diag);
    } else if (std.mem.eql(u8, key, "key")) {
        b.key = try wantString(value, line_no, diag);
    } else if (std.mem.eql(u8, key, "endpoint")) {
        b.endpoint = try wantString(value, line_no, diag);
    } else if (std.mem.eql(u8, key, "model")) {
        b.model = try wantString(value, line_no, diag);
    } else if (std.mem.eql(u8, key, "max_tokens")) {
        b.max_tokens = switch (value) {
            .integer => |n| n,
            else => return fail(diag, line_no, "wrong value type for key", error.ParseToml),
        };
    } else if (std.mem.eql(u8, key, "temperature")) {
        b.temperature = switch (value) {
            .float => |f| f,
            .integer => |n| @floatFromInt(n),
            else => return fail(diag, line_no, "wrong value type for key", error.ParseToml),
        };
    } // unknown keys skipped (schema allows additional properties)
}

fn assignCli(b: *CliBuild, key: []const u8, value: Value, line_no: usize, diag: ?*Diag) Error!void {
    if (std.mem.eql(u8, key, "name")) {
        b.name = try wantString(value, line_no, diag);
    } else if (std.mem.eql(u8, key, "command")) {
        b.command = try wantString(value, line_no, diag);
    } else if (std.mem.eql(u8, key, "args")) {
        b.args = switch (value) {
            .string_array => |a| a,
            else => return fail(diag, line_no, "wrong value type for key", error.ParseToml),
        };
    } // unknown keys skipped
}

// ── validation (fail closed) ─────────────────────────────────────────────────

fn validateProviders(arena: std.mem.Allocator, builds: []const ProviderBuild, diag: ?*Diag) Error![]const Provider {
    const providers = try arena.alloc(Provider, builds.len);
    const slugs = try arena.alloc([]const u8, builds.len);
    for (builds, 0..) |b, i| {
        const name = b.name orelse return fail(diag, b.line, "provider missing 'name'", error.InvalidCatalog);
        const kind_str = b.kind_str orelse return fail(diag, b.line, "provider missing 'type'", error.InvalidCatalog);
        const model = b.model orelse return fail(diag, b.line, "provider missing 'model'", error.InvalidCatalog);
        const kind = std.meta.stringToEnum(ProviderKind, kind_str) orelse
            return fail(diag, b.line, "unknown provider 'type'", error.InvalidCatalog);
        if ((kind == .openai_compatible or kind == .anthropic_compatible or kind == .ollama) and b.endpoint == null)
            return fail(diag, b.line, "provider missing 'endpoint'", error.InvalidCatalog);
        if (b.max_tokens) |mt| if (mt < 1)
            return fail(diag, b.line, "'max_tokens' must be >= 1", error.InvalidCatalog);
        if (b.temperature) |temp| if (temp < 0 or temp > 2)
            return fail(diag, b.line, "'temperature' must be in [0, 2]", error.InvalidCatalog);
        providers[i] = .{
            .name = name,
            .kind = kind,
            .model = model,
            .key_env = b.key_env,
            .key = b.key,
            .endpoint = b.endpoint,
            .max_tokens = if (b.max_tokens) |mt| @intCast(mt) else null,
            .temperature = b.temperature,
        };
        slugs[i] = try slug(arena, name);
        for (0..i) |j| {
            if (std.mem.eql(u8, providers[j].name, name))
                return fail(diag, b.line, "duplicate provider 'name'", error.InvalidCatalog);
            if (std.mem.eql(u8, slugs[j], slugs[i]))
                return fail(diag, b.line, "duplicate provider slug", error.InvalidCatalog);
        }
    }
    return providers;
}

fn validateClis(arena: std.mem.Allocator, builds: []const CliBuild, diag: ?*Diag) Error![]const Cli {
    const clis = try arena.alloc(Cli, builds.len);
    for (builds, 0..) |b, i| {
        clis[i] = .{
            .name = b.name orelse return fail(diag, b.line, "cli missing 'name'", error.InvalidCatalog),
            .command = b.command orelse return fail(diag, b.line, "cli missing 'command'", error.InvalidCatalog),
            .args = b.args orelse &.{},
        };
    }
    return clis;
}

// ── tests (X1 contract, docs/specs/providers.md) ─────────────────────────────

const t = std.testing;

// Real-shaped fixture: mirrors ~/.agents/providers.toml (which tests must
// never read — it may carry inline key fallbacks). Fake values throughout.
const fixture =
    \\# shared catalog fixture
    \\
    \\[[providers]]
    \\name     = "NVidia DeepseekV4 Pro"
    \\type     = "openai_compatible"
    \\key_env  = "NVIDIA_API_KEY"
    \\# key    = "nvapi-..."
    \\endpoint = "https://integrate.api.nvidia.com/v1"
    \\model    = "deepseek-ai/deepseek-v4-pro"
    \\max_tokens  = 16384
    \\temperature = 1
    \\
    \\[[providers]]
    \\name     = "NVidia Minimax M3"
    \\type     = "openai_compatible"
    \\key_env  = "NVIDIA_API_KEY"
    \\endpoint = "https://integrate.api.nvidia.com/v1"
    \\model    = "minimaxai/minimax-m3"
    \\max_tokens  = 8192
    \\temperature = 1
    \\
    \\[[providers]]
    \\name     = "Kimi K2.7"
    \\type     = "openai_compatible"
    \\key_env  = "KIMI_API_KEY"
    \\endpoint = "https://api.moonshot.cn/v1"
    \\model    = "moonshot-v1-8k"
    \\max_tokens  = 4096
    \\temperature = 0.7
    \\
    \\[[providers]]
    \\name     = "OpenRouter MiMo-V2.5"
    \\type     = "openai_compatible"
    \\key_env  = "OPENROUTER_API_KEY"
    \\endpoint = "https://openrouter.ai/api/v1"
    \\model    = "xiaomi/mimo-v2.5"
    \\max_tokens  = 131072
    \\temperature = 1
    \\
    \\[[providers]]
    \\name     = "Deepseek Flash"
    \\type     = "openai_compatible"
    \\key_env  = "DEEPSEEK_API_KEY"
    \\endpoint = "https://openrouter.ai/api/v1"
    \\model    = "deepseek-v4-flash"
    \\max_tokens  = 8192
    \\temperature = 0.7
    \\
    \\[[providers]]
    \\name     = "Google Gemini 3.5-flash"
    \\type     = "google"
    \\key_env  = "GOOGLE_API_KEY"
    \\model    = "gemini-3.5-flash"
    \\max_tokens  = 65000
    \\temperature = 1
    \\
    \\[[providers]]
    \\name     = "GLM 5.2"
    \\type     = "openai_compatible"
    \\key_env  = "Z_AI_API_KEY"
    \\endpoint = "https://open.bigmodel.cn/api/paas/v4"
    \\model    = "glm-5.2"
    \\max_tokens  = 131072
    \\temperature = 0.7
    \\
    \\[[providers]]
    \\name     = "Ollama Qwen3 Coder Next"
    \\type     = "openai_compatible"
    \\endpoint = "http://localhost:11434/v1"
    \\model    = "qwen3-coder-next"
    \\key      = "qwen3-coder-next"
    \\max_tokens  = 8192
    \\temperature = 0.7
    \\
    \\[[providers]]
    \\name     = "Anthropic Claude Sonnet"
    \\type     = "anthropic_compatible"
    \\key_env  = "ANTHROPIC_API_KEY"
    \\endpoint = "https://api.anthropic.com"
    \\model    = "claude-sonnet-4"
    \\max_tokens  = 8192
    \\temperature = 1
    \\
    \\[[clis]]
    \\name    = "claude"
    \\command = "claude"
    \\args    = ["-p"]
    \\
    \\[[clis]]
    \\name    = "opencode"
    \\command = "opencode"
    \\args    = ["run"]
;

test "parse: real-shaped fixture (9 providers incl google + local + anthropic, 2 clis) round-trips every field" {
    var cat = try Catalog.parse(t.allocator, fixture, null);
    defer cat.deinit();

    try t.expectEqual(@as(usize, 9), cat.providers.len);
    try t.expectEqual(@as(usize, 2), cat.clis.len);

    const first = cat.providers[0];
    try t.expectEqualStrings("NVidia DeepseekV4 Pro", first.name);
    try t.expectEqual(ProviderKind.openai_compatible, first.kind);
    try t.expectEqualStrings("NVIDIA_API_KEY", first.key_env.?);
    try t.expectEqual(@as(?[]const u8, null), first.key);
    try t.expectEqualStrings("https://integrate.api.nvidia.com/v1", first.endpoint.?);
    try t.expectEqualStrings("deepseek-ai/deepseek-v4-pro", first.model);
    try t.expectEqual(@as(u32, 16384), first.max_tokens.?);
    try t.expectEqual(@as(f64, 1), first.temperature.?);

    const google = cat.providers[5];
    try t.expectEqual(ProviderKind.google, google.kind);
    try t.expectEqual(@as(?[]const u8, null), google.endpoint);
    try t.expectEqualStrings("gemini-3.5-flash", google.model);

    const local = cat.providers[7];
    try t.expectEqual(@as(?[]const u8, null), local.key_env);
    try t.expectEqualStrings("qwen3-coder-next", local.key.?);
    try t.expectEqual(@as(f64, 0.7), local.temperature.?);

    const anthropic = cat.providers[8];
    try t.expectEqual(ProviderKind.anthropic_compatible, anthropic.kind);
    try t.expectEqualStrings("ANTHROPIC_API_KEY", anthropic.key_env.?);
    try t.expectEqualStrings("https://api.anthropic.com", anthropic.endpoint.?);
    try t.expectEqualStrings("claude-sonnet-4", anthropic.model);

    try t.expectEqualStrings("claude", cat.clis[0].name);
    try t.expectEqualStrings("claude", cat.clis[0].command);
    try t.expectEqual(@as(usize, 1), cat.clis[0].args.len);
    try t.expectEqualStrings("-p", cat.clis[0].args[0]);
    try t.expectEqualStrings("run", cat.clis[1].args[0]);
}

test "parse: comments, trailing comments, blank lines ignored" {
    const text =
        \\# leading comment
        \\
        \\[[providers]]  # trailing on header
        \\name  = "A"    # trailing on string
        \\type  = "google"
        \\model = "m"    # another
        \\max_tokens = 5 # trailing on number
    ;
    var cat = try Catalog.parse(t.allocator, text, null);
    defer cat.deinit();
    try t.expectEqual(@as(usize, 1), cat.providers.len);
    try t.expectEqual(@as(u32, 5), cat.providers[0].max_tokens.?);
}

test "parse: unknown keys and unknown array-of-table sections skipped" {
    const text =
        \\[[extras]]
        \\whatever = "ignored"
        \\count = 3
        \\[[providers]]
        \\name = "A"
        \\type = "google"
        \\model = "m"
        \\future_knob = "ignored"
    ;
    var cat = try Catalog.parse(t.allocator, text, null);
    defer cat.deinit();
    try t.expectEqual(@as(usize, 1), cat.providers.len);
    try t.expectEqualStrings("A", cat.providers[0].name);
}

test "parse: string escapes decoded; unsupported escape is ParseToml with line" {
    const good =
        \\[[providers]]
        \\name = "A\"B\\C\nD\tE"
        \\type = "google"
        \\model = "m"
    ;
    var cat = try Catalog.parse(t.allocator, good, null);
    defer cat.deinit();
    try t.expectEqualStrings("A\"B\\C\nD\tE", cat.providers[0].name);

    const bad =
        \\[[providers]]
        \\name = "bad\qescape"
        \\type = "google"
        \\model = "m"
    ;
    var diag: Diag = .{};
    try t.expectError(error.ParseToml, Catalog.parse(t.allocator, bad, &diag));
    try t.expectEqual(@as(usize, 2), diag.line);
    try t.expectEqualStrings("unsupported string escape", diag.message);
}

test "parse: malformed input is ParseToml, no leaks" {
    const cases = [_][]const u8{
        "[[providers]]\nname = \"unclosed",
        "[providers]\nname = \"x\"",
        "[[providers]]\njust junk with no equals",
        "name = \"key outside any table\"",
        "[[providers]\nname = \"x\"",
        "[[providers]] trailing junk",
        "[[providers]]\nname = ",
        "[[providers]]\nmax_tokens = 12x4",
        "[[clis]]\nargs = [\"a\" \"b\"]",
        "[[clis]]\nargs = [1, 2]",
        "[[providers]]\nname = \"x\" junk-after-value",
    };
    for (cases) |case| {
        var diag: Diag = .{};
        try t.expectError(error.ParseToml, Catalog.parse(t.allocator, case, &diag));
        try t.expect(diag.line > 0);
    }
}

test "validate: missing name/type/model is InvalidCatalog, diag names the field" {
    const missing_name = "[[providers]]\ntype = \"google\"\nmodel = \"m\"";
    var diag: Diag = .{};
    try t.expectError(error.InvalidCatalog, Catalog.parse(t.allocator, missing_name, &diag));
    try t.expectEqualStrings("provider missing 'name'", diag.message);
    try t.expectEqual(@as(usize, 1), diag.line); // entry header line

    const missing_type = "[[providers]]\nname = \"a\"\nmodel = \"m\"";
    try t.expectError(error.InvalidCatalog, Catalog.parse(t.allocator, missing_type, &diag));
    try t.expectEqualStrings("provider missing 'type'", diag.message);

    const missing_model = "[[providers]]\nname = \"a\"\ntype = \"google\"";
    try t.expectError(error.InvalidCatalog, Catalog.parse(t.allocator, missing_model, &diag));
    try t.expectEqualStrings("provider missing 'model'", diag.message);
}

test "validate: openai_compatible, anthropic_compatible or ollama without endpoint is InvalidCatalog" {
    const oa = "[[providers]]\nname = \"a\"\ntype = \"openai_compatible\"\nmodel = \"m\"";
    var diag: Diag = .{};
    try t.expectError(error.InvalidCatalog, Catalog.parse(t.allocator, oa, &diag));
    try t.expectEqualStrings("provider missing 'endpoint'", diag.message);

    const an = "[[providers]]\nname = \"a\"\ntype = \"anthropic_compatible\"\nmodel = \"m\"";
    try t.expectError(error.InvalidCatalog, Catalog.parse(t.allocator, an, &diag));
    try t.expectEqualStrings("provider missing 'endpoint'", diag.message);

    const ol = "[[providers]]\nname = \"a\"\ntype = \"ollama\"\nmodel = \"m\"";
    try t.expectError(error.InvalidCatalog, Catalog.parse(t.allocator, ol, &diag));
    try t.expectEqualStrings("provider missing 'endpoint'", diag.message);

    // google needs no endpoint
    const g = "[[providers]]\nname = \"a\"\ntype = \"google\"\nmodel = \"m\"";
    var cat = try Catalog.parse(t.allocator, g, null);
    defer cat.deinit();
    try t.expectEqual(@as(usize, 1), cat.providers.len);
}

test "validate: unknown type enum is InvalidCatalog" {
    const text = "[[providers]]\nname = \"a\"\ntype = \"anthropic\"\nmodel = \"m\"";
    var diag: Diag = .{};
    try t.expectError(error.InvalidCatalog, Catalog.parse(t.allocator, text, &diag));
    try t.expectEqualStrings("unknown provider 'type'", diag.message);
}

test "validate: temperature out of [0,2] or max_tokens < 1 is InvalidCatalog" {
    const hot = "[[providers]]\nname = \"a\"\ntype = \"google\"\nmodel = \"m\"\ntemperature = 2.1";
    var diag: Diag = .{};
    try t.expectError(error.InvalidCatalog, Catalog.parse(t.allocator, hot, &diag));
    try t.expectEqualStrings("'temperature' must be in [0, 2]", diag.message);

    const cold = "[[providers]]\nname = \"a\"\ntype = \"google\"\nmodel = \"m\"\ntemperature = -1";
    try t.expectError(error.InvalidCatalog, Catalog.parse(t.allocator, cold, &diag));

    const zero = "[[providers]]\nname = \"a\"\ntype = \"google\"\nmodel = \"m\"\nmax_tokens = 0";
    try t.expectError(error.InvalidCatalog, Catalog.parse(t.allocator, zero, &diag));
    try t.expectEqualStrings("'max_tokens' must be >= 1", diag.message);
}

test "validate: duplicate provider name and slug-colliding names are InvalidCatalog" {
    const dup_name =
        \\[[providers]]
        \\name = "A"
        \\type = "google"
        \\model = "m"
        \\[[providers]]
        \\name = "A"
        \\type = "google"
        \\model = "m2"
    ;
    var diag: Diag = .{};
    try t.expectError(error.InvalidCatalog, Catalog.parse(t.allocator, dup_name, &diag));
    try t.expectEqualStrings("duplicate provider 'name'", diag.message);
    try t.expectEqual(@as(usize, 5), diag.line); // second entry's header

    const dup_slug =
        \\[[providers]]
        \\name = "GLM 5.2"
        \\type = "google"
        \\model = "m"
        \\[[providers]]
        \\name = "glm 5-2"
        \\type = "google"
        \\model = "m2"
    ;
    try t.expectError(error.InvalidCatalog, Catalog.parse(t.allocator, dup_slug, &diag));
    try t.expectEqualStrings("duplicate provider slug", diag.message);
}

test "validate: cli missing command is InvalidCatalog" {
    const text = "[[clis]]\nname = \"claude\"";
    var diag: Diag = .{};
    try t.expectError(error.InvalidCatalog, Catalog.parse(t.allocator, text, &diag));
    try t.expectEqualStrings("cli missing 'command'", diag.message);
}

test "resolveKey: key_env present in env wins; absent falls back to inline key; neither is null" {
    const p = Provider{
        .name = "a",
        .kind = .google,
        .model = "m",
        .key_env = "MY_KEY",
        .key = "inline-fallback",
    };
    const env = [_]EnvPair{.{ .name = "MY_KEY", .value = "from-env" }};
    try t.expectEqualStrings("from-env", p.resolveKey(&env).?);
    try t.expectEqualStrings("inline-fallback", p.resolveKey(&.{}).?);

    const bare = Provider{ .name = "b", .kind = .google, .model = "m", .key_env = "MISSING" };
    try t.expectEqual(@as(?[]const u8, null), bare.resolveKey(&.{}));
}

test "slug: mixed case, spaces, punctuation, leading/trailing junk" {
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "NVidia DeepseekV4 Pro", .out = "nvidia-deepseekv4-pro" },
        .{ .in = "GLM 5.2", .out = "glm-5-2" },
        .{ .in = "Ollama Qwen3 Coder Next", .out = "ollama-qwen3-coder-next" },
        .{ .in = "  A/B (test)! ", .out = "a-b-test" },
        .{ .in = "OpenRouter MiMo-V2.5", .out = "openrouter-mimo-v2-5" },
    };
    for (cases) |case| {
        const s = try slug(t.allocator, case.in);
        defer t.allocator.free(s);
        try t.expectEqualStrings(case.out, s);
    }
}

test "functionForModel maps the approved pilot model and refuses the rest" {
    const toml =
        \\[[providers]]
        \\name = "GLM Flash"
        \\type = "anthropic_compatible"
        \\model = "glm-5.3-flash"
        \\endpoint = "https://api.z.ai/api/anthropic"
        \\
        \\[[providers]]
        \\name = "GLM 5.2"
        \\type = "openai_compatible"
        \\model = "glm-5.3"
        \\endpoint = "https://example.invalid"
    ;
    var cat = try Catalog.parse(t.allocator, toml, null);
    defer cat.deinit();
    const fn_name = try functionForModel(t.allocator, &cat, "glm-5.3-flash");
    defer t.allocator.free(fn_name);
    try t.expectEqualStrings("zygos::providers::glm-flash", fn_name);
    try t.expectError(error.ModelKind, functionForModel(t.allocator, &cat, "glm-5.3"));
    try t.expectError(error.ModelNotFound, functionForModel(t.allocator, &cat, "glm5.3-flash"));

    const duped =
        \\[[providers]]
        \\name = "GLM Flash"
        \\type = "anthropic_compatible"
        \\model = "glm-5.3-flash"
        \\endpoint = "https://api.z.ai/api/anthropic"
        \\
        \\[[providers]]
        \\name = "GLM Flash Copy"
        \\type = "anthropic_compatible"
        \\model = "glm-5.3-flash"
        \\endpoint = "https://api.z.ai/api/anthropic"
    ;
    var two = try Catalog.parse(t.allocator, duped, null);
    defer two.deinit();
    try t.expectError(error.ModelAmbiguous, functionForModel(t.allocator, &two, "glm-5.3-flash"));

    const wrong_kind =
        \\[[providers]]
        \\name = "GLM Flash"
        \\type = "openai_compatible"
        \\model = "glm-5.3-flash"
        \\endpoint = "https://example.invalid"
    ;
    var openai = try Catalog.parse(t.allocator, wrong_kind, null);
    defer openai.deinit();
    try t.expectError(error.ModelKind, functionForModel(t.allocator, &openai, "glm-5.3-flash"));
}

test "configPath: AI_PROVIDERS_CONFIG override, else HOME fallback" {
    const override = [_]EnvPair{
        .{ .name = "AI_PROVIDERS_CONFIG", .value = "/etc/agents/alt.toml" },
        .{ .name = "HOME", .value = "/home/u" },
    };
    const p1 = try configPath(t.allocator, &override);
    defer t.allocator.free(p1);
    try t.expectEqualStrings("/etc/agents/alt.toml", p1);

    const home_only = [_]EnvPair{.{ .name = "HOME", .value = "/home/u" }};
    const p2 = try configPath(t.allocator, &home_only);
    defer t.allocator.free(p2);
    try t.expectEqualStrings("/home/u/.agents/providers.toml", p2);

    try t.expectError(error.NoHome, configPath(t.allocator, &.{}));
}

test "no leaks across parse/deinit loops incl. error paths" {
    for (0..3) |_| {
        var cat = try Catalog.parse(t.allocator, fixture, null);
        cat.deinit();
        try t.expectError(error.ParseToml, Catalog.parse(t.allocator, "[[providers]]\nname = \"unclosed", null));
        try t.expectError(error.InvalidCatalog, Catalog.parse(t.allocator, "[[providers]]\nname = \"a\"", null));
    }
}
