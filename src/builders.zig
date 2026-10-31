//! Typed column builders: a batch of accepted rows as columns, which every
//! writer reads, so adding a format never touches parsing or validation.
//! A batch is reset after the writers have it; the builders keep their
//! memory, so they only grow on the first file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const schema = @import("schema.zig");
const types = @import("types.zig");
const Value = types.Value;

pub const Column = struct {
    type: schema.Type,
    utf8: schema.Utf8Policy,
    /// One a row: false for a null.
    valid: std.ArrayList(bool) = .empty,
    /// int64, time (us), timestamp (us).
    ints: std.ArrayList(i64) = .empty,
    /// date: days since 1970-01-01, as Arrow's date32 holds them.
    days: std.ArrayList(i32) = .empty,
    floats: std.ArrayList(f64) = .empty,
    decimals: std.ArrayList(i128) = .empty,
    bools: std.ArrayList(bool) = .empty,
    /// enum: the value's index.
    indices: std.ArrayList(u32) = .empty,
    /// string and binary: row i is bytes[offsets[i]..offsets[i + 1]], in
    /// UTF-8 (transcoded from Latin-1, or with U+FFFD for invalid bytes
    /// under utf8: replace). Every other type: its text as read, for the
    /// CSV writer.
    offsets: std.ArrayList(u64) = .empty,
    bytes: std.ArrayList(u8) = .empty,

    const lists = .{ "valid", "ints", "days", "floats", "decimals", "bools", "indices", "offsets", "bytes" };

    fn deinit(c: *Column, gpa: Allocator) void {
        inline for (lists) |f| @field(c, f).deinit(gpa);
    }

    fn clear(c: *Column) void {
        inline for (lists) |f| @field(c, f).clearRetainingCapacity();
    }

    /// Row i's bytes: its string or binary value, or its text as read.
    pub fn text(c: *const Column, i: usize) []const u8 {
        return c.bytes.items[@intCast(c.offsets.items[i])..@intCast(c.offsets.items[i + 1])];
    }
};

pub const Batch = struct {
    gpa: Allocator,
    encoding: types.Encoding,
    columns: []Column,
    rows: usize = 0,

    pub fn init(gpa: Allocator, s: *const schema.Schema, encoding: types.Encoding) Allocator.Error!Batch {
        const columns = try gpa.alloc(Column, s.columns.len);
        for (columns, s.columns) |*c, sc| c.* = .{ .type = sc.type, .utf8 = sc.utf8 };
        var b: Batch = .{ .gpa = gpa, .encoding = encoding, .columns = columns };
        errdefer b.deinit();
        // Room for each column's first offset, which reset puts back.
        for (columns) |*c| try c.offsets.ensureTotalCapacity(gpa, 1);
        b.reset();
        return b;
    }

    pub fn deinit(b: *Batch) void {
        for (b.columns) |*c| c.deinit(b.gpa);
        b.gpa.free(b.columns);
    }

    pub fn reset(b: *Batch) void {
        b.rows = 0;
        for (b.columns) |*c| {
            c.clear();
            c.offsets.appendAssumeCapacity(0);
        }
    }

    /// Adds a row: raw is each column's text as read, cells its value or
    /// null.
    pub fn append(b: *Batch, raw: []const []const u8, cells: []const ?Value) Allocator.Error!void {
        const gpa = b.gpa;
        for (b.columns, raw, cells) |*c, text, cell| {
            try c.valid.append(gpa, cell != null);
            const v = cell orelse {
                try pushDefault(gpa, c);
                try c.offsets.append(gpa, c.bytes.items.len);
                continue;
            };
            switch (v) {
                .int, .time, .timestamp => |n| try c.ints.append(gpa, n),
                .date => |d| try c.days.append(gpa, d),
                .float => |f| try c.floats.append(gpa, f),
                .decimal => |d| try c.decimals.append(gpa, d),
                .bool => |x| try c.bools.append(gpa, x),
                .enumeration => |i| try c.indices.append(gpa, i),
                .string => |s| try appendUtf8(gpa, &c.bytes, s, b.encoding, c.utf8 == .replace),
                .binary => |s| try c.bytes.appendSlice(gpa, s),
            }
            if (v != .string and v != .binary) try c.bytes.appendSlice(gpa, text);
            try c.offsets.append(gpa, c.bytes.items.len);
        }
        b.rows += 1;
    }
};

