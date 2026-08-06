//! Filter dispatch (S8.2, docs/specs/filter.md; decision Z-09 second half).
//!
//! Maps a tool invocation to the command-aware filter that knows how to
//! compress its output. Pure lookup: no I/O, no allocation, no bus.
//!
//! Ideas ported from ztk/rtk (MIT) — notably that a filter table keyed on a
//! bare argv[0] is trivially dodged by spelling `/usr/bin/git`, and that a
//! pipeline's output is not the named command's output.

const std = @import("std");

/// A filter inspects output it believes it understands and returns the
/// compressed form, or null meaning "I looked and decided not to touch this".
/// Filters are pure: same input, same output, no I/O.
pub const Filter = *const fn (std.mem.Allocator, []const u8) error{OutOfMemory}!?[]const u8;

/// What a filter belongs to — also the dedup cache's TTL class (S8.4).
pub const Family = enum {
    git_diff,
    git_log,
    git_status,
    testrun,
    listing,
    buildlint,

    /// Commands whose output changes fast are cached briefly; a `git log`
    /// rewrite is rare enough to trust for minutes.
    pub fn ttlMs(self: Family) i64 {
        return switch (self) {
            .git_status, .listing => 30 * 1000,
            .testrun, .buildlint => 120 * 1000,
            .git_diff, .git_log => 300 * 1000,
        };
    }
};

pub const Selection = struct {
    family: Family,
    filter: Filter,
};

/// Commands that change repo/workspace state, invalidating every cached
/// result (S8.4). Correctness over hit rate: one mutation clears the cache.
pub fn isMutating(tool: []const u8, command: ?[]const u8) bool {
    if (std.mem.eql(u8, tool, "write_file")) return true;
    const cmd = command orelse return false;
    var argv = tokenize(cmd);
    const head = argv.next() orelse return false;
    const exe = basename(head);
    if (std.mem.eql(u8, exe, "git")) {
        const sub = argv.next() orelse return false;
        inline for (.{ "add", "commit", "checkout", "switch", "merge", "rebase", "reset", "stash", "pull", "apply", "restore", "rm", "mv" }) |m| {
            if (std.mem.eql(u8, sub, m)) return true;
        }
        return false;
    }
    inline for (.{ "rm", "mv", "cp", "touch", "mkdir", "sed", "install" }) |m| {
        if (std.mem.eql(u8, exe, m)) return true;
    }
    return false;
}

/// Null ⇒ no filter applies; the caller falls back to the generic trim.
///
/// Fails open on anything ambiguous: a non-bash tool, an unrecognized
/// command, or a shell pipeline (whose output is not the named command's).
pub fn select(tool: []const u8, command: ?[]const u8) ?Selection {
    if (!std.mem.eql(u8, tool, "bash")) return null;
    const cmd = command orelse return null;
    if (hasShellMeta(cmd)) return null;

    var argv = tokenize(cmd);
    const head = argv.next() orelse return null;
    // Basename so `/usr/bin/git` and `/opt/homebrew/bin/git` still match:
    // an agent must not dodge compression by spelling a full path.
    const exe = basename(head);
    // Skip `env`-style prefixes and long-option noise to reach the verb.
    const sub = nextWord(&argv);

    if (std.mem.eql(u8, exe, "git")) {
        const s = sub orelse return null;
        if (std.mem.eql(u8, s, "diff") or std.mem.eql(u8, s, "show"))
            return .{ .family = .git_diff, .filter = &git.diff };
        if (std.mem.eql(u8, s, "log"))
            return .{ .family = .git_log, .filter = &git.log };
        if (std.mem.eql(u8, s, "status"))
            return .{ .family = .git_status, .filter = &git.status };
        return null;
    }

    // Test runners and build/lint tools share argv[0] (`cargo test` vs
    // `cargo build`), so the verb decides the family.
    if (std.mem.eql(u8, exe, "cargo")) {
        const s = sub orelse return null;
        if (std.mem.eql(u8, s, "test") or std.mem.eql(u8, s, "nextest"))
            return .{ .family = .testrun, .filter = &testrun.run };
        if (std.mem.eql(u8, s, "build") or std.mem.eql(u8, s, "check") or std.mem.eql(u8, s, "clippy"))
            return .{ .family = .buildlint, .filter = &buildlint.run };
        return null;
    }
    if (std.mem.eql(u8, exe, "go")) {
        const s = sub orelse return null;
        if (std.mem.eql(u8, s, "test")) return .{ .family = .testrun, .filter = &testrun.run };
        if (std.mem.eql(u8, s, "build") or std.mem.eql(u8, s, "vet"))
            return .{ .family = .buildlint, .filter = &buildlint.run };
        return null;
    }
    if (std.mem.eql(u8, exe, "zig")) {
        const s = sub orelse return null;
        if (!std.mem.eql(u8, s, "build")) return null;
        // `zig build test` is a test run; plain `zig build` is a compile.
        const third = nextWord(&argv);
        if (third != null and std.mem.eql(u8, third.?, "test"))
            return .{ .family = .testrun, .filter = &testrun.run };
        return .{ .family = .buildlint, .filter = &buildlint.run };
    }
    if (std.mem.eql(u8, exe, "npm") or std.mem.eql(u8, exe, "pnpm") or
        std.mem.eql(u8, exe, "yarn") or std.mem.eql(u8, exe, "npx"))
    {
        var s = sub orelse return null;
        if (std.mem.eql(u8, s, "run")) s = nextWord(&argv) orelse return null;
        if (std.mem.eql(u8, s, "test") or std.mem.eql(u8, s, "jest") or std.mem.eql(u8, s, "vitest"))
            return .{ .family = .testrun, .filter = &testrun.run };
        return null;
    }

    inline for (.{ "pytest", "jest", "vitest" }) |t| {
        if (std.mem.eql(u8, exe, t)) return .{ .family = .testrun, .filter = &testrun.run };
    }
    inline for (.{ "ls", "find", "tree", "du" }) |t| {
        if (std.mem.eql(u8, exe, t)) return .{ .family = .listing, .filter = &listing.run };
    }
    inline for (.{ "tsc", "eslint", "ruff", "mypy", "clippy", "golangci-lint" }) |t| {
        if (std.mem.eql(u8, exe, t)) return .{ .family = .buildlint, .filter = &buildlint.run };
    }
    return null;
}

