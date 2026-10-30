//! enum: one of the column's values, exactly or ignoring case.

const std = @import("std");

/// The value's index in values, or null.
pub fn index(v: []const u8, values: []const []const u8, case_insensitive: bool) ?u32 {
    for (values, 0..) |s, i| {
        const same = if (case_insensitive) std.ascii.eqlIgnoreCase(v, s) else std.mem.eql(u8, v, s);
        if (same) return @intCast(i);
    }
    return null;
}

test index {
    const values: []const []const u8 = &.{ "open", "closed" };
    try std.testing.expectEqual(@as(?u32, 1), index("closed", values, false));
    try std.testing.expectEqual(@as(?u32, null), index("OPEN", values, false));
    try std.testing.expectEqual(@as(?u32, 0), index("OPEN", values, true));
    try std.testing.expectEqual(@as(?u32, null), index("pending", values, true));
}
