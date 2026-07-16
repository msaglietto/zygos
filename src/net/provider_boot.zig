//! Catalog → bus provider boot (X2, docs/specs/provider-boot.md).
//!
//! Boots one openai-compat provider worker instance per `providers.toml`
//! catalog entry (X1), each registered as `zygos::providers::<slug>`. Lives
//! in `src/net/` because instances hold `std.Io` (Z-02 boundary).
//! `zig build test` never opens a socket — registration and config plumbing
//! only; handlers are probed with non-object request bytes so they fail
//! before any HTTP.

const std = @import("std");
const actor_mod = @import("../kernel/actor.zig");
const inproc = @import("../kernel/inproc.zig");
const providers_catalog = @import("../config/providers.zig");
const router = @import("../worker/router.zig");
const provider_openai = @import("provider_openai.zig");
const provider_anthropic = @import("provider_anthropic.zig");
const openai = @import("openai.zig");
const stream_guard = @import("stream_guard.zig");

/// Gemini OpenAI-compat base when a `google` entry has no endpoint.
pub const gemini_compat_base_url = "https://generativelanguage.googleapis.com/v1beta/openai";

const providers_prefix = "zygos::providers::";

/// One booted provider worker. A catalog entry's `type` selects the backend:
/// `anthropic_compatible` speaks the Anthropic Messages wire, everything else
/// (incl. `google` via the Gemini compat base) speaks OpenAI chat-completions.
/// Both register under the same `zygos::providers::<slug>` name so routing in
/// zygos.zon stays uniform across provider types.
const Instance = union(enum) {
    openai: *provider_openai.OpenAiProvider,
    anthropic: *provider_anthropic.AnthropicProvider,

    fn stop(self: Instance) void {
        switch (self) {
            inline else => |inst| inst.stop(),
        }
    }
};

/// Owns `std.Io.Threaded` so binary entry points (Z-02: no std.Io in main)
/// can boot catalog providers without naming the Io type themselves.
pub const IoBoot = struct {
    backing: std.Io.Threaded,

    pub fn start(gpa: std.mem.Allocator) IoBoot {
        return .{ .backing = std.Io.Threaded.init(gpa, .{}) };
    }

    pub fn io(self: *IoBoot) std.Io {
        return self.backing.io();
    }

    pub fn stop(self: *IoBoot) void {
        self.backing.deinit();
        self.* = undefined;
    }
};

pub const CatalogBoot = struct {
    gpa: std.mem.Allocator,
    instances: []Instance,

    /// One instance per catalog provider entry. `[[clis]]` are ignored.
    /// `api_key` is resolveKey(env) or `""` — never a boot error. The entry's
    /// `type` selects the backend (anthropic_compatible ⇒ Anthropic Messages,
    /// otherwise OpenAI chat-completions); both register `zygos::providers::<slug>`.
    pub fn start(
        gpa: std.mem.Allocator,
        actor: *actor_mod.Actor,
        registry: *inproc.Registry,
        io: std.Io,
        catalog: *const providers_catalog.Catalog,
        env: []const providers_catalog.EnvPair,
    ) !CatalogBoot {
        const instances = try gpa.alloc(Instance, catalog.providers.len);
        errdefer gpa.free(instances);
        var n: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < n) : (i += 1) instances[i].stop();
        }

        const idle_ms = streamIdleMs(env) orelse stream_guard.default_idle_ms;
        for (catalog.providers) |entry| {
            const s = try providers_catalog.slug(gpa, entry.name);
            defer gpa.free(s);
            const fn_name = try std.fmt.allocPrint(gpa, "{s}{s}", .{ providers_prefix, s });
            defer gpa.free(fn_name);

            const base_url = entry.endpoint orelse blk: {
                std.debug.assert(entry.kind == .google);
                break :blk gemini_compat_base_url;
            };
            const api_key = entry.resolveKey(env) orelse "";

            instances[n] = switch (entry.kind) {
                .anthropic_compatible => .{ .anthropic = try provider_anthropic.AnthropicProvider.startWith(gpa, actor, registry, io, .{
                    .worker_name = s,
                    .function_name = fn_name,
                    .api_key = api_key,
                    .base_url = base_url,
                    .default_model = entry.model,
                    .default_max_tokens = entry.max_tokens,
                    .default_temperature = entry.temperature,
                    .idle_timeout_ms = idle_ms,
                }) },
                else => .{ .openai = try provider_openai.OpenAiProvider.startWith(gpa, actor, registry, io, .{
                    .worker_name = s,
                    .function_name = fn_name,
                    .api_key = api_key,
                    .base_url = base_url,
                    .default_model = entry.model,
                    .default_max_tokens = entry.max_tokens,
                    .default_temperature = entry.temperature,
                    .idle_timeout_ms = idle_ms,
                }) },
            };
            n += 1;
        }

        return .{ .gpa = gpa, .instances = instances };
    }

    pub fn stop(self: *CatalogBoot) void {
        for (self.instances) |inst| inst.stop();
        self.gpa.free(self.instances);
        self.* = undefined;
    }
};

