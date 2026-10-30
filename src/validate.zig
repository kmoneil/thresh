//! Validation: each record against the schema, counted per column, with
//! the rejected rows written out as they come.
//!
//! The error classes, from the spec: structural (the file's columns do not
//! fit the schema) fails the file; a row error (a ragged row, a broken
//! quote) rejects the row and counts against every column; a cell error (a
//! type mismatch, an enum miss, a null where none is allowed, a string over
//! max_len or not UTF-8) rejects the row and counts against its column.
//! Invalid UTF-8 is a cell error here, not the spec table's row error: the
//! policy is per column, so it counts against the column that has it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const schema_mod = @import("schema.zig");
const Schema = schema_mod.Schema;
const Column = schema_mod.Column;
const types = @import("types.zig");
const Reason = types.Reason;
const records = @import("records.zig");
const Field = records.Field;
const Record = records.Record;
const Dialect = @import("dialect.zig").Dialect;
const csv = @import("write/csv.zig");

pub const Ragged = enum { reject, pad, truncate };

pub const Options = struct {
    /// Strings read as null in every column: the schema's and --null's.
    nulls: []const []const u8 = &.{""},
    encoding: types.Encoding = .utf8,
    threshold: f64 = 1.0,
    strict: bool = false,
    ragged: Ragged = .reject,
    /// --day-first: every date column reads ambiguous dates day first.
    day_first: bool = false,
};

/// The most mismatch samples a column keeps, and rejected rows the report
/// lists, so a file with a million bad rows has a small report.
pub const max_samples = 10;
/// A sample's value is cut to this many bytes.
pub const max_sample_len = 200;

pub const Sample = struct { row: u64, value: []const u8, reason: Reason };

pub const ColumnStats = struct {
    nulls: u64 = 0,
    mismatches: u64 = 0,
    samples: std.ArrayList(Sample) = .empty,
};

