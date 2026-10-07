//! Wait-status decoding for the filter probe.
//!
//! `pclose` returns a wait(2) status, not an exit code. `git diff` exits 1
//! when the patch is non-empty and 128 when the revision does not exist
//! (a depth-1 checkout has no `HEAD~1`). Only an accepted exit may be scored.

const std = @import("std");

pub const ExitError = error{ PcloseFailed, CommandSignaled };

pub fn commandExit(status: c_int) ExitError!u8 {
    if (status < 0) return error.PcloseFailed;
    // WIFEXITED: the low 7 bits are 0. Anything else is a signal (or a stop).
    if ((status & 0x7f) != 0) return error.CommandSignaled;
    return @intCast((status >> 8) & 0xff);
}

/// `max_exit` is the highest exit that still produced the command's output.
/// `git diff` uses 1; every other probe command uses 0.
pub fn exitAccepted(code: u8, max_exit: u8) bool {
    return code <= max_exit;
}

test "probe: clean wait status is the exit code" {
    try std.testing.expectEqual(@as(u8, 0), try commandExit(0));
    try std.testing.expectEqual(@as(u8, 1), try commandExit(1 << 8));
    try std.testing.expectEqual(@as(u8, 128), try commandExit(128 << 8));
}

test "probe: pclose failure and signals are not exit codes" {
    try std.testing.expectError(error.PcloseFailed, commandExit(-1));
    // SIGTERM is a wait status with the signal in the low 7 bits, not an exit.
    try std.testing.expectError(error.CommandSignaled, commandExit(15));
}

test "probe: git diff may exit 1; a fatal exit is not a sample" {
    try std.testing.expect(exitAccepted(0, 0));
    try std.testing.expect(!exitAccepted(1, 0));
    try std.testing.expect(exitAccepted(1, 1));
    try std.testing.expect(!exitAccepted(2, 1));
    try std.testing.expect(!exitAccepted(128, 1));
}
