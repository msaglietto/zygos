//! Test-runner output filter (S8.3, docs/specs/filter.md).
//!
//! A green suite is one bit of information spread over hundreds of lines.
//! ztk measured `cargo test` all-passing at 397 tokens → 21. A *red* suite is
//! the opposite: every failure line is the reason the agent ran the command,
//! and none of it may be touched.
//!
//! So this filter is asymmetric by design: aggressive on PASS lines and
//! progress noise, conservative around anything that smells like a failure.

const std = @import("std");
const guard = @import("guard.zig");

pub fn run(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}!?[]const u8 {
    // Note: NOT shouldSkipOrErrored — failures are this filter's payload.
    if (guard.shouldSkip(text)) return null;

    // Pass 1: drop the noise lines.
    var kept: std.ArrayList(u8) = .empty;
    var dropped: usize = 0;
    var kept_any = false;
    var it = guard.lines(text);
    while (it.next()) |line| {
        if (isNoise(line)) {
            dropped += 1;
            continue;
        }
        try kept.appendSlice(arena, line);
        try kept.append(arena, '\n');
        kept_any = true;
    }
    if (!kept_any) return null;

    // Pass 2: collapse runs of the identical line. Real runners flood their
    // output with repeated worker/log lines that no per-line rule catches;
    // `zig build filter-probe` found this dominating `zig build test` here.
    var out: std.ArrayList(u8) = .empty;
    dropped += try guard.collapseRepeats(arena, &out, kept.items, 3);

    if (dropped == 0) return null;
    try out.appendSlice(arena, try guard.marker(
        arena,
        "tests: dropped {d} passing/progress/repeated lines",
        .{dropped},
    ));
    try out.append(arena, '\n');
    return guard.keepIfSmaller(text, out.items);
}

/// Only lines that provably carry no failure information. When in doubt,
/// keep — a dropped assertion is a far worse outcome than a wasted token.
fn isNoise(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t\r");
    if (t.len == 0) return true;
    // Any failure signal anywhere on the line wins over every rule below.
    if (guard.hasErrorSignal(t)) return false;

    // Per-test pass lines across runners:
    //   cargo:  "test foo::bar ... ok"
    //   go:     "--- PASS: TestFoo (0.00s)" / "ok  \tpkg\t0.1s"
    //   pytest: "tests/test_x.py::test_y PASSED"
    //   zig:    "N/M test.name... OK"
    //   jest:   "  ✓ renders (3 ms)"
    if (std.mem.endsWith(u8, t, "... ok") or std.mem.endsWith(u8, t, "... OK")) return true;
    if (std.mem.startsWith(u8, t, "--- PASS")) return true;
    if (std.mem.startsWith(u8, t, "=== RUN")) return true;
    if (std.mem.startsWith(u8, t, "ok  ")) return true;
    if (std.mem.endsWith(u8, t, "PASSED")) return true;
    if (std.mem.startsWith(u8, t, "✓") or std.mem.startsWith(u8, t, "√")) return true;
    if (std.mem.startsWith(u8, t, "PASS ")) return true;

    // Build/progress chatter interleaved into test output.
    inline for (.{ "Compiling ", "Downloading ", "Finished ", "Running ", "Doc-tests ", "Fresh " }) |p| {
        if (std.mem.startsWith(u8, t, p)) return true;
    }
    // Separator rules and platform banners.
    if (t.len >= 8 and allSame(t)) return true;
    if (std.mem.startsWith(u8, t, "platform ") or std.mem.startsWith(u8, t, "rootdir:") or
        std.mem.startsWith(u8, t, "collected ") or std.mem.startsWith(u8, t, "cachedir:") or
        std.mem.startsWith(u8, t, "plugins:")) return true;

    return false;
}

