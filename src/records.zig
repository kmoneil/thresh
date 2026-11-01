//! Records and fields as the parsers emit them: byte ranges into the input
//! with flags, never copies. A field's value is materialized only when
//! something needs it, and only a field with an escape in it is copied.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Dialect = @import("dialect.zig").Dialect;
const reference = @import("reference.zig");
const scan = @import("scan.zig");

/// One field: where its content is in the input, 16 bytes.
pub const Field = struct {
    /// Offset of the content, inside the quotes for a quoted field.
    start: u64,
    /// Length of the content, escapes not yet undone.
    len: u32,
    flags: Flags = .{},

    pub const Flags = packed struct(u32) {
        quoted: bool = false,
        /// The content holds an escaped quote or backslash to undo.
        needs_unescape: bool = false,
        _: u30 = 0,
    };

    pub fn raw(f: Field, input: []const u8) []const u8 {
        return input[@intCast(f.start)..][0..f.len];
    }

    /// The field's value: its bytes when there is nothing to undo, and
    /// otherwise the bytes with their escapes undone, written into scratch,
    /// which must hold `f.len` bytes.
    pub fn value(f: Field, input: []const u8, d: Dialect, scratch: []u8) []const u8 {
        const bytes = f.raw(input);
        if (!f.flags.needs_unescape) return bytes;
        return unescape(bytes, d, scratch);
    }
};

comptime {
    std.debug.assert(@sizeOf(Field) == 16);
}

/// Why a record is rejected before any column sees it.
pub const Problem = enum {
    /// A quoted field still open at the end of the input.
    unterminated_quote,
    /// Something other than a delimiter or line break after a closing quote.
    bad_quote,
    /// A field longer than the parser takes (4 GiB by default).
    field_too_long,
};

/// One record: its byte range, where it starts in the source, and what
/// was wrong or unusual about it. The fields are the parser's to hand out.
pub const Record = struct {
    /// Offset of the record's first byte.
    start: u64,
    /// Offset just past its line break, or the end of the input.
    end: u64,
    /// The source line it starts on, from 1, counting line breaks inside
    /// quoted fields too, the way an editor numbers them.
    line: u64,
    /// Line breaks inside its quoted fields: the lines it spans, less one.
    inner_lines: u64 = 0,
    problem: ?Problem = null,
    /// Quote characters inside unquoted fields: data, and a warning.
    stray_quotes: u32 = 0,
    /// It ended in a line break other than the dialect's.
    foreign_newline: bool = false,
};

/// Whether a file's quotes are data, not quoting: `"` an inch mark in a
/// file that never quotes, say. A value that starts with one opens a quoted
/// field that runs on, over delimiters and line breaks, to the next value
/// that ends in one, and the lines between fold into one record, which is
/// as wide as a row often enough to pass. So each record that spans lines
/// is read again without quotes: lines that each split into a whole row are
/// rows folded together; any other is quoted text with line breaks in it,
/// which is what quoting is for. A record on one line is not looked at, so
/// a file with no line breaks inside quotes pays one comparison a record.
pub const QuoteCheck = struct {
    /// Records whose every line is a whole row without quotes, the lines
    /// they hold, and the line the first starts on.
    folded: u64 = 0,
    folded_lines: u64 = 0,
    first: u64 = 0,
    /// Records across lines that are not rows folded together.
    multiline: u64 = 0,

    /// rec, in data from base, in a file whose rows are width fields wide.
    pub fn record(c: *QuoteCheck, rec: Record, width: usize, d: Dialect, data: []const u8, base: u64) void {
        // One field a row: every line splits into a whole row.
        if (rec.inner_lines == 0 or width < 2) return;
        var rest = data[@intCast(rec.start - base)..@intCast(rec.end - base)];
        // Its own line break ends it and is not one of its lines.
        if (std.mem.endsWith(u8, rest, "\r\n")) {
            rest.len -= 2;
        } else if (rest.len > 0 and (rest[rest.len - 1] == '\n' or rest[rest.len - 1] == '\r')) rest.len -= 1;
        while (true) {
            const nl = std.mem.findAny(u8, rest, "\r\n");
            if (std.mem.countScalar(u8, rest[0 .. nl orelse rest.len], d.delimiter) != width - 1) {
                c.multiline += 1;
                return;
            }
            const n = nl orelse break;
            rest = rest[n + @as(usize, if (rest[n] == '\r' and n + 1 < rest.len and rest[n + 1] == '\n') 2 else 1) ..];
        }
        if (c.folded == 0) c.first = rec.line;
        c.folded += 1;
        c.folded_lines += rec.inner_lines + 1;
    }

    /// The quotes look like data: more records are rows folded together
    /// than quoted text across lines, in a file whose unquoted fields hold
    /// quotes too (stray_quotes), as a file that never quotes does.
    pub fn isData(c: QuoteCheck, stray_quotes: u64) bool {
        return c.folded > c.multiline and stray_quotes > 0;
    }

    /// The folded rows when the quotes look like data, or null.
    pub fn folding(c: QuoteCheck, stray_quotes: u64) ?Folded {
        if (!c.isData(stray_quotes)) return null;
        return .{ .records = c.folded, .lines = c.folded_lines, .line = c.first };
    }
};

