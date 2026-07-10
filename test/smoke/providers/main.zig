//! Env-gated multi-provider smoke (X4, docs/specs/providers-smoke.md).
//! Never part of `zig build test` — this is the one place the REAL
//! `~/.agents/providers.toml` (and real keys from the real env) is read.
//! Two `zygos::turns::run` calls, one routed to each argv slug, prove the
//! X1→X2 chain against live endpoints. Exits 2 (skip-friendly) on missing
//! args/keys/catalog; 0 only when both turns end with a terminal message.

const std = @import("std");
const json = std.json;
const zygos = @import("zygos");

fn fail(comptime what: []const u8, args: anytype) noreturn {
    std.debug.print("SMOKE FAIL: " ++ what ++ "\n", args);
    std.process.exit(1);
}

fn skip(comptime what: []const u8, args: anytype) noreturn {
    std.debug.print("SMOKE SKIP: " ++ what ++ "\n", args);
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.c_allocator;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const want_a = args.next() orelse skip("usage: smoke-providers <slug-a> <slug-b>", .{});
    const want_b = args.next() orelse skip("usage: smoke-providers <slug-a> <slug-b>", .{});

    // ---- the real catalog ----------------------------------------------------
    const env = try envPairs(gpa);
    const cat_path = zygos.providers_catalog.configPath(gpa, env) catch
        skip("no AI_PROVIDERS_CONFIG and no HOME", .{});
    const cat_text = readWholeFile(gpa, cat_path) orelse
        skip("cannot read provider catalog {s}", .{cat_path});
    var diag: zygos.providers_catalog.Diag = .{};
    var catalog = zygos.providers_catalog.Catalog.parse(gpa, cat_text, &diag) catch
        skip("{s}:{d}: {s}", .{ cat_path, diag.line, diag.message });

    const pa = findBySlug(gpa, &catalog, want_a) orelse unknownSlug(gpa, &catalog, want_a);
    const pb = findBySlug(gpa, &catalog, want_b) orelse unknownSlug(gpa, &catalog, want_b);
    if (pa.resolveKey(env) == null and pa.kind != .ollama)
        skip("{s}: no key ({s} unset)", .{ want_a, pa.key_env orelse "no key_env" });
    if (pb.resolveKey(env) == null and pb.kind != .ollama)
        skip("{s}: no key ({s} unset)", .{ want_b, pb.key_env orelse "no key_env" });

    // ---- minimal roster: turns + router + catalog providers -------------------
    var registry = zygos.inproc.Registry.init(gpa, null);
    var actor = try zygos.actor.Actor.init(gpa, .{ .invoke_timeout_ms = 120_000 }, registry.outbound());
    _ = try std.Thread.spawn(.{}, zygos.actor.Actor.run, .{&actor});

    var io_boot = zygos.provider_boot.IoBoot.start(gpa);
    var boot = try zygos.provider_boot.CatalogBoot.start(gpa, &actor, &registry, io_boot.io(), &catalog, env);
    _ = &boot;
    _ = try zygos.turn.TurnOrchestrator.start(gpa, &actor, &registry);

    const zon_text = try std.fmt.allocPrintSentinel(gpa,
        \\.{{
        \\    .routes = .{{
        \\        .{{ .step_id = "smoke-a", .attempts = .{{
        \\            .{{ .provider_function = "zygos::providers::{s}", .model = "{s}" }},
        \\        }} }},
        \\        .{{ .step_id = "smoke-b", .attempts = .{{
        \\            .{{ .provider_function = "zygos::providers::{s}", .model = "{s}" }},
        \\        }} }},
        \\    }},
        \\}}
    , .{ want_a, pa.model, want_b, pb.model }, 0);
    const route_cfg = try zygos.router.Config.parse(gpa, zon_text);
    _ = try zygos.router.RouterWorker.start(gpa, &actor, &registry, route_cfg);

    const caller = try zygos.inproc.Worker.spawn(gpa, &actor, &registry, "smoke");

    // ---- one short turn per provider ------------------------------------------
    runOne(gpa, caller, "smoke-a", want_a, pa.model);
    runOne(gpa, caller, "smoke-b", want_b, pb.model);
    std.debug.print("SMOKE OK: both providers completed\n", .{});
    std.process.exit(0);
}

