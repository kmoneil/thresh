//! A cell against its column's type and constraints: hand-written byte
//! loops over the field, no allocation and no regex, so a check runs close
//! to parse speed. Nulls are the caller's to settle first.

const std = @import("std");
const schema = @import("schema.zig");
pub const int = @import("types/int.zig");
pub const float = @import("types/float.zig");
pub const decimal = @import("types/decimal.zig");
pub const boolean = @import("types/bool.zig");
pub const time = @import("types/time.zig");
pub const enumeration = @import("types/enum.zig");
pub const utf8 = @import("types/utf8.zig");
pub const date = @import("types/date.zig");

pub const Encoding = enum { utf8, latin1, cp1252 };

/// A single-byte encoding's byte as a code point. Latin-1's is the byte.
/// Windows-1252 differs in 0x80 to 0x9f, where it has punctuation and a
/// few letters (0x92 is U+2019, 0x9c U+0153); its five unassigned bytes
/// there are their Latin-1 code points, as WHATWG's decoder reads them.
pub fn codepoint(e: Encoding, b: u8) u21 {
    if (e == .cp1252 and b >= 0x80 and b < 0xa0) return cp1252_c1[b - 0x80];
    return b;
}

const cp1252_c1 = [32]u21{
    0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
    0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
};

/// Why a cell or a row is rejected. The text is what the report's samples
/// and the reject file's _errors carry.
pub const Reason = enum {
    null_value,
    not_bool,
    not_int,
    int_overflow,
    not_float,
    not_decimal,
    decimal_precision,
    decimal_scale,
    not_time,
    not_in_enum,
    too_long,
    invalid_utf8,
    not_date,
    not_in_format,
    relative_date,
    ambiguous_date,
    // Rows: counted against every column.
    ragged,
    unterminated_quote,
    bad_quote,
    field_too_long,

    pub fn text(r: Reason) []const u8 {
        return switch (r) {
            .null_value => "null in a non-nullable column",
            .not_bool => "not a bool",
            .not_int => "not an int64",
            .int_overflow => "out of int64 range",
            .not_float => "not a float64",
            .not_decimal => "not a decimal",
            .decimal_precision => "too many digits for the decimal's precision",
            .decimal_scale => "too many digits after the point for the decimal's scale",
            .not_time => "not a time",
            .not_in_enum => "not one of the enum's values",
            .too_long => "longer than max_len",
            .invalid_utf8 => "not valid UTF-8",
            .not_date => "not a date",
            .not_in_format => "not in the column's format",
            .relative_date => "a relative date, which needs a base time",
            .ambiguous_date => "an ambiguous date (--strict)",
            .ragged => "a different number of fields",
            .unterminated_quote => "a quote never closed",
            .bad_quote => "something after a closing quote",
            .field_too_long => "a field over 4 GiB",
        };
    }
};

/// A cell's typed value, what the builders keep and the writers write.
pub const Value = union(enum) {
    bool: bool,
    int: i64,
    float: f64,
    /// Scaled by 10^scale.
    decimal: i128,
    /// Microseconds since midnight.
    time: i64,
    /// Days since 1970-01-01, the date as written.
    date: i32,
    /// Microseconds since 1970-01-01T00:00:00Z: a naive time read as UTC.
    timestamp: i64,
    /// The value's index in the enum's values.
    enumeration: u32,
    /// The bytes as read; the builder transcodes them.
    string: []const u8,
    binary: []const u8,
};

pub const Read = union(enum) { ok: Value, bad: Reason };