/// Rows folded into records by quotes that are data: the records, the
/// lines they hold, and the line the first starts on.
pub const Folded = struct { records: u64, lines: u64, line: u64 };

test QuoteCheck {
    const d: Dialect = .{ .delimiter = '|', .quote = '"', .escape = .doubled, .newline = .crlf, .header = true };
    // Inch marks in a file that never quotes: the quote opened on line 2
    // closes on line 4, and lines 2 to 4 fold into one record of 3 fields.
    const data = "lug_id|bin|cultivar\r\n1|\"36|Starfall\r\n2|48 in|Quillon\r\n3|36\"|Brookwood\r\n4|36\" deep|Starfall\r\n";
    var p: reference.Parser = .init(data, d, .{});
    var fields: std.ArrayList(Field) = .empty;
    defer fields.deinit(std.testing.allocator);
    var c: QuoteCheck = .{};
    var stray: u64 = 0;
    var seen: usize = 0;
    while (try p.next(std.testing.allocator, &fields)) |rec| : (seen += 1) {
        c.record(rec, 3, d, data, 0);
        stray += rec.stray_quotes;
    }
    try std.testing.expectEqual(@as(usize, 3), seen);
    try std.testing.expectEqual(@as(u64, 1), c.folded);
    try std.testing.expectEqual(@as(u64, 3), c.folded_lines);
    try std.testing.expectEqual(@as(u64, 2), c.first);
    try std.testing.expect(c.isData(stray));

    // Quoted text with a line break in it, as quoting means: not rows.
    var q: QuoteCheck = .{};
    const text = "lug_id,remark\n1,\"two lines\nof a remark, and, commas\"\n";
    var p2: reference.Parser = .init(text, .rfc4180, .{});
    while (try p2.next(std.testing.allocator, &fields)) |rec| q.record(rec, 2, .rfc4180, text, 0);
    try std.testing.expectEqual(@as(u64, 0), q.folded);
    try std.testing.expectEqual(@as(u64, 1), q.multiline);
    try std.testing.expect(!q.isData(1));
    // In a narrow file a line of text can split into a whole row by chance
    // (one comma, two columns): with no quote inside an unquoted field, a
    // file that quotes, it is not taken for data.
    var narrow: QuoteCheck = .{};
    const chance = "lug_id,remark\n1,\"late pick\nshade side, small\"\n";
    var p3: reference.Parser = .init(chance, .rfc4180, .{});
    while (try p3.next(std.testing.allocator, &fields)) |rec| narrow.record(rec, 2, .rfc4180, chance, 0);
    try std.testing.expectEqual(@as(u64, 1), narrow.folded);
    try std.testing.expect(!narrow.isData(0));
    // A line break inside quotes in a one-column file says nothing.
    var one: QuoteCheck = .{};
    one.record(.{ .start = 0, .end = 6, .line = 1, .inner_lines = 1 }, 1, .rfc4180, "\"a\nb\"\n", 0);
    try std.testing.expectEqual(@as(u64, 0), one.folded + one.multiline);
}

/// The bytes with their escapes undone: a doubled quote to one, and under
/// backslash escaping a backslash and the byte after it to that byte (a
/// backslash dialect takes doubled quotes too). out must hold bytes.len.
pub fn unescape(bytes: []const u8, d: Dialect, out: []u8) []u8 {
    const q = d.quote orelse {
        @memcpy(out[0..bytes.len], bytes);
        return out[0..bytes.len];
    };
    var n: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];
        if (d.escape == .backslash and c == '\\' and i + 1 < bytes.len) {
            i += 1;
        } else if (c == q and i + 1 < bytes.len and bytes[i + 1] == q) {
            i += 1;
        }
        out[n] = bytes[i];
        n += 1;
    }
    return out[0..n];
}

test "unescape" {
    var buf: [32]u8 = undefined;
    var d = Dialect.rfc4180;
    try std.testing.expectEqualStrings("a\"b", unescape("a\"\"b", d, &buf));
    try std.testing.expectEqualStrings("\"", unescape("\"\"", d, &buf));
    try std.testing.expectEqualStrings("a\\\"b", unescape("a\\\"\"b", d, &buf));
    d.escape = .backslash;
    try std.testing.expectEqualStrings("a\"b\\c", unescape("a\\\"b\\\\c", d, &buf));
    try std.testing.expectEqualStrings("a\"b", unescape("a\"\"b", d, &buf));
    d.quote = '\'';
    try std.testing.expectEqualStrings("it's", unescape("it\\'s", d, &buf));
}

