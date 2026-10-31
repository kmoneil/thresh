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
const builders = @import("builders.zig");
const Problem = @import("problem.zig").Problem;

/// What a short or long row becomes.
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

/// The most mismatch samples a column keeps, and rejected rows and
/// repeated header lines the report lists, so a file with a million bad
/// rows has a small report.
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
    /// Rows rejected whole (row_errors): no column's values are read from
    /// them, so they count in no column.
    whole: u64 = 0,
    rejected_sample: std.ArrayList(u64) = .empty,
    row_errors: std.EnumArray(Reason, u64) = .initFill(0),
    structural: std.ArrayList(Problem) = .empty,
    extra_columns: bool = false,
    /// The file had a header, and records that are it again (two exports
    /// joined): skipped, and the first lines they are on.
    header_seen: bool = false,
    repeated_headers: u64 = 0,
    repeated_lines: std.ArrayList(u64) = .empty,
    /// Quote characters read as data inside unquoted fields, and records
    /// ended by a line break other than the dialect's.
    stray_quotes: u64 = 0,
    foreign_newlines: u64 = 0,
    /// --strict made a ragged row fail the file.
    strict_failure: bool = false,
    /// Whether the quotes are data: records.QuoteCheck.
    quotes: records.QuoteCheck = .{},
    reject: ?*Io.Writer = null,
    /// Where accepted rows go, for the writers.
    batch: ?*builders.Batch = null,
    /// The row's text and value per schema column, for the batch.
    raw: [][]const u8,
    cells: []?types.Value,
    reject_header_written: bool = false,
    scratch: std.ArrayList(u8) = .empty,
    errors: std.ArrayList(u8) = .empty,
    values: std.ArrayList([]const u8) = .empty,

    pub fn init(gpa: Allocator, s: *const Schema, d: Dialect, options: Options) Allocator.Error!Validator {
        var v: Validator = .{
            .gpa = gpa,
            .arena = .init(gpa),
            .schema = s,
            .dialect = d,
            .options = options,
            .mapping = &.{},
            .width = s.columns.len,
            .names = &.{},
            .stats = &.{},
            .dates = &.{},
            .raw = &.{},
            .cells = &.{},
        };
        // deinit frees what is allocated by then; an empty slice is nothing.
        errdefer v.deinit();
        v.stats = try gpa.alloc(ColumnStats, s.columns.len);
        @memset(v.stats, .{});
        v.mapping = try gpa.alloc(?u32, s.columns.len);
        for (v.mapping, 0..) |*m, i| m.* = @intCast(i);
        v.raw = try gpa.alloc([]const u8, s.columns.len);
        v.cells = try gpa.alloc(?types.Value, s.columns.len);
        v.dates = try gpa.alloc(?types.date.Column, s.columns.len);
        for (v.dates, s.columns) |*dc, c| dc.* = switch (c.type) {
            .date, .timestamp => .init(c.format, c.day_first or options.day_first, options.strict),
            else => null,
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
        v.gpa.free(v.raw);
        v.gpa.free(v.cells);
        v.rejected_sample.deinit(v.gpa);
        v.repeated_lines.deinit(v.gpa);
        v.structural.deinit(v.gpa);
        v.scratch.deinit(v.gpa);
        v.errors.deinit(v.gpa);
        v.values.deinit(v.gpa);
        v.arena.deinit();
    }

    /// A problem that fails the file, its names copied.
    fn fail(v: *Validator, p: Problem) Allocator.Error!void {
        try v.structural.append(v.gpa, try p.dupe(v.arena.allocator()));
    }

    /// Settles which field each column is in. With a header and matching by
    /// name, header is its fields: a column missing from it fails the file,
    /// and one it has that the schema does not is a warning (a failure
    /// under --strict). Otherwise by position, width the file's fields.
    /// width: the rows', whatever the header is; blank names past it at the
    /// header's end are not columns (schema.headerWidth).
    pub fn columns(v: *Validator, header: ?[]const Field, width: usize, data: []const u8, base: u64) Allocator.Error!void {
        const s = v.schema;
        const by_name = (s.match orelse if (header != null) schema_mod.Match.name else .position) == .name;
        if (by_name and header == null) return v.fail(.match_needs_header);
        const a = v.arena.allocator();
        if (header) |h| {
            const names = try a.alloc([]const u8, h.len);
            for (names, h) |*n, f| n.* = try a.dupe(u8, try v.valueOf(f, data, base));
            v.names = names[0..schema_mod.headerWidth(names, width)];
            v.width = v.names.len;
            v.header_seen = true;
        } else v.width = width;

        if (by_name) {
            // Named as infer names them, so its schema matches its files.
            const h = try schema_mod.headerNames(a, v.names);
            const used = try v.gpa.alloc(bool, h.len);
            defer v.gpa.free(used);
            @memset(used, false);
            // Each header name's first index, and after each index the next
            // with the same name: a schema column takes the first not used.
            const next = try v.gpa.alloc(?u32, h.len);
            defer v.gpa.free(next);
            var first: schema_mod.NameMap(u32) = .empty;
            defer first.deinit(v.gpa);
            try first.ensureTotalCapacity(v.gpa, @intCast(h.len));
            var i = h.len;
            while (i > 0) {
                i -= 1;
                const r = first.getOrPutAssumeCapacity(std.mem.trim(u8, h[i], " \t"));
                next[i] = if (r.found_existing) r.value_ptr.* else null;
                r.value_ptr.* = @intCast(i);
            }
            for (s.columns, v.mapping) |c, *m| {
                m.* = null;
                var at = first.get(std.mem.trim(u8, c.name, " \t"));
                while (at) |k| : (at = next[k]) {
                    if (used[k]) continue;
                    m.* = k;
                    used[k] = true;
                    break;
                }
                if (m.* == null) try v.fail(.{ .column_missing = .{ .column = c.name } });
            }
            for (used, h) |u, n| if (!u) {
                v.extra_columns = true;
                if (v.options.strict) try v.fail(.{ .column_extra = .{ .column = n } });
            };
        } else {
            for (v.mapping, 0..) |*m, i| m.* = if (i < v.width) @intCast(i) else null;
            if (v.width < s.columns.len) try v.fail(.{ .width_mismatch = .{ .columns = v.width, .schema_columns = s.columns.len } });
            if (v.width > s.columns.len) {
                v.extra_columns = true;
                if (v.options.strict) try v.fail(.{ .width_mismatch = .{ .columns = v.width, .schema_columns = s.columns.len } });
            }
        }
    }

    /// One data record: its row errors, then each column's cell.
    pub fn record(v: *Validator, rec: Record, fields: []const Field, data: []const u8, base: u64) (Allocator.Error || Io.Writer.Error)!void {
        v.quotes.record(rec, v.width, v.dialect, data, base);
        // The header again: not a row, and said so.
        if (v.header_seen and fields.len == v.names.len and try v.isHeader(fields, data, base)) {
            v.repeated_headers += 1;
            if (v.repeated_lines.items.len < max_samples) try v.repeated_lines.append(v.gpa, rec.line);
            return;
        }
        v.rows += 1;
        v.stray_quotes += rec.stray_quotes;
        if (rec.foreign_newline) v.foreign_newlines += 1;
        v.errors.clearRetainingCapacity();
        if (rec.end > base and !endsLine(data[@intCast(rec.end - 1 - base)])) try v.cutOff(rec, fields.len);
        if (v.rowError(rec, fields.len)) |r| {
            v.row_errors.getPtr(r).* += 1;
            v.whole += 1;
            try v.errors.print(v.gpa, "*:{s}", .{r.text()});
            return v.rejectRow(rec, fields, data, base);
        }
        // Every value at once, so none overwrites another: the batch keeps
        // them all.
        try records.values(v.gpa, fields, data, base, v.dialect, &v.scratch, &v.values);
        for (v.schema.columns, v.mapping, v.stats, v.dates, v.raw, v.cells) |*c, m, *st, *dc, *raw, *cell| {
            cell.* = null;
            raw.* = "";
            const i = m orelse continue;
            const value = if (i < v.values.items.len) v.values.items[i] else "";
            raw.* = value;
            const r = v.cellReason(c, dc, st, value, cell) orelse continue;
            try v.mismatch(c, st, rec.line, value, r);
        }
        if (v.errors.items.len > 0) return v.rejectRow(rec, fields, data, base);
        if (v.batch) |b| try b.append(v.raw, v.cells);
    }

    /// The last record, with no line break after it, short of fields or
    /// inside a quote: the file stops mid-record, most likely cut off in a
    /// copy or a transfer. Its row is rejected (or padded) as any other,
    /// and the file fails, since it is not all there.
    fn cutOff(v: *Validator, rec: Record, width: usize) Allocator.Error!void {
        if (rec.problem == .unterminated_quote) {
            try v.fail(.cut_off_in_quote);
        } else if (rec.problem == null and width < v.width) {
            try v.fail(.{ .cut_off = .{ .fields = width, .width = v.width } });
        }
    }

    /// Why the whole record is rejected, or null: a problem the parser
    /// found, or a width the ragged policy does not take.
    fn rowError(v: *Validator, rec: Record, width: usize) ?Reason {
        if (rec.problem) |p| return switch (p) {
            .unterminated_quote => .unterminated_quote,
            .bad_quote => .bad_quote,
            .field_too_long => .field_too_long,
        };
        if (width == v.width) return null;
        const ok = switch (v.options.ragged) {
            .reject => false,
            .pad => width < v.width,
            .truncate => width > v.width,
        };
        if (ok) return null;
        if (v.options.strict) v.strict_failure = true;
        return .ragged;
    }

    /// Why value does not fit column c, or null when it does: a null c
    /// allows is counted, and anything else read into cell.
    fn cellReason(v: *Validator, c: *const Column, dc: *?types.date.Column, st: *ColumnStats, value: []const u8, cell: *?types.Value) ?Reason {
        if (v.isNull(c, value)) {
            if (!c.nullable) return .null_value;
            st.nulls += 1;
            return null;
        }
        if (dc.*) |*d| switch (d.read(value)) {
            .ok => |t| {
                cell.* = if (c.type == .date) .{ .date = types.date.days(t) } else .{ .timestamp = types.date.micros(t) };
                return null;
            },
            .bad => |p| return types.dateReason(p),
        };
        switch (types.read(c, value, v.options.encoding)) {
            .ok => |x| {
                cell.* = x;
                return null;
            },
            .bad => |r| return r,
        }
    }

    /// A cell that does not fit: counted against its column, kept as a
    /// sample while there is room, and named in the row's _errors.
    fn mismatch(v: *Validator, c: *const Column, st: *ColumnStats, line: u64, value: []const u8, r: Reason) Allocator.Error!void {
        st.mismatches += 1;
        if (st.samples.items.len < max_samples) try st.samples.append(v.gpa, .{
            .row = line,
            .value = try v.arena.allocator().dupe(u8, value[0..@min(value.len, max_sample_len)]),
            .reason = r,
        });
        if (v.errors.items.len > 0) try v.errors.append(v.gpa, ';');
        try v.errors.print(v.gpa, "{s}:{s}", .{ c.name, r.text() });
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

    /// Whether fields are the header's names again, trimmed and in any
    /// case. The first field decides most records.
    fn isHeader(v: *Validator, fields: []const Field, data: []const u8, base: u64) Allocator.Error!bool {
        for (fields, v.names) |f, n| {
            const value = try v.valueOf(f, data, base);
            if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t"), std.mem.trim(u8, n, " \t"))) return false;
        }
        return true;
    }

    /// The file passes: nothing structural, no --strict failure, rows read
    /// whole at least as often as the threshold asks, and every column
    /// conforming as often over the rows read into columns.
    pub fn passed(v: *const Validator) bool {
        if (v.structural.items.len > 0 or v.strict_failure) return false;
        if (v.rows > 0 and 1.0 - @as(f64, @floatFromInt(v.whole)) / @as(f64, @floatFromInt(v.rows)) < v.options.threshold) return false;
        for (v.stats) |s| if (conformance(s, v.columnRows()) < v.options.threshold) return false;
        return true;
    }

    /// The rows read into columns: all but those rejected whole.
    pub fn columnRows(v: *const Validator) u64 {
        return v.rows - v.whole;
    }
};

fn endsLine(c: u8) bool {
    return c == '\n' or c == '\r';
}

/// The fraction of rows a column's cells conform in, of the rows read into
/// columns: nulls it allows count.
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

test "rows: ragged and broken rows count in row_errors, in no column, and against the file" {
    var rejects: Io.Writer.Allocating = .init(testing.allocator);
    defer rejects.deinit();
    const input = "id,amount,status\n1,1.50\n2,\"3\"x,open\n3,4.00,open\n";
    var v = try run(input, &orders, .{}, &rejects);
    defer v.deinit();
    try testing.expectEqual(@as(u64, 2), v.rejected);
    try testing.expectEqual(@as(u64, 1), v.row_errors.get(.ragged));
    try testing.expectEqual(@as(u64, 1), v.row_errors.get(.bad_quote));
    // No column's values were read from them: each column is all there.
    for (v.stats) |s| try testing.expectEqual(@as(u64, 0), s.mismatches);
    try testing.expectEqual(@as(u64, 1), v.columnRows());
    try testing.expectEqual(@as(f64, 1.0), conformance(v.stats[0], v.columnRows()));
    // But the file is a third read whole: it fails 1.0, and a half, not a third.
    try testing.expect(!v.passed());
    for ([_]struct { f64, bool }{ .{ 0.5, false }, .{ 0.3, true } }) |c| {
        var r: Io.Writer.Allocating = .init(testing.allocator);
        defer r.deinit();
        var t = try run(input, &orders, .{ .threshold = c[0] }, &r);
        defer t.deinit();
        try testing.expectEqual(c[1], t.passed());
    }

    var padded: Io.Writer.Allocating = .init(testing.allocator);
    defer padded.deinit();
    var p = try run("id,amount,status\n1,1.50\n", &orders, .{ .ragged = .pad }, &padded);
    defer p.deinit();
    try testing.expectEqual(@as(u64, 0), p.rejected);
    try testing.expectEqual(@as(u64, 1), p.stats[2].nulls);
}

test "a header again mid-file is skipped and counted, not a row" {
    var rejects: Io.Writer.Allocating = .init(testing.allocator);
    defer rejects.deinit();
    var v = try run("id,amount,status\n1,1.50,open\nID, Amount ,status\n2,2.00,closed\n", &orders, .{}, &rejects);
    defer v.deinit();
    try testing.expectEqual(@as(u64, 2), v.rows);
    try testing.expectEqual(@as(u64, 1), v.repeated_headers);
    try testing.expectEqualSlices(u64, &.{3}, v.repeated_lines.items);
    try testing.expectEqual(@as(u64, 0), v.rejected);
    try testing.expect(v.passed());
}

test "structure: a file that stops mid-record says so" {
    var rejects: Io.Writer.Allocating = .init(testing.allocator);
    defer rejects.deinit();
    var cut = try run("id,amount,status\n1,1.50,open\n2,3", &orders, .{}, &rejects);
    defer cut.deinit();
    try testing.expectEqual(@as(usize, 1), cut.structural.items.len);
    try testing.expectEqualDeep(Problem{ .cut_off = .{ .fields = 2, .width = 3 } }, cut.structural.items[0]);
    try testing.expectEqual(@as(u64, 1), cut.row_errors.get(.ragged));
    // Padding takes the row, but the file is still not all there.
    var padded = try run("id,amount,status\n1,1.50,open\n2,3", &orders, .{ .ragged = .pad }, &rejects);
    defer padded.deinit();
    try testing.expectEqual(@as(u64, 0), padded.rejected);
    try testing.expect(!padded.passed());
    var quoted = try run("id,amount,status\n1,1.50,\"op", &orders, .{}, &rejects);
    defer quoted.deinit();
    try testing.expectEqualDeep(@as(Problem, .cut_off_in_quote), quoted.structural.items[0]);
    // A whole last record with no line break is only that.
    var whole = try run("id,amount,status\n1,1.50,open", &orders, .{}, &rejects);
    defer whole.deinit();
    try testing.expectEqual(@as(usize, 0), whole.structural.items.len);
    try testing.expect(whole.passed());
    // A short row that ends its line is a ragged row, nothing more.
    var short = try run("id,amount,status\n1,1.50\n", &orders, .{}, &rejects);
    defer short.deinit();
    try testing.expectEqual(@as(usize, 0), short.structural.items.len);
}

test "structure: a missing column fails the file, an extra one only under --strict" {
    var rejects: Io.Writer.Allocating = .init(testing.allocator);
    defer rejects.deinit();
    var v = try run("id,status,note\n1,open,x\n", &orders, .{}, &rejects);
    defer v.deinit();
    try testing.expectEqual(@as(usize, 1), v.structural.items.len);
    try testing.expectEqualDeep(Problem{ .column_missing = .{ .column = "amount" } }, v.structural.items[0]);
    try testing.expect(v.extra_columns);
    try testing.expect(!v.passed());

    var ok = try run("id,amount,status,note\n1,2,open,x\n", &orders, .{}, &rejects);
    defer ok.deinit();
    try testing.expect(ok.passed());
    var strict = try run("id,amount,status,note\n1,2,open,x\n", &orders, .{ .strict = true }, &rejects);
    defer strict.deinit();
    try testing.expect(!strict.passed());
}

test "a header's blank and repeated names match the columnN infer gives them" {
    const s: Schema = .{ .columns = &.{
        .{ .name = "zv_id", .type = .int64 },
        .{ .name = "column2", .type = .string },
        .{ .name = "zv_vol", .type = .int64 },
        .{ .name = "column4", .type = .string },
    } };
    var rejects: Io.Writer.Allocating = .init(testing.allocator);
    defer rejects.deinit();
    var v = try run("zv_id,,zv_vol,ZV_ID\n1,a,2,b\n3,c,4,d\n", &s, .{}, &rejects);
    defer v.deinit();
    try testing.expect(v.passed());
    try testing.expectEqual(@as(u64, 2), v.rows);
}

test "blank names past the rows at a header's end are no columns" {
    const s: Schema = .{ .columns = &.{
        .{ .name = "zq_a", .type = .int64 },
        .{ .name = "zq_b", .type = .string },
    } };
    var v: Validator = try .init(testing.allocator, &s, .rfc4180, .{});
    defer v.deinit();
    const input = "zq_a,zq_b,\n";
    var p: reference.Parser = .init(input, .rfc4180, .{});
    var fields: std.ArrayList(Field) = .empty;
    defer fields.deinit(testing.allocator);
    _ = try p.next(testing.allocator, &fields);
    try v.columns(fields.items, 2, input, 0);
    try testing.expectEqual(@as(usize, 2), v.width);
    try testing.expectEqual(@as(usize, 0), v.structural.items.len);
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

fn initDeinit(gpa: Allocator, s: *const Schema) !void {
    var v: Validator = try .init(gpa, s, .rfc4180, .{});
    v.deinit();
}

test "init frees what it holds when an allocation fails" {
    const s: Schema = .{ .columns = &.{ .{ .name = "id", .type = .int64 }, .{ .name = "status", .type = .@"enum", .values = &.{ "open", "closed" } }, .{ .name = "day", .type = .date } } };
    try testing.checkAllAllocationFailures(testing.allocator, initDeinit, .{&s});
}