pub const Validator = struct {
    gpa: Allocator,
    /// The samples' values, header names and messages.
    arena: std.heap.ArenaAllocator,
    schema: *const Schema,
    dialect: Dialect,
    options: Options,
    /// Each schema column's field in a record, or null when the file does
    /// not have it.
    mapping: []?u32,
    /// Fields a record should have: the header's, or the schema's.
    width: usize,
    /// The header's names, for the reject file.
    names: []const []const u8,
    stats: []ColumnStats,
    /// Each date or timestamp column's reader; null for other types.
    dates: []?types.date.Column,
    rows: u64 = 0,
    rejected: u64 = 0,
    rejected_sample: std.ArrayList(u64) = .empty,
    row_errors: std.EnumArray(Reason, u64) = .initFill(0),
    structural: std.ArrayList([]const u8) = .empty,
    extra_columns: bool = false,
    /// Quote characters read as data inside unquoted fields, and records
    /// ended by a line break other than the dialect's.
    stray_quotes: u64 = 0,
    foreign_newlines: u64 = 0,
    /// --strict made a ragged row fail the file.
    strict_failure: bool = false,
    reject: ?*Io.Writer = null,
    reject_header_written: bool = false,
    scratch: std.ArrayList(u8) = .empty,
    errors: std.ArrayList(u8) = .empty,
    values: std.ArrayList([]const u8) = .empty,

    pub fn init(gpa: Allocator, s: *const Schema, d: Dialect, options: Options) Allocator.Error!Validator {
        const stats = try gpa.alloc(ColumnStats, s.columns.len);
        @memset(stats, .{});
        const mapping = try gpa.alloc(?u32, s.columns.len);
        for (mapping, 0..) |*m, i| m.* = @intCast(i);
        const dates = try gpa.alloc(?types.date.Column, s.columns.len);
        for (dates, s.columns) |*dc, c| dc.* = switch (c.type) {
            .date, .timestamp => .init(c.format, c.day_first or options.day_first, options.strict),
            else => null,
        };
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(gpa);
        var v: Validator = .{
            .gpa = gpa,
            .arena = .init(gpa),
            .schema = s,
            .dialect = d,
            .options = options,
            .mapping = mapping,
            .width = s.columns.len,
            .names = &.{},
            .stats = stats,
            .dates = dates,
        };
        const a = v.arena.allocator();
        const ns = try a.alloc([]const u8, s.columns.len);
        for (ns, s.columns) |*n, c| n.* = c.name;
        v.names = ns;
        return v;
    }

    pub fn deinit(v: *Validator) void {
        for (v.stats) |*s| s.samples.deinit(v.gpa);
        v.gpa.free(v.stats);
        v.gpa.free(v.mapping);
        v.gpa.free(v.dates);
        v.rejected_sample.deinit(v.gpa);
        v.structural.deinit(v.gpa);
        v.scratch.deinit(v.gpa);
        v.errors.deinit(v.gpa);
        v.values.deinit(v.gpa);
        v.arena.deinit();
    }

    fn fail(v: *Validator, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try v.structural.append(v.gpa, try std.fmt.allocPrint(v.arena.allocator(), fmt, args));
    }

    /// Settles which field each column is in. With a header and matching by
    /// name, header is its fields: a column missing from it fails the file,
    /// and one it has that the schema does not is a warning (a failure
    /// under --strict). Otherwise by position, width the file's fields.
    pub fn columns(v: *Validator, header: ?[]const Field, width: usize, data: []const u8, base: u64) Allocator.Error!void {
        const s = v.schema;
        const by_name = (s.match orelse if (header != null) schema_mod.Match.name else .position) == .name;
        if (by_name and header == null) return v.fail("match by name needs a header", .{});
        const a = v.arena.allocator();
        if (header) |h| {
            const names = try a.alloc([]const u8, h.len);
            for (names, h) |*n, f| n.* = try a.dupe(u8, try v.valueOf(f, data, base));
            v.names = names;
            v.width = h.len;
        } else v.width = width;

        if (by_name) {
            const h = v.names;
            const used = try v.gpa.alloc(bool, h.len);
            defer v.gpa.free(used);
            @memset(used, false);
            for (s.columns, v.mapping) |c, *m| {
                m.* = null;
                for (h, 0..) |n, i| {
                    if (!used[i] and std.ascii.eqlIgnoreCase(std.mem.trim(u8, n, " \t"), std.mem.trim(u8, c.name, " \t"))) {
                        m.* = @intCast(i);
                        used[i] = true;
                        break;
                    }
                }
                if (m.* == null) try v.fail("the schema's column '{s}' is not in the header", .{c.name});
            }
            for (used, h) |u, n| if (!u) {
                v.extra_columns = true;
                if (v.options.strict) try v.fail("the header's column '{s}' is not in the schema", .{n});
            };
        } else {
            for (v.mapping, 0..) |*m, i| m.* = if (i < v.width) @intCast(i) else null;
            if (v.width < s.columns.len) try v.fail("the file has {d} columns, the schema {d}", .{ v.width, s.columns.len });
            if (v.width > s.columns.len) {
                v.extra_columns = true;
                if (v.options.strict) try v.fail("the file has {d} columns, the schema {d}", .{ v.width, s.columns.len });
            }
        }
    }

    /// One data record: its row errors, then each column's cell.
    pub fn record(v: *Validator, rec: Record, fields: []const Field, data: []const u8, base: u64) (Allocator.Error || Io.Writer.Error)!void {
        v.rows += 1;
        v.stray_quotes += rec.stray_quotes;
        if (rec.foreign_newline) v.foreign_newlines += 1;
        v.errors.clearRetainingCapacity();
        var row_error: ?Reason = if (rec.problem) |p| switch (p) {
            .unterminated_quote => .unterminated_quote,
            .bad_quote => .bad_quote,
            .field_too_long => .field_too_long,
        } else null;
        if (row_error == null and fields.len != v.width) {
            const ok = switch (v.options.ragged) {
                .reject => false,
                .pad => fields.len < v.width,
                .truncate => fields.len > v.width,
            };
            if (!ok) {
                row_error = .ragged;
                if (v.options.strict) v.strict_failure = true;
            }
        }
        if (row_error) |r| {
            v.row_errors.getPtr(r).* += 1;
            for (v.stats) |*s| s.mismatches += 1;
            try v.errors.print(v.gpa, "*:{s}", .{r.text()});
            return v.rejectRow(rec, fields, data, base);
        }
        for (v.schema.columns, v.mapping, v.stats, v.dates) |*c, m, *st, *dc| {
            const i = m orelse continue;
            const value = if (i < fields.len) try v.valueOf(fields[i], data, base) else "";
            const r: Reason = if (v.isNull(c, value)) r: {
                if (c.nullable) {
                    st.nulls += 1;
                    continue;
                }
                break :r .null_value;
            } else if (dc.*) |*d| switch (d.read(value)) {
                .ok => continue,
                .bad => |p| types.dateReason(p),
            } else types.check(c, value, v.options.encoding) orelse continue;
            st.mismatches += 1;
            if (st.samples.items.len < max_samples) try st.samples.append(v.gpa, .{
                .row = rec.line,
                .value = try v.arena.allocator().dupe(u8, value[0..@min(value.len, max_sample_len)]),
                .reason = r,
            });
            if (v.errors.items.len > 0) try v.errors.append(v.gpa, ';');
            try v.errors.print(v.gpa, "{s}:{s}", .{ c.name, r.text() });
        }
        if (v.errors.items.len > 0) try v.rejectRow(rec, fields, data, base);
    }

    fn isNull(v: *const Validator, c: *const Column, value: []const u8) bool {
        for (v.options.nulls) |n| if (std.mem.eql(u8, n, value)) return true;
        for (c.nulls) |n| if (std.mem.eql(u8, n, value)) return true;
        return false;
    }

    /// A field's value, escapes undone, valid until the next call.
    fn valueOf(v: *Validator, f: Field, data: []const u8, base: u64) Allocator.Error![]const u8 {
        const local: Field = .{ .start = f.start - base, .len = f.len, .flags = f.flags };
        if (!f.flags.needs_unescape) return local.raw(data);
        try v.scratch.resize(v.gpa, f.len);
        return local.value(data, v.dialect, v.scratch.items);
    }

    /// Counts the row as rejected and writes it to the reject file: its
    /// fields as read, then _row (its source line) and _errors.
    fn rejectRow(v: *Validator, rec: Record, fields: []const Field, data: []const u8, base: u64) (Allocator.Error || Io.Writer.Error)!void {
        v.rejected += 1;
        if (v.rejected_sample.items.len < max_samples) try v.rejected_sample.append(v.gpa, rec.line);
        const w = v.reject orelse return;
        if (!v.reject_header_written) {
            v.reject_header_written = true;
            for (v.names) |n| {
                try csv.field(w, n, .{});
                try csv.delimiter(w, .{});
            }
            try w.writeAll("_row,_errors\n");
        }
        for (fields) |f| {
            try csv.field(w, try v.valueOf(f, data, base), .{});
            try csv.delimiter(w, .{});
        }
        try w.print("{d},", .{rec.line});
        try csv.field(w, v.errors.items, .{});
        try w.writeByte('\n');
    }

    /// The file passes: nothing structural, no --strict failure, and every
    /// column conforms at least as often as the threshold asks.
    pub fn passed(v: *const Validator) bool {
        if (v.structural.items.len > 0 or v.strict_failure) return false;
        for (v.stats) |s| if (conformance(s, v.rows) < v.options.threshold) return false;
        return true;
    }
};

