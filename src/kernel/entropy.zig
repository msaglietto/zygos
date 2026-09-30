//! CSPRNG bytes for kernel ids and channel keys.
//!
//! Zig 0.16 moved `std.crypto.random` onto `std.Io`, which Z-02 keeps out of
//! the kernel. `std.c.arc4random_buf` is a real function on macOS and `void`
//! on the Linux target, and glibc only grew that symbol in 2.36. The Linux
//! binary is built for glibc 2.31, so the fill uses the `getrandom` syscall
//! (kernel 5.10, inside the target's version range). A failed fill panics:
//! a zeroed key or worker id would be a silent trust-boundary break.

const std = @import("std");
const builtin = @import("builtin");

pub fn fill(buf: []u8) void {
    if (buf.len == 0) return;
    switch (builtin.os.tag) {
        .macos => std.c.arc4random_buf(buf.ptr, buf.len),
        .linux => fillGetrandom(buf) catch @panic("entropy unavailable"),
        else => @compileError("entropy is macOS or Linux only"),
    }
}

fn fillGetrandom(buf: []u8) error{EntropyUnavailable}!void {
    var filled: usize = 0;
    while (filled < buf.len) {
        const rc = std.os.linux.getrandom(buf[filled..].ptr, buf.len - filled, 0);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return error.EntropyUnavailable;
                filled += n;
            },
            .INTR => continue,
            else => return error.EntropyUnavailable,
        }
    }
}

test "fill replaces a fixed pattern and two fills differ" {
    var first: [32]u8 = [_]u8{0xA5} ** 32;
    var second: [32]u8 = [_]u8{0xA5} ** 32;
    fill(&first);
    fill(&second);
    try std.testing.expect(!allEqual(u8, &first, 0xA5));
    try std.testing.expect(!std.mem.eql(u8, &first, &second));

    var empty: [0]u8 = .{};
    fill(&empty);
}

fn allEqual(comptime T: type, buf: []const T, value: T) bool {
    for (buf) |item| if (item != value) return false;
    return true;
}