/// s's bytes as UTF-8 onto out: Latin-1 or Windows-1252 transcoded,
/// invalid UTF-8 replaced with U+FFFD when replace is set, else kept.
fn appendUtf8(gpa: Allocator, out: *std.ArrayList(u8), s: []const u8, encoding: types.Encoding, replace: bool) Allocator.Error!void {
    if (encoding != .utf8) {
        for (s) |ch| {
            if (ch < 0x80) {
                try out.append(gpa, ch);
                continue;
            }
            var buf: [3]u8 = undefined;
            const n = std.unicode.utf8Encode(types.codepoint(encoding, ch), &buf) catch unreachable;
            try out.appendSlice(gpa, buf[0..n]);
        }
        return;
    }
    if (!replace or types.utf8.valid(s)) return out.appendSlice(gpa, s);
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 0;
        if (len > 0 and i + len <= s.len) {
            if (std.unicode.utf8Decode(s[i..][0..len])) |_| {
                try out.appendSlice(gpa, s[i..][0..len]);
                i += len;
                continue;
            } else |_| {}
        }
        try out.appendSlice(gpa, "\xef\xbf\xbd");
        i += 1;
    }
}

/// A column of UTF-8 text, a value or a null a row: row i is
/// bytes[offsets[i]..offsets[i + 1]]. offsets is empty until the first row.
pub const Text = struct {
    valid: std.ArrayList(bool) = .empty,
    offsets: std.ArrayList(u64) = .empty,
    bytes: std.ArrayList(u8) = .empty,

    const lists = .{ "valid", "offsets", "bytes" };

    fn deinit(t: *Text, gpa: Allocator) void {
        inline for (lists) |f| @field(t, f).deinit(gpa);
    }

    fn clear(t: *Text) void {
        inline for (lists) |f| @field(t, f).clearRetainingCapacity();
    }

    /// value as UTF-8 (transcoded from encoding, invalid bytes replaced),
    /// or a null.
    fn append(t: *Text, gpa: Allocator, value: ?[]const u8, encoding: types.Encoding) Allocator.Error!void {
        if (t.offsets.items.len == 0) try t.offsets.append(gpa, 0);
        try t.valid.append(gpa, value != null);
        if (value) |s| try appendUtf8(gpa, &t.bytes, s, encoding, true);
        try t.offsets.append(gpa, t.bytes.items.len);
    }

    /// Row i's text; "" for a null.
    pub fn at(t: *const Text, i: usize) []const u8 {
        return t.bytes.items[@intCast(t.offsets.items[i])..@intCast(t.offsets.items[i + 1])];
    }
};

/// One thing wrong with a rejected row: the schema column it is in, or
/// null for the whole row, and why.
pub const RowError = struct { column: ?[]const u8, reason: types.Reason };

/// A batch of rejected rows, as the reject file has them: each of the
/// file's fields as text (null where a short row has none), the line the
/// row starts on, its errors, and a wide row's fields past the header
/// (null for any other row). A row is added a field at a time (begin,
/// field, end), since each value is read into the same scratch.
pub const Rejects = struct {
    gpa: Allocator,
    encoding: types.Encoding,
    /// One a field of the header's width, made at the first row.
    fields: []Text = &.{},
    rows: usize = 0,
    lines: std.ArrayList(i64) = .empty,
    /// Row i's errors are those from error_offsets[i] to [i + 1]: each
    /// error's column (null for the whole row) and its reason's code.
    error_offsets: std.ArrayList(u64) = .empty,
    error_columns: Text = .{},
    error_codes: Text = .{},
    extra: Text = .{},

    pub fn init(gpa: Allocator, encoding: types.Encoding) Rejects {
        return .{ .gpa = gpa, .encoding = encoding };
    }

    pub fn deinit(r: *Rejects) void {
        for (r.fields) |*t| t.deinit(r.gpa);
        r.gpa.free(r.fields);
        r.lines.deinit(r.gpa);
        r.error_offsets.deinit(r.gpa);
        inline for (.{ "error_columns", "error_codes", "extra" }) |f| @field(r, f).deinit(r.gpa);
    }

    pub fn reset(r: *Rejects) void {
        r.rows = 0;
        for (r.fields) |*t| t.clear();
        r.lines.clearRetainingCapacity();
        r.error_offsets.clearRetainingCapacity();
        inline for (.{ "error_columns", "error_codes", "extra" }) |f| @field(r, f).clear();
    }

    /// Starts a row of width fields: the same width every row.
    pub fn begin(r: *Rejects, width: usize) Allocator.Error!void {
        if (r.fields.len == width) return;
        std.debug.assert(r.fields.len == 0);
        r.fields = try r.gpa.alloc(Text, width);
        @memset(r.fields, .{});
    }

    /// Field i of the row, or null where the row has none.
    pub fn field(r: *Rejects, i: usize, value: ?[]const u8) Allocator.Error!void {
        try r.fields[i].append(r.gpa, value, r.encoding);
    }

    /// Ends the row: its line, what was wrong, and a wide row's fields
    /// past the header.
    pub fn end(r: *Rejects, line: u64, errors: []const RowError, extra: ?[]const u8) Allocator.Error!void {
        const gpa = r.gpa;
        try r.lines.append(gpa, @intCast(line));
        if (r.error_offsets.items.len == 0) try r.error_offsets.append(gpa, 0);
        for (errors) |e| {
            try r.error_columns.append(gpa, e.column, .utf8);
            try r.error_codes.append(gpa, @tagName(e.reason), .utf8);
        }
        try r.error_offsets.append(gpa, r.error_codes.valid.items.len);
        try r.extra.append(gpa, extra, r.encoding);
        r.rows += 1;
    }
};