/// The fraction of rows a column's cells conform in: nulls it allows count.
pub fn conformance(s: ColumnStats, rows: u64) f64 {
    if (rows == 0) return 1.0;
    return 1.0 - @as(f64, @floatFromInt(s.mismatches)) / @as(f64, @floatFromInt(rows));
}

const testing = std.testing;
const reference = @import("reference.zig");

/// Validates input (a header, then data) against s, returning the
/// validator for the test to look at, and the reject file in rejects.
fn run(input: []const u8, s: *const Schema, options: Options, rejects: *Io.Writer.Allocating) !Validator {
    var v: Validator = try .init(testing.allocator, s, .rfc4180, options);
    errdefer v.deinit();
    v.reject = &rejects.writer;
    var p: reference.Parser = .init(input, .rfc4180, .{});
    var fields: std.ArrayList(Field) = .empty;
    defer fields.deinit(testing.allocator);
    var first = true;
    while (try p.next(testing.allocator, &fields)) |rec| {
        if (first) {
            first = false;
            try v.columns(fields.items, fields.items.len, input, 0);
            continue;
        }
        try v.record(rec, fields.items, input, 0);
    }
    return v;
}

const orders: Schema = .{
    .columns = &.{
        .{ .name = "id", .type = .int64, .nullable = false },
        .{ .name = "amount", .type = .decimal, .precision = 8, .scale = 2 },
        .{ .name = "status", .type = .@"enum", .values = &.{ "open", "closed" } },
    },
    .nulls = &.{ "", "N/A" },
};