test "value copies only what needs it" {
    const input = "x\"a\"\"b\"";
    var scratch: [8]u8 = undefined;
    const plain: Field = .{ .start = 0, .len = 1 };
    try std.testing.expectEqual(@as([*]const u8, input.ptr), plain.value(input, .rfc4180, &scratch).ptr);
    const escaped: Field = .{ .start = 2, .len = 4, .flags = .{ .quoted = true, .needs_unescape = true } };
    try std.testing.expectEqualStrings("a\"b", escaped.value(input, .rfc4180, &scratch));
}

/// Stage 2: records and fields from the structural index, emitting what
/// reference.Parser does on the same bytes. The index is built a window at
/// a time, each window starting at a record boundary (outside quotes, so
/// from parity 0) and cut back to its last line break. A field is checked
/// against the special mask: a quoted one must end in its quote with every
/// inner quote doubled or escaped, an unquoted one must hold no quote.
/// A record that fails, or that the index cannot settle (an unterminated
/// quote, an over-long field, a record too dense for the index), is read
/// again by the reference parser, which also takes the next few records
/// before the index resumes, so a file full of stray quotes costs a scalar
/// parse rather than a re-index per record.
pub const Scanner = struct {
    gpa: Allocator,
    dialect: Dialect,
    options: Options,
    /// The bytes on hand, from base: all of the input when it is mapped.
    data: []const u8,
    base: u64,
    /// data runs to the end of the input.
    eof: bool,
    /// Where the next record starts, in data.
    cur: usize,
    line: u64 = 1,
    /// The dialect is one the index can read; otherwise every record goes
    /// to the reference parser.
    simd: bool,
    scalar_left: u32 = 0,
    /// Records read from the index and by the reference parser.
    stats: struct { indexed: u64 = 0, scalar: u64 = 0 } = .{},

    window: struct {
        valid: bool = false,
        start: usize = 0,
        /// Everything from start to the end of the input is indexed, not cut.
        final: bool = false,
        count: usize = 0,
        next: usize = 0,
    } = .{},
    positions: []u32,
    special: std.ArrayList(u64) = .empty,
    scratch: std.ArrayList(Field) = .empty,

    pub const Options = struct {
        reference: reference.Options = .{},
        /// Bytes indexed at a time; doubled for a record that does not fit.
        window: usize = 1 << 20,
        /// Index entries a window can hold, at least 64.
        positions: usize = 1 << 20,
        /// Records the reference parser reads after one the index could not.
        scalar_run: u32 = 32,
        /// An index buffer to use rather than allocate: a worker's, reused
        /// from file to file. Its length is the positions the index holds.
        positions_buffer: ?[]u32 = null,
    };

    /// The largest window: past it, a record goes to the reference parser.
    const max_window = 1 << 30;

    pub fn init(gpa: Allocator, dialect: Dialect, options: Options) Allocator.Error!Scanner {
        std.debug.assert(options.positions >= scan.block);
        return .{
            .gpa = gpa,
            .dialect = dialect,
            .options = options,
            .data = &.{},
            .base = 0,
            .eof = true,
            .cur = options.reference.start,
            .simd = indexable(dialect),
            .positions = options.positions_buffer orelse try gpa.alloc(u32, options.positions),
        };
    }

    pub fn deinit(s: *Scanner) void {
        if (s.options.positions_buffer == null) s.gpa.free(s.positions);
        s.special.deinit(s.gpa);
        s.scratch.deinit(s.gpa);
    }

    /// The index reads a dialect when its bytes are distinct and are not
    /// line breaks, and no comment byte has to be looked for at each record.
    fn indexable(d: Dialect) bool {
        if (d.comment != null) return false;
        if (d.delimiter == '\n' or d.delimiter == '\r') return false;
        if (d.quote) |q| {
            if (q == d.delimiter or q == '\n' or q == '\r') return false;
            if (d.escape == .backslash and (q == '\\' or d.delimiter == '\\')) return false;
        }
        return true;
    }

    /// Hands the scanner bytes: data starts at absolute offset base, and
    /// eof says whether it runs to the end of the input. The record the
    /// scanner was at must still be in data.
    pub fn feed(s: *Scanner, data: []const u8, base: u64, eof: bool) void {
        const at = s.base + s.cur;
        std.debug.assert(at >= base and at <= base + data.len);
        s.cur = @intCast(at - base);
        s.data = data;
        s.base = base;
        s.eof = eof;
        s.window.valid = false;
    }

    /// The absolute offset the next record starts at: what a refill must keep.
    pub fn keepFrom(s: *const Scanner) u64 {
        return s.base + s.cur;
    }

    pub const Next = union(enum) {
        record: Record,
        /// The next record may run past data: feed more and ask again.
        need_more,
        end,
    };

    /// The next record, its fields appended to fields with absolute offsets.
    pub fn next(s: *Scanner, fields: *std.ArrayList(Field)) Allocator.Error!Next {
        const first = fields.items.len;
        while (true) {
            if (!s.simd or s.scalar_left > 0) return s.scalar(fields);
            if (!s.options.reference.keep_empty) s.skipEmptyLines();
            if (s.cur >= s.data.len) return if (s.eof) .end else .need_more;
            if (!s.window.valid or (s.window.next == s.window.count and !s.window.final)) {
                switch (try s.reindex()) {
                    .ok => {},
                    .need_more => return .need_more,
                    .scalar => return s.fallback(fields),
                }
                continue;
            }
            if (try s.record(fields)) |rec| {
                s.stats.indexed += 1;
                return .{ .record = rec };
            }
            fields.shrinkRetainingCapacity(first);
            return s.fallback(fields);
        }
    }

    /// Steps over empty lines at cur, without the index: a line break at a
    /// record's start is outside quotes whatever came before.
    fn skipEmptyLines(s: *Scanner) void {
        const data = s.data;
        while (s.cur < data.len and (data[s.cur] == '\n' or data[s.cur] == '\r')) {
            if (data[s.cur] == '\r' and s.cur + 1 == data.len and !s.eof) return;
            const crlf = data[s.cur] == '\r' and s.cur + 1 < data.len and data[s.cur + 1] == '\n';
            s.cur += if (crlf) 2 else 1;
            s.line += 1;
            s.window.valid = s.window.valid and s.dropEntries(s.cur);
        }
    }

    /// Moves the window's next entry past entries before at; false when the
    /// window does not reach that far.
    fn dropEntries(s: *Scanner, at: usize) bool {
        const w = &s.window;
        while (w.next < w.count and w.start + s.positions[w.next] < at) w.next += 1;
        return w.next < w.count or w.final;
    }

    /// Indexes a window from cur, cut back to its last line break.
    fn reindex(s: *Scanner) Allocator.Error!enum { ok, need_more, scalar } {
        var size = s.options.window;
        const avail = s.data.len - s.cur;
        while (true) {
            const len = @min(size, avail);
            try s.special.resize(s.gpa, len / scan.block + 1);
            var carry: scan.Carry = .{};
            const got = scan.index(s.data[s.cur..][0..len], s.dialect, &carry, s.positions, s.special.items);
            s.window = .{ .valid = true, .start = s.cur, .count = got.count };
            if (got.len == avail and s.eof) {
                s.window.final = true;
                return .ok;
            }
            if (s.cut(got)) return .ok;
            s.window.valid = false;
            if (got.len < len) return .scalar; // index full, and no line break in it
            if (len == avail) return if (s.eof) .scalar else .need_more;
            if (size >= max_window) return .scalar;
            size *= 2;
        }
    }

    /// Keeps the window's entries up to its last line break that has a byte
    /// after it in the window, so a CR's LF is never on the far side.
    fn cut(s: *Scanner, got: scan.Index) bool {
        const w = &s.window;
        var i = got.count;
        while (i > 0) {
            i -= 1;
            const p = s.positions[i];
            if (p + 1 >= got.len) continue;
            const c = s.data[w.start + p];
            if (c != '\n' and c != '\r') continue;
            const keep = if (c == '\r' and s.data[w.start + p + 1] == '\n') i + 2 else i + 1;
            w.count = keep;
            return true;
        }
        return false;
    }

    /// The record at cur from the index, or null for one the index cannot
    /// vouch for. Leaves fields with the record's on success.
    fn record(s: *Scanner, fields: *std.ArrayList(Field)) Allocator.Error!?Record {
        const data = s.data;
        const w = &s.window;
        const rec_start = s.cur;
        var inner_lines: u64 = 0;
        var field_start = rec_start;
        var i = w.next;
        while (true) {
            if (i == w.count) {
                // The end of the input, which is final, without a line break.
                std.debug.assert(w.final);
                const f = s.classify(field_start, data.len, &inner_lines) orelse return null;
                try fields.append(s.gpa, f);
                w.next = i;
                s.cur = data.len;
                defer s.line += inner_lines;
                return .{ .start = s.base + rec_start, .end = s.base + data.len, .line = s.line, .inner_lines = inner_lines };
            }
            const e = w.start + s.positions[i];
            const f = s.classify(field_start, e, &inner_lines) orelse return null;
            try fields.append(s.gpa, f);
            const c = data[e];
            if (c == s.dialect.delimiter) {
                field_start = e + 1;
                i += 1;
                continue;
            }
            var nl: Dialect.Newline = .lf;
            var end = e + 1;
            i += 1;
            if (c == '\r') {
                if (e + 1 < data.len and data[e + 1] == '\n') {
                    nl = .crlf;
                    end = e + 2;
                    i += 1;
                } else nl = .cr;
            }
            w.next = i;
            s.cur = end;
            defer s.line += 1 + inner_lines;
            return .{
                .start = s.base + rec_start,
                .end = s.base + end,
                .line = s.line,
                .inner_lines = inner_lines,
                .foreign_newline = nl != s.dialect.newline,
            };
        }
    }

    /// The field from fs to fe if the index read it as the reference parser
    /// would, counting the line breaks inside its quotes into lines.
    fn classify(s: *const Scanner, fs: usize, fe: usize, lines: *u64) ?Field {
        const data = s.data;
        const len = fe - fs;
        if (len > s.options.reference.max_field_len) return null;
        const q = s.dialect.quote orelse return .{ .start = s.base + fs, .len = @intCast(len) };
        if (len == 0 or data[fs] != q) {
            if (s.nextSpecial(fs, fe) != null) return null;
            return .{ .start = s.base + fs, .len = @intCast(len) };
        }
        if (len < 2 or data[fe - 1] != q) return null;
        const close = fe - 1;
        var flags: Field.Flags = .{ .quoted = true };
        var found: u64 = 0;
        var at = fs + 1;
        while (s.nextSpecial(at, close)) |p| {
            switch (data[p]) {
                '\\' => {
                    flags.needs_unescape = true;
                    const escaped = p + 1;
                    if (escaped >= close) return null;
                    if (data[escaped] == '\n' or (data[escaped] == '\r' and data[escaped + 1] != '\n')) found += 1;
                    at = escaped + 1;
                },
                '\n' => {
                    found += 1;
                    at = p + 1;
                },
                '\r' => {
                    if (data[p + 1] != '\n') found += 1;
                    at = p + 1;
                },
                else => {
                    // The quote: doubled, or it closed the field early.
                    if (p + 1 >= close or data[p + 1] != q) return null;
                    flags.needs_unescape = true;
                    at = p + 2;
                },
            }
        }
        lines.* += found;
        return .{ .start = s.base + fs + 1, .len = @intCast(len - 2), .flags = flags };
    }

    /// The first byte from a to b (exclusive) the special mask marks.
    fn nextSpecial(s: *const Scanner, a: usize, b: usize) ?usize {
        if (a >= b) return null;
        const w0 = s.window.start;
        var word = (a - w0) / scan.block;
        var m = s.special.items[word] & (~@as(u64, 0) << @intCast((a - w0) % scan.block));
        while (true) {
            if (m != 0) {
                const p = w0 + word * scan.block + @ctz(m);
                return if (p < b) p else null;
            }
            word += 1;
            if (w0 + word * scan.block >= b) return null;
            m = s.special.items[word];
        }
    }

    /// The record at cur from the reference parser, which then also takes
    /// the next scalar_run records. Every record goes this way when the
    /// dialect is one the index cannot read.
    fn fallback(s: *Scanner, fields: *std.ArrayList(Field)) Allocator.Error!Next {
        s.scalar_left = s.options.scalar_run + 1;
        return s.scalar(fields);
    }

    fn scalar(s: *Scanner, fields: *std.ArrayList(Field)) Allocator.Error!Next {
        var opts = s.options.reference;
        opts.start = s.cur;
        var p: reference.Parser = .init(s.data, s.dialect, opts);
        p.line = s.line;
        const rec = try p.next(s.gpa, &s.scratch) orelse {
            if (!s.eof) return .need_more;
            s.cur = s.data.len;
            s.line = p.line;
            return .end;
        };
        // A record that runs to the end of the bytes on hand may run on.
        if (!s.eof and rec.end == s.data.len) return .need_more;
        for (s.scratch.items) |f| {
            var g = f;
            g.start += s.base;
            try fields.append(s.gpa, g);
        }
        s.cur = @intCast(rec.end);
        s.line = p.line;
        s.window.valid = false;
        if (s.scalar_left > 0) s.scalar_left -= 1;
        s.stats.scalar += 1;
        var out = rec;
        out.start += s.base;
        out.end += s.base;
        return .{ .record = out };
    }
};

