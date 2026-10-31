//! The scalar reference parser: byte at a time, quote-aware, and the
//! definition of what a record is. The SIMD scanner (milestone 3) must
//! find exactly the fields this does, on every input; the two are
//! differentially tested and fuzzed.
//!
//! The rules, from the spec's edge-case table:
//!
//! - A field is quoted only when its first byte is the quote character.
//!   Anywhere else a quote character is data, counted in stray_quotes.
//! - Inside quotes, a doubled quote is one quote; under backslash escaping
//!   a backslash takes the next byte as data too (and a doubled quote
//!   still counts, as Python's csv reads it). Delimiters and line breaks
//!   inside quotes are data.
//! - After a closing quote comes a delimiter, a line break or the end;
//!   anything else is bad_quote, and the field runs on as data to the next
//!   delimiter or line break.
//! - A quoted field still open at the end of the input is
//!   unterminated_quote, and holds the rest of the input.
//! - LF, CRLF and a lone CR outside quotes each end a record, whatever the
//!   dialect; one that is not the dialect's sets foreign_newline.
//! - An empty line is skipped, or with keep_empty is a record of one empty
//!   field. A last line with no line break is a record.
//! - With a comment byte, a line starting with it is skipped whole.
//! - NUL and every other byte is data.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Dialect = @import("dialect.zig").Dialect;
const records = @import("records.zig");
const Field = records.Field;
const Record = records.Record;

pub const Options = struct {
    /// Where the first record starts: 3 past a UTF-8 BOM.
    start: usize = 0,
    keep_empty: bool = false,
    /// Longer fields are field_too_long.
    max_field_len: u32 = std.math.maxInt(u32),
};

pub const Parser = struct {
    input: []const u8,
    dialect: Dialect,
    options: Options,
    pos: usize,
    line: u64 = 1,

    pub fn init(input: []const u8, dialect: Dialect, options: Options) Parser {
        return .{ .input = input, .dialect = dialect, .options = options, .pos = options.start };
    }

    /// The next record, its fields in fields (emptied first), or null at
    /// the end of the input.
    pub fn next(p: *Parser, gpa: Allocator, fields: *std.ArrayList(Field)) Allocator.Error!?Record {
        fields.clearRetainingCapacity();
        const in = p.input;
        while (true) {
            if (p.pos >= in.len) return null;
            const c = in[p.pos];
            if ((c == '\n' or c == '\r') and !p.options.keep_empty) {
                _ = p.lineBreak();
                continue;
            }
            if (p.dialect.comment) |cc| if (c == cc) {
                while (p.pos < in.len and in[p.pos] != '\n' and in[p.pos] != '\r') p.pos += 1;
                if (p.pos < in.len) _ = p.lineBreak();
                continue;
            };
            break;
        }
        var rec: Record = .{ .start = p.pos, .end = undefined, .line = p.line };
        // The line break that ends it, which is not inside it.
        var ended: u64 = 0;
        while (true) {
            try fields.append(gpa, p.field(&rec));
            if (p.pos >= in.len) break;
            if (in[p.pos] == p.dialect.delimiter) {
                p.pos += 1;
                continue;
            }
            if (p.lineBreak() != p.dialect.newline) rec.foreign_newline = true;
            ended = 1;
            break;
        }
        rec.end = p.pos;
        rec.inner_lines = p.line - rec.line - ended;
        return rec;
    }

    /// Steps over the line break at pos and counts it.
    fn lineBreak(p: *Parser) Dialect.Newline {
        const in = p.input;
        p.line += 1;
        if (in[p.pos] == '\n') {
            p.pos += 1;
            return .lf;
        }
        if (p.pos + 1 < in.len and in[p.pos + 1] == '\n') {
            p.pos += 2;
            return .crlf;
        }
        p.pos += 1;
        return .cr;
    }

    /// The field at pos, leaving pos on the delimiter or line break after
    /// it, or at the end.
    fn field(p: *Parser, rec: *Record) Field {
        const in = p.input;
        const d = p.dialect;
        if (d.quote) |q| if (p.pos < in.len and in[p.pos] == q) return p.quoted(rec, q);
        const start = p.pos;
        while (p.pos < in.len) : (p.pos += 1) {
            const c = in[p.pos];
            if (c == d.delimiter or c == '\n' or c == '\r') break;
            if (c == d.quote) rec.stray_quotes +|= 1;
        }
        return p.made(rec, start, .{});
    }

    fn quoted(p: *Parser, rec: *Record, q: u8) Field {
        const in = p.input;
        const d = p.dialect;
        p.pos += 1;
        const start = p.pos;
        var flags: Field.Flags = .{ .quoted = true };
        while (p.pos < in.len) {
            const c = in[p.pos];
            if (c == '\\' and d.escape == .backslash) {
                flags.needs_unescape = true;
                p.pos += 1;
                if (p.pos == in.len) break;
                p.countBreakInside();
                p.pos += 1;
                continue;
            }
            if (c != q) {
                p.countBreakInside();
                p.pos += 1;
                continue;
            }
            if (p.pos + 1 < in.len and in[p.pos + 1] == q) {
                flags.needs_unescape = true;
                p.pos += 2;
                continue;
            }
            const f = p.made(rec, start, flags);
            p.pos += 1;
            if (p.pos == in.len or p.atBoundary()) return f;
            rec.problem = rec.problem orelse .bad_quote;
            while (p.pos < in.len and !p.atBoundary()) p.pos += 1;
            return p.made(rec, start, flags);
        }
        rec.problem = rec.problem orelse .unterminated_quote;
        return p.made(rec, start, flags);
    }

    /// Counts a line break inside quotes: LF, and CR unless LF follows.
    fn countBreakInside(p: *Parser) void {
        const in = p.input;
        switch (in[p.pos]) {
            '\n' => p.line += 1,
            '\r' => if (p.pos + 1 == in.len or in[p.pos + 1] != '\n') {
                p.line += 1;
            },
            else => {},
        }
    }

    fn atBoundary(p: *const Parser) bool {
        const c = p.input[p.pos];
        return c == p.dialect.delimiter or c == '\n' or c == '\r';
    }

    /// The field from start to pos.
    fn made(p: *const Parser, rec: *Record, start: usize, flags: Field.Flags) Field {
        const len = p.pos - start;
        if (len > p.options.max_field_len) rec.problem = rec.problem orelse .field_too_long;
        return .{ .start = start, .len = @intCast(@min(len, p.options.max_field_len)), .flags = flags };
    }
};