/// ZYGOS_STREAM_IDLE_MS: per-request idle timeout override for every booted
/// provider stream (0 disables the guard). Absent or unparsable ⇒ null and
/// the client default applies.
pub fn streamIdleMs(env: []const providers_catalog.EnvPair) ?u64 {
    for (env) |p| {
        if (!std.mem.eql(u8, p.name, "ZYGOS_STREAM_IDLE_MS")) continue;
        return std.fmt.parseInt(u64, p.value, 10) catch null;
    }
    return null;
}

/// Fail closed at startup: every `zygos::providers::*` function in any ladder
/// (including `.default`) must name a slug present in the catalog. Other
/// function names pass untouched.
pub fn checkRoutes(
    catalog: *const providers_catalog.Catalog,
    router_config: *const router.Config,
) error{UnknownProviderSlug}!void {
    try checkLadder(catalog, router_config.data.default);
    for (router_config.data.routes) |r| try checkLadder(catalog, r.attempts);
}

fn checkLadder(catalog: *const providers_catalog.Catalog, attempts: []const router.Attempt) error{UnknownProviderSlug}!void {
    for (attempts) |a| {
        if (!std.mem.startsWith(u8, a.provider_function, providers_prefix)) continue;
        const want = a.provider_function[providers_prefix.len..];
        if (!catalogHasSlug(catalog, want)) return error.UnknownProviderSlug;
    }
}

/// Non-allocating slug check: re-derives each entry's slug into a stack buffer.
fn catalogHasSlug(catalog: *const providers_catalog.Catalog, want: []const u8) bool {
    var buf: [256]u8 = undefined;
    for (catalog.providers) |entry| {
        const s = slugInto(&buf, entry.name) orelse continue;
        if (std.mem.eql(u8, s, want)) return true;
    }
    return false;
}

fn slugInto(buf: []u8, name: []const u8) ?[]const u8 {
    var len: usize = 0;
    var pending = false;
    for (name) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (pending and len > 0) {
                if (len >= buf.len) return null;
                buf[len] = '-';
                len += 1;
            }
            pending = false;
            if (len >= buf.len) return null;
            buf[len] = std.ascii.toLower(c);
            len += 1;
        } else pending = true;
    }
    return buf[0..len];
}

// ===========================================================================
// Tests (X2 contract, docs/specs/provider-boot.md) — no sockets, no network
// ===========================================================================

const testing = std.testing;

/// Real-shaped subset of the X1 fixture (enough for boot plumbing).
const fixture =
    \\[[providers]]
    \\name     = "NVidia DeepseekV4 Pro"
    \\type     = "openai_compatible"
    \\key_env  = "NVIDIA_API_KEY"
    \\endpoint = "https://integrate.api.nvidia.com/v1"
    \\model    = "deepseek-ai/deepseek-v4-pro"
    \\max_tokens  = 16384
    \\temperature = 1
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
;