/// A record's values with escapes undone, into out; scratch holds the
/// unescaped ones and is sized first, so no slice into it moves. Fields
/// hold absolute offsets; data starts at base. Aligned to a cache line, as
/// reference.Parser.next is, so its loop sits where it did whatever changes
/// around it: every stage past parse runs it, and a 16-byte shift cost the
/// text profile 10% on the CI runner (docs/PERF.md).
pub fn values(
    gpa: Allocator,
    fields: []const Field,
    data: []const u8,
    base: u64,
    d: Dialect,
    scratch: *std.ArrayList(u8),
    out: *std.ArrayList([]const u8),
) align(64) Allocator.Error!void {
    out.clearRetainingCapacity();
    var need: usize = 0;
    for (fields) |f| {
        if (f.flags.needs_unescape) need += f.len;
    }
    try scratch.resize(gpa, need);
    var at: usize = 0;
    for (fields) |f| {
        const local: Field = .{ .start = f.start - base, .len = f.len, .flags = f.flags };
        if (!f.flags.needs_unescape) {
            try out.append(gpa, local.raw(data));
            continue;
        }
        try out.append(gpa, local.value(data, d, scratch.items[at..][0..f.len]));
        at += f.len;
    }
}

/// Records grouped for the stages after parsing: at most max_rows records
/// or max_bytes of fields, whichever comes first. A field's bytes are its
/// content and the Field that marks it, so a wide row of empty fields
/// fills a batch as surely as long ones do.
pub const Batch = struct {
    records: std.ArrayList(Record) = .empty,
    /// Every record's fields, in order: record i's are fields[firsts[i]..firsts[i + 1]].
    fields: std.ArrayList(Field) = .empty,
    firsts: std.ArrayList(usize) = .empty,
    field_bytes: u64 = 0,

    pub const Limits = struct {
        rows: usize = 65_536,
        bytes: u64 = 64 << 20,
    };

    pub fn deinit(b: *Batch, gpa: Allocator) void {
        b.records.deinit(gpa);
        b.fields.deinit(gpa);
        b.firsts.deinit(gpa);
    }

    pub fn clear(b: *Batch) void {
        b.records.clearRetainingCapacity();
        b.fields.clearRetainingCapacity();
        b.firsts.clearRetainingCapacity();
        b.field_bytes = 0;
    }

    pub fn len(b: *const Batch) usize {
        return b.records.items.len;
    }

    pub fn recordFields(b: *const Batch, i: usize) []const Field {
        const end = if (i + 1 < b.firsts.items.len) b.firsts.items[i + 1] else b.fields.items.len;
        return b.fields.items[b.firsts.items[i]..end];
    }

    /// Reads records from s into b until b is full or s needs more or is
    /// done; which of those, so the caller knows what to do next.
    pub fn fill(b: *Batch, gpa: Allocator, s: *Scanner, limits: Limits) Allocator.Error!enum { full, need_more, end } {
        while (b.len() < limits.rows and b.field_bytes < limits.bytes) {
            const first = b.fields.items.len;
            switch (try s.next(&b.fields)) {
                .record => |rec| {
                    try b.records.append(gpa, rec);
                    try b.firsts.append(gpa, first);
                    for (b.fields.items[first..]) |f| b.field_bytes += f.len + @sizeOf(Field);
                },
                .need_more => return .need_more,
                .end => return .end,
            }
        }
        return .full;
    }
};