fn allSame(t: []const u8) bool {
    const c = t[0];
    if (std.ascii.isAlphanumeric(c)) return false;
    for (t) |x| if (x != c) return false;
    return true;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

const green_fixture =
    \\   Compiling zygos v0.1.0 (/repo)
    \\    Finished test [unoptimized + debuginfo] target(s) in 2.31s
    \\     Running unittests src/lib.rs
    \\
    \\running 6 tests
    \\test catalog::tests::register ... ok
    \\test catalog::tests::cas_teardown ... ok
    \\test invocation::tests::timeout ... ok
    \\test invocation::tests::late_result ... ok
    \\test channel::tests::take ... ok
    \\test trigger::tests::rebind ... ok
    \\
    \\test result: ok. 6 passed; 0 failed; 0 ignored; 0 measured
    \\
;

test "S8.3 testrun: green run collapses to the tally" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = (try run(arena, green_fixture)).?;
    try testing.expect(std.mem.indexOf(u8, got, "test result: ok. 6 passed") != null);
    try testing.expect(std.mem.indexOf(u8, got, "running 6 tests") != null);
    // Every per-test PASS line is gone.
    try testing.expect(std.mem.indexOf(u8, got, "catalog::tests::register") == null);
    try testing.expect(std.mem.indexOf(u8, got, "channel::tests::take") == null);
    try testing.expect(std.mem.indexOf(u8, got, "Compiling") == null);
    try testing.expect(got.len < green_fixture.len / 2);
}

const red_fixture =
    \\   Compiling zygos v0.1.0 (/repo)
    \\    Finished test [unoptimized + debuginfo] target(s) in 2.31s
    \\running 3 tests
    \\test catalog::tests::register ... ok
    \\test catalog::tests::cas_teardown ... FAILED
    \\test channel::tests::take ... ok
    \\
    \\failures:
    \\
    \\---- catalog::tests::cas_teardown stdout ----
    \\thread 'main' panicked at src/catalog.rs:88:9:
    \\assertion `left == right` failed
    \\  left: 2
    \\ right: 1
    \\
    \\test result: FAILED. 2 passed; 1 failed
    \\
;

test "S8.3 testrun: every byte of a failure survives" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = (try run(arena, red_fixture)).?;
    try testing.expect(std.mem.indexOf(u8, got, "cas_teardown ... FAILED") != null);
    try testing.expect(std.mem.indexOf(u8, got, "panicked at src/catalog.rs:88:9") != null);
    try testing.expect(std.mem.indexOf(u8, got, "assertion `left == right` failed") != null);
    try testing.expect(std.mem.indexOf(u8, got, "left: 2") != null);
    try testing.expect(std.mem.indexOf(u8, got, "right: 1") != null);
    try testing.expect(std.mem.indexOf(u8, got, "test result: FAILED") != null);
    // Passing noise around the failure still goes.
    try testing.expect(std.mem.indexOf(u8, got, "catalog::tests::register") == null);
}

test "S8.3 testrun: go and pytest pass lines are recognized" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const go =
        \\=== RUN   TestAlpha
        \\--- PASS: TestAlpha (0.00s)
        \\=== RUN   TestBeta
        \\--- PASS: TestBeta (0.01s)
        \\PASS
        \\ok    github.com/x/y   0.014s
        \\
    ;
    const got = (try run(arena, go)).?;
    try testing.expect(std.mem.indexOf(u8, got, "TestAlpha") == null);
    try testing.expect(got.len < go.len);

    const py = "platform darwin -- Python 3.12\n" ++
        "collected 4 items\n" ++
        "tests/test_a.py::test_one PASSED\n" ++
        "tests/test_a.py::test_two PASSED\n" ++
        "tests/test_b.py::test_three PASSED\n" ++
        "tests/test_b.py::test_four PASSED\n" ++
        "==== 4 passed in 0.12s ====\n";
    const got2 = (try run(arena, py)).?;
    try testing.expect(std.mem.indexOf(u8, got2, "test_one") == null);
    try testing.expect(std.mem.indexOf(u8, got2, "4 passed in 0.12s") != null);
}

test "S8.3 testrun: small and structured output pass through" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expect(try run(arena, "test result: ok. 1 passed\n") == null);
    const as_json = "{\"passed\":6,\"failed\":0,\"pad\":\"" ++ "x" ** 80 ++ "\"}";
    try testing.expect(try run(arena, as_json) == null);
}

