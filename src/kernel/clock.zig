//! The one monotonic millisecond clock for deadlines and elapsed time.

const std = @import("std");

/// Milliseconds on CLOCK_MONOTONIC. `clock_gettime` cannot fail with a valid
/// pointer and this clock on macOS or Linux, so failure is a broken platform
/// and panics: returning 0 would silently turn every deadline loop into a
/// hang. Not for use between fork and exec (a panic there is not
/// async-signal-safe); no fork child calls it.
pub fn monotonicMs() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) @panic("clock_gettime(MONOTONIC) failed");
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

test "monotonicMs is positive and never goes backwards" {
    const a = monotonicMs();
    const b = monotonicMs();
    try std.testing.expect(a > 0);
    try std.testing.expect(b >= a);
}
