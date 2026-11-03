//! int64: an optional sign and digits, nothing else; overflow is a mismatch.

const std = @import("std");

pub const Error = error{ NotInt, Overflow };

pub fn parse(v: []const u8) Error!i64 {
    if (v.len == 0) return error.NotInt;
    const neg = v[0] == '-';
    const digits = if (v[0] == '-' or v[0] == '+') v[1..] else v;
    if (digits.len == 0) return error.NotInt;
    return if (digits.len <= 18) short(digits, neg) else long(digits, neg);
}

/// Up to 18 digits, which cannot overflow an i64: no checks on the way.
fn short(digits: []const u8, neg: bool) Error!i64 {
    var u: u64 = 0;
    for (digits) |c| {
        if (c < '0' or c > '9') return error.NotInt;
        u = u * 10 + (c - '0');
    }
    const s: i64 = @intCast(u);
    return if (neg) -s else s;
}

/// More digits, each step checked for overflow.
fn long(digits: []const u8, neg: bool) Error!i64 {
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
