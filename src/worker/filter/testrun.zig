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

    var out: std.ArrayList(u8) = .empty;
    var dropped: usize = 0;
    var kept_any = false;
    var it = guard.lines(text);
    while (it.next()) |line| {
        if (isNoise(line)) {
            dropped += 1;
            continue;
        }
        try out.appendSlice(arena, line);
        try out.append(arena, '\n');
        kept_any = true;
    }
    if (dropped == 0 or !kept_any) return null;
    try out.appendSlice(arena, try guard.marker(
        arena,
        "tests: dropped {d} passing/progress lines",
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

    const dense = "some meaningful line about the suite\n" ** 4;
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