/// Shell metacharacters mean the output belongs to a pipeline, not to
/// argv[0]. Fail open — never compress what we cannot attribute.
fn hasShellMeta(cmd: []const u8) bool {
    for (cmd, 0..) |c, i| switch (c) {
        '|', '&', ';', '`', '\n', '<' => return true,
        '>' => return true,
        '$' => if (i + 1 < cmd.len and cmd[i + 1] == '(') return true,
        else => {},
    };
    return false;
}

fn basename(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

fn tokenize(cmd: []const u8) std.mem.TokenIterator(u8, .any) {
    return std.mem.tokenizeAny(u8, cmd, " \t");
}

/// Next token that is not a flag — `git --no-pager diff` still reaches `diff`.
fn nextWord(it: *std.mem.TokenIterator(u8, .any)) ?[]const u8 {
    while (it.next()) |t| {
        if (t.len > 0 and t[0] == '-') continue;
        return t;
    }
    return null;
}

const git = @import("git.zig");
const testrun = @import("testrun.zig");
const listing = @import("listing.zig");
const buildlint = @import("buildlint.zig");

// ===========================================================================
// Tests (docs/specs/filter.md S8.2 contract)
// ===========================================================================

const testing = std.testing;

test "S8.2: select maps known commands to their families" {
    try testing.expectEqual(Family.git_diff, select("bash", "git diff HEAD~5").?.family);
    try testing.expectEqual(Family.git_log, select("bash", "git log --oneline -20").?.family);
    try testing.expectEqual(Family.git_status, select("bash", "git status").?.family);
    try testing.expectEqual(Family.testrun, select("bash", "cargo test").?.family);
    try testing.expectEqual(Family.testrun, select("bash", "zig build test").?.family);
    try testing.expectEqual(Family.buildlint, select("bash", "zig build").?.family);
    try testing.expectEqual(Family.testrun, select("bash", "npm run test").?.family);
    try testing.expectEqual(Family.testrun, select("bash", "pytest -q").?.family);
    try testing.expectEqual(Family.listing, select("bash", "ls -la src/").?.family);
    try testing.expectEqual(Family.listing, select("bash", "find src -name '*.zig'").?.family);
    try testing.expectEqual(Family.buildlint, select("bash", "cargo check").?.family);
    try testing.expectEqual(Family.buildlint, select("bash", "eslint .").?.family);
}

test "S8.2: path-qualified argv[0] still matches" {
    try testing.expectEqual(Family.git_diff, select("bash", "/usr/bin/git diff").?.family);
    try testing.expectEqual(Family.git_status, select("bash", "/opt/homebrew/bin/git status").?.family);
    try testing.expectEqual(Family.listing, select("bash", "/bin/ls -la").?.family);
}

test "S8.2: flags before the verb do not hide it" {
    try testing.expectEqual(Family.git_diff, select("bash", "git --no-pager diff").?.family);
}

test "S8.2: unknown command selects nothing" {
    try testing.expect(select("bash", "curl https://example.com") == null);
    try testing.expect(select("bash", "echo hi") == null);
    try testing.expect(select("bash", "git bisect") == null);
    try testing.expect(select("bash", "") == null);
    try testing.expect(select("bash", null) == null);
}

test "S8.2: shell pipelines and redirects fail open" {
    try testing.expect(select("bash", "git diff | head -20") == null);
    try testing.expect(select("bash", "git status && ls") == null);
    try testing.expect(select("bash", "ls > out.txt") == null);
    try testing.expect(select("bash", "git diff $(git rev-parse HEAD)") == null);
    try testing.expect(select("bash", "git log; ls") == null);
}

test "S8.2: non-bash tools select nothing" {
    try testing.expect(select("read_file", "git diff") == null);
    try testing.expect(select("web_fetch", null) == null);
}

test "S8.2: TTL classes match the spec" {
    try testing.expectEqual(@as(i64, 30_000), Family.git_status.ttlMs());
    try testing.expectEqual(@as(i64, 30_000), Family.listing.ttlMs());
    try testing.expectEqual(@as(i64, 120_000), Family.testrun.ttlMs());
    try testing.expectEqual(@as(i64, 300_000), Family.git_log.ttlMs());
}

test "S8.2: mutating commands are recognized" {
    try testing.expect(isMutating("bash", "git add -A"));
    try testing.expect(isMutating("bash", "git commit -m wip"));
    try testing.expect(isMutating("bash", "/usr/bin/git checkout main"));
    try testing.expect(isMutating("bash", "rm -rf build"));
    try testing.expect(isMutating("write_file", null));
    try testing.expect(!isMutating("bash", "git status"));
    try testing.expect(!isMutating("bash", "ls -la"));
    try testing.expect(!isMutating("read_file", "whatever"));
}