/// v's value as col's type, or why it does not fit. Numbers, booleans and
/// times may have spaces or tabs around them; strings are taken as they are.
pub fn read(col: *const schema.Column, v: []const u8, encoding: Encoding) Read {
    const t = std.mem.trim(u8, v, " \t");
    return switch (col.type) {
        .bool => if (boolean.parse(t, col.true_values, col.false_values)) |b| .{ .ok = .{ .bool = b } } else .{ .bad = .not_bool },
        .int64 => if (int.parse(t)) |n| .{ .ok = .{ .int = n } } else |e| .{ .bad = switch (e) {
            error.NotInt => .not_int,
            error.Overflow => .int_overflow,
        } },
        .float64 => if (float.parse(t)) |f| .{ .ok = .{ .float = f } } else .{ .bad = .not_float },
        .decimal => if (decimal.parse(t, col.precision, col.scale)) |d| .{ .ok = .{ .decimal = d } } else |e| .{ .bad = switch (e) {
            error.NotDecimal => .not_decimal,
            error.OverPrecision => .decimal_precision,
            error.OverScale => .decimal_scale,
        } },
        .time => if (time.parse(t)) |us| .{ .ok = .{ .time = us } } else .{ .bad = .not_time },
        .@"enum" => if (enumeration.index(v, col.values, col.case_insensitive)) |i| .{ .ok = .{ .enumeration = i } } else .{ .bad = .not_in_enum },
        .string => str: {
            if (col.max_len) |m| if (v.len > m) break :str .{ .bad = .too_long };
            if (encoding == .utf8 and col.utf8 == .@"error" and !utf8.valid(v)) break :str .{ .bad = .invalid_utf8 };
            break :str .{ .ok = .{ .string = v } };
        },
        // A column's dates need its date.Column, which the validator keeps.
        .date, .timestamp => unreachable,
        .binary => .{ .ok = .{ .binary = v } },
    };
}

/// Why v does not fit col, or null when it does.
fn check(col: *const schema.Column, v: []const u8, encoding: Encoding) ?Reason {
    return switch (read(col, v, encoding)) {
        .ok => null,
        .bad => |r| r,
    };
}

/// The Reason for a date column's problem.
pub fn dateReason(p: date.Problem) Reason {
    return switch (p) {
        .not_date => .not_date,
        .not_in_format => .not_in_format,
        .relative => .relative_date,
        .ambiguous => .ambiguous_date,
    };
}

test {
    _ = date;
    _ = int;
    _ = float;
    _ = decimal;
    _ = boolean;
    _ = time;
    _ = enumeration;
    _ = utf8;
}

test check {
    const t = std.testing;
    const amount: schema.Column = .{ .name = "amount", .type = .decimal, .precision = 6, .scale = 2 };
    try t.expectEqual(@as(?Reason, null), check(&amount, " 12.50 ", .utf8));
    try t.expectEqual(@as(?Reason, .not_decimal), check(&amount, "12,50", .utf8));
    try t.expectEqual(@as(?Reason, .decimal_scale), check(&amount, "1.234", .utf8));
    try t.expectEqual(@as(?Reason, .decimal_precision), check(&amount, "12345.6", .utf8));
    const id: schema.Column = .{ .name = "id", .type = .int64 };
    try t.expectEqual(@as(?Reason, .int_overflow), check(&id, "99999999999999999999", .utf8));
    const note: schema.Column = .{ .name = "note", .type = .string, .max_len = 4 };
    try t.expectEqual(@as(?Reason, .too_long), check(&note, "abcde", .utf8));
    try t.expectEqual(@as(?Reason, .invalid_utf8), check(&note, "\xe9", .utf8));
    try t.expectEqual(@as(?Reason, null), check(&note, "\xe9", .latin1));
    try t.expectEqual(@as(?Reason, null), check(&note, "\x92", .cp1252));
    const status: schema.Column = .{ .name = "status", .type = .@"enum", .values = &.{ "open", "closed" } };
    try t.expectEqual(@as(?Reason, .not_in_enum), check(&status, " open", .utf8));
}

test codepoint {
    const t = std.testing;
    try t.expectEqual(@as(u21, 0xe9), codepoint(.latin1, 0xe9));
    try t.expectEqual(@as(u21, 0x92), codepoint(.latin1, 0x92));
    try t.expectEqual(@as(u21, 0xe9), codepoint(.cp1252, 0xe9));
    try t.expectEqual(@as(u21, 0x2019), codepoint(.cp1252, 0x92));
    try t.expectEqual(@as(u21, 0x0153), codepoint(.cp1252, 0x9c));
    try t.expectEqual(@as(u21, 0x20ac), codepoint(.cp1252, 0x80));
    try t.expectEqual(@as(u21, 0x81), codepoint(.cp1252, 0x81));
    try t.expectEqual(@as(u21, 'a'), codepoint(.cp1252, 'a'));
}
