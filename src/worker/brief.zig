//! Mission brief validation (W1, M4; docs/specs/brief.md). Pure linter over a
//! GOAL.md-shaped markdown document with YAML frontmatter. No bus, no I/O, no
//! allocation — only scans `[]const u8`. `zygos::missions::start` runs this
//! before the FSM; a failing lint refuses the mission (fail closed).

const std = @import("std");
const textx = @import("textx.zig");
const nextLine = textx.nextLine;
const isBlank = textx.isBlank;
const containsIgnoreCase = textx.containsIgnoreCase;
const eqlIgnoreCase = textx.eqlIgnoreCase;

pub const LintError = enum {
    no_frontmatter,
    missing_budget,
    missing_gates,
    no_success_criteria,
    success_criteria_not_verifiable,
    no_non_goals,
};

pub const Result = union(enum) {
    ok,
    invalid: LintError,
};

/// Lint in document order; the FIRST failing check is returned.
pub fn lint(text: []const u8) Result {
    const fm = parseFrontmatter(text) orelse return .{ .invalid = .no_frontmatter };
    if (!hasTopLevelKey(fm.inner, "budget:")) return .{ .invalid = .missing_budget };
    if (!hasTopLevelKey(fm.inner, "gates:")) return .{ .invalid = .missing_gates };

    const body = text[fm.body_start..];
    const sc = findHeadingContaining(body, "success criteria") orelse
        return .{ .invalid = .no_success_criteria };
    if (!sectionHasVerifiableTable(body, sc)) return .{ .invalid = .success_criteria_not_verifiable };

    const ng = findHeadingContaining(body, "non-goal") orelse
        return .{ .invalid = .no_non_goals };
    if (!sectionHasNonBlankContent(body, ng)) return .{ .invalid = .no_non_goals };

    return .ok;
}

/// Stable machine tag for a LintError (snake_case, matches the enum name).
pub fn tag(e: LintError) []const u8 {
    return @tagName(e);
}

// ── scanning helpers (no allocation) ────────────────────────────────────────

const Frontmatter = struct {
    inner: []const u8,
    body_start: usize,
};

const Heading = struct {
    level: u8,
    text: []const u8,
    line_start: usize,
    body_start: usize, // first byte after the heading line's newline (or EOF)
};

fn parseFrontmatter(text: []const u8) ?Frontmatter {
    var pos: usize = 0;
    // Optional leading blank lines, then open fence.
    while (true) {
        const line = nextLine(text, &pos) orelse return null;
        if (isBlank(line)) continue;
        if (!std.mem.eql(u8, line, "---")) return null;
        const inner_start = pos;
        while (true) {
            const close_start = pos;
            const inner_line = nextLine(text, &pos) orelse return null;
            if (std.mem.eql(u8, inner_line, "---")) {
                return .{
                    .inner = text[inner_start..close_start],
                    .body_start = pos,
                };
            }
        }
    }
}

fn hasTopLevelKey(fm: []const u8, key: []const u8) bool {
    var pos: usize = 0;
    while (nextLine(fm, &pos)) |line| {
        if (std.mem.startsWith(u8, line, key)) return true;
    }
    return false;
}

fn findHeadingContaining(body: []const u8, needle: []const u8) ?Heading {
    var pos: usize = 0;
    while (pos < body.len) {
        const line_start = pos;
        const line = nextLine(body, &pos) orelse break;
        if (parseHeading(line)) |h| {
            if (containsIgnoreCase(h.text, needle)) {
                return .{
                    .level = h.level,
                    .text = h.text,
                    .line_start = line_start,
                    .body_start = pos,
                };
            }
        }
    }
    return null;
}

fn sectionEnd(body: []const u8, h: Heading) usize {
    var pos = h.body_start;
    while (pos < body.len) {
        const line_start = pos;
        const line = nextLine(body, &pos) orelse break;
        if (parseHeading(line)) |next| {
            if (next.level <= h.level) return line_start;
        }
    }
    return body.len;
}

fn sectionSlice(body: []const u8, h: Heading) []const u8 {
    return body[h.body_start..sectionEnd(body, h)];
}

