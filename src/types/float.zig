//! float64: decimal or exponent form, inf and nan; the grammar is checked
//! here, since std.fmt.parseFloat also takes forms a data file should not
//! (hex floats, underscores between digits).

const std = @import("std");

pub fn parse(v: []const u8) ?f64 {
    if (!valid(v)) return null;
    return std.fmt.parseFloat(f64, v) catch null;
}

fn valid(v: []const u8) bool {
    var i: usize = 0;
    if (i < v.len and (v[i] == '+' or v[i] == '-')) i += 1;
    const rest = v[i..];
    for ([_][]const u8{ "inf", "infinity", "nan" }) |word| {
        if (std.ascii.eqlIgnoreCase(rest, word)) return true;
    }
    var int_digits: usize = 0;
    while (i < v.len and std.ascii.isDigit(v[i])) : (i += 1) int_digits += 1;
    var frac_digits: usize = 0;
    if (i < v.len and v[i] == '.') {
        i += 1;
        while (i < v.len and std.ascii.isDigit(v[i])) : (i += 1) frac_digits += 1;
    }
    if (int_digits + frac_digits == 0) return false;
    if (i < v.len and (v[i] == 'e' or v[i] == 'E')) {
        i += 1;
        if (i < v.len and (v[i] == '+' or v[i] == '-')) i += 1;
        var exp_digits: usize = 0;
        while (i < v.len and std.ascii.isDigit(v[i])) : (i += 1) exp_digits += 1;
        if (exp_digits == 0) return false;
    }
    return i == v.len;
}

test parse {
    const t = std.testing;
    try t.expectEqual(@as(?f64, 1.5), parse("1.5"));
    try t.expectEqual(@as(?f64, -0.25), parse("-.25"));
    try t.expectEqual(@as(?f64, 3), parse("3."));
    try t.expectEqual(@as(?f64, 1.5e-5), parse("1.5e-05"));
    try t.expectEqual(@as(?f64, 2e10), parse("2E+10"));
    try t.expect(std.math.isInf(parse("-inf").?));
    try t.expect(std.math.isInf(parse("Infinity").?));
    try t.expect(std.math.isNan(parse("NaN").?));
    for ([_][]const u8{ "", ".", "-", "e5", "1e", "1.2.3", "0x1p3", "1_000.5", "12,50", "1.5f", "--1" }) |v| {
        if (parse(v) != null) {
            std.debug.print("{s} should not parse\n", .{v});
            return error.TestUnexpectedResult;
        }
    }
}