const Harness = struct {
    registry: inproc.Registry,
    actor: actor_mod.Actor,
    kernel: std.Thread,
    caller: *inproc.Worker,
    io_backing: std.Io.Threaded,

    fn init(gpa: std.mem.Allocator) !*Harness {
        const self = try gpa.create(Harness);
        errdefer gpa.destroy(self);
        self.io_backing = std.Io.Threaded.init(gpa, .{});
        errdefer self.io_backing.deinit();
        self.registry = inproc.Registry.init(gpa, null);
        self.actor = try actor_mod.Actor.init(gpa, .{}, self.registry.outbound());
        self.kernel = try std.Thread.spawn(.{}, actor_mod.Actor.run, .{&self.actor});
        self.caller = try inproc.Worker.spawn(gpa, &self.actor, &self.registry, "test-caller");
        return self;
    }

    fn deinit(self: *Harness) void {
        const gpa = self.actor.gpa;
        self.caller.stop();
        self.actor.post(.shutdown);
        self.kernel.join();
        self.actor.deinit();
        self.registry.deinit();
        self.io_backing.deinit();
        gpa.destroy(self);
    }

    fn io(self: *Harness) std.Io {
        return self.io_backing.io();
    }
};

test "boot: fixture catalog registers zygos::providers::<slug> per entry" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var cat = try providers_catalog.Catalog.parse(testing.allocator, fixture, null);
    defer cat.deinit();

    var boot = try CatalogBoot.start(testing.allocator, &h.actor, &h.registry, h.io(), &cat, &.{});
    defer boot.stop();

    try testing.expectEqual(@as(usize, 4), boot.instances.len);

    // The anthropic_compatible entry boots the Anthropic backend; all others
    // (incl. google) the OpenAI backend — both under zygos::providers::<slug>.
    try testing.expect(boot.instances[3] == .anthropic);
    try testing.expect(boot.instances[0] == .openai);

    // Non-object JSON → handler returns Failed → bus error handler_failed.
    // Proves registration + handler wiring without any HTTP.
    const slugs = [_][]const u8{
        "nvidia-deepseekv4-pro",
        "google-gemini-3-5-flash",
        "ollama-qwen3-coder-next",
        "anthropic-claude-sonnet",
    };
    for (slugs) |s| {
        const fn_name = try std.fmt.allocPrint(testing.allocator, "{s}{s}", .{ providers_prefix, s });
        defer testing.allocator.free(fn_name);
        const res = try h.caller.call(fn_name, "\"not-a-request-object\"");
        defer res.deinit(testing.allocator);
        try testing.expect(res == .err);
        try testing.expectEqualStrings("handler_failed", res.err);
    }

    // clis must not register anything
    const missing = try h.caller.call("zygos::providers::claude", "\"x\"");
    defer missing.deinit(testing.allocator);
    try testing.expect(missing == .err);
    try testing.expectEqualStrings("function_not_found", missing.err);
}

test "boot: google entry with no endpoint gets the Gemini compat base_url" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var cat = try providers_catalog.Catalog.parse(testing.allocator, fixture, null);
    defer cat.deinit();

    var boot = try CatalogBoot.start(testing.allocator, &h.actor, &h.registry, h.io(), &cat, &.{});
    defer boot.stop();

    // Index 1 is the google entry in the fixture.
    try testing.expectEqualStrings(gemini_compat_base_url, boot.instances[1].openai.base_url);
    try testing.expectEqualStrings("https://integrate.api.nvidia.com/v1", boot.instances[0].openai.base_url);
    try testing.expectEqualStrings("http://localhost:11434/v1", boot.instances[2].openai.base_url);
    // Index 3 is the anthropic_compatible entry — endpoint verbatim.
    try testing.expectEqualStrings("https://api.anthropic.com", boot.instances[3].anthropic.base_url);
}

test "boot: api_key resolution — env var wins, inline key falls back, neither ⇒ \"\"" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var cat = try providers_catalog.Catalog.parse(testing.allocator, fixture, null);
    defer cat.deinit();

    // Env provides NVIDIA + ANTHROPIC keys; GOOGLE missing → ""; ollama inline.
    const env = [_]providers_catalog.EnvPair{
        .{ .name = "NVIDIA_API_KEY", .value = "nv-from-env" },
        .{ .name = "ANTHROPIC_API_KEY", .value = "sk-ant-from-env" },
    };
    var boot = try CatalogBoot.start(testing.allocator, &h.actor, &h.registry, h.io(), &cat, &env);
    defer boot.stop();

    try testing.expectEqualStrings("nv-from-env", boot.instances[0].openai.api_key);
    try testing.expectEqualStrings("", boot.instances[1].openai.api_key);
    try testing.expectEqualStrings("qwen3-coder-next", boot.instances[2].openai.api_key);
    try testing.expectEqualStrings("sk-ant-from-env", boot.instances[3].anthropic.api_key);
}