test "cells: mismatches, nulls and samples per column" {
    var rejects: Io.Writer.Allocating = .init(testing.allocator);
    defer rejects.deinit();
    const input = "ID,Status,amount\n1,open,1.50\n2,closed,N/A\n,open,2\n4,maybe,\"12,50\"\n";
    var v = try run(input, &orders, .{ .nulls = orders.nulls }, &rejects);
    defer v.deinit();
    try testing.expectEqual(@as(usize, 0), v.structural.items.len);
    try testing.expectEqual(@as(u64, 4), v.rows);
    try testing.expectEqual(@as(u64, 2), v.rejected);
    try testing.expectEqualSlices(u64, &.{ 4, 5 }, v.rejected_sample.items);
    try testing.expectEqual(@as(u64, 1), v.stats[0].mismatches);
    try testing.expectEqual(Reason.null_value, v.stats[0].samples.items[0].reason);
    try testing.expectEqual(@as(u64, 1), v.stats[1].nulls);
    try testing.expectEqual(@as(u64, 1), v.stats[1].mismatches);
    try testing.expectEqualStrings("12,50", v.stats[1].samples.items[0].value);
    try testing.expectEqual(@as(u64, 1), v.stats[2].mismatches);
    try testing.expect(!v.passed());
    try testing.expectEqualStrings(
        \\ID,Status,amount,_row,_errors
        \\,open,2,4,id:null in a non-nullable column
        \\4,maybe,"12,50",5,amount:not a decimal;status:not one of the enum's values
        \\
    , rejects.written());
}

test "rows: ragged and broken rows count against every column" {
    var rejects: Io.Writer.Allocating = .init(testing.allocator);
    defer rejects.deinit();
    const input = "id,amount,status\n1,1.50\n2,\"3\"x,open\n3,4.00,open\n";
    var v = try run(input, &orders, .{}, &rejects);
    defer v.deinit();
    try testing.expectEqual(@as(u64, 2), v.rejected);
    try testing.expectEqual(@as(u64, 1), v.row_errors.get(.ragged));
    try testing.expectEqual(@as(u64, 1), v.row_errors.get(.bad_quote));
    for (v.stats) |s| try testing.expectEqual(@as(u64, 2), s.mismatches);
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0), conformance(v.stats[0], v.rows), 1e-12);

    var padded: Io.Writer.Allocating = .init(testing.allocator);
    defer padded.deinit();
    var p = try run("id,amount,status\n1,1.50\n", &orders, .{ .ragged = .pad }, &padded);
    defer p.deinit();
    try testing.expectEqual(@as(u64, 0), p.rejected);
    try testing.expectEqual(@as(u64, 1), p.stats[2].nulls);
}

