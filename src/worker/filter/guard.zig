//! Guards every command-aware filter must honor (docs/specs/filter.md S8.3).
//! Shared so an invariant is stated once, not re-derived per filter.

const std = @import("std");

/// Below this, compressing is not worth the fidelity risk (ztk's threshold).
pub const min_bytes: usize = 80;

/// The universal "do not touch this" test: too small to be worth the
/// fidelity risk, or structured data that must survive byte-exact.
///
/// Note what is NOT here: error signals. A filter's correct response to an
/// error differs by family — `git`/`listing` bail out entirely (they have no
/// model of failure output), while `testrun`/`buildlint` exist precisely to
/// *keep* the diagnostics and drop the surrounding noise. Folding
/// `hasErrorSignal` in here would make those two filters no-ops on exactly
/// the runs that matter. Each filter opts in explicitly.
pub fn shouldSkip(text: []const u8) bool {
    if (text.len < min_bytes) return true;
    if (looksStructured(text)) return true;
    return false;
}

/// `shouldSkip` plus a bail-out on any error signal — for filters that only
/// understand success-shaped output (git, listing).
pub fn shouldSkipOrErrored(text: []const u8) bool {
    return shouldSkip(text) or hasErrorSignal(text);
}

/// JSON/YAML-ish payloads are data, not chatter — never reshape them.
fn looksStructured(text: []const u8) bool {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0) return false;
    return (t[0] == '{' and t[t.len - 1] == '}') or
        (t[0] == '[' and t[t.len - 1] == ']') or
        std.mem.startsWith(u8, t, "---\n");
}

/// Does the output carry a genuine failure diagnostic?
///
/// **Line-anchored on purpose.** A substring scan over the whole text is
/// useless in practice: `zig build filter-probe` showed it disabling the git
/// filter on this repo's own `git log`, because commit messages discuss
/// assertions and warnings, and on any `git diff` touching error-handling
/// code. A diagnostic is a *line that starts with* the signal, or one
/// prefixed by a `file:line:col:` location and then carrying it — that is
/// where compilers, test runners and git actually put it.
///
/// A diff's `+`/`-` lines are skipped entirely: quoting `return error.X` is
/// content, not a failure of the command that printed it.
pub fn hasErrorSignal(text: []const u8) bool {
    var it = lines(text);
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) continue;
        // Diff payload lines quote code; they say nothing about this command.
        // `---`/`+++` are diff file headers, not payload, and `--- FAIL:` is
        // go test's failure banner — so only single +/- lines are skipped.
        if ((t[0] == '+' or t[0] == '-') and !(t.len > 1 and (t[1] == '-' or t[1] == '+'))) continue;
        if (lineIsDiagnostic(t)) return true;
    }
    return false;
}

fn lineIsDiagnostic(t: []const u8) bool {
    // Leading-signal forms: `error: ...`, `fatal: ...`, `FAILED ...`.
    inline for (.{
        "error:",             "Error:",  "ERROR:",    "error[",
        "fatal:",             "Fatal:",  "panic:",    "panicked",
        "Traceback",          "FAILED",  "FAIL:",     "FAIL ",
        "--- FAIL",           "SIGSEGV", "Unhandled", "Uncaught",
        "Segmentation fault",
    }) |p| {
        if (std.mem.startsWith(u8, t, p)) return true;
    }
    // Located form: `path/file.ext:LINE[:COL]: error: message`. Only the
    // segment after the location counts, so a path containing the word
    // "error" is not a diagnostic.
    if (afterLocation(t)) |rest| {
        inline for (.{ "error", "fatal", "panic" }) |p| {
            if (std.mem.startsWith(u8, rest, p)) return true;
        }
    }
    // Runtime panic banners: `thread 'main' panicked at ...`.
    if (std.mem.startsWith(u8, t, "thread '") and
        std.mem.indexOf(u8, t, "panicked") != null) return true;
    return false;
}

