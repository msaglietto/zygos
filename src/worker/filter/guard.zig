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

/// Error text is the whole reason the agent ran the command. Case-sensitive
/// on purpose: `Error:`/`error:` are signals, the word "errors" in prose is
/// matched too — over-preserving is the safe direction.
pub fn hasErrorSignal(text: []const u8) bool {
    inline for (.{
        "error:",    "Error:",       "ERROR",    "fatal:",
        "panic:",    "Panic",        "FAILED",   "FAIL ",
        "Traceback", "Exception",    "assert",   "SIGSEGV",
        "error[",    "thread 'main", "warning:",
    }) |needle| {
        if (std.mem.indexOf(u8, text, needle) != null) return true;
    }
    return false;
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