fn sectionHasNonBlankContent(body: []const u8, h: Heading) bool {
    const sec = sectionSlice(body, h);
    var pos: usize = 0;
    while (nextLine(sec, &pos)) |line| {
        if (!isBlank(line)) return true;
    }
    return false;
}

fn sectionHasVerifiableTable(body: []const u8, h: Heading) bool {
    const sec = sectionSlice(body, h);
    var pos: usize = 0;
    while (nextLine(sec, &pos)) |line| {
        if (!isTableRow(line)) continue;
        if (!headerHasVerifiedBy(line)) continue;
        // Next non-empty line must be a separator; then at least one data row.
        while (nextLine(sec, &pos)) |sep_cand| {
            if (isBlank(sep_cand)) continue;
            if (!isTableSeparator(sep_cand)) return false;
            while (nextLine(sec, &pos)) |data| {
                if (isBlank(data)) continue;
                if (isTableRow(data) and !isTableSeparator(data)) return true;
                return false;
            }
            return false;
        }
        return false;
    }
    return false;
}

fn headerHasVerifiedBy(line: []const u8) bool {
    // Split on '|' and check each cell for "verified by".
    var start: usize = 0;
    while (start <= line.len) {
        const bar = std.mem.indexOfScalarPos(u8, line, start, '|');
        const end = bar orelse line.len;
        const cell = std.mem.trim(u8, line[start..end], " \t");
        if (cell.len > 0 and containsIgnoreCase(cell, "verified by")) return true;
        if (bar == null) break;
        start = bar.? + 1;
    }
    return false;
}

fn isTableRow(line: []const u8) bool {
    return std.mem.indexOfScalar(u8, line, '|') != null;
}

fn isTableSeparator(line: []const u8) bool {
    if (std.mem.indexOfScalar(u8, line, '|') == null) return false;
    var has_dash = false;
    for (line) |c| {
        switch (c) {
            '|', '-', ':', ' ', '\t' => {
                if (c == '-') has_dash = true;
            },
            else => return false,
        }
    }
    return has_dash;
}

const ParsedHeading = struct { level: u8, text: []const u8 };

