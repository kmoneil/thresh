//! A delimited file's dialect: how its fields and records are separated and
//! quoted, and whether its first record is a header; and the sniffer that
//! settles one from a sample.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const reference = @import("reference.zig");
const Field = @import("records.zig").Field;
const NameMap = @import("schema.zig").NameMap;

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

pub const HeaderMode = enum { auto, yes, no };

/// Dialect dimensions given on the command line. Null leaves one to the
/// sniffer.
pub const Pins = struct {
    delimiter: ?u8 = null,
    quote: ?Quote = null,
    escape: ?Dialect.Escape = null,
    newline: ?Dialect.Newline = null,
    header: HeaderMode = .auto,
    comment: ?u8 = null,

    pub const Quote = union(enum) { none, byte: u8 };

    /// Every dimension the sniffer would otherwise settle is pinned, so a
    /// low-confidence verdict does not stop the file.
    pub fn complete(p: Pins) bool {
        return p.delimiter != null and p.quote != null and p.escape != null and
            p.newline != null and p.header != .auto;
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

/// How sure the sniffer is: high when nearly every record has the winning
/// shape and the best other delimiter is well behind, medium when most do.
pub const Confidence = enum { high, medium, low };

/// What the pre-checks and the winning parse noticed; none stops the file.
pub const Warnings = packed struct(u8) {
    utf8_bom: bool = false,
    /// Records end in more than one kind of line break.
    mixed_newlines: bool = false,
    /// A quote character inside an unquoted field, read as data.
    quote_in_unquoted: bool = false,
    /// Read as UTF-8, and the sample is not: a Windows or Latin-1 export,
    /// most likely, which --encoding cp1252 or latin1 reads.
    not_utf8: bool = false,
    /// The file is UTF-16 (a byte order mark), read transcoded to UTF-8:
    /// set by whoever opened it, as the sniffer sees only the UTF-8.
    utf16: bool = false,
    /// Some of its code units made no character and are U+FFFD.
    utf16_invalid: bool = false,
    _: u2 = 0,

    pub const names = .{ "utf8_bom", "mixed_newlines", "quote_in_unquoted", "not_utf8", "utf16", "utf16_invalid" };

    pub fn jsonStringify(w: Warnings, s: *std.json.Stringify) std.json.Stringify.Error!void {
        try s.beginArray();
        inline for (names) |name| {
            if (@field(w, name)) try s.write(name);
        }
        try s.endArray();
    }
};

/// The most of a file's start the sniffer reads, unless --sample-bytes
/// asks for more: what its window may grow to.
pub const max_sample_bytes = 16 << 20;

pub const SniffOptions = struct {
    pins: Pins = .{},
    /// The first window; it doubles while the winner has seen fewer than
    /// `records` complete records, up to max_sample.
    sample_bytes: usize = 64 << 10,
    max_sample: usize = max_sample_bytes,
    records: usize = 32,
    /// The schema's columns, when there is one: its count is the strongest
    /// evidence there is, and its names say whether row 1 is a header.
    schema: ?[]const []const u8 = null,
    /// The file is to be read as UTF-8 (no --encoding): a sample that is
    /// not is warned of.
    utf8: bool = true,
};

pub const Verdict = struct {
    dialect: Dialect,
    confidence: Confidence,
    score: f64,
    /// The fraction of the winner's records with its most common field count.
    consistency: f64,
    /// Fields in most of its records.
    fields: usize,
    /// Complete records the winner read.
    records: usize,
    /// Bytes the last window held.
    sample_len: usize,
    /// Where records start: 3 past a UTF-8 BOM.
    start: usize,
    warnings: Warnings,
    /// The best candidates with other delimiters, best first.
    runners_up: [2]?Runner = .{ null, null },

    pub const Runner = struct { delimiter: u8, score: f64 };

    /// The report's dialect object: the dialect, how sure, and why.
    pub fn jsonStringify(v: Verdict, s: *std.json.Stringify) std.json.Stringify.Error!void {
        const d = v.dialect;
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
        try s.objectField("confidence");
        try s.write(@tagName(v.confidence));
        try s.objectField("score");
        try s.print("{d:.2}", .{v.score});
        try s.objectField("runners_up");
        try s.beginArray();
        for (v.runners_up) |r| if (r) |runner| {
            try s.beginObject();
            try s.objectField("delimiter");
            try s.write(@as([]const u8, &.{runner.delimiter}));
            try s.objectField("score");
            try s.print("{d:.2}", .{runner.score});
            try s.endObject();
        };
        try s.endArray();
        try s.endObject();
    }
};

pub const SniffError = error{
    /// A UTF-16 byte order mark: bytes not transcoded first, as
    /// input.Input does for every file thresh reads.
    Utf16,
    /// A NUL byte in the first 8 KiB, and no UTF-16 BOM to explain it.
    Binary,
    /// The pins leave no dialect to score: a backslash escape with no
    /// quote, or a quote that is the delimiter.
    Unscorable,
} || Allocator.Error;

/// The delimiters tried first, in the order a tie goes.
const prior_delimiters = [_]u8{ ',', '\t', '|', ';', ':', '~', 0x01, 0x1f, ' ' };
const prior_quotes = [_]?u8{ '"', '\'', null };

/// The dialect of data, its first bytes or (complete) all of a file. Every
/// candidate is parsed, not counted: the one whose records most often have
/// the same number of fields wins. This is DuckDB's approach, which free
/// text full of delimiters does not fool the way character counts are.
pub fn sniff(gpa: Allocator, data: []const u8, complete: bool, options: SniffOptions) SniffError!Verdict {
    var warnings: Warnings = .{};
    var start: usize = 0;
    if (std.mem.startsWith(u8, data, "\xef\xbb\xbf")) {
        start = 3;
        warnings.utf8_bom = true;
    } else if (std.mem.startsWith(u8, data, "\xff\xfe") or std.mem.startsWith(u8, data, "\xfe\xff")) {
        return error.Utf16;
    }
    if (std.mem.findScalar(u8, data[0..@min(data.len, 8192)], 0) != null) return error.Binary;

    var parser_fields: std.ArrayList(Field) = .empty;
    defer parser_fields.deinit(gpa);
    var counts: std.ArrayList(u32) = .empty;
    defer counts.deinit(gpa);
    const pins = options.pins;
    const delimiters = candidateDelimiters(data[start..@min(data.len, options.sample_bytes)], pins);
    const pinned_quote = [1]?u8{if (pins.quote) |pq| switch (pq) {
        .none => null,
        .byte => |b| b,
    } else null};
    const quotes: []const ?u8 = if (pins.quote != null) &pinned_quote else &prior_quotes;

    var window = @max(options.sample_bytes, 1);
    var best: Scored = undefined;
    var runners: [2]?Verdict.Runner = undefined;
    while (true) {
        const len = @min(window, data.len);
        const sample = data[0..len];
        const whole = complete and len == data.len;
        var any = false;
        runners = .{ null, null };
        for (delimiters.slice()) |delim| {
            const readings = readingsOf(delim, quotes, pins, sample);
            if (readings.len == 0) continue;
            var scored: [max_readings]Scored = undefined;
            for (readings.slice(), scored[0..readings.len]) |d, *s| {
                s.* = try score(gpa, sample[start..], whole, d, options, &parser_fields, &counts);
            }
            const c = pick(scored[0..readings.len]);
            if (!any or c.score > best.score + 1e-9) {
                if (any) pushRunner(&runners, .{ .delimiter = best.dialect.delimiter, .score = best.score });
                best = c;
                any = true;
            } else pushRunner(&runners, .{ .delimiter = delim, .score = c.score });
        }
        if (!any) return error.Unscorable;
        // The spec grows the window only while the winner has seen too few
        // records; this also grows it while the winner is not a clear one,
        // since a record bigger than the window loses its dialect the count
        // (its parse stops at the window's end) and lets a wrong one win
        // with many short records. Each parse stops at options.records
        // records, so a bigger window costs little unless a record is big.
        const clear = best.records >= options.records and confidenceOf(best, runners, options) == .high;
        if (clear or whole or len == data.len or window >= options.max_sample) break;
        window = @min(window * 2, @max(options.max_sample, options.sample_bytes));
    }

    var d = best.dialect;
    const len = @min(window, data.len);
    const sample = data[start..len];
    const shape = try lines(gpa, sample, d, &parser_fields);
    d.newline = pins.newline orelse shape.newline;
    if (shape.mixed) warnings.mixed_newlines = true;
    if (shape.stray_quotes) warnings.quote_in_unquoted = true;
    if (options.utf8 and notUtf8(sample, complete and len == data.len)) warnings.not_utf8 = true;
    d.header = switch (pins.header) {
        .yes => true,
        .no => false,
        .auto => try isHeader(gpa, sample, d, options, &parser_fields),
    };
    const confidence = confidenceOf(best, runners, options);
    return .{
        .dialect = d,
        .confidence = confidence,
        .score = best.score,
        .consistency = best.consistency,
        .fields = best.mode,
        .records = best.records,
        .sample_len = len,
        .start = start,
        .warnings = warnings,
        .runners_up = runners,
    };
}

/// High when nearly every record has the winner's shape and the best other
/// delimiter scores 0.2 or more below it; medium when most records do.
/// When a schema's column count is the winner's and it leads by as much,
/// at least medium however ragged the rows: the schema is the strongest
/// evidence there is, and the ragged rows are then the file's errors to
/// report, not a dialect left unsettled. So too when --delimiter is
/// pinned: a file with unquoted delimiters in a value can be read with
/// that one flag, its wide rows reported as ragged.
fn confidenceOf(best: Scored, runners: [2]?Verdict.Runner, options: SniffOptions) Confidence {
    const margin = if (runners[0]) |r| best.score - r.score else std.math.inf(f64);
    if (best.consistency >= 0.98 and margin >= 0.2) return .high;
    if (best.consistency >= 0.9) return .medium;
    if (options.pins.delimiter != null and best.mode >= 2) return .medium;
    if (options.schema) |cols| if (cols.len == best.mode and margin >= 0.2) return .medium;
    return .low;
}

/// Keeps the two best runners-up, best first.
fn pushRunner(runners: *[2]?Verdict.Runner, r: Verdict.Runner) void {
    if (runners[0] == null or r.score > runners[0].?.score) {
        runners[1] = runners[0];
        runners[0] = r;
    } else if (runners[1] == null or r.score > runners[1].?.score) {
        runners[1] = r;
    }
}

/// The candidates' delimiters, in prior order.
const Delimiters = struct {
    buf: [prior_delimiters.len + 2]u8 = undefined,
    len: usize = 0,

    fn append(d: *Delimiters, c: u8) void {
        d.buf[d.len] = c;
        d.len += 1;
    }

    fn slice(d: *const Delimiters) []const u8 {
        return d.buf[0..d.len];
    }
};

/// The pinned delimiter alone, or the prior ones and then up to two other
/// punctuation bytes the sample has more than two of a line.
fn candidateDelimiters(sample: []const u8, pins: Pins) Delimiters {
    var out: Delimiters = .{};
    if (pins.delimiter) |d| {
        out.append(d);
        return out;
    }
    for (prior_delimiters) |d| out.append(d);
    var freq: [128]u32 = @splat(0);
    var line_count: u32 = 1;
    for (sample) |c| {
        if (c == '\n') line_count += 1;
        if (c < 128) freq[c] += 1;
    }
    for (0..2) |_| {
        var top: ?u8 = null;
        for (freq, 0..) |n, i| {
            const c: u8 = @intCast(i);
            if (!std.ascii.isPrint(c) or std.ascii.isAlphanumeric(c)) continue;
            if (c == '"' or c == '\'' or c == '\\' or std.mem.findScalar(u8, out.slice(), c) != null) continue;
            if (n <= 2 * line_count) continue;
            if (top == null or n > freq[top.?]) top = c;
        }
        out.append(top orelse break);
    }
    return out;
}

fn hasBackslashQuote(sample: []const u8, q: u8) bool {
    var it = std.mem.splitScalar(u8, sample, '\\');
    _ = it.next();
    while (it.next()) |after| if (after.len > 0 and after[0] == q) return true;
    return false;
}

/// The most readings one delimiter has: each quote under each escape.
const max_readings = prior_quotes.len * 2;

/// One delimiter's readings, in the order they are scored.
const Readings = struct {
    buf: [max_readings]Dialect = undefined,
    len: usize = 0,

    fn slice(r: *const Readings) []const Dialect {
        return r.buf[0..r.len];
    }
};

/// The readings of delim worth scoring: each of quotes but the delimiter
/// itself, under each escape the pins allow; backslash escaping only with
/// a quote, and unless pinned, only where the sample has a backslash
/// before one.
fn readingsOf(delim: u8, quotes: []const ?u8, pins: Pins, sample: []const u8) Readings {
    var out: Readings = .{};
    for (quotes) |quote| {
        if (quote == delim) continue;
        for ([_]Dialect.Escape{ .doubled, .backslash }) |escape| {
            if (pins.escape) |pe| if (pe != escape) continue;
            if (escape == .backslash) {
                const q = quote orelse continue;
                if (pins.escape == null and !hasBackslashQuote(sample, q)) continue;
            }
            out.buf[out.len] = .{
                .delimiter = delim,
                .quote = quote,
                .escape = escape,
                .newline = .lf,
                .header = false,
                .comment = pins.comment,
            };
            out.len += 1;
        }
    }
    return out;
}

/// The reading a delimiter is ranked by, of its readings scored in order:
/// the first with the best score, unless a quote has a better claim.
fn pick(scored: []const Scored) Scored {
    var best = scored[0];
    var clean: ?Scored = null;
    // The best reading under each quote character, '"' and '\''.
    var by_quote: [2]?Scored = .{ null, null };
    for (scored) |c| {
        if (c.score > best.score + 1e-9) best = c;
        if (c.clean_quoted and (clean == null or c.score > clean.?.score + 1e-9)) clean = c;
        if (quoteIndex(c.dialect.quote)) |k| if (by_quote[k] == null or c.score > by_quote[k].?.score + 1e-9) {
            by_quote[k] = c;
        };
    }
    // A quote whose parse is clean beats reading its characters as data:
    // a file whose every row quotes two fields holding the delimiter
    // splits into a consistent, wider shape without them, and the wider
    // shape scores higher.
    if (clean) |c| if (c.consistency >= best.consistency) {
        best = c;
    };
    // A reading that leaves fields wrapped in a quote character as data,
    // when the reading that honours it parses most records: the quote is
    // the file's, and the records it breaks are its errors (a quote inside
    // a quoted field, not doubled), not a sign it has none.
    for (by_quote, 0..) |cand, k| {
        const q = cand orelse continue;
        if (best.dialect.quote == q.dialect.quote) continue;
        if (best.bare[k] * 2 >= best.records and q.consistency >= 0.8) return q;
    }
    return best;
}

const Scored = struct {
    dialect: Dialect,
    score: f64,
    consistency: f64,
    mode: usize,
    records: usize,
    /// The parse quoted at least one field, and left no quote character
    /// as data and no record broken: the quote explains every one of its
    /// characters in the sample.
    clean_quoted: bool = false,
    /// Unquoted fields that start and end with '"', and with '\'': quotes
    /// this reading leaves as data.
    bare: [2]usize = .{ 0, 0 },
};

fn quoteIndex(q: ?u8) ?usize {
    return if (q == '"') 0 else if (q == '\'') 1 else null;
}

/// One candidate's score over its first options.records complete records:
/// consistency x ln(1 + mode), less 0.5 for a single column and 0.3 for a
/// quote still open where the sample stops, plus 1.0 when mode is the
/// schema's column count. A record the dialect reads as broken (a bad or
/// unterminated quote) counts against consistency whatever its fields.
///
/// Less 1.0, too, when the first record is half the mode's width or less,
/// or twice it or more: a real delimiter makes the header (or a headerless
/// file's first row) about as wide as the rows. Without it ln(1 + mode)
/// lets a byte inside values win: `_` over `,` in a file of codes like
/// AB_CD_EF, whose header has no `_` (one field) or, with names like
/// emp_id, many more than the rows' steady few. A header one name short
/// of its rows is not half or twice them, and keeps its delimiter.
fn score(
    gpa: Allocator,
    sample: []const u8,
    whole: bool,
    d: Dialect,
    options: SniffOptions,
    fields: *std.ArrayList(Field),
    counts: *std.ArrayList(u32),
) Allocator.Error!Scored {
    counts.clearRetainingCapacity();
    var p: reference.Parser = .init(sample, d, .{});
    var unbalanced = false;
    var quoted_fields: usize = 0;
    var bare: [2]usize = .{ 0, 0 };
    var dirty = false;
    while (counts.items.len < options.records) {
        const rec = try p.next(gpa, fields) orelse break;
        if (!whole and rec.end == sample.len) {
            const last = sample[sample.len - 1];
            const ended = rec.problem == null and (last == '\n' or last == '\r');
            if (!ended) {
                unbalanced = rec.problem == .unterminated_quote;
                break;
            }
        }
        if (rec.problem == .unterminated_quote) unbalanced = true;
        if (rec.problem != null or rec.stray_quotes > 0) dirty = true;
        for (fields.items) |f| {
            quoted_fields += @intFromBool(f.flags.quoted);
            if (f.flags.quoted or f.len < 2) continue;
            const v = sample[@intCast(f.start)..][0..f.len];
            if (v[0] != v[v.len - 1]) continue;
            if (quoteIndex(v[0])) |k| bare[k] += 1;
        }
        // A broken record is no field count at all: 0 never wins the mode.
        try counts.append(gpa, if (rec.problem != null) 0 else @intCast(fields.items.len));
    }
    const n = counts.items.len;
    if (n == 0) return .{ .dialect = d, .score = -1, .consistency = 0, .mode = 0, .records = 0 };
    const first_width = counts.items[0];
    std.mem.sort(u32, counts.items, {}, std.sort.asc(u32));
    var mode: u32 = 0;
    var mode_n: usize = 0;
    var i: usize = 0;
    while (i < n) {
        var j = i;
        while (j < n and counts.items[j] == counts.items[i]) j += 1;
        // Ties go to the larger count; 0 (broken records) never wins.
        if (counts.items[i] != 0 and j - i >= mode_n) {
            mode = counts.items[i];
            mode_n = j - i;
        }
        i = j;
    }
    const consistency = @as(f64, @floatFromInt(mode_n)) / @as(f64, @floatFromInt(n));
    var s = consistency * @log(1 + @as(f64, @floatFromInt(mode)));
    if (mode == 1) s -= 0.5;
    if (mode >= 2 and first_width > 0 and (first_width * 2 <= mode or first_width >= mode * 2)) s -= 1.0;
    if (unbalanced) s -= 0.3;
    if (options.schema) |cols| if (mode == cols.len) {
        s += 1.0;
    };
    return .{
        .dialect = d,
        .score = s,
        .consistency = consistency,
        .mode = mode,
        .records = n,
        .clean_quoted = d.quote != null and quoted_fields > 0 and !dirty and !unbalanced,
        .bare = bare,
    };
}

const Shape = struct { newline: Dialect.Newline, mixed: bool, stray_quotes: bool };

/// The kind of the first record's line break, and whether a later one is
/// another kind or a field held a stray quote, over the scored records.
fn lines(gpa: Allocator, sample: []const u8, d: Dialect, fields: *std.ArrayList(Field)) Allocator.Error!Shape {
    var shape: Shape = .{ .newline = .lf, .mixed = false, .stray_quotes = false };
    var first: ?Dialect.Newline = null;
    var p: reference.Parser = .init(sample, d, .{});
    var n: usize = 0;
    while (n < 1000) : (n += 1) {
        const rec = try p.next(gpa, fields) orelse break;
        if (rec.stray_quotes > 0) shape.stray_quotes = true;
        const end: usize = @intCast(rec.end);
        if (end == 0) break;
        const kind: Dialect.Newline = switch (sample[end - 1]) {
            '\n' => if (end >= 2 and sample[end - 2] == '\r') .crlf else .lf,
            '\r' => .cr,
            else => break,
        };
        if (first) |f| {
            if (f != kind) shape.mixed = true;
        } else first = kind;
    }
    shape.newline = first orelse .lf;
    return shape;
}

/// Whether sample holds bytes that are not UTF-8. A sample cut short of
/// the file's end may stop inside a character; that is not counted.
fn notUtf8(sample: []const u8, whole: bool) bool {
    var s = sample;
    if (!whole) {
        var i = s.len;
        while (i > 0 and s.len - i < 3 and s[i - 1] & 0xc0 == 0x80) i -= 1;
        if (i > 0 and s[i - 1] >= 0xc0) s = s[0 .. i - 1];
    }
    return !std.unicode.utf8ValidateSlice(s);
}

/// Whether the first record names the columns. With a schema, it does when
/// at least half its fields are the schema's names, trimmed and in any
/// case: a header missing a column, or with one the schema lacks, is still
/// a header, and validation says which column. Failing that, it does when
/// every field in it is a non-empty string and some column below it holds
/// only values of another type.
fn isHeader(gpa: Allocator, sample: []const u8, d: Dialect, options: SniffOptions, fields: *std.ArrayList(Field)) Allocator.Error!bool {
    var p: reference.Parser = .init(sample, d, .{});
    _ = try p.next(gpa, fields) orelse return false;
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(gpa);
    const first = try fields.toOwnedSlice(gpa);
    defer gpa.free(first);
    if (options.schema) |names| {
        var known: NameMap(void) = .empty;
        defer known.deinit(gpa);
        try known.ensureTotalCapacity(gpa, @intCast(names.len));
        for (names) |name| known.putAssumeCapacity(std.mem.trim(u8, name, " \t"), {});
        var named: usize = 0;
        for (first) |f| {
            if (known.contains(std.mem.trim(u8, try value(gpa, &scratch, sample, d, f), " \t"))) named += 1;
        }
        if (named * 2 >= first.len and named > 0) return true;
    }
    // Row 1's values, to know it again below: two exports joined repeat it.
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(gpa);
    const ends = try gpa.alloc(usize, first.len);
    defer gpa.free(ends);
    for (first, ends) |f, *e| {
        const v = try value(gpa, &scratch, sample, d, f);
        if (v.len == 0 or looksTyped(v)) return false;
        try names.appendSlice(gpa, std.mem.trim(u8, v, " \t"));
        e.* = names.items.len;
    }
    // Per column: still typed (every non-empty value so far), and seen one.
    const typed = try gpa.alloc(bool, first.len);
    defer gpa.free(typed);
    const seen = try gpa.alloc(bool, first.len);
    defer gpa.free(seen);
    @memset(typed, true);
    @memset(seen, false);
    var rows: usize = 0;
    while (rows < 100) : (rows += 1) {
        const rec = try p.next(gpa, fields) orelse break;
        if (rec.end == sample.len and sample[sample.len - 1] != '\n' and sample[sample.len - 1] != '\r') break;
        if (fields.items.len != first.len) continue;
        // Row 1 again is not a column's evidence either way.
        const again = for (fields.items, ends, 0..) |f, end, col| {
            const start = if (col == 0) 0 else ends[col - 1];
            const v = std.mem.trim(u8, try value(gpa, &scratch, sample, d, f), " \t");
            if (!std.ascii.eqlIgnoreCase(v, names.items[start..end])) break false;
        } else true;
        if (again) continue;
        for (fields.items, 0..) |f, col| {
            const v = try value(gpa, &scratch, sample, d, f);
            if (v.len == 0) continue;
            seen[col] = true;
            if (!looksTyped(v)) typed[col] = false;
        }
    }
    for (typed, seen) |t, s| if (t and s) return true;
    return false;
}

fn value(gpa: Allocator, scratch: *std.ArrayList(u8), sample: []const u8, d: Dialect, f: Field) Allocator.Error![]const u8 {
    try scratch.resize(gpa, f.len);
    return f.value(sample, d, scratch.items);
}

/// A value that is not a plain string: an integer, a decimal or float, a
/// boolean, or a date or time written in digits and separators.
fn looksTyped(v: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(v, "true") or std.ascii.eqlIgnoreCase(v, "false")) return true;
    var i: usize = 0;
    if (v[0] == '-' or v[0] == '+') i = 1;
    var digits: usize = 0;
    var dots: usize = 0;
    var seps: usize = 0;
    var exp = false;
    while (i < v.len) : (i += 1) {
        switch (v[i]) {
            '0'...'9' => digits += 1,
            '.' => dots += 1,
            'e', 'E' => {
                if (exp or digits == 0) return false;
                exp = true;
                if (i + 1 < v.len and (v[i + 1] == '-' or v[i + 1] == '+')) i += 1;
            },
            '-', '/', ':', ' ', 'T' => seps += 1,
            else => return false,
        }
    }
    if (digits == 0) return false;
    if (seps > 0) return !exp and digits >= 4 and std.ascii.isDigit(v[0]) and std.ascii.isDigit(v[v.len - 1]);
    return dots <= 1;
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

fn sniffed(data: []const u8, options: SniffOptions) !Verdict {
    return sniff(std.testing.allocator, data, true, options);
}

test "sniff settles a plain CSV with a header" {
    const v = try sniffed("id,name,amount\n1,apple,1.50\n2,\"pear, green\",2.25\n", .{});
    try std.testing.expectEqual(Dialect{ .delimiter = ',', .quote = '"', .escape = .doubled, .newline = .lf, .header = true }, v.dialect);
    try std.testing.expectEqual(Confidence.high, v.confidence);
    try std.testing.expectEqual(@as(usize, 3), v.fields);
}

test "sniff reads a BOM, and refuses UTF-16 and binary data" {
    const v = try sniffed("\xef\xbb\xbfa;b\n1;2\n3;4\n", .{});
    try std.testing.expect(v.warnings.utf8_bom);
    try std.testing.expectEqual(@as(usize, 3), v.start);
    try std.testing.expectEqual(@as(u8, ';'), v.dialect.delimiter);
    try std.testing.expectError(error.Utf16, sniffed("\xff\xfea\x00,\x00", .{}));
    try std.testing.expectError(error.Binary, sniffed("a,b\n\x00\x01,c\n", .{}));
}

test "sniff keeps a pinned dimension and settles the rest" {
    const data = "a|b|c\r\n1|2|3\r\n";
    const v = try sniffed(data, .{ .pins = .{ .quote = .none, .header = .no } });
    try std.testing.expectEqual(@as(u8, '|'), v.dialect.delimiter);
    try std.testing.expectEqual(@as(?u8, null), v.dialect.quote);
    try std.testing.expectEqual(Dialect.Newline.crlf, v.dialect.newline);
    try std.testing.expect(!v.dialect.header);
}

test "sniff scores a pinned quote it would not guess, and refuses pins that leave nothing" {
    const data = "id,name\n1,~pear, green~\n2,apple\n";
    const v = try sniffed(data, .{ .pins = .{ .quote = .{ .byte = '~' } } });
    try std.testing.expectEqual(@as(u8, ','), v.dialect.delimiter);
    try std.testing.expectEqual(@as(?u8, '~'), v.dialect.quote);
    try std.testing.expectEqual(@as(usize, 2), v.fields);
    try std.testing.expectError(error.Unscorable, sniffed(data, .{ .pins = .{ .quote = .none, .escape = .backslash } }));
    try std.testing.expectError(error.Unscorable, sniffed(data, .{ .pins = .{ .delimiter = '~', .quote = .{ .byte = '~' } } }));
}

test "sniff picks backslash escaping when the escaped quotes need it" {
    const data = "id,text\n1,\"say \\\"hi, there\\\" now\"\n2,\"plain\"\n3,\"a \\\"b, c\\\" d\"\n";
    const v = try sniffed(data, .{});
    try std.testing.expectEqual(Dialect.Escape.backslash, v.dialect.escape);
}

test "a clean quote beats a wider shape that reads its characters as data" {
    const data = "id,price,qty,vat\n1,\"7408,07\",261,\"21,0\"\n2,\"1587,65\",323,\"19,0\"\n3,\"5714,51\",447,\"20,0\"\n";
    const v = try sniffed(data, .{});
    try std.testing.expectEqual(@as(?u8, '"'), v.dialect.quote);
    try std.testing.expectEqual(@as(usize, 4), v.fields);
    try std.testing.expect(v.dialect.header);
}

test "a header repeated below, as joined files have, is still a header" {
    const v = try sniffed("id,qty\n1,2\nid,qty\n3,4\n ID , Qty\n5,6\n", .{});
    try std.testing.expect(v.dialect.header);
}

test "a delimiter the header lacks loses to one it has" {
    // Codes split on _ into more columns, nearly as consistently.
    const codes = "id,code,name\n0,CD_AB_EF_AB_GH,blue\n1,GH_GH_CD_AB_GH,red\n2,AB_CD_EF_GH_AB,red\n3,EF_EF_AB_CD_GH,blue\n";
    const v = try sniffed(codes, .{});
    try std.testing.expectEqual(@as(u8, ','), v.dialect.delimiter);
    try std.testing.expect(v.dialect.header);
    try std.testing.expectEqual(Confidence.high, v.confidence);
    // Unquoted commas in a text column: the commas are still the
    // delimiter, the wide rows the file's errors, and the verdict not sure.
    const ragged = "sku,desc,qty\nA_B_C_D_1,red, large,3\nA_B_C_D_2,blue,4\nA_B_C_D_3,green, small, round,5\nA_B_C_D_4,pink,6\n";
    const r = try sniffed(ragged, .{});
    try std.testing.expectEqual(@as(u8, ','), r.dialect.delimiter);
    try std.testing.expectEqual(Confidence.low, r.confidence);
    // Told the delimiter, it is settled enough to read and report.
    const pinned = try sniffed(ragged, .{ .pins = .{ .delimiter = ',' } });
    try std.testing.expectEqual(Confidence.medium, pinned.confidence);
    try std.testing.expect(pinned.dialect.header);
}

test "a byte far more often in the header than in the rows is not the delimiter" {
    // Names with _ split the header into 7 fields and a code each row into
    // 3, every row alike, while the commas are ragged: a free-text column
    // holds unquoted ones. A delimiter makes the header about as wide as
    // the rows, so the commas, unsure, and not the _ at medium.
    const steady = "ka_id,ka_day,ka_band,ka_vel,ka_memo,ka_kind\n" ++
        "1,2026-02-01,QX_LUM_0,10.50,red,REG\n2,2026-02-02,QX_LUM_1,11.50,blue, late,REG\n" ++
        "3,2026-02-03,QX_LUM_2,12.50,red,REG\n4,2026-02-04,QX_LUM_3,13.50,swap, cover, red,REG\n" ++
        "5,2026-02-05,QX_LUM_0,14.50,blue,REG\n6,2026-02-06,QX_LUM_1,15.50,late, red,REG\n" ++
        "7,2026-02-07,QX_LUM_2,16.50,cover,REG\n8,2026-02-08,QX_LUM_3,17.50,red, blue,REG\n" ++
        "9,2026-02-09,QX_LUM_0,18.50,swap,REG\n10,2026-02-10,QX_LUM_1,10.50,blue, swap, late, red,REG\n";
    const v = try sniffed(steady, .{});
    try std.testing.expectEqual(@as(u8, ','), v.dialect.delimiter);
    try std.testing.expect(v.dialect.header);
    try std.testing.expectEqual(Confidence.low, v.confidence);
    // A header one name short of its rows is not half or twice them.
    const short = "ka_id|ka_memo\n1|red|3\n2|blue|4\n3|late|5\n4|swap|6\n";
    try std.testing.expectEqual(@as(u8, '|'), (try sniffed(short, .{})).dialect.delimiter);
}

test "a sample that is not UTF-8 is warned of, unless another encoding is given" {
    try std.testing.expect((try sniffed("id,name\n1,caf\xe9\n2,l\x92\x9cuvre\n", .{})).warnings.not_utf8);
    try std.testing.expect(!(try sniffed("id,name\n1,caf\xe9\n", .{ .utf8 = false })).warnings.not_utf8);
    try std.testing.expect(!(try sniffed("id,name\n1,café\n", .{})).warnings.not_utf8);
    // A window that stops inside a character is not a broken one.
    const cut = try sniff(std.testing.allocator, "id,name\n1,caf\xc3", false, .{});
    try std.testing.expect(!cut.warnings.not_utf8);
}

test "a quote that wraps every field wins, though a few of its fields break" {
    // Two values with a quote inside them, not doubled: those two records
    // break under '"', and reading every quote as data parses all of them.
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try buf.writer.writeAll("id, name, note\n");
    for (0..30) |i| try buf.writer.print("\"{d}\",\"n{d}\",\"{s}\"\n", .{ i, i, if (i == 5 or i == 9) "say \"hi\" now" else "plain" });
    const v = try sniffed(buf.written(), .{});
    try std.testing.expectEqual(@as(?u8, '"'), v.dialect.quote);
    try std.testing.expect(v.dialect.header);
    try std.testing.expect(v.confidence != .low);
}

test "ragged records are low confidence, not a wrong high" {
    const v = try sniffed("a,b\nc\nd,e,f\ng h,i\nj,k,l,m\n", .{});
    try std.testing.expect(v.confidence != .high);
}

test "a schema whose width the winner has keeps ragged rows from unsettling it" {
    const data = "id,name,amount\n1,apple,1.50\n,pear,2\n4,b\n";
    try std.testing.expectEqual(Confidence.low, (try sniffed(data, .{})).confidence);
    const v = try sniffed(data, .{ .schema = &.{ "id", "name", "amount" } });
    try std.testing.expectEqual(Confidence.medium, v.confidence);
    try std.testing.expect(v.dialect.header);
}

test "a header missing a schema column, or with an extra, is still a header" {
    const names: []const []const u8 = &.{ "id", "name", "amount" };
    try std.testing.expect((try sniffed("id,amount\nx,y\nu,v\n", .{ .schema = names })).dialect.header);
    try std.testing.expect((try sniffed("id,name,amount,note\nx,y,z,w\n", .{ .schema = names })).dialect.header);
    try std.testing.expect(!(try sniffed("a,b,c\nx,y,z\n", .{ .schema = names })).dialect.header);
}

test "a schema's names make row 1 a header, and its count settles the delimiter" {
    const names: []const []const u8 = &.{ "ID", " Name ", "amount" };
    const v = try sniffed("id,name,amount\nx,y,z\nu,v,w\n", .{ .schema = names });
    try std.testing.expect(v.dialect.header);
    // Without the schema, all strings: nothing says row 1 is a header.
    try std.testing.expect(!(try sniffed("id,name,amount\nx,y,z\nu,v,w\n", .{})).dialect.header);
}

test "looksTyped" {
    for ([_][]const u8{ "12", "-3", "1.5", "+0.25", "1e-05", "2.5E3", "true", "FALSE", "2026-10-29", "2026-10-29 12:30:00", "10/29/2026", "12:30" }) |v| {
        if (!looksTyped(v)) {
            std.debug.print("{s} should look typed\n", .{v});
            return error.TestUnexpectedResult;
        }
    }
    for ([_][]const u8{ "id", "e5", "1.2.3", "-", "12,50", "N/A", "2026 sales", "1-" }) |v| {
        if (looksTyped(v)) {
            std.debug.print("{s} should not look typed\n", .{v});
            return error.TestUnexpectedResult;
        }
    }
}
