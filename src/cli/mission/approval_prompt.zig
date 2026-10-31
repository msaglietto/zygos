//! Operator-facing text for one pending approval (console prompt and TUI
//! band). Pure: the entry is one element of `zygos::approvals::pending`;
//! cli/mission.zig owns the polling and the terminal.
//!
//! The input is model-controlled, so every field passes the TUI scrubber
//! before it can reach the operator's terminal, and the prompt stays on one
//! line. The input's JSON is capped with a visible marker, never silently.

const std = @import("std");
const json = std.json;
const zygos = @import("zygos");

/// Cap on the input's JSON text shown to the operator.
pub const max_input_bytes: usize = 400;

/// Owned one-line text for `entry` (one element of the `pending` array):
/// `<tool> [step <id>] <input json> (<reason>)`, absent parts omitted.
pub fn display(gpa: std.mem.Allocator, entry: json.ObjectMap) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try appendField(gpa, &out, strOf(entry.get("tool")) orelse "?");
    if (strOf(entry.get("step_id"))) |step| if (step.len > 0) {
        try out.appendSlice(gpa, " [step ");
        try appendField(gpa, &out, step);
        try out.append(gpa, ']');
    };
    if (entry.get("input")) |input| if (input != .null) {
        const text = try std.fmt.allocPrint(gpa, "{f}", .{json.fmt(input, .{})});
        defer gpa.free(text);
        try out.append(gpa, ' ');
        try appendCapped(gpa, &out, text);
    };
    if (strOf(entry.get("reason"))) |reason| if (reason.len > 0) {
        try out.appendSlice(gpa, " (");
        try appendField(gpa, &out, reason);
        try out.append(gpa, ')');
    };
    return out.toOwnedSlice(gpa);
}

fn strOf(v: ?json.Value) ?[]const u8 {
    const val = v orelse return null;
    return if (val == .string) val.string else null;
}

/// Scrubbed `s`; a newline that survives the scrubber becomes a space so the
/// prompt stays on one line.
fn appendField(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) std.mem.Allocator.Error!void {
    const start = out.items.len;
    try zygos.tui.scrub.appendScrubbed(gpa, out, s);
    for (out.items[start..]) |*b| {
        if (b.* == '\n') b.* = ' ';
    }
}

/// `text` cut at `max_input_bytes` on a UTF-8 boundary with a visible
/// `…[<n> bytes total]` marker (the shape of worker/trace.zig `clip`), then
/// scrubbed. Cutting first is safe: serialized JSON carries no raw ESC or C0,
/// and a raw C1 is a whole sequence or is dropped by the cut.
fn appendCapped(gpa: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) std.mem.Allocator.Error!void {
    if (text.len <= max_input_bytes) return appendField(gpa, out, text);
    var end: usize = max_input_bytes;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    try appendField(gpa, out, text[0..end]);
    const marker = try std.fmt.allocPrint(gpa, "…[{d} bytes total]", .{text.len});
    defer gpa.free(marker);
    try out.appendSlice(gpa, marker);
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn render(gpa: std.mem.Allocator, entry_json: []const u8) ![]u8 {
    var parsed = try json.parseFromSlice(json.Value, gpa, entry_json, .{});
    defer parsed.deinit();
    return display(gpa, parsed.value.object);
}

test "console prompt renders tool, step and input" {
    const got = try render(testing.allocator,
        \\{"id":"a-1","tool":"bash","step_id":"executor","input":{"command":"ls -la"},"reason":"policy ask: rule: bash"}
    );
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        "bash [step executor] {\"command\":\"ls -la\"} (policy ask: rule: bash)",
        got,
    );
}

test "console prompt omits the step when absent or empty and the input when missing or null" {
    const a = try render(testing.allocator,
        \\{"id":"a-1","tool":"bash","input":null,"reason":"r"}
    );
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("bash (r)", a);
    try testing.expect(std.mem.indexOf(u8, a, "[step") == null);

    const b = try render(testing.allocator,
        \\{"id":"a-1","tool":"bash","step_id":"","reason":"r"}
    );
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("bash (r)", b);

    const c = try render(testing.allocator,
        \\{"id":"a-1"}
    );
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("?", c);
}

test "console prompt caps a long input with a marker" {
    const gpa = testing.allocator;
    const long = try gpa.alloc(u8, 1000);
    defer gpa.free(long);
    @memset(long, 'a');
    const entry = try std.fmt.allocPrint(gpa,
        \\{{"id":"a-1","tool":"bash","input":{{"command":"{s}"}},"reason":"r"}}
    , .{long});
    defer gpa.free(entry);
    const got = try render(gpa, entry);
    defer gpa.free(got);

    const total = "{\"command\":\"\"}".len + long.len;
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(gpa);
    try want.appendSlice(gpa, "bash {\"command\":\"");
    try want.appendNTimes(gpa, 'a', max_input_bytes - "{\"command\":\"".len);
    try want.print(gpa, "…[{d} bytes total] (r)", .{total});
    try testing.expectEqualStrings(want.items, got);
}

test "console prompt cuts a long input on a UTF-8 boundary" {
    const gpa = testing.allocator;
    // 3-byte code points straddle the cap: the cut must back up, not split.
    const body = try gpa.alloc(u8, 300 * 3);
    defer gpa.free(body);
    for (0..300) |i| @memcpy(body[i * 3 ..][0..3], "€");
    const entry = try std.fmt.allocPrint(gpa,
        \\{{"id":"a-1","tool":"t","input":"{s}","reason":""}}
    , .{body});
    defer gpa.free(entry);
    const got = try render(gpa, entry);
    defer gpa.free(got);
    try testing.expect(std.unicode.utf8ValidateSlice(got));
    try testing.expect(std.mem.indexOf(u8, got, "…[902 bytes total]") != null);
}

test "console prompt strips escape sequences from the input" {
    const gpa = testing.allocator;
    // Raw ESC in tool/step/reason (built as JSON \u001b escapes so the entry
    // parses), ESC and a raw C1 (U+009B) inside the input string, a C1 in
    // the reason, and a surviving newline.
    const got = try render(gpa, "{\"id\":\"a-1\",\"tool\":\"ba\\u001b[2Ksh\"," ++
        "\"step_id\":\"ex\\u001b]0;pwn\\u0007ec\"," ++
        "\"input\":{\"command\":\"\\u001b[2K\\rls \u{009b}31m!\"}," ++
        "\"reason\":\"why\u{009b}2J\\nnext\\u001b[31m\"}");
    defer gpa.free(got);
    for (got) |b| try testing.expect(b >= 0x20 and b != 0x7f);
    try testing.expect(std.mem.indexOf(u8, got, "\u{009b}") == null);
    try testing.expect(std.mem.indexOf(u8, got, "\x1b") == null);
    // std.json re-escapes ESC/CR inside the input as visible \u001b / \r
    // text (harmless, and shows the operator what was sent); the raw C1 is
    // the byte the serializer leaves alone, so only the scrubber removes it.
    try testing.expectEqualStrings(
        "bash [step exec] {\"command\":\"\\u001b[2K\\rls 31m!\"} (why2J next)",
        got,
    );
}
