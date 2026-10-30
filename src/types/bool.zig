//! bool: true/false, t/f, yes/no, 1/0 by default, ignoring case; a
//! column may name its own spellings.

const std = @import("std");

const default_true = [_][]const u8{ "true", "t", "yes", "1" };
const default_false = [_][]const u8{ "false", "f", "no", "0" };

pub fn parse(v: []const u8, true_values: ?[]const []const u8, false_values: ?[]const []const u8) ?bool {
    for (true_values orelse &default_true) |s| if (std.ascii.eqlIgnoreCase(v, s)) return true;
    for (false_values orelse &default_false) |s| if (std.ascii.eqlIgnoreCase(v, s)) return false;
    return null;
}

test parse {
    const t = std.testing;
    try t.expectEqual(@as(?bool, true), parse("TRUE", null, null));
    try t.expectEqual(@as(?bool, false), parse("No", null, null));
    try t.expectEqual(@as(?bool, true), parse("1", null, null));
    try t.expectEqual(@as(?bool, null), parse("maybe", null, null));
    try t.expectEqual(@as(?bool, null), parse("y", null, null));
    try t.expectEqual(@as(?bool, true), parse("Y", &.{"y"}, &.{"n"}));
    try t.expectEqual(@as(?bool, null), parse("true", &.{"y"}, &.{"n"}));
}
