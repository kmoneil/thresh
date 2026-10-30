//! int64: an optional sign and digits, nothing else; overflow is a mismatch.

const std = @import("std");

pub const Error = error{ NotInt, Overflow };

pub fn parse(v: []const u8) Error!i64 {
    if (v.len == 0) return error.NotInt;
    const neg = v[0] == '-';
    const digits = if (v[0] == '-' or v[0] == '+') v[1..] else v;
    if (digits.len == 0) return error.NotInt;
    // Accumulate negatively, so the most negative i64 fits.
    var n: i64 = 0;
    for (digits) |c| {
        if (c < '0' or c > '9') return error.NotInt;
        n = std.math.mul(i64, n, 10) catch return error.Overflow;
        n = std.math.sub(i64, n, c - '0') catch return error.Overflow;
    }
    if (neg) return n;
    return std.math.negate(n) catch error.Overflow;
}

test parse {
    const t = std.testing;
    try t.expectEqual(@as(i64, 42), try parse("42"));
    try t.expectEqual(@as(i64, -7), try parse("-7"));
    try t.expectEqual(@as(i64, 3), try parse("+3"));
    try t.expectEqual(@as(i64, 0), try parse("-0"));
    try t.expectEqual(@as(i64, std.math.maxInt(i64)), try parse("9223372036854775807"));
    try t.expectEqual(@as(i64, std.math.minInt(i64)), try parse("-9223372036854775808"));
    try t.expectError(error.Overflow, parse("9223372036854775808"));
    try t.expectError(error.Overflow, parse("-9223372036854775809"));
    for ([_][]const u8{ "", "-", "+", "1.0", "1e3", "12a", " 1", "1_000", "1,000", "0x10" }) |v| try t.expectError(error.NotInt, parse(v));
}