fn runOne(gpa: std.mem.Allocator, caller: *zygos.inproc.Worker, step_id: []const u8, slug_name: []const u8, model: []const u8) void {
    const request = std.fmt.allocPrint(gpa,
        \\{{"system":"You are a smoke test.","max_steps":1,"turn_id":{f},
        \\ "router_function":"zygos::models::resolve","step_id":{f},
        \\ "messages":[{{"role":"user","content":"Reply with exactly one word: ok"}}]}}
    , .{ json.fmt(step_id, .{}), json.fmt(step_id, .{}) }) catch fail("oom", .{});
    defer gpa.free(request);

    const res = caller.call("zygos::turns::run", request) catch fail("{s}: bus call failed", .{slug_name});
    defer res.deinit(gpa);
    if (res != .ok) fail("{s}: turn errored: {s}", .{ slug_name, res.err });

    var p = json.parseFromSlice(json.Value, gpa, res.ok, .{}) catch
        fail("{s}: unparseable reply: {s}", .{ slug_name, res.ok });
    defer p.deinit();
    const stop = p.value.object.get("stop") orelse fail("{s}: no stop: {s}", .{ slug_name, res.ok });
    if (stop != .string or std.mem.eql(u8, stop.string, "failed"))
        fail("{s}: turn failed: {s}", .{ slug_name, res.ok });
    std.debug.print("SMOKE {s} model={s} stop={s}\n", .{ slug_name, model, stop.string });
}

fn findBySlug(gpa: std.mem.Allocator, catalog: *const zygos.providers_catalog.Catalog, want: []const u8) ?zygos.providers_catalog.Provider {
    for (catalog.providers) |p| {
        const s = zygos.providers_catalog.slug(gpa, p.name) catch return null;
        defer gpa.free(s);
        if (std.mem.eql(u8, s, want)) return p;
    }
    return null;
}

fn unknownSlug(gpa: std.mem.Allocator, catalog: *const zygos.providers_catalog.Catalog, want: []const u8) noreturn {
    std.debug.print("SMOKE SKIP: unknown slug {s}; available:\n", .{want});
    for (catalog.providers) |p| {
        const s = zygos.providers_catalog.slug(gpa, p.name) catch continue;
        defer gpa.free(s);
        std.debug.print("  {s}\n", .{s});
    }
    std.process.exit(2);
}

fn readWholeFile(gpa: std.mem.Allocator, path: []const u8) ?[:0]u8 {
    const path_z = std.fmt.allocPrintSentinel(gpa, "{s}", .{path}, 0) catch return null;
    defer gpa.free(path_z);
    const f = std.c.fopen(path_z.ptr, "r") orelse return null;
    defer _ = std.c.fclose(f);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.c.fread(&chunk, 1, chunk.len, f);
        if (n == 0) break;
        buf.appendSlice(gpa, chunk[0..n]) catch return null;
    }
    return buf.toOwnedSliceSentinel(gpa, 0) catch null;
}

fn envPairs(gpa: std.mem.Allocator) error{OutOfMemory}![]zygos.providers_catalog.EnvPair {
    var list: std.ArrayList(zygos.providers_catalog.EnvPair) = .empty;
    defer list.deinit(gpa);
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const span = std.mem.span(entry);
        const eq = std.mem.indexOfScalar(u8, span, '=') orelse continue;
        try list.append(gpa, .{ .name = span[0..eq], .value = span[eq + 1 ..] });
    }
    return list.toOwnedSlice(gpa);
}
