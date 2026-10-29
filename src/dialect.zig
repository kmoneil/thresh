//! A delimited file's dialect: how its fields and records are separated and
//! quoted, and whether its first record is a header.
//!
//! The sniffer that settles one from a sample is milestone 4; until then
//! `sniff` answers RFC 4180 for every input.

const std = @import("std");
const Io = std.Io;

pub const Dialect = struct {
    delimiter: u8,
    /// Null when the file does not quote fields at all.
    quote: ?u8,
    escape: Escape,
    newline: Newline,
    header: bool,
    /// Opt-in: a record starting with this byte is skipped.
    comment: ?u8 = null,

    pub const Escape = enum { doubled, backslash };
    pub const Newline = enum { lf, crlf, cr };

    /// What thresh writes, and what RFC 4180 describes: commas, double
    /// quotes doubled inside quoted fields, LF records.
    pub const rfc4180: Dialect = .{
        .delimiter = ',',
        .quote = '"',
        .escape = .doubled,
        .newline = .lf,
        .header = false,
    };

    /// The dialect as one line of `name=value` pairs, bytes written the
    /// way `--delimiter` and `--quote` take them back.
    pub fn format(d: Dialect, w: *Io.Writer) Io.Writer.Error!void {
        try w.writeAll("delimiter=");
        try writeByte(w, d.delimiter);
        try w.writeAll(" quote=");
        if (d.quote) |q| try writeByte(w, q) else try w.writeAll("none");
        try w.print(" escape={t} newline={t} header={s}", .{
            d.escape,
            d.newline,
            if (d.header) "yes" else "no",
        });
        if (d.comment) |c| {
            try w.writeAll(" comment=");
            try writeByte(w, c);
        }
    }

    /// The dialect as a JSON object, the shape the report's `dialect` takes.
    pub fn jsonStringify(d: Dialect, s: *std.json.Stringify) std.json.Stringify.Error!void {
        try s.beginObject();
        try s.objectField("delimiter");
        try s.write(@as([]const u8, &.{d.delimiter}));
        try s.objectField("quote");
        if (d.quote) |q| try s.write(@as([]const u8, &.{q})) else try s.write(null);
        try s.objectField("escape");
        try s.write(@tagName(d.escape));
        try s.objectField("newline");
        try s.write(@tagName(d.newline));
        try s.objectField("header");
        try s.write(d.header);
        if (d.comment) |c| {
            try s.objectField("comment");
            try s.write(@as([]const u8, &.{c}));
        }
        try s.endObject();
    }
};

/// A byte as `--delimiter` reads it back: itself when printable, `\t` for a
/// tab, `\xHH` otherwise (space is printable, so `--delimiter ' '`).
fn writeByte(w: *Io.Writer, c: u8) Io.Writer.Error!void {
    switch (c) {
        '\t' => try w.writeAll("\\t"),
        ' '...'~' => try w.writeByte(c),
        else => try w.print("\\x{x:0>2}", .{c}),
    }
}

/// The dialect of a sample. A stub until milestone 4: RFC 4180, with no
/// header, for anything.
pub fn sniff(sample: []const u8) Dialect {
    _ = sample;
    return .rfc4180;
}

test "format writes each dimension" {
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try w.print("{f}", .{Dialect.rfc4180});
    try std.testing.expectEqualStrings(
        "delimiter=, quote=\" escape=doubled newline=lf header=no",
        w.buffered(),
    );
}

test "format writes unprintable bytes the way --delimiter takes them" {
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const d: Dialect = .{
        .delimiter = 0x1f,
        .quote = null,
        .escape = .doubled,
        .newline = .crlf,
        .header = true,
        .comment = '\t',
    };
    try w.print("{f}", .{d});
    try std.testing.expectEqualStrings(
        "delimiter=\\x1f quote=none escape=doubled newline=crlf header=yes comment=\\t",
        w.buffered(),
    );
}

test "jsonStringify matches the report's dialect object" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var d = Dialect.rfc4180;
    d.delimiter = '|';
    d.quote = null;
    try std.json.Stringify.value(d, .{}, &w);
    try std.testing.expectEqualStrings(
        \\{"delimiter":"|","quote":null,"escape":"doubled","newline":"lf","header":false}
    , w.buffered());
}
