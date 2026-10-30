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
