//! Build/lint output filter (S8.3, docs/specs/filter.md).
//!
//! Compilers and linters bury a handful of actionable diagnostics under
//! progress chatter, and then repeat the same diagnostic once per call site.
//! The agent needs each distinct `file:line:col: message` once, plus the
//! summary. Same asymmetry as the test-runner filter: aggressive on progress
//! lines, conservative around anything diagnostic-shaped.

const std = @import("std");
const guard = @import("guard.zig");

pub fn run(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}!?[]const u8 {
    // NOT shouldSkipOrErrored — diagnostics are this filter's payload.
    if (guard.shouldSkip(text)) return null;

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var out: std.ArrayList(u8) = .empty;
    var dropped_progress: usize = 0;
    var dropped_dupes: usize = 0;
    var kept_any = false;

    var it = guard.lines(text);
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) {
            dropped_progress += 1;
            continue;
        }
        if (isProgress(t)) {
            dropped_progress += 1;
            continue;
        }
        // Collapse repeats of the same diagnostic (the same error reported
        // at N call sites is one thing to fix).
        if (looksDiagnostic(t)) {
            const gop = try seen.getOrPut(arena, t);
            if (gop.found_existing) {
                dropped_dupes += 1;
                continue;
            }
        }
        try out.appendSlice(arena, line);
        try out.append(arena, '\n');
        kept_any = true;
    }
    if ((dropped_progress + dropped_dupes) == 0 or !kept_any) return null;
    try out.appendSlice(arena, try guard.marker(
        arena,
        "build: dropped {d} progress lines, {d} repeated diagnostics",
        .{ dropped_progress, dropped_dupes },
    ));
    try out.append(arena, '\n');
    return guard.keepIfSmaller(text, out.items);
}

fn isProgress(t: []const u8) bool {
    if (guard.hasErrorSignal(t)) return false;
    inline for (.{
        "Compiling ",  "Downloading ", "Downloaded ", "Fresh ",
        "Finished ",   "Building ",    "Installing ", "Updating ",
        "Blocking ",   "Checking ",    "Waiting ",    "Adding ",
        "Locking ",    "Packaging ",   "Verifying ",  "Uploading ",
        "Generating ", "Linking ",
    }) |p| {
        if (std.mem.startsWith(u8, t, p)) return true;
    }
    // Progress bars / spinner rules.
    if (t.len >= 8 and allSame(t)) return true;
    return false;
}

/// `path/to/file.zig:12:5: error: message` — the shape worth deduping.
fn looksDiagnostic(t: []const u8) bool {
    const first = std.mem.indexOfScalar(u8, t, ':') orelse return false;
    if (first == 0) return false;
    const rest = t[first + 1 ..];
    const second = std.mem.indexOfScalar(u8, rest, ':') orelse return false;
    if (second == 0) return false;
    for (rest[0..second]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
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

const build_fixture =
    \\   Compiling libc v0.2.155
    \\   Compiling serde v1.0.203
    \\   Compiling zygos v0.1.0 (/repo)
    \\   Downloading crates ...
    \\src/kernel/catalog.rs:88:9: error: cannot borrow `self.map` as mutable
    \\src/kernel/catalog.rs:88:9: error: cannot borrow `self.map` as mutable
    \\src/kernel/catalog.rs:92:5: warning: unused variable `x`
    \\    Finished dev [unoptimized] target(s) in 12.31s
    \\error: could not compile `zygos` due to 1 previous error
    \\
;

test "S8.3 buildlint: diagnostics survive, progress and dupes do not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = (try run(arena, build_fixture)).?;
    try testing.expect(std.mem.indexOf(u8, got, "catalog.rs:88:9: error: cannot borrow") != null);
    try testing.expect(std.mem.indexOf(u8, got, "catalog.rs:92:5: warning: unused variable") != null);
    try testing.expect(std.mem.indexOf(u8, got, "could not compile") != null);
    try testing.expect(std.mem.indexOf(u8, got, "Compiling libc") == null);
    try testing.expect(std.mem.indexOf(u8, got, "Downloading") == null);
    // The duplicated diagnostic appears exactly once.
    const first = std.mem.indexOf(u8, got, "cannot borrow").?;
    try testing.expect(std.mem.indexOfPos(u8, got, first + 1, "cannot borrow") == null);
    try testing.expect(std.mem.indexOf(u8, got, "1 repeated diagnostics") != null);
    try testing.expect(got.len < build_fixture.len);
}

test "S8.3 buildlint: a clean build collapses to almost nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const clean = "   Compiling a v0.1.0\n" ** 12 ++ "    Finished dev target(s) in 3.2s\n" ++
        "build succeeded with no diagnostics at all today\n";
    const got = (try run(arena, clean)).?;
    try testing.expect(std.mem.indexOf(u8, got, "build succeeded") != null);
    try testing.expect(std.mem.indexOf(u8, got, "Compiling") == null);
    try testing.expect(got.len < clean.len / 2);
}