fn pushDefault(gpa: Allocator, c: *Column) Allocator.Error!void {
    switch (c.type) {
        .int64, .time, .timestamp => try c.ints.append(gpa, 0),
        .date => try c.days.append(gpa, 0),
        .float64 => try c.floats.append(gpa, 0),
        .decimal => try c.decimals.append(gpa, 0),
        .bool => try c.bools.append(gpa, false),
        .@"enum" => try c.indices.append(gpa, 0),
        .string, .binary => {},
    }
}

const testing = std.testing;

test "a batch keeps typed values, text and nulls" {
    const s: schema.Schema = .{ .columns = &.{
        .{ .name = "id", .type = .int64 },
        .{ .name = "name", .type = .string, .utf8 = .replace },
    } };
    var b: Batch = try .init(testing.allocator, &s, .utf8);
    defer b.deinit();
    try b.append(&.{ "7", "caf\xe9" }, &.{ .{ .int = 7 }, .{ .string = "caf\xe9" } });
    try b.append(&.{ "", "ok" }, &.{ null, .{ .string = "ok" } });
    try testing.expectEqual(@as(usize, 2), b.rows);
    try testing.expectEqualSlices(i64, &.{ 7, 0 }, b.columns[0].ints.items);
    try testing.expectEqualSlices(bool, &.{ true, false }, b.columns[0].valid.items);
    try testing.expectEqualStrings("7", b.columns[0].text(0));
    try testing.expectEqualStrings("caf\u{fffd}", b.columns[1].text(0));
    b.reset();
    try testing.expectEqual(@as(usize, 0), b.rows);
    try b.append(&.{ "1", "x" }, &.{ .{ .int = 1 }, .{ .string = "x" } });
    try testing.expectEqualStrings("x", b.columns[1].text(0));
}

test "Latin-1 strings are transcoded" {
    const s: schema.Schema = .{ .columns = &.{.{ .name = "n", .type = .string }} };
    var b: Batch = try .init(testing.allocator, &s, .latin1);
    defer b.deinit();
    try b.append(&.{"caf\xe9"}, &.{.{ .string = "caf\xe9" }});
    try testing.expectEqualStrings("café", b.columns[0].text(0));
}

test "Windows-1252 strings are transcoded, its punctuation too" {
    const s: schema.Schema = .{ .columns = &.{.{ .name = "n", .type = .string }} };
    var b: Batch = try .init(testing.allocator, &s, .cp1252);
    defer b.deinit();
    try b.append(&.{"l\x92\x9cuvre \x80"}, &.{.{ .string = "l\x92\x9cuvre \x80" }});
    try testing.expectEqualStrings("l\u{2019}\u{153}uvre \u{20ac}", b.columns[0].text(0));
}

fn batchInitDeinit(gpa: Allocator, s: *const schema.Schema) !void {
    var b: Batch = try .init(gpa, s, .utf8);
    b.deinit();
}

test "init frees what it holds when an allocation fails" {
    const s: schema.Schema = .{ .columns = &.{
        .{ .name = "id", .type = .int64 },
        .{ .name = "name", .type = .string },
        .{ .name = "day", .type = .date },
    } };
    try testing.checkAllAllocationFailures(testing.allocator, batchInitDeinit, .{&s});
}