const testing = std.testing;

/// What a parser made of an input, for comparing two of them.
const Parsed = struct {
    records: std.ArrayList(Record) = .empty,
    fields: std.ArrayList(Field) = .empty,
    counts: std.ArrayList(usize) = .empty,

    fn deinit(p: *Parsed) void {
        p.records.deinit(testing.allocator);
        p.fields.deinit(testing.allocator);
        p.counts.deinit(testing.allocator);
    }
};

fn parseReference(input: []const u8, d: Dialect, opts: reference.Options) !Parsed {
    var out: Parsed = .{};
    errdefer out.deinit();
    var fields: std.ArrayList(Field) = .empty;
    defer fields.deinit(testing.allocator);
    var p: reference.Parser = .init(input, d, opts);
    while (try p.next(testing.allocator, &fields)) |rec| {
        try out.records.append(testing.allocator, rec);
        try out.fields.appendSlice(testing.allocator, fields.items);
        try out.counts.append(testing.allocator, fields.items.len);
    }
    return out;
}

/// The scanner over input, handed piece bytes at a time (all of it when
/// piece is 0), more each time it asks, the way a buffered reader would.
fn parseScanner(input: []const u8, d: Dialect, opts: Scanner.Options, piece: usize) !Parsed {
    var out: Parsed = .{};
    errdefer out.deinit();
    var s: Scanner = try .init(testing.allocator, d, opts);
    defer s.deinit();
    var have = if (piece == 0) input.len else @min(piece, input.len);
    s.feed(input[0..have], 0, have == input.len);
    while (true) {
        const before = out.fields.items.len;
        switch (try s.next(&out.fields)) {
            .record => |rec| {
                try out.records.append(testing.allocator, rec);
                try out.counts.append(testing.allocator, out.fields.items.len - before);
            },
            .need_more => {
                try testing.expect(have < input.len);
                const keep: usize = @intCast(s.keepFrom());
                have = @min(have + piece, input.len);
                s.feed(input[keep..have], keep, have == input.len);
            },
            .end => return out,
        }
    }
}

