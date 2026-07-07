//! Shared kernel identity types. I/O-free so catalog/invocation/trigger can
//! share WorkerId/Uuid without importing each other (module independence rule,
//! AGENTS.md). Wire ids are UUID text; the kernel works in bytes.

/// Worker connection identity: UUID bytes assigned at connect.
pub const WorkerId = [16]u8;

/// Owner of built-in functions; never removed by any disconnect path.
pub const KERNEL_WORKER: WorkerId = [_]u8{0} ** 16;

/// Invocation correlation id (UUID bytes).
pub const Uuid = [16]u8;

const std = @import("std");

/// Parse hyphenated UUID text (8-4-4-4-12 hex, either case) into bytes.
/// Shape-only validation — iii accepts any UUID variant (docs/specs/actor.md).
pub fn parseUuid(text: []const u8) error{InvalidUuid}!Uuid {
    if (text.len != 36) return error.InvalidUuid;
    var out: Uuid = undefined;
    var oi: usize = 0;
    var i: usize = 0;
    while (i < 36) {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (text[i] != '-') return error.InvalidUuid;
            i += 1;
            continue;
        }
        const hi = hexVal(text[i]) orelse return error.InvalidUuid;
        const lo = hexVal(text[i + 1]) orelse return error.InvalidUuid;
        out[oi] = hi << 4 | lo;
        oi += 1;
        i += 2;
    }
    return out;
}

/// Format UUID bytes as lowercase hyphenated text into `buf`; returns the
/// filled slice (always 36 bytes).
pub fn formatUuid(id: Uuid, buf: *[36]u8) []const u8 {
    const hex = "0123456789abcdef";
    var bi: usize = 0;
    for (id, 0..) |byte, idx| {
        buf[bi] = hex[byte >> 4];
        buf[bi + 1] = hex[byte & 0xf];
        bi += 2;
        if (idx == 3 or idx == 5 or idx == 7 or idx == 9) {
            buf[bi] = '-';
            bi += 1;
        }
    }
    return buf[0..36];
}

fn hexVal(ch: u8) ?u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => null,
    };
}

const testing = std.testing;

test "uuid text round-trips through bytes and back lowercase" {
    const text = "0af76519-16cd-43dd-8448-eb211c80319c";
    const id = try parseUuid(text);
    var buf: [36]u8 = undefined;
    try testing.expectEqualStrings(text, formatUuid(id, &buf));
}

test "uuid parse accepts uppercase, formats lowercase" {
    const id = try parseUuid("0AF76519-16CD-43DD-8448-EB211C80319C");
    var buf: [36]u8 = undefined;
    try testing.expectEqualStrings("0af76519-16cd-43dd-8448-eb211c80319c", formatUuid(id, &buf));
}

test "uuid parse rejects bad shape" {
    try testing.expectError(error.InvalidUuid, parseUuid("not-a-uuid"));
    try testing.expectError(error.InvalidUuid, parseUuid("0af7651916cd43dd8448eb211c80319c")); // no dashes
    try testing.expectError(error.InvalidUuid, parseUuid("0af76519-16cd-43dd-8448-eb211c80319g")); // bad hex
    try testing.expectError(error.InvalidUuid, parseUuid("0af76519-16cd+43dd-8448-eb211c80319c")); // dash misplaced
    try testing.expectError(error.InvalidUuid, parseUuid(""));
}