test "boot: instance defaults carry the entry's model/max_tokens/temperature" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var cat = try providers_catalog.Catalog.parse(testing.allocator, fixture, null);
    defer cat.deinit();

    var boot = try CatalogBoot.start(testing.allocator, &h.actor, &h.registry, h.io(), &cat, &.{});
    defer boot.stop();

    const first = boot.instances[0].openai;
    try testing.expectEqualStrings("deepseek-ai/deepseek-v4-pro", first.default_model.?);
    try testing.expectEqual(@as(u32, 16384), first.default_max_tokens.?);
    try testing.expectEqual(@as(f64, 1), first.default_temperature.?);

    const local = boot.instances[2].openai;
    try testing.expectEqualStrings("qwen3-coder-next", local.default_model.?);
    try testing.expectEqual(@as(u32, 8192), local.default_max_tokens.?);
    try testing.expectEqual(@as(f64, 0.7), local.default_temperature.?);

    const anthropic = boot.instances[3].anthropic;
    try testing.expectEqualStrings("claude-sonnet-4", anthropic.default_model.?);
    try testing.expectEqual(@as(u32, 8192), anthropic.default_max_tokens.?);
    try testing.expectEqual(@as(f64, 1), anthropic.default_temperature.?);
}

test "boot: ZYGOS_STREAM_IDLE_MS reaches every instance; absent env keeps the client default" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var cat = try providers_catalog.Catalog.parse(testing.allocator, fixture, null);
    defer cat.deinit();

    var boot = try CatalogBoot.start(testing.allocator, &h.actor, &h.registry, h.io(), &cat, &.{
        .{ .name = "ZYGOS_STREAM_IDLE_MS", .value = "45000" },
    });
    defer boot.stop();
    try testing.expectEqual(@as(u64, 45_000), boot.instances[0].openai.idle_timeout_ms);
    try testing.expectEqual(@as(u64, 45_000), boot.instances[3].anthropic.idle_timeout_ms);

    var boot_default = try CatalogBoot.start(testing.allocator, &h.actor, &h.registry, h.io(), &cat, &.{});
    defer boot_default.stop();
    try testing.expectEqual(stream_guard.default_idle_ms, boot_default.instances[0].openai.idle_timeout_ms);
}

test "merge helper: request model wins; absent model falls to default; neither ⇒ error; max_tokens/temperature likewise" {
    // Request model wins
    const a = try provider_openai.mergeRequestDefaults("req", 99, 0.1, "def", 50, 0.9);
    try testing.expectEqualStrings("req", a.model);
    try testing.expectEqual(@as(u32, 99), a.max_tokens);
    try testing.expectEqual(@as(f64, 0.1), a.temperature.?);

    // Absent request falls to default
    const b = try provider_openai.mergeRequestDefaults(null, null, null, "def", 50, 0.9);
    try testing.expectEqualStrings("def", b.model);
    try testing.expectEqual(@as(u32, 50), b.max_tokens);
    try testing.expectEqual(@as(f64, 0.9), b.temperature.?);

    // Neither model ⇒ error
    try testing.expectError(
        error.Failed,
        provider_openai.mergeRequestDefaults(null, 1, 0.5, null, 1, 0.5),
    );

    // max_tokens: neither falls to StreamOptions default 1024
    const c = try provider_openai.mergeRequestDefaults("m", null, null, "d", null, null);
    try testing.expectEqual(@as(u32, 1024), c.max_tokens);
    // temperature: neither stays unset (not emitted)
    try testing.expectEqual(@as(?f64, null), c.temperature);
}