fn expectSame(input: []const u8, d: Dialect, opts: Scanner.Options, piece: usize) !void {
    var want = try parseReference(input, d, opts.reference);
    defer want.deinit();
    var got = try parseScanner(input, d, opts, piece);
    defer got.deinit();
    const ok = std.meta.eql(want.records.items.len, got.records.items.len) and
        std.mem.eql(usize, want.counts.items, got.counts.items) and
        for (want.records.items, got.records.items) |a, b| {
            if (!std.meta.eql(a, b)) break false;
        } else true and
            for (want.fields.items, got.fields.items) |a, b| {
                if (!std.meta.eql(a, b)) break false;
            } else true;
    if (!ok) {
        std.debug.print("input ({d} bytes, dialect {f}, window {d}, positions {d}, piece {d}): \"{f}\"\n", .{
            input.len, d, opts.window, opts.positions, piece, std.zig.fmtString(input),
        });
        std.debug.print("reference: {any}\n  fields {any}\nscanner:   {any}\n  fields {any}\n", .{
            want.records.items, want.fields.items, got.records.items, got.fields.items,
        });
        return error.TestUnexpectedResult;
    }
}

test "the scanner agrees with the reference on the edge cases" {
    const csv = Dialect.rfc4180;
    var bs = csv;
    bs.escape = .backslash;
    var sq = csv;
    sq.quote = '\'';
    var none = csv;
    none.quote = null;
    var crlf = csv;
    crlf.newline = .crlf;
    var comment = csv;
    comment.comment = '#';
    const cases = [_]struct { []const u8, Dialect }{
        .{ "a,b\nc,d\n", csv },
        .{ "", csv },
        .{ "\n\n\r\n\r", csv },
        .{ "a,\n,b\n,\n", csv },
        .{ "\"a\r\nb\",c\r\nd,e\r\n", crlf },
        .{ "\"a\rb\",c\nd\n", csv },
        .{ "a,b\rc,d\n", csv },
        .{ "a,b\nc,d", csv },
        .{ "a\n\nb\n", csv },
        .{ "a,b,c\nd\ne,f,g,h\n", csv },
        .{ "ab\"c,d\n5'11\",x\n", csv },
        .{ "a,\"bc\nd,e", csv },
        .{ "x\n\"", csv },
        .{ "\"ab\"c,d\ne,f\n", csv },
        .{ "\"a\"\"b\",c\n\"\",\"\"\"\"\n", csv },
        .{ "\"a\\\"b\\\\c\",d\n", bs },
        .{ "\"a\"\"b\"\n", bs },
        .{ "\"a\\\n\",b\n", bs },
        .{ "\"ab\\", bs },
        .{ "a\\,b\n\\\"x,y\n", bs },
        .{ "'a,b','it''s',\"x\"\n", sq },
        .{ "\"a,b\"\n", none },
        .{ "a\x00b,\xff\n", csv },
        .{ "#x,\"y\na,b\n# z\nc\n", comment },
        .{ "\"\"\"\n\"a\n", csv },
        .{ "\"a\"\"\"\n", csv },
    };
    for (cases) |c| {
        for ([_]usize{ 0, 1, 3, 7 }) |piece| {
            try expectSame(c[0], c[1], .{ .window = 64, .positions = 64 }, piece);
            try expectSame(c[0], c[1], .{}, piece);
            try expectSame(c[0], c[1], .{ .reference = .{ .keep_empty = true, .max_field_len = 2 } }, piece);
        }
    }
}

