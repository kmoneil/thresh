//! ArrayList appends with the common case inline.

const std = @import("std");

/// list.append with its common case inline: with room, the item is
/// stored, and only growing the list is a call. An append a call apiece,
/// for each field (records) or each cell (builders), was a tenth of the
/// time where it was made.
pub inline fn push(comptime T: type, list: *std.ArrayList(T), gpa: std.mem.Allocator, x: T) std.mem.Allocator.Error!void {
    if (list.items.len < list.capacity) return list.appendAssumeCapacity(x);
    return list.append(gpa, x);
}

test push {
    const gpa = std.testing.allocator;
    var l: std.ArrayList(u32) = .empty;
    defer l.deinit(gpa);
    for (0..100) |i| try push(u32, &l, gpa, @intCast(i));
    try std.testing.expectEqual(@as(usize, 100), l.items.len);
    try std.testing.expectEqual(@as(u32, 99), l.items[99]);
}