fn parseHeading(line: []const u8) ?ParsedHeading {
    if (line.len == 0 or line[0] != '#') return null;
    var i: usize = 0;
    while (i < line.len and line[i] == '#') : (i += 1) {}
    if (i < 1 or i > 6) return null;
    // ATX: hashes must be followed by whitespace (or be the whole line).
    if (i < line.len and line[i] != ' ' and line[i] != '\t') return null;
    var text = std.mem.trim(u8, line[i..], " \t");
    // Strip optional trailing closing hashes.
    if (text.len > 0 and text[text.len - 1] == '#') {
        var end = text.len;
        while (end > 0 and text[end - 1] == '#') : (end -= 1) {}
        text = std.mem.trim(u8, text[0..end], " \t");
    }
    return .{ .level = @intCast(i), .text = text };
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

const well_formed =
    \\---
    \\budget:
    \\  max_tokens: 1000
    \\gates:
    \\  new_dependency: human
    \\---
    \\
    \\# Mission
    \\
    \\## Success criteria
    \\
    \\| # | Criterion | Verified by |
    \\|---|-----------|-------------|
    \\| 1 | ships     | zig build test |
    \\
    \\## Non-goals
    \\
    \\- No Windows support
    \\
;

test "a well-formed GOAL.md-shaped brief lints ok" {
    try testing.expectEqual(Result.ok, lint(well_formed));
}

test "no frontmatter ⇒ no_frontmatter" {
    const text =
        \\# Just a heading
        \\
        \\## Success criteria
        \\
        \\| # | Criterion | Verified by |
        \\|---|-----------|-------------|
        \\| 1 | x | y |
        \\
        \\## Non-goals
        \\
        \\- none
        \\
    ;
    try testing.expectEqual(Result{ .invalid = .no_frontmatter }, lint(text));
}

test "frontmatter without budget ⇒ missing_budget" {
    const text =
        \\---
        \\gates:
        \\  x: human
        \\---
        \\
        \\## Success criteria
        \\
        \\| # | Criterion | Verified by |
        \\|---|-----------|-------------|
        \\| 1 | x | y |
        \\
        \\## Non-goals
        \\
        \\- none
        \\
    ;
    try testing.expectEqual(Result{ .invalid = .missing_budget }, lint(text));
}

test "frontmatter without gates ⇒ missing_gates" {
    const text =
        \\---
        \\budget:
        \\  max: 1
        \\---
        \\
        \\## Success criteria
        \\
        \\| # | Criterion | Verified by |
        \\|---|-----------|-------------|
        \\| 1 | x | y |
        \\
        \\## Non-goals
        \\
        \\- none
        \\
    ;
    try testing.expectEqual(Result{ .invalid = .missing_gates }, lint(text));
}

test "no success-criteria heading ⇒ no_success_criteria" {
    const text =
        \\---
        \\budget:
        \\  max: 1
        \\gates:
        \\  x: human
        \\---
        \\
        \\## Objectives
        \\
        \\Do the thing.
        \\
        \\## Non-goals
        \\
        \\- none
        \\
    ;
    try testing.expectEqual(Result{ .invalid = .no_success_criteria }, lint(text));
}

test "success-criteria section without a Verified-by table ⇒ success_criteria_not_verifiable" {
    const text =
        \\---
        \\budget:
        \\  max: 1
        \\gates:
        \\  x: human
        \\---
        \\
        \\## Success criteria
        \\
        \\- just a bullet, no table
        \\
        \\## Non-goals
        \\
        \\- none
        \\
    ;
    try testing.expectEqual(Result{ .invalid = .success_criteria_not_verifiable }, lint(text));
}

test "success-criteria table header present but zero data rows ⇒ success_criteria_not_verifiable" {
    const text =
        \\---
        \\budget:
        \\  max: 1
        \\gates:
        \\  x: human
        \\---
        \\
        \\## Success criteria
        \\
        \\| # | Criterion | Verified by |
        \\|---|-----------|-------------|
        \\
        \\## Non-goals
        \\
        \\- none
        \\
    ;
    try testing.expectEqual(Result{ .invalid = .success_criteria_not_verifiable }, lint(text));
}

test "non-goals heading missing ⇒ no_non_goals" {
    const text =
        \\---
        \\budget:
        \\  max: 1
        \\gates:
        \\  x: human
        \\---
        \\
        \\## Success criteria
        \\
        \\| # | Criterion | Verified by |
        \\|---|-----------|-------------|
        \\| 1 | x | y |
        \\
    ;
    try testing.expectEqual(Result{ .invalid = .no_non_goals }, lint(text));
}

test "non-goals heading present but empty (immediately followed by another heading) ⇒ no_non_goals" {
    const text =
        \\---
        \\budget:
        \\  max: 1
        \\gates:
        \\  x: human
        \\---
        \\
        \\## Success criteria
        \\
        \\| # | Criterion | Verified by |
        \\|---|-----------|-------------|
        \\| 1 | x | y |
        \\
        \\## Non-goals
        \\## Constraints
        \\
        \\Something else.
        \\
    ;
    try testing.expectEqual(Result{ .invalid = .no_non_goals }, lint(text));
}

test "first failing check wins" {
    // Missing budget and missing non-goals → missing_budget (document order).
    const text =
        \\---
        \\gates:
        \\  x: human
        \\---
        \\
        \\## Success criteria
        \\
        \\| # | Criterion | Verified by |
        \\|---|-----------|-------------|
        \\| 1 | x | y |
        \\
    ;
    try testing.expectEqual(Result{ .invalid = .missing_budget }, lint(text));
}

test "tag() returns the snake_case enum name for every LintError" {
    try testing.expectEqualStrings("no_frontmatter", tag(.no_frontmatter));
    try testing.expectEqualStrings("missing_budget", tag(.missing_budget));
    try testing.expectEqualStrings("missing_gates", tag(.missing_gates));
    try testing.expectEqualStrings("no_success_criteria", tag(.no_success_criteria));
    try testing.expectEqualStrings("success_criteria_not_verifiable", tag(.success_criteria_not_verifiable));
    try testing.expectEqualStrings("no_non_goals", tag(.no_non_goals));
}
