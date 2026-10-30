//! time: HH:MM[:SS[.ffffff]], as microseconds since midnight.

const std = @import("std");

pub fn parse(v: []const u8) ?i64 {
    if (v.len < 5 or v[2] != ':') return null;
    const h = two(v[0..2]) orelse return null;
    const m = two(v[3..5]) orelse return null;
    if (h > 23 or m > 59) return null;
    var us: i64 = (@as(i64, h) * 60 + m) * 60 * std.time.us_per_s;
    if (v.len == 5) return us;
    if (v.len < 8 or v[5] != ':') return null;
    const s = two(v[6..8]) orelse return null;
    if (s > 59) return null;
    us += @as(i64, s) * std.time.us_per_s;
    if (v.len == 8) return us;
    if (v[8] != '.' or v.len == 9 or v.len > 15) return null;
    var frac: i64 = 0;
    for (v[9..]) |c| {
        if (!std.ascii.isDigit(c)) return null;
        frac = frac * 10 + (c - '0');
    }
    var pad = 15 - v.len;
    while (pad > 0) : (pad -= 1) frac *= 10;
    return us + frac;
}

fn two(d: *const [2]u8) ?u8 {
    if (!std.ascii.isDigit(d[0]) or !std.ascii.isDigit(d[1])) return null;
    return (d[0] - '0') * 10 + (d[1] - '0');
}

test parse {
    const t = std.testing;
    try t.expectEqual(@as(?i64, 0), parse("00:00"));
    try t.expectEqual(@as(?i64, (13 * 3600 + 5 * 60) * 1_000_000), parse("13:05"));
    try t.expectEqual(@as(?i64, (23 * 3600 + 59 * 60 + 59) * 1_000_000), parse("23:59:59"));
    try t.expectEqual(@as(?i64, 1_500_000), parse("00:00:01.5"));
    try t.expectEqual(@as(?i64, 1_000_001), parse("00:00:01.000001"));
    for ([_][]const u8{ "", "1:05", "24:00", "12:60", "12:00:60", "12:00:00.", "12:00:00.1234567", "12-00", "12:00:0a" }) |v| {
        if (parse(v) != null) {
            std.debug.print("{s} should not parse\n", .{v});
            return error.TestUnexpectedResult;
        }
    }
}