/// A random input: mostly the dialect's own bytes, so quotes, escapes and
/// line breaks meet each other often.
fn randomInput(r: std.Random, buf: []u8, d: Dialect) []u8 {
    const alphabet = [_]u8{ 'a', 'b', ' ', d.delimiter, d.delimiter, d.quote orelse '"', d.quote orelse '\'', '"', '\'', '\n', '\n', '\r', '\\', '#' };
    const n = switch (r.uintLessThan(u8, 10)) {
        0 => r.uintLessThan(usize, 8),
        1...6 => r.uintLessThan(usize, 120),
        else => r.uintLessThan(usize, buf.len),
    };
    for (buf[0..n]) |*c| {
        c.* = if (r.uintLessThan(u8, 4) == 0) 'a' + r.uintLessThan(u8, 3) else alphabet[r.uintLessThan(usize, alphabet.len)];
    }
    return buf[0..n];
}

const dialects = [_]Dialect{
    .rfc4180,
    .{ .delimiter = ',', .quote = '"', .escape = .backslash, .newline = .lf, .header = false },
    .{ .delimiter = '\t', .quote = '\'', .escape = .doubled, .newline = .crlf, .header = false },
    .{ .delimiter = '|', .quote = null, .escape = .doubled, .newline = .lf, .header = false },
    .{ .delimiter = ';', .quote = '\'', .escape = .backslash, .newline = .cr, .header = false },
    .{ .delimiter = ',', .quote = '"', .escape = .doubled, .newline = .lf, .header = false, .comment = '#' },
};