test "S8.3 testrun: output with nothing to drop passes through" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Distinct, non-noise lines: no per-line rule fires and no run repeats,
    // so the filter declines and the generic trim handles it.
    const dense =
        "a meaningful line about the suite\n" ++
        "a different meaningful line here\n" ++
        "a third distinct line of detail\n" ++
        "and a fourth, all unlike each other\n";
    try testing.expect(try run(arena, dense) == null);
}

test "S8.3 testrun: no leaks over repeated filtering" {
    for (0..50) |_| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        _ = try run(arena, green_fixture);
        _ = try run(arena, red_fixture);
    }
}

// --- Reality-check regressions (found by `zig build filter-probe`) ---

test "S8.3 testrun: floods of identical log lines collapse with a count" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Real `zig build test` output on this repo: hundreds of identical
    // worker log lines dwarf the actual result. No fixture had this shape,
    // so the filter declined and saved 0% on the single most-run command.
    const flood = "test\n+- run test w\n" ++
        ("[actor] (warn): registerfunction f: overwrote existing registration (last wins)\n" ** 120) ++
        "All 736 tests passed.\n";
    const got = (try run(arena, flood)).?;
    try testing.expect(std.mem.indexOf(u8, got, "All 736 tests passed.") != null);
    // The line survives once, with an honest count of the repeats.
    try testing.expect(std.mem.indexOf(u8, got, "overwrote existing registration") != null);
    try testing.expect(std.mem.indexOf(u8, got, "119 more identical") != null);
    try testing.expect(got.len < flood.len / 4);
}

test "S8.3 testrun: distinct lines are never collapsed into each other" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const mixed = "test a::b ... ok\n" ** 4 ++
        "[warn] alpha happened\n[warn] beta happened\n[warn] gamma happened\n" ++
        "test result: ok. 4 passed\n";
    const got = (try run(arena, mixed)).?;
    try testing.expect(std.mem.indexOf(u8, got, "alpha") != null);
    try testing.expect(std.mem.indexOf(u8, got, "beta") != null);
    try testing.expect(std.mem.indexOf(u8, got, "gamma") != null);
}

test "S8.3 testrun: a repeated FAILURE line is still shown in full" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Collapsing repeats must never hide a failure: if the same assertion
    // fires 50 times, the agent still needs to see it is a failure.
    const repeated_fail = "running tests\n" ++
        ("error: assertion failed at src/x.zig:12\n" ** 50) ++
        "test result: FAILED\n";
    const got = try run(arena, repeated_fail);
    if (got) |g| {
        try testing.expect(std.mem.indexOf(u8, g, "assertion failed at src/x.zig:12") != null);
        try testing.expect(std.mem.indexOf(u8, g, "test result: FAILED") != null);
    }
}

test "S8.3 testrun: a REAL zig compile failure survives intact" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Verbatim `zig build test` output from a deliberately broken build in
    // this repo (min_bytes made a string). This is the highest-stakes case
    // in the whole filter set: lose a compiler diagnostic and the agent
    // cannot fix its own code.
    const real =
        \\test
        \\+- run test
        \\   +- compile test Debug native 1 errors
        \\src/worker/filter/guard.zig:7:30: error: expected type 'usize', found '*const [6:0]u8'
        \\pub const min_bytes: usize = "eighty";
        \\                             ^~~~~~~~
        \\    test.S8.3 guard: small output is skipped: src/worker/filter/guard.zig:200:34
        \\    3 reference(s) hidden; use '-freference-trace=5' to see all references
        \\error: 1 compilation errors
        \\
    ;
    const got = try run(arena, real);
    const body = got orelse real; // declining is also acceptable here
    // Every part the agent needs to act on must survive verbatim.
    try testing.expect(std.mem.indexOf(u8, body, "guard.zig:7:30: error: expected type 'usize'") != null);
    try testing.expect(std.mem.indexOf(u8, body, "pub const min_bytes: usize = \"eighty\";") != null);
    try testing.expect(std.mem.indexOf(u8, body, "^~~~~~~~") != null);
    try testing.expect(std.mem.indexOf(u8, body, "error: 1 compilation errors") != null);
}