test "checkRoutes: unknown zygos::providers::* slug in any ladder (incl. default) ⇒ UnknownProviderSlug; known slugs and non-catalog functions pass" {
    var cat = try providers_catalog.Catalog.parse(testing.allocator, fixture, null);
    defer cat.deinit();

    // Known catalog slug + legacy non-catalog function → ok
    const good: [:0]const u8 =
        \\.{
        \\    .default = .{
        \\        .{ .provider_function = "zygos::providers::nvidia-deepseekv4-pro", .model = "m" },
        \\        .{ .provider_function = "zygos::provider::anthropic::messages", .model = "claude" },
        \\    },
        \\    .routes = .{
        \\        .{
        \\            .step_id = "plan",
        \\            .attempts = .{
        \\                .{ .provider_function = "zygos::providers::ollama-qwen3-coder-next", .model = "q" },
        \\            },
        \\        },
        \\    },
        \\}
    ;
    var good_cfg = try router.Config.parse(testing.allocator, good);
    defer good_cfg.deinit();
    try checkRoutes(&cat, &good_cfg);

    // Unknown slug in a step ladder
    const bad_route: [:0]const u8 =
        \\.{
        \\    .default = .{},
        \\    .routes = .{
        \\        .{
        \\            .step_id = "plan",
        \\            .attempts = .{
        \\                .{ .provider_function = "zygos::providers::does-not-exist", .model = "m" },
        \\            },
        \\        },
        \\    },
        \\}
    ;
    var bad_r = try router.Config.parse(testing.allocator, bad_route);
    defer bad_r.deinit();
    try testing.expectError(error.UnknownProviderSlug, checkRoutes(&cat, &bad_r));

    // Unknown slug in the default ladder
    const bad_default: [:0]const u8 =
        \\.{
        \\    .default = .{
        \\        .{ .provider_function = "zygos::providers::missing-slug", .model = "m" },
        \\    },
        \\    .routes = .{},
        \\}
    ;
    var bad_d = try router.Config.parse(testing.allocator, bad_default);
    defer bad_d.deinit();
    try testing.expectError(error.UnknownProviderSlug, checkRoutes(&cat, &bad_d));
}

test "chatUrl: version-carrying base joins to <base>/chat/completions" {
    const url = try openai.chatUrl(testing.allocator, "https://api.openai.com/v1");
    defer testing.allocator.free(url);
    try testing.expectEqualStrings("https://api.openai.com/v1/chat/completions", url);

    const gem = try openai.chatUrl(testing.allocator, gemini_compat_base_url);
    defer testing.allocator.free(gem);
    try testing.expectEqualStrings(
        "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
        gem,
    );
}

test "temperature emitted in the request body only when set" {
    const bare = try openai.buildChatBody(testing.allocator, "m", 64, "", "", null);
    defer testing.allocator.free(bare);
    try testing.expect(std.mem.indexOf(u8, bare, "temperature") == null);

    const with = try openai.buildChatBody(testing.allocator, "m", 64, "", "", 1.0);
    defer testing.allocator.free(with);
    try testing.expect(std.mem.indexOf(u8, with, "\"temperature\":") != null);
}

test "streamIdleMs: absent or garbage env is null; a number parses; 0 passes through" {
    const P = providers_catalog.EnvPair;
    try testing.expectEqual(@as(?u64, null), streamIdleMs(&.{}));
    try testing.expectEqual(@as(?u64, null), streamIdleMs(&.{
        .{ .name = "ZYGOS_STREAM_IDLE_MS", .value = "soon" },
    }));
    try testing.expectEqual(@as(?u64, 45_000), streamIdleMs(&[_]P{
        .{ .name = "OTHER", .value = "1" },
        .{ .name = "ZYGOS_STREAM_IDLE_MS", .value = "45000" },
    }));
    try testing.expectEqual(@as(?u64, 0), streamIdleMs(&.{
        .{ .name = "ZYGOS_STREAM_IDLE_MS", .value = "0" },
    }));
}

test "no leaks across boot/stop loops" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var cat = try providers_catalog.Catalog.parse(testing.allocator, fixture, null);
    defer cat.deinit();

    const env = [_]providers_catalog.EnvPair{
        .{ .name = "NVIDIA_API_KEY", .value = "k" },
        .{ .name = "GOOGLE_API_KEY", .value = "g" },
    };

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        var boot = try CatalogBoot.start(testing.allocator, &h.actor, &h.registry, h.io(), &cat, &env);
        // Probe one registration each loop so stop joins live handlers.
        const res = try h.caller.call("zygos::providers::nvidia-deepseekv4-pro", "null");
        defer res.deinit(testing.allocator);
        try testing.expect(res == .err);
        boot.stop();
    }
}
