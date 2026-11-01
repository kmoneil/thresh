//! decimal(p, s): digits with at most s after the point and p in all,
//! stored as an i128 scaled by 10^s. No exponent and no rounding: a value
//! with more fractional digits than the scale is a mismatch.

const std = @import("std");

pub const Error = error{ NotDecimal, OverPrecision, OverScale };

pub fn parse(v: []const u8, precision: u8, scale: u8) Error!i128 {
    const neg = v.len > 0 and v[0] == '-';
    const unsigned = if (neg or (v.len > 0 and v[0] == '+')) v[1..] else v;
    const int = digitsFrom(unsigned, 0);
    // Leading zeros are not digits of the value.
    const int_digits = std.mem.trimStart(u8, int, "0").len;
    if (int_digits > precision) return error.OverPrecision;
    var rest = unsigned[int.len..];
    var frac: []const u8 = "";
    if (std.mem.startsWith(u8, rest, ".")) {
        frac = digitsFrom(rest, 1);
        if (frac.len > scale) return error.OverScale;
        rest = rest[1 + frac.len ..];
    }
    if (int.len + frac.len == 0 or rest.len > 0) return error.NotDecimal;
    if (int_digits + scale > precision) return error.OverPrecision;
    // At most precision digits now, which schema.check holds to 38: an
    // i128 takes them. Up to the scale: 1.5 in decimal(10, 2) is 150.
    var n: i128 = 0;
    for (int) |c| n = n * 10 + (c - '0');
    for (frac) |c| n = n * 10 + (c - '0');
    for (frac.len..scale) |_| n *= 10;
    return if (neg) -n else n;
}

/// The run of digits in s from start.
fn digitsFrom(s: []const u8, start: usize) []const u8 {
    var end = start;
    while (end < s.len and std.ascii.isDigit(s[end])) end += 1;
    return s[start..end];
}

test parse {
    const t = std.testing;
    try t.expectEqual(@as(i128, 1250), try parse("12.50", 18, 2));
    try t.expectEqual(@as(i128, 150), try parse("1.5", 18, 2));
    try t.expectEqual(@as(i128, -5), try parse("-.05", 18, 2));
    try t.expectEqual(@as(i128, 700), try parse("7", 18, 2));
    try t.expectEqual(@as(i128, 700), try parse("7.", 18, 2));
    try t.expectEqual(@as(i128, 123), try parse("000123", 3, 0));
    try t.expectEqual(@as(i128, 9999999999999999999999999999999999999), try parse("9999999999999999999999999999999999999", 38, 0));
    try t.expectError(error.OverScale, parse("1.234", 18, 2));
    try t.expectError(error.OverPrecision, parse("1234567890123.45", 12, 2));
    try t.expectError(error.OverPrecision, parse("1000", 5, 2));
    try t.expectError(error.OverPrecision, parse("99999999999999999999999999999999999999999", 38, 0));
    // More digits in all than an i128 holds, each failing as it did.
    try t.expectError(error.OverPrecision, parse("99999999999999999999.12345678901234567890123456", 38, 38));
    try t.expectError(error.OverScale, parse("99999999999999999999.123456789012345678901234567890123456789", 38, 38));
    try t.expectError(error.NotDecimal, parse("99999999999999999999.12345678901234567890123456x", 38, 38));
    try t.expectEqual(@as(i128, 12345678901234567890123456789012345678), try parse(".12345678901234567890123456789012345678", 38, 38));
    for ([_][]const u8{ "", ".", "-", "12,50", "1e3", "1.2.3", "abc", "1 " }) |v| try t.expectError(error.NotDecimal, parse(v, 18, 2));
}