test "S8.3 buildlint: distinct diagnostics are never merged" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const many = "   Compiling x v0.1.0\n" ** 8 ++
        "a.zig:1:1: error: one\n" ++
        "a.zig:2:1: error: two\n" ++
        "a.zig:3:1: error: three\n" ++
        "   Compiling y v0.1.0\n" ** 8;
    const got = (try run(arena, many)).?;
    try testing.expect(std.mem.indexOf(u8, got, "error: one") != null);
    try testing.expect(std.mem.indexOf(u8, got, "error: two") != null);
    try testing.expect(std.mem.indexOf(u8, got, "error: three") != null);
}

test "S8.3 buildlint: small and structured output pass through" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expect(try run(arena, "Finished in 1s\n") == null);
    const as_json = "{\"diagnostics\":[],\"pad\":\"" ++ "x" ** 80 ++ "\"}";
    try testing.expect(try run(arena, as_json) == null);
}

test "S8.3 buildlint: no leaks over repeated filtering" {
    for (0..50) |_| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        _ = try run(arena, build_fixture);
    }
}

test "S8.3 buildlint: a REAL zig build failure survives intact" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Verbatim shape of a real `zig build` failure. The probe could not
    // exercise buildlint (a cached clean build prints nothing), so this
    // pins the failing case by hand from real output.
    const real =
        \\install
        \\+- install zygos
        \\   +- compile exe zygos Debug native 1 errors
        \\src/worker/filter/guard.zig:7:30: error: expected type 'usize', found '*const [6:0]u8'
        \\pub const min_bytes: usize = "eighty";
        \\                             ^~~~~~~~
        \\referenced by:
        \\    shouldSkip: src/worker/filter/guard.zig:19:20
        \\error: the following build command failed with exit code 1:
        \\
    ;
    const got = try run(arena, real);
    const body = got orelse real;
    try testing.expect(std.mem.indexOf(u8, body, "guard.zig:7:30: error: expected type 'usize'") != null);
    try testing.expect(std.mem.indexOf(u8, body, "pub const min_bytes: usize = \"eighty\";") != null);
    try testing.expect(std.mem.indexOf(u8, body, "^~~~~~~~") != null);
    try testing.expect(std.mem.indexOf(u8, body, "referenced by:") != null);
    try testing.expect(std.mem.indexOf(u8, body, "exit code 1") != null);
}

test "S8.3 buildlint: dedup never merges same-message diagnostics at different sites" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Identical message, different file:line — two separate things to fix.
    // Only a byte-identical repeat may collapse.
    const two_sites = "   Compiling x v0.1.0\n" ** 6 ++
        "a.zig:1:1: error: expected type 'usize'\n" ++
        "b.zig:9:4: error: expected type 'usize'\n" ++
        "   Compiling y v0.1.0\n" ** 6;
    const got = (try run(arena, two_sites)).?;
    try testing.expect(std.mem.indexOf(u8, got, "a.zig:1:1") != null);
    try testing.expect(std.mem.indexOf(u8, got, "b.zig:9:4") != null);
}
