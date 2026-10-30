//! decimal(p, s): digits with at most s after the point and p in all,
//! stored as an i128 scaled by 10^s. No exponent and no rounding: a value
//! with more fractional digits than the scale is a mismatch.

const std = @import("std");

pub const Error = error{ NotDecimal, OverPrecision, OverScale };

pub fn parse(v: []const u8, precision: u8, scale: u8) Error!i128 {
    var i: usize = 0;
    const neg = v.len > 0 and v[0] == '-';
    if (v.len > 0 and (v[0] == '-' or v[0] == '+')) i = 1;
    var n: i128 = 0;
    var int_digits: usize = 0;
    var frac_digits: usize = 0;
    var seen_digit = false;
    var significant = false;
    while (i < v.len and std.ascii.isDigit(v[i])) : (i += 1) {
        seen_digit = true;
        // Leading zeros are not digits of the value.
        if (v[i] != '0') significant = true;
        if (significant) int_digits += 1;
        if (int_digits > precision) return error.OverPrecision;
        n = n * 10 + (v[i] - '0');
    }
    if (i < v.len and v[i] == '.') {
        i += 1;
        while (i < v.len and std.ascii.isDigit(v[i])) : (i += 1) {
            seen_digit = true;
            frac_digits += 1;
            if (frac_digits > scale) return error.OverScale;
            n = n * 10 + (v[i] - '0');
        }
    }
    if (!seen_digit or i != v.len) return error.NotDecimal;
    if (int_digits + scale > precision) return error.OverPrecision;
    // Up to the scale: 1.5 in decimal(10, 2) is 150.
    var pad = scale - frac_digits;
    while (pad > 0) : (pad -= 1) n *= 10;
    return if (neg) -n else n;
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
    for ([_][]const u8{ "", ".", "-", "12,50", "1e3", "1.2.3", "abc", "1 " }) |v| try t.expectError(error.NotDecimal, parse(v, 18, 2));
}