/// For `a/b.zig:12:5: error: msg`, return `error: msg`. Null when the line is
/// not location-prefixed. Walks colon-separated segments, remembering whether
/// a purely numeric one (the line/column) has been seen; the first
/// non-numeric segment after that starts the message.
fn afterLocation(t: []const u8) ?[]const u8 {
    var rest = t;
    var seen_numeric = false;
    var hops: usize = 0;
    while (hops < 5) : (hops += 1) {
        const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
        const seg = rest[0..colon];
        const after = std.mem.trimStart(u8, rest[colon + 1 ..], " ");
        if (seg.len == 0) return null;
        if (allDigits(seg)) {
            seen_numeric = true;
            rest = after;
            continue;
        }
        // A non-numeric segment: the message iff a line number preceded it.
        if (seen_numeric) return seg;
        rest = after;
    }
    return null;
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// Honest marker, same voice as the generic trim's.
pub fn marker(arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(arena, "[... zygos " ++ fmt ++ " ...]", args);
}

/// Iterate lines without the trailing newline; the final line need not end
/// in one.
pub fn lines(text: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
}

pub fn countLines(text: []const u8) usize {
    if (text.len == 0) return 0;
    var it = lines(text);
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n;
}

/// A filter's result is only worth taking if it actually saved something.
/// Guards against a filter that "compresses" into something longer.
pub fn keepIfSmaller(original: []const u8, compressed: []const u8) ?[]const u8 {
    return if (compressed.len < original.len) compressed else null;
}

/// Collapse runs of the identical line into one plus a count.
///
/// Real tool output is full of these — `zig build test` on this repo emits
/// the same worker warning 100+ times, which dwarfs the actual result. No
/// hand-written fixture had that shape, so `zig build filter-probe` is what
/// surfaced it. Only *consecutive* repeats collapse, so interleaved output
/// keeps its ordering.
///
/// Returns the number of lines dropped; appends to `out`.
pub fn collapseRepeats(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
    comptime min_run: usize,
) error{OutOfMemory}!usize {
    var dropped: usize = 0;
    var it = lines(text);
    var pending: ?[]const u8 = null;
    var run: usize = 0;

    while (true) {
        const line = it.next();
        const same = if (line != null and pending != null)
            std.mem.eql(u8, line.?, pending.?)
        else
            false;
        if (same) {
            run += 1;
            continue;
        }
        if (pending) |p| {
            try out.appendSlice(arena, p);
            try out.append(arena, '\n');
            if (run >= min_run) {
                try out.appendSlice(arena, try marker(arena, "{d} more identical lines", .{run}));
                try out.append(arena, '\n');
                dropped += run;
            } else if (run > 0) {
                for (0..run) |_| {
                    try out.appendSlice(arena, p);
                    try out.append(arena, '\n');
                }
            }
        }
        if (line == null) break;
        pending = line;
        run = 0;
    }
    return dropped;
}

const testing = std.testing;

test "S8.3 guard: small output is skipped" {
    try testing.expect(shouldSkip("tiny"));
    try testing.expect(shouldSkip("x" ** 79));
    try testing.expect(!shouldSkip("x" ** 80));
}

test "S8.3 guard: structured output is skipped" {
    const obj = "{\"a\":1,\"b\":[2,3],\"c\":\"" ++ "x" ** 80 ++ "\"}";
    try testing.expect(shouldSkip(obj));
    const arr = "[" ++ "1," ** 60 ++ "1]";
    try testing.expect(shouldSkip(arr));
    const yaml = "---\nkey: value\n" ++ "pad: xxxxxxxxxx\n" ** 8;
    try testing.expect(shouldSkip(yaml));
}

test "S8.3 guard: error signals bail out the success-only filters" {
    const long = "a" ** 100;
    try testing.expect(shouldSkipOrErrored(long ++ "\nerror: undefined symbol"));
    try testing.expect(shouldSkipOrErrored(long ++ "\nfatal: not a git repository"));
    try testing.expect(shouldSkipOrErrored(long ++ "\nFAILED tests/test_x.py"));
    try testing.expect(shouldSkipOrErrored("Traceback (most recent call last):\n" ++ long));
    try testing.expect(!shouldSkipOrErrored("clean output line\n" ++ long));
    // But plain shouldSkip must let diagnostics through — testrun/buildlint
    // depend on seeing them.
    try testing.expect(!shouldSkip(long ++ "\nerror: undefined symbol"));
}

test "S8.3 guard: keepIfSmaller rejects non-savings" {
    try testing.expect(keepIfSmaller("abc", "abcd") == null);
    try testing.expect(keepIfSmaller("abc", "abc") == null);
    try testing.expectEqualStrings("ab", keepIfSmaller("abc", "ab").?);
}

test "S8.3 guard: countLines handles trailing newline" {
    try testing.expectEqual(@as(usize, 0), countLines(""));
    try testing.expectEqual(@as(usize, 1), countLines("a"));
    try testing.expectEqual(@as(usize, 1), countLines("a\n"));
    try testing.expectEqual(@as(usize, 3), countLines("a\nb\nc\n"));
}

// --- Reality-check regressions (found by `zig build filter-probe`) ---

test "S8.3 guard: prose mentioning errors is not an error signal" {
    // Real git log output. Commit messages discuss assertions, warnings and
    // failures constantly; substring matching disabled the git filter on
    // this repo's own history.
    const log_text =
        \\commit 63e0b39958020b70a3c2f71d777698768f3d1e60
        \\Author: Someone <s@example.com>
        \\Date:   Wed Aug 5 22:18:09 2026 -0500
        \\
        \\    fix: the assertion was wrong and the warning was noise
        \\
        \\    Explains why the test failed and what error handling changed.
        \\
    ;
    try testing.expect(!hasErrorSignal(log_text));
}

test "S8.3 guard: a real diagnostic line is still an error signal" {
    // The signal must survive at the start of a line, which is where
    // compilers and runtimes actually put it.
    try testing.expect(hasErrorSignal("src/main.zig:3:5: error: expected type\n"));
    try testing.expect(hasErrorSignal("error: could not compile\n"));
    try testing.expect(hasErrorSignal("fatal: not a git repository\n"));
    try testing.expect(hasErrorSignal("thread 'main' panicked at src/x.rs:1:1\n"));
    try testing.expect(hasErrorSignal("Traceback (most recent call last):\n"));
    try testing.expect(hasErrorSignal("--- FAIL: TestThing (0.00s)\n"));
    try testing.expect(hasErrorSignal("FAILED tests/test_x.py::test_y\n"));
    try testing.expect(hasErrorSignal("  error[E0502]: cannot borrow\n"));
}

test "S8.3 guard: a diff that merely touches error-handling code is filterable" {
    // Real `git diff` on this repo: +/- lines quoting error strings must not
    // be read as the command having failed.
    const d =
        \\diff --git a/src/x.zig b/src/x.zig
        \\@@ -1,3 +1,3 @@
        \\-    return error.Failed;
        \\+    return error.Refused;
        \\     // warning: this comment mentions a warning
        \\
    ;
    try testing.expect(!hasErrorSignal(d));
}

test "S8.3 guard: a diff whose changed lines look like diagnostics is still filterable" {
    // The diff-payload skip in hasErrorSignal must be load-bearing. Without
    // it, any commit that adds or removes a line beginning with `error:` --
    // routine in this codebase -- makes every later `git diff` unfilterable.
    // The located form is what actually needs the skip: `-a.zig:1:1: error:`
    // still parses as file:line:col + message once the leading +/- is not
    // excluded, so without the skip this diff reads as a failed command.
    const d =
        \\diff --git a/src/x.zig b/src/x.zig
        \\@@ -1,4 +1,4 @@
        \\-src/x.zig:12:5: error: old message
        \\+src/x.zig:12:5: error: new message
        \\ fn main() void {}
        \\-error: could not compile
        \\+error: could not compile the module
        \\ const pad = 0;
        \\
    ;
    // These are content lines, not this command's failure.
    try testing.expect(!hasErrorSignal(d));

    // But an unprefixed diagnostic line in the same output still counts:
    // that is git itself reporting failure.
    const with_real =
        \\diff --git a/src/x.zig b/src/x.zig
        \\-error: this is content
        \\fatal: your current branch has no commits yet
        \\
    ;
    try testing.expect(hasErrorSignal(with_real));
}