test "structure: a missing column fails the file, an extra one only under --strict" {
    var rejects: Io.Writer.Allocating = .init(testing.allocator);
    defer rejects.deinit();
    var v = try run("id,status,note\n1,open,x\n", &orders, .{}, &rejects);
    defer v.deinit();
    try testing.expectEqual(@as(usize, 1), v.structural.items.len);
    try testing.expectEqualStrings("the schema's column 'amount' is not in the header", v.structural.items[0]);
    try testing.expect(v.extra_columns);
    try testing.expect(!v.passed());

    var ok = try run("id,amount,status,note\n1,2,open,x\n", &orders, .{}, &rejects);
    defer ok.deinit();
    try testing.expect(ok.passed());
    var strict = try run("id,amount,status,note\n1,2,open,x\n", &orders, .{ .strict = true }, &rejects);
    defer strict.deinit();
    try testing.expect(!strict.passed());
}

test "the threshold lets a little dirt through" {
    var rejects: Io.Writer.Allocating = .init(testing.allocator);
    defer rejects.deinit();
    var v = try run("id,amount,status\n1,1,open\n2,2,open\n3,x,open\n4,4,open\n", &orders, .{ .threshold = 0.7 }, &rejects);
    defer v.deinit();
    try testing.expect(v.passed());
    v.options.threshold = 0.8;
    try testing.expect(!v.passed());
}

test "a format from formatOf sends the column down the fast path" {
    const values = [_][]const u8{ "2024-03-15 10:20:30", "2023-01-02 03:04:05", "2025-12-31 23:59:59" };
    var buf: [64]u8 = undefined;
    const format = types.date.formatOf(&values, false, &buf).?;
    try testing.expectEqualStrings("%Y-%m-%d %H:%M:%S", format);
    const s: Schema = .{ .columns = &.{
        .{ .name = "id", .type = .int64 },
        .{ .name = "at", .type = .timestamp, .format = format },
    } };
    var rejects: Io.Writer.Allocating = .init(testing.allocator);
    defer rejects.deinit();
    var v = try run("id,at\n1,2024-03-15 10:20:30\n2,2023-01-02 03:04:05\n3,2025-12-31 23:59:59\n4,yesterday\n", &s, .{}, &rejects);
    defer v.deinit();
    try testing.expectEqual(@as(u64, 1), v.rejected);
    // The first value showed the layout; the other two were read with it.
    try testing.expectEqual(@as(u64, 2), v.dates[1].?.fast);
    try testing.expectEqual(Reason.not_in_format, v.stats[1].samples.items[0].reason);
}

test "dates without a format: ambiguity counted, refused under --strict" {
    const s: Schema = .{ .columns = &.{.{ .name = "d", .type = .date }} };
    var rejects: Io.Writer.Allocating = .init(testing.allocator);
    defer rejects.deinit();
    const input = "d\n03/04/2024\n05/06/2024\n2024-07-08\n3 days ago\n";
    var v = try run(input, &s, .{}, &rejects);
    defer v.deinit();
    try testing.expectEqual(@as(u64, 2), v.dates[0].?.ambiguous);
    try testing.expectEqual(@as(u64, 1), v.rejected);
    try testing.expectEqual(Reason.relative_date, v.stats[0].samples.items[0].reason);
    var strict = try run(input, &s, .{ .strict = true }, &rejects);
    defer strict.deinit();
    try testing.expectEqual(@as(u64, 3), strict.rejected);
    var day_first = try run("d\n13/04/2024\n05/06/2024\n", &s, .{ .day_first = true }, &rejects);
    defer day_first.deinit();
    try testing.expectEqual(@as(u64, 0), day_first.rejected);
}
