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
    var cmd = command orelse return false;
    // A `cd DIR &&` prefix hides the real verb from the head check; peel
    // every one (the safe direction here: over-invalidating only costs hits).
    while (true) {
        const split = splitCd(cmd);
        if (split.dir == null) break;
        cmd = split.rest;
    }
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
    const raw_cmd = command orelse return null;
    const cmd = (stripWrappers(raw_cmd) orelse return null).command;

    if (isPythonPytest(cmd)) return .{ .family = .testrun, .filter = &testrun.run };

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

/// A command with the two benign wrappers agents add by habit removed:
/// a single leading `cd DIR &&` and a trailing ` 2>&1`.
pub const Wrapped = struct {
    dir: ?[]const u8,
    command: []const u8,
};

const CdSplit = struct {
    dir: ?[]const u8,
    rest: []const u8,
};

/// Splits one leading `cd DIR && ` off `cmd`. DIR is a single token: bare
/// (no shell syntax) or wrapped in one pair of matching quotes with plain
/// text inside. Anything else is not a cd prefix and `rest` is the whole
/// command. `rest` is NOT checked for shell syntax here.
fn splitCd(cmd: []const u8) CdSplit {
    const whole: CdSplit = .{ .dir = null, .rest = cmd };
    const t = std.mem.trim(u8, cmd, " \t");
    if (!std.mem.startsWith(u8, t, "cd") or t.len < 3 or (t[2] != ' ' and t[2] != '\t')) return whole;
    const after = std.mem.trimStart(u8, t[2..], " \t");
    const end = std.mem.indexOfAny(u8, after, " \t") orelse return whole;
    const token = after[0..end];
    const tail = std.mem.trimStart(u8, after[end..], " \t");
    if (!std.mem.startsWith(u8, tail, "&&")) return whole;
    const rest = tail[2..];
    // `&&` must stand alone as an operator, not open `&&&` or `&&;`.
    if (rest.len == 0 or (rest[0] != ' ' and rest[0] != '\t')) return whole;

    var dir = token;
    if (dir.len >= 2 and (dir[0] == '\'' or dir[0] == '"') and dir[dir.len - 1] == dir[0])
        dir = dir[1 .. dir.len - 1];
    if (dir.len == 0 or dir[0] == '-') return whole;
    for (dir) |c| {
        if (std.mem.indexOfScalar(u8, "|&;`<>$()\\\"'*?!#{}[]\n\r", c) != null) return whole;
    }
    return .{ .dir = dir, .rest = std.mem.trim(u8, rest, " \t") };
}

/// Null when what remains still carries shell syntax (a pipeline, a second
/// command, any other redirect, a second `cd`) or is empty.
fn stripWrappers(cmd: []const u8) ?Wrapped {
    var t = std.mem.trim(u8, cmd, " \t");
    // Only a whitespace-separated trailing `2>&1`: `2>file`, `&>`, and a
    // `2>&1` mid-command all keep their metacharacters and fail open.
    if (std.mem.endsWith(u8, t, "2>&1") and t.len > 4 and (t[t.len - 5] == ' ' or t[t.len - 5] == '\t'))
        t = std.mem.trimEnd(u8, t[0 .. t.len - 4], " \t");
    const split = splitCd(t);
    const rest = std.mem.trim(u8, split.rest, " \t");
    if (rest.len == 0 or hasShellMeta(rest)) return null;
    return .{ .dir = split.dir, .command = rest };
}

/// `python -m pytest ...` / `python3 -m pytest ...` (also `python3.11`).
fn isPythonPytest(cmd: []const u8) bool {
    var it = tokenize(cmd);
    const exe = basename(it.next() orelse return false);
    if (!std.mem.eql(u8, exe, "python") and !std.mem.startsWith(u8, exe, "python3")) return false;
    const m = it.next() orelse return false;
    if (!std.mem.eql(u8, m, "-m")) return false;
    const mod = it.next() orelse return false;
    return std.mem.eql(u8, mod, "pytest");
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

test "S8.4: a cd-prefixed mutating command is still mutating" {
    try testing.expect(isMutating("bash", "cd /app && rm -rf build"));
    try testing.expect(isMutating("bash", "cd /app && git add -A"));
    try testing.expect(isMutating("bash", "cd \"/app\" && touch x"));
    try testing.expect(isMutating("bash", "cd a && cd b && mv x y"));
    try testing.expect(!isMutating("bash", "cd /app && git status"));
    try testing.expect(!isMutating("bash", "cd /app && pytest -q"));
}

test "S8.2: benign shell wrappers still select" {
    try testing.expectEqual(Family.testrun, select("bash", "pytest -q 2>&1").?.family);
    try testing.expectEqual(Family.testrun, select("bash", "python -m pytest -q").?.family);
    try testing.expectEqual(Family.testrun, select("bash", "python3 -m pytest tests/ -v").?.family);
    try testing.expectEqual(Family.testrun, select("bash", "cd /app && pytest -q").?.family);
    try testing.expectEqual(Family.git_status, select("bash", "cd /app && git status").?.family);
    try testing.expectEqual(Family.git_diff, select("bash", "git diff 2>&1").?.family);
    try testing.expectEqual(Family.git_diff, select("bash", "cd /app && git diff 2>&1").?.family);
    // A quoted DIR is accepted only when it is a single plain token.
    try testing.expectEqual(Family.testrun, select("bash", "cd \"/app\" && pytest -q").?.family);
    try testing.expectEqual(Family.testrun, select("bash", "cd '/app' && pytest -q").?.family);

    try testing.expect(select("bash", "pytest -q | tail -30") == null);
    try testing.expect(select("bash", "pytest; rm x") == null);
    try testing.expect(select("bash", "pytest > out.txt") == null);
    try testing.expect(select("bash", "cd a && cd b && pytest") == null);
    try testing.expect(select("bash", "cd a && pytest && rm x") == null);
    try testing.expect(select("bash", "pytest 2>&1 | tail") == null);
    try testing.expect(select("bash", "cd $(pwd) && pytest") == null);
    try testing.expect(select("bash", "pytest 2>&1 -q") == null);
    try testing.expect(select("bash", "pytest 2>file") == null);
    try testing.expect(select("bash", "pytest &> out") == null);
    try testing.expect(select("bash", "pytest < in") == null);
    try testing.expect(select("bash", "pytest 2>&1 2>&1") == null);
    try testing.expect(select("bash", "pytest2>&1") == null);
    try testing.expect(select("bash", "cd a b && pytest") == null);
    try testing.expect(select("bash", "cd 'a b' && pytest") == null);
    try testing.expect(select("bash", "cd && pytest") == null);
    try testing.expect(select("bash", "cd a && ") == null);
    try testing.expect(select("bash", "cd a;b && pytest") == null);
    try testing.expect(select("bash", "python -m pip install x") == null);
    try testing.expect(select("bash", "python -m pytest | tail") == null);
}

test "S8.2: stripWrappers separates the directory from the command" {
    const w = stripWrappers("cd /app && pytest -q 2>&1").?;
    try testing.expectEqualStrings("/app", w.dir.?);
    try testing.expectEqualStrings("pytest -q", w.command);
    const bare = stripWrappers("git status").?;
    try testing.expect(bare.dir == null);
    try testing.expectEqualStrings("git status", bare.command);
    try testing.expect(stripWrappers("cd a && cd b && x") == null);
}