const testing = std.testing;

/// The records of input as text: fields joined by '|', a quoted field in
/// «», each record on its line with its marks after a space: !problem,
/// ~strays, %foreign newline, @line when it is not the record's index + 1.
fn render(input: []const u8, d: Dialect, options: Options) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    const w = &out.writer;
    var fields: std.ArrayList(Field) = .empty;
    defer fields.deinit(testing.allocator);
    var scratch: [256]u8 = undefined;
    var p: Parser = .init(input, d, options);
    var index: u64 = 0;
    while (try p.next(testing.allocator, &fields)) |rec| : (index += 1) {
        for (fields.items, 0..) |f, i| {
            if (i > 0) try w.writeByte('|');
            const v = f.value(input, d, &scratch);
            if (f.flags.quoted) try w.print("«{s}»", .{v}) else try w.writeAll(v);
        }
        if (rec.problem) |pr| try w.print(" !{t}", .{pr});
        if (rec.stray_quotes > 0) try w.print(" ~{d}", .{rec.stray_quotes});
        if (rec.foreign_newline) try w.writeAll(" %");
        if (rec.line != index + 1) try w.print(" @{d}", .{rec.line});
        try w.writeByte('\n');
    }
    return out.toOwnedSlice();
}

fn expectRecords(input: []const u8, d: Dialect, options: Options, want: []const u8) !void {
    const got = try render(input, d, options);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

const csv = Dialect.rfc4180;

test "plain records" {
    try expectRecords("a,b\nc,d\n", csv, .{}, "a|b\nc|d\n");
    try expectRecords("", csv, .{}, "");
    try expectRecords("\n\n", csv, .{}, "");
    try expectRecords("a,\n,b\n,\n", csv, .{}, "a|\n|b\n|\n");
}

test "a line break inside quotes is data, and still a line" {
    try expectRecords("\"a\r\nb\",c\r\nd,e\r\n", .{ .delimiter = ',', .quote = '"', .escape = .doubled, .newline = .crlf, .header = false }, .{}, "«a\r\nb»|c\nd|e @3\n");
    try expectRecords("\"a\rb\",c\nd\n", csv, .{}, "«a\rb»|c\nd @3\n");
    try expectRecords("\"a\nb\nc\"\nd\n", csv, .{}, "«a\nb\nc»\nd @4\n");
}

test "a lone CR ends a record, a warning unless the dialect says cr" {
    var cr = csv;
    cr.newline = .cr;
    try expectRecords("a,b\rc,d\r", cr, .{}, "a|b\nc|d\n");
    try expectRecords("a,b\rc,d\n", csv, .{}, "a|b %\nc|d\n");
    try expectRecords("a\r\nb\n", csv, .{}, "a %\nb\n");
}

test "a last line without a line break" {
    try expectRecords("a,b\nc,d", csv, .{}, "a|b\nc|d\n");
    try expectRecords("a,\"b\"", csv, .{}, "a|«b»\n");
}

test "empty lines are skipped, or one empty field with keep_empty" {
    try expectRecords("a\n\nb\n", csv, .{}, "a\nb @3\n");
    try expectRecords("a\r\n\r\nb\r\n", csv, .{}, "a %\nb % @3\n");
    try expectRecords("a\n\nb\n", csv, .{ .keep_empty = true }, "a\n\nb\n");
}

test "ragged rows are records like any other" {
    try expectRecords("a,b,c\nd\ne,f,g,h\n", csv, .{}, "a|b|c\nd\ne|f|g|h\n");
}

test "a quote inside an unquoted field is data" {
    try expectRecords("ab\"c,d\n5'11\",x\n", csv, .{}, "ab\"c|d ~1\n5'11\"|x ~1\n");
    try expectRecords(" \"a,b\"\n", csv, .{}, " \"a|b\" ~2\n");
}

test "an unterminated quote holds the rest of the input" {
    try expectRecords("a,\"bc\nd,e", csv, .{}, "a|«bc\nd,e» !unterminated_quote\n");
    try expectRecords("x\n\"", csv, .{}, "x\n«» !unterminated_quote\n");
}

test "anything after a closing quote but a boundary is bad_quote" {
    try expectRecords("\"ab\"c,d\ne,f\n", csv, .{}, "«ab\"c»|d !bad_quote\ne|f\n");
    try expectRecords("\"a\" ,b\n", csv, .{}, "«a\" »|b !bad_quote\n");
}

test "doubled quotes" {
    try expectRecords("\"a\"\"b\",c\n\"\",\"\"\"\"\n", csv, .{}, "«a\"b»|c\n«»|«\"»\n");
}

test "backslash escapes, and doubled quotes under them" {
    var bs = csv;
    bs.escape = .backslash;
    try expectRecords("\"a\\\"b\\\\c\",d\n", bs, .{}, "«a\"b\\c»|d\n");
    try expectRecords("\"a\"\"b\"\n", bs, .{}, "«a\"b»\n");
    try expectRecords("\"a\\\n\",b\n", bs, .{}, "«a\n»|b\n");
    try expectRecords("\"ab\\", bs, .{}, "«ab\\» !unterminated_quote\n");
    // Outside quotes a backslash is data.
    try expectRecords("a\\,b\n", bs, .{}, "a\\|b\n");
}

test "single quotes, and no quoting at all" {
    var sq = csv;
    sq.quote = '\'';
    try expectRecords("'a,b','it''s',\"x\"\n", sq, .{}, "«a,b»|«it's»|\"x\"\n");
    var none = csv;
    none.quote = null;
    try expectRecords("\"a,b\"\n", none, .{}, "\"a|b\"\n");
}

test "NUL and other bytes are data" {
    try expectRecords("a\x00b,\xff\n", csv, .{}, "a\x00b|\xff\n");
}

test "comment lines are skipped whole, quotes and all" {
    var c = csv;
    c.comment = '#';
    try expectRecords("#x,\"y\na,b\n# z\nc\n", c, .{}, "a|b @2\nc @4\n");
    try expectRecords("a,#b\n", c, .{}, "a|#b\n");
}

test "a field over the limit" {
    try expectRecords("abcd,e\nab,c\n", csv, .{ .max_field_len = 3 }, "abc|e !field_too_long\nab|c\n");
}

test "start skips a BOM, and offsets stay the input's" {
    const input = "\xef\xbb\xbfa,\"b\"\n";
    var fields: std.ArrayList(Field) = .empty;
    defer fields.deinit(testing.allocator);
    var p: Parser = .init(input, csv, .{ .start = 3 });
    const rec = (try p.next(testing.allocator, &fields)).?;
    try testing.expectEqual(@as(u64, 3), rec.start);
    try testing.expectEqual(@as(u64, input.len), rec.end);
    try testing.expectEqual(@as(u64, 3), fields.items[0].start);
    try testing.expectEqual(@as(u64, 6), fields.items[1].start);
    try testing.expectEqual(@as(u32, 1), fields.items[1].len);
    try testing.expect(fields.items[1].flags.quoted);
    try testing.expect(!fields.items[1].flags.needs_unescape);
    try testing.expectEqual(@as(?records.Record, null), try p.next(testing.allocator, &fields));
}
