//! RFC 4180 output: comma, double quote, doubled-quote escaping, LF. A
//! field is quoted only when it holds the delimiter, the quote or a line
//! break; a null is empty.

const std = @import("std");
const Io = std.Io;
const Newline = @import("../dialect.zig").Dialect.Newline;

pub const Options = struct {
    delimiter: u8 = ',',
    newline: Newline = .lf,
};

const quote = '"';

/// One field's value, quoted and escaped when it needs to be.
pub fn field(w: *Io.Writer, v: []const u8, o: Options) Io.Writer.Error!void {
    if (!needsQuotes(v, o.delimiter)) return w.writeAll(v);
    try w.writeByte(quote);
    var rest = v;
    while (std.mem.findScalar(u8, rest, quote)) |i| {
        try w.writeAll(rest[0 .. i + 1]);
        try w.writeByte(quote);
        rest = rest[i + 1 ..];
    }
    try w.writeAll(rest);
    try w.writeByte(quote);
}

pub fn needsQuotes(v: []const u8, delim: u8) bool {
    for (v) |c| {
        if (c == delim or c == quote or c == '\n' or c == '\r') return true;
    }
    return false;
}

pub fn delimiter(w: *Io.Writer, o: Options) Io.Writer.Error!void {
    try w.writeByte(o.delimiter);
}

pub fn endRecord(w: *Io.Writer, o: Options) Io.Writer.Error!void {
    try w.writeAll(switch (o.newline) {
        .lf => "\n",
        .crlf => "\r\n",
        .cr => "\r",
    });
}

/// A record of values, each as field writes it.
pub fn record(w: *Io.Writer, values: []const []const u8, o: Options) Io.Writer.Error!void {
    for (values, 0..) |v, i| {
        if (i > 0) try delimiter(w, o);
        try field(w, v, o);
    }
    try endRecord(w, o);
}

test record {
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try record(&w, &.{ "a", "b,c", "say \"hi\"", "x\ny", "" }, .{});
    try std.testing.expectEqualStrings("a,\"b,c\",\"say \"\"hi\"\"\",\"x\ny\",\n", w.buffered());
    w = .fixed(&buf);
    try record(&w, &.{ "a,b", "c|d" }, .{ .delimiter = '|', .newline = .crlf });
    try std.testing.expectEqualStrings("a,b|\"c|d\"\r\n", w.buffered());
}

const builders = @import("../builders.zig");
const schema = @import("../schema.zig");
const date = @import("../types/date.zig");

/// The CSV writer: a header, then each batch's rows in the schema's column
/// order. Values are written as read, except that strings are UTF-8 (a
/// Latin-1 file transcoded) and, with normalize_dates, dates and
/// timestamps are RFC 3339 (timestamps in UTC).
pub const Writer = struct {
    options: Options,
    normalize_dates: bool = false,

    pub fn header(w: *Writer, out: *Io.Writer, names: []const []const u8) Io.Writer.Error!void {
        try record(out, names, w.options);
    }

    pub fn batch(w: *Writer, out: *Io.Writer, b: *const builders.Batch) Io.Writer.Error!void {
        var buf: [64]u8 = undefined;
        for (0..b.rows) |row| {
            for (b.columns, 0..) |*c, i| {
                if (i > 0) try delimiter(out, w.options);
                if (!c.valid.items[row]) continue;
                if (w.normalize_dates and (c.type == .date or c.type == .timestamp)) {
                    const v: i64 = if (c.type == .date) c.days.items[row] else c.ints.items[row];
                    try field(out, rfc3339(&buf, c.type, v), w.options);
                    continue;
                }
                try field(out, c.text(row), w.options);
            }
            try endRecord(out, w.options);
        }
    }
};

/// A date (days) as YYYY-MM-DD, a timestamp (microseconds) as
/// YYYY-MM-DDTHH:MM:SS[.ffffff]Z.
fn rfc3339(buf: []u8, t: schema.Type, n: i64) []const u8 {
    var w: Io.Writer = .fixed(buf);
    if (t == .date) {
        const d = date.civil(n);
        w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u32, @intCast(@max(d.year, 0))), d.month, d.day }) catch unreachable;
        return w.buffered();
    }
    const secs = @divFloor(n, 1_000_000);
    const frac: u32 = @intCast(@mod(n, 1_000_000));
    const d = date.civil(@divFloor(secs, 86_400));
    const sod: u32 = @intCast(@mod(secs, 86_400));
    w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        @as(u32, @intCast(@max(d.year, 0))), d.month, d.day, sod / 3600, sod % 3600 / 60, sod % 60,
    }) catch unreachable;
    if (frac != 0) w.print(".{d:0>6}", .{frac}) catch unreachable;
    w.writeByte('Z') catch unreachable;
    return w.buffered();
}

test "batches as RFC 4180, dates normalized when asked" {
    const s: schema.Schema = .{ .columns = &.{
        .{ .name = "id", .type = .int64 },
        .{ .name = "at", .type = .timestamp },
        .{ .name = "day", .type = .date },
        .{ .name = "note", .type = .string },
    } };
    var b: builders.Batch = try .init(std.testing.allocator, &s, .utf8);
    defer b.deinit();
    try b.append(&.{ "1", "2024-03-15 10:20:30", "15/03/2024", "a, \"b\"" }, &.{ .{ .int = 1 }, .{ .timestamp = 1710498030_000_000 }, .{ .date = 19797 }, .{ .string = "a, \"b\"" } });
    try b.append(&.{ "", "", "", "" }, &.{ null, null, null, null });
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var w: Writer = .{ .options = .{} };
    try w.header(&out.writer, &.{ "id", "at", "day", "note" });
    try w.batch(&out.writer, &b);
    try std.testing.expectEqualStrings("id,at,day,note\n1,2024-03-15 10:20:30,15/03/2024,\"a, \"\"b\"\"\"\n,,,\n", out.written());
    out.clearRetainingCapacity();
    w.normalize_dates = true;
    try w.batch(&out.writer, &b);
    try std.testing.expectEqualStrings("1,2024-03-15T10:20:30Z,2024-03-15,\"a, \"\"b\"\"\"\n,,,\n", out.written());
}