// Seeded inputs through both parsers. build_options.differential_cases
// says how many; `zig build test -Ddifferential=1000000` is the
// milestone's million.
test "the scanner agrees with the reference on random inputs" {
    const cases = @import("build_options").differential_cases;
    var rng: std.Random.DefaultPrng = .init(0x7363_616e);
    const r = rng.random();
    var buf: [700]u8 = undefined;
    for (0..cases) |_| {
        const d = dialects[r.uintLessThan(usize, dialects.len)];
        const input = randomInput(r, &buf, d);
        const opts: Scanner.Options = .{
            .reference = .{
                .keep_empty = r.boolean(),
                .max_field_len = if (r.uintLessThan(u8, 8) == 0) r.uintLessThan(u32, 20) else std.math.maxInt(u32),
            },
            .window = ([_]usize{ 64, 100, 192, 1 << 12 })[r.uintLessThan(usize, 4)],
            .positions = ([_]usize{ 64, 70, 128, 1 << 12 })[r.uintLessThan(usize, 4)],
            .scalar_run = ([_]u32{ 0, 1, 32 })[r.uintLessThan(usize, 3)],
        };
        const piece = ([_]usize{ 0, 0, 1, 5, 64, 200 })[r.uintLessThan(usize, 6)];
        try expectSame(input, d, opts, piece);
    }
}

test "well-formed records never leave the index" {
    // Fifty copies; 0.17 has no array repeat operator.
    const input = comptime blk: {
        const one = "id,\"name\",note\n1,\"a \"\"b\"\"\",\"x\r\ny\"\n2,c,\n3,\"d,e\",\"\"\n";
        var buf: [one.len * 50]u8 = undefined;
        for (0..50) |i| @memcpy(buf[i * one.len ..][0..one.len], one);
        const all = buf;
        break :blk &all;
    };
    var s: Scanner = try .init(testing.allocator, .rfc4180, .{ .window = 256 });
    defer s.deinit();
    s.feed(input, 0, true);
    var fields: std.ArrayList(Field) = .empty;
    defer fields.deinit(testing.allocator);
    while (try s.next(&fields) != .end) {}
    try testing.expectEqual(@as(u64, 200), s.stats.indexed);
    try testing.expectEqual(@as(u64, 0), s.stats.scalar);
    try testing.expectEqual(@as(u64, 251), s.line);
}

test "a batch stops at its row and byte limits" {
    const input = "a,b\nc,d\ne,f\ng,h\n";
    var s: Scanner = try .init(testing.allocator, .rfc4180, .{});
    defer s.deinit();
    s.feed(input, 0, true);
    var b: Batch = .{};
    defer b.deinit(testing.allocator);
    try testing.expectEqual(.full, try b.fill(testing.allocator, &s, .{ .rows = 3 }));
    try testing.expectEqual(@as(usize, 3), b.len());
    try testing.expectEqual(@as(u64, 6 + 6 * @sizeOf(Field)), b.field_bytes);
    try testing.expectEqualStrings("c", b.recordFields(1)[0].raw(input));
    b.clear();
    try testing.expectEqual(.full, try b.fill(testing.allocator, &s, .{ .bytes = 1 }));
    try testing.expectEqual(@as(usize, 1), b.len());
    try testing.expectEqualStrings("h", b.recordFields(0)[1].raw(input));
    b.clear();
    try testing.expectEqual(.end, try b.fill(testing.allocator, &s, .{}));
    try testing.expectEqual(@as(usize, 0), b.len());
}

test "a batch of wide rows of empty fields stops at its byte limit" {
    // 100 fields a record, every one empty: no content, a Field apiece.
    const row = @as([99]u8, @splat(',')) ++ "\n";
    const input = row ++ row ++ row ++ row;
    var s: Scanner = try .init(testing.allocator, .rfc4180, .{});
    defer s.deinit();
    s.feed(input, 0, true);
    var b: Batch = .{};
    defer b.deinit(testing.allocator);
    try testing.expectEqual(.full, try b.fill(testing.allocator, &s, .{ .bytes = 150 * @sizeOf(Field) }));
    try testing.expectEqual(@as(usize, 2), b.len());
    try testing.expectEqual(@as(usize, 100), b.recordFields(1).len);
}

fn scannerInitDeinit(gpa: Allocator) !void {
    var s: Scanner = try .init(gpa, .rfc4180, .{ .positions = 64 });
    s.deinit();
}

test "Scanner.init frees what it holds when an allocation fails" {
    try testing.checkAllAllocationFailures(testing.allocator, scannerInitDeinit, .{});
}
