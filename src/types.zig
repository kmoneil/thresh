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

pub const Encoding = enum { utf8, latin1 };

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
            .ragged => "a different number of fields",
            .unterminated_quote => "a quote never closed",
            .bad_quote => "something after a closing quote",
            .field_too_long => "a field over 4 GiB",
        };
    }
};

/// Why v does not fit col, or null when it does. Numbers, booleans and
/// times may have spaces or tabs around them; strings are taken as they are.
pub fn check(col: *const schema.Column, v: []const u8, encoding: Encoding) ?Reason {
    const t = std.mem.trim(u8, v, " \t");
    return switch (col.type) {
        .bool => if (boolean.parse(t, col.true_values, col.false_values) == null) .not_bool else null,
        .int64 => if (int.parse(t)) |_| null else |e| switch (e) {
            error.NotInt => .not_int,
            error.Overflow => .int_overflow,
        },
        .float64 => if (float.parse(t) == null) .not_float else null,
        .decimal => if (decimal.parse(t, col.precision, col.scale)) |_| null else |e| switch (e) {
            error.NotDecimal => .not_decimal,
            error.OverPrecision => .decimal_precision,
            error.OverScale => .decimal_scale,
        },
        .time => if (time.parse(t) == null) .not_time else null,
        .@"enum" => if (enumeration.index(v, col.values, col.case_insensitive) == null) .not_in_enum else null,
        .string => str: {
            if (col.max_len) |m| if (v.len > m) break :str .too_long;
            if (encoding == .utf8 and col.utf8 == .@"error" and !utf8.valid(v)) break :str .invalid_utf8;
            break :str null;
        },
        // Milestone 6 reads these with dateparsa; until then any value is one.
        .date, .timestamp => null,
        .binary => null,
    };
}

test {
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
    const status: schema.Column = .{ .name = "status", .type = .@"enum", .values = &.{ "open", "closed" } };
    try t.expectEqual(@as(?Reason, .not_in_enum), check(&status, " open", .utf8));
}
