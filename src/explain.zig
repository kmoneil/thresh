//! explain: a file said in plain words, for a reader who knows neither the
//! file nor thresh. What describe found (lib.Description) becomes a few
//! sentences: what is wrong, or that the file is fine; then what to notice;
//! then how it is written and what its columns hold. Each sentence is a
//! finding with a stable kind, so findings can be counted and grouped
//! across files whatever their wording, and the JSON carries describe's
//! whole document beside them (docs/REPORT.md, "An explanation").
//!
//! The result is the file's as it came, but for one thing: a row set aside
//! makes it a failure whatever --threshold allows, since in explain the
//! threshold decides the columns' types and not the result. Nothing here
//! reads a file: main.zig describes it first, and reread.zig reads it
//! again where its stop can be worked out. Read again, it is still the
//! file as it came: the stop is the summary and the result, and what the
//! read again found follows it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const dialect = @import("dialect.zig");
const lib = @import("lib.zig");
const Problem = @import("problem.zig").Problem;
const report = @import("report.zig");
const reread = @import("reread.zig");
const schema = @import("schema.zig");
const stats = @import("stats.zig");
const types = @import("types.zig");
const validate = @import("validate.zig");

/// What a finding says, by name, whatever the file and the wording.
/// docs/REPORT.md lists each; one added leaves format_version as it is.
pub const Kind = enum {
    /// The file could not be opened or read: code is the problem's.
    unreadable,
    /// The file stopped before its rows were read: code is the problem's.
    stopped,
    /// The file read again as its stop points, and why so; the findings
    /// after it are that read's: code is the stop's.
    read_again,
    /// Not read again: some of it is UTF-8 and some is not. Code is the
    /// stop's.
    encoding_mixed,
    /// Not read again: neither Windows-1252 nor Latin-1 reads every byte
    /// past ASCII as a character. Code is the stop's.
    encoding_unknown,
    /// Read, it fails as a whole (a column the schema has and the header
    /// does not, a last line cut off): code is the problem's.
    fails,
    /// How many rows were set aside, of how many.
    rows_set_aside,
    /// Rows set aside for one reason, or one column's values that do not
    /// fit: code is the reason's.
    set_aside,
    no_rows,
    no_header,
    header_repeated,
    extra_columns,
    not_utf8,
    utf16_invalid,
    mixed_newlines,
    quote_in_unquoted,
    dates_ambiguous,
    /// What inference said of the file: code is the problem's.
    note,
    written,
    columns,
    dates,
    digit_codes,
    key,
    one_value,
    empty_columns,

    /// How much it matters, the same for every finding of the kind.
    pub fn level(k: Kind) Level {
        return switch (k) {
            .unreadable, .stopped, .fails, .rows_set_aside, .set_aside => .problem,
            .read_again, .encoding_mixed, .encoding_unknown => .notice,
            .no_rows, .no_header, .header_repeated, .extra_columns, .not_utf8 => .notice,
            .utf16_invalid, .mixed_newlines, .quote_in_unquoted, .dates_ambiguous, .note => .notice,
            .written, .columns, .dates, .digit_codes, .key, .one_value, .empty_columns => .info,
        };
    }
};

/// How much a finding matters: a problem is why the file is not fine, a
/// notice is worth acting on, info says what the file is.
pub const Level = enum { problem, notice, info };

pub const Finding = struct {
    kind: Kind,
    level: Level,
    /// The problem's code, or the reason's, for the kinds that have one.
    code: ?[]const u8 = null,
    /// A sentence.
    text: []const u8,

    pub fn jsonStringify(f: Finding, s: *Stringify) Stringify.Error!void {
        try s.beginObject();
        try s.objectField("kind");
        try s.write(@tagName(f.kind));
        try s.objectField("level");
        try s.write(@tagName(f.level));
        if (f.code) |c| {
            try s.objectField("code");
            try s.write(c);
        }
        try s.objectField("text");
        try s.write(f.text);
        try s.endObject();
    }
};

pub const Explanation = struct {
    file: []const u8,
    /// As explain judges the file: describe's result, but fail when a row
    /// was set aside.
    result: report.Result,
    /// The sentence that says it: the first problem's, or that it is fine.
    summary: []const u8,
    /// Problems first, then notices, then info.
    findings: []const Finding,
    /// The finding summary is, which the text does not say twice.
    headline: ?usize = null,
    /// The file read again, when its stop was worked out so.
    again: ?ReadAgain = null,
};

/// The file read again as its stop pointed: with what, as explain judges
/// that read, and its description.
pub const ReadAgain = struct {
    with: reread.With,
    result: report.Result,
    description: lib.Description,
};

pub const Options = struct {
    /// What --day-first said, for dates that read either way.
    day_first: bool = false,
    /// How reread.zig worked the file's stop out, when it did.
    worked: ?reread.Worked = null,
};

/// What d says, in plain words; every string in a. Read again (o.worked),
/// the findings after the stop are the read again's.
pub fn of(a: Allocator, d: lib.Description, o: Options) Allocator.Error!Explanation {
    var b: Builder = .{ .a = a };
    const f = d.file;
    try b.problems(f);
    if (o.worked) |w| switch (w) {
        .encoding, .header => return b.readAgain(f, w, o),
        .mixed => |t| try b.mixed(f, t),
        .neither => |t| try b.neither(f, t),
    };
    if (f.read) |r| try b.setAside(f.outcome.rows, r);
    try b.notices(d, o);
    try b.written(d);
    if (f.read) |r| try b.columns(r.columns, d.inferred);
    return b.done(f);
}

/// The explanation as text: the file and its summary on a line, then
/// each other finding indented on its own.
pub fn writeText(w: *Io.Writer, e: Explanation) Io.Writer.Error!void {
    try w.print("{s}: {s}\n", .{ e.file, e.summary });
    for (e.findings, 0..) |f, i| {
        if (e.headline == i) continue;
        try w.print("  {s}\n", .{f.text});
    }
}

/// The explanation as JSON, with d, the description it says, as its
/// description field: indented, or compact on one line.
pub fn writeJson(w: *Io.Writer, e: Explanation, d: lib.Description, compact: bool) Stringify.Error!void {
    var s: Stringify = .{ .writer = w, .options = .{ .whitespace = if (compact) .minified else .indent_2 } };
    try s.beginObject();
    try s.objectField("format_version");
    try s.write(report.format_version);
    try s.objectField("file");
    try s.write(e.file);
    try s.objectField("result");
    try s.write(@tagName(e.result));
    try s.objectField("summary");
    try s.write(e.summary);
    try s.objectField("findings");
    try s.write(e.findings);
    try s.objectField("description");
    try s.write(d);
    if (e.again) |g| {
        try s.objectField("read_again");
        try s.write(g);
    }
    try s.endObject();
    try w.writeByte('\n');
}

/// The findings, as they are worked out.
const Builder = struct {
    a: Allocator,
    list: std.ArrayList(Finding) = .empty,

    fn put(b: *Builder, kind: Kind, code: ?[]const u8, text: []const u8) Allocator.Error!void {
        try b.list.append(b.a, .{ .kind = kind, .level = kind.level(), .code = code, .text = text });
    }

    fn add(b: *Builder, kind: Kind, code: ?[]const u8, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try b.put(kind, code, try std.fmt.allocPrint(b.a, fmt, args));
    }

    /// The explanation of f that the findings make.
    fn done(b: *Builder, f: report.File) Allocator.Error!Explanation {
        const headline = headlineOf(b.list.items);
        return .{
            .file = f.outcome.file,
            .result = resultOf(f),
            .summary = if (headline) |i| b.list.items[i].text else try fine(b.a, f.outcome.rows),
            .findings = b.list.items,
            .headline = headline,
        };
    }

    /// f read again (w): why so and what the read found, then the rest of
    /// what it found. The stop stays the summary and the result.
    fn readAgain(b: *Builder, f: report.File, w: reread.Worked, o: Options) Allocator.Error!Explanation {
        const g = w.again().?;
        const second = try of(b.a, asShown(w, g.description), .{ .day_first = o.day_first });
        var t: Io.Writer.Allocating = .init(b.a);
        writeAgain(&t.writer, w, second) catch return error.OutOfMemory;
        try b.put(.read_again, stopCode(f), t.written());
        for (second.findings, 0..) |x, i| if (second.headline != i) try b.list.append(b.a, x);
        var e = try b.done(f);
        e.again = .{ .with = g.with, .result = second.result, .description = g.description };
        return e;
    }

    /// Why a file not UTF-8 that is UTF-8 in part is not read again.
    fn mixed(b: *Builder, f: report.File, t: reread.Bytes) Allocator.Error!void {
        try b.add(.encoding_mixed, stopCode(f), "Some of it is UTF-8 ({d} character{s} past ASCII) and some is not ({d} byte{s}), as where files written two ways were joined, so it is not read again: as Windows-1252 (--encoding cp1252), each UTF-8 character would come out as two or three, é as Ã©.", .{ t.utf8, plural(t.utf8), t.lone, plural(t.lone) });
    }

    /// Why a file not UTF-8 that no encoding reads is not read again.
    fn neither(b: *Builder, f: report.File, t: reread.Bytes) Allocator.Error!void {
        const code = stopCode(f);
        const first = t.firstControl() orelse
            return b.put(.encoding_unknown, code, "Its bytes past ASCII are shaped as UTF-8, but some make no character, and Windows-1252 or Latin-1 would read them no better; it is not read again.");
        const n = t.controls();
        const are = if (n == 1) "is a control code" else "are control codes";
        try b.add(.encoding_unknown, code, "{d} of its bytes {s} in Windows-1252 and Latin-1 alike (0x{x:0>2}{s}), so neither reads it, and it is not read again.", .{ n, are, first, if (n == 1) "" else " among them" });
    }

    /// p's sentence after prefix, as a finding of its own with p's code:
    /// a capital first, unless it starts with a column's name.
    fn problem(b: *Builder, kind: Kind, comptime prefix: []const u8, p: Problem) Allocator.Error!void {
        const said = try std.fmt.allocPrint(b.a, prefix ++ "{f}", .{p});
        if (p != .columns_thin) said[0] = std.ascii.toUpper(said[0]);
        const end = said[said.len - 1];
        try b.put(kind, @tagName(p), if (end == '.' or end == '?') said else try std.mem.concat(b.a, u8, &.{ said, "." }));
    }

    /// What stops the file, or fails it as a whole.
    fn problems(b: *Builder, f: report.File) Allocator.Error!void {
        if (f.outcome.result == .@"error") {
            const p = f.outcome.problem orelse return;
            if (unreadable(p)) return b.problem(.unreadable, "Cannot be read: ", p);
            return b.problem(.stopped, stopped_prefix, p);
        }
        for (f.problems) |p| try b.problem(.fails, "", p);
    }

    /// How many rows were set aside and why, a sentence a reason: the
    /// rows set aside whole, then each column's values that do not fit.
    fn setAside(b: *Builder, rows: u64, r: report.Read) Allocator.Error!void {
        if (r.rows_rejected == 0) return;
        try b.rowsSetAside(r.rows_rejected, rows);
        var reasons: usize = 0;
        for (std.enums.values(types.Reason)) |reason| {
            const n = r.row_errors.get(reason);
            if (n == 0) continue;
            reasons += 1;
            if (reasons <= max_reasons) try b.wholeRows(reason, n, r);
        }
        for (r.columns) |c| {
            if (c.mismatches == 0) continue;
            reasons += 1;
            if (reasons <= max_reasons) try b.values(c);
        }
        if (reasons > max_reasons) try b.add(.set_aside, null, "And {d} more reasons rows were set aside; --json lists them.", .{reasons - max_reasons});
    }

    fn rowsSetAside(b: *Builder, n: u64, rows: u64) Allocator.Error!void {
        const k: Kind = .rows_set_aside;
        if (n >= rows and rows == 1) return b.add(k, null, "Its one row has a problem and was set aside.", .{});
        if (n >= rows) return b.add(k, null, "All {d} rows have a problem and were set aside.", .{rows});
        const rest = rows - n;
        const are = if (rest == 1) "is" else "are";
        if (n == 1) return b.add(k, null, "1 of {d} rows has a problem and was set aside; the other {d} {s} fine.", .{ rows, rest, are });
        return b.add(k, null, "{d} of {d} rows have a problem and were set aside; the other {d} {s} fine.", .{ n, rows, rest, are });
    }

    /// The n rows set aside whole for reason, and the first one's line
    /// when the report kept it.
    fn wholeRows(b: *Builder, reason: types.Reason, n: u64, r: report.Read) Allocator.Error!void {
        const what = if (reason == .ragged)
            try std.fmt.allocPrint(b.a, "a different number of fields from the {d} columns", .{r.columns.len})
        else
            reason.text();
        const code = @tagName(reason);
        const line = firstLine(r.rejected_lines, reason) orelse
            return b.add(.set_aside, code, "{d} row{s}: {s}.", .{ n, plural(n), what });
        if (n == 1) return b.add(.set_aside, code, "Line {d}: {s}.", .{ line, what });
        return b.add(.set_aside, code, "{d} rows: {s}, the first on line {d}.", .{ n, what, line });
    }

    /// Column c's values that do not fit, by its first sample.
    fn values(b: *Builder, c: report.Column) Allocator.Error!void {
        const name: Name = .{ .s = c.name };
        if (c.samples.len == 0) return b.add(.set_aside, null, "{f}: {d} value{s} that do not fit.", .{ name, c.mismatches, plural(c.mismatches) });
        const s = c.samples[0];
        const code = @tagName(s.code);
        if (c.mismatches == 1) return b.add(.set_aside, code, "{f}, line {d}: \"{s}\", {s}.", .{ name, s.row, s.value, valueReason(s.code) });
        return b.add(.set_aside, code, "{f}: {d} values set aside, the first on line {d}: \"{s}\", {s}.", .{ name, c.mismatches, s.row, s.value, valueReason(s.code) });
    }

    /// What to notice: no rows, no names, the header again, the bytes, and
    /// what inference said.
    fn notices(b: *Builder, d: lib.Description, o: Options) Allocator.Error!void {
        const f = d.file;
        if (f.read) |r| {
            try b.layout(f, r, d.inferred);
            try b.ambiguous(r.columns, o);
        }
        try b.warnings(f.warnings);
        for (d.notes) |p| switch (p) {
            // Said already: the rows set aside, and the header again.
            .rows_wider, .rows_short, .rows_bad_quote, .header_repeated => {},
            else => try b.problem(.note, "", p),
        };
    }

    /// The rows as the file lays them out: none, no header, the header
    /// again.
    fn layout(b: *Builder, f: report.File, r: report.Read, inferred: bool) Allocator.Error!void {
        const header = if (f.verdict) |v| v.dialect.header else true;
        if (f.outcome.rows == 0) try b.put(.no_rows, null, if (header) "No rows: a header and nothing under it." else "No rows: the file is empty.");
        if (!header) try b.noHeader(r.columns.len, inferred);
        const repeats = r.repeated_header_rows;
        if (repeats.len == 1) try b.add(.header_repeated, null, "The header row comes again on line {d}, as where files were joined end to end; it is skipped.", .{repeats[0]});
        if (repeats.len > 1) try b.add(.header_repeated, null, "The header row comes again {d}{s} times, first on line {d}, as where files were joined end to end; they are skipped.", .{ repeats.len, if (repeats.len >= validate.max_samples) " or more" else "", repeats[0] });
    }

    fn noHeader(b: *Builder, n: usize, inferred: bool) Allocator.Error!void {
        const k: Kind = .no_header;
        if (!inferred) return b.put(k, null, "No header row: the columns are the schema's, in order.");
        if (n == 1) return b.put(k, null, "No header row, so the column has no name; a loader needs one (thresh calls it column1).");
        return b.add(k, null, "No header row, so the {d} columns have no names; a loader needs them (thresh calls them column1 to column{d}).", .{ n, n });
    }

    /// Each date column whose values read either day or month first.
    fn ambiguous(b: *Builder, cols: []const report.Column, o: Options) Allocator.Error!void {
        const read = if (o.day_first) "day first, as --day-first asks" else "month first (--day-first reads them day first)";
        for (cols) |c| {
            const n = c.ambiguous orelse continue;
            if (n == 0) continue;
            try b.add(.dates_ambiguous, null, "{f}: {d} date{s} read either day first or month first; thresh read them {s}.", .{ Name{ .s = c.name }, n, plural(n), read });
        }
    }

    fn warnings(b: *Builder, w: report.Warnings) Allocator.Error!void {
        const d = w.dialect;
        if (d.not_utf8) try b.put(.not_utf8, null, "Some of its bytes are not UTF-8: a Windows or Latin-1 export, most likely, which --encoding cp1252 or latin1 reads.");
        if (d.utf16_invalid) try b.put(.utf16_invalid, null, "Some of its UTF-16 makes no character; those places read as \u{FFFD}.");
        if (d.mixed_newlines) try b.put(.mixed_newlines, null, "Its lines end in more than one way (Windows and Unix line ends mixed).");
        if (d.quote_in_unquoted) try b.put(.quote_in_unquoted, null, "A quote mark sits inside a field that is not quoted; it is read as part of the value.");
        if (w.extra_columns) try b.put(.extra_columns, null, "The header has columns the schema does not; they are left out.");
    }

    /// How the file is written, when the sniffer settled it.
    fn written(b: *Builder, d: lib.Description) Allocator.Error!void {
        const v = d.file.verdict orelse return;
        if (d.file.outcome.problem) |p| if (p == .dialect_unsettled) return;
        var w: Io.Writer.Allocating = .init(b.a);
        writeDialect(&w.writer, v.dialect, d.encoding, v.warnings.utf8_bom) catch return error.OutOfMemory;
        try b.put(.written, null, w.written());
    }

    /// What the columns hold: their types, their dates, and the columns
    /// that stand out.
    fn columns(b: *Builder, cols: []const report.Column, inferred: bool) Allocator.Error!void {
        if (cols.len == 0) return;
        var w: Io.Writer.Allocating = .init(b.a);
        writeTypes(&w.writer, cols) catch return error.OutOfMemory;
        try b.put(.columns, null, w.written());
        try b.dates(cols);
        if (inferred) try b.digitCodes(cols);
        try b.key(cols);
        try b.oneValue(cols);
        const empty = try b.matching(cols, isEmpty);
        if (empty.len > 0) try b.add(.empty_columns, null, "{f} {s} empty in every row.", .{ Names{ .names = empty }, verb(empty, "is", "are") });
    }

    /// The date, timestamp and time columns, each with how it is written.
    fn dates(b: *Builder, cols: []const report.Column) Allocator.Error!void {
        var w: Io.Writer.Allocating = .init(b.a);
        var n: usize = 0;
        for (cols) |c| {
            if (c.type != .date and c.type != .timestamp and c.type != .time) continue;
            n += 1;
            writeDate(&w.writer, c, n) catch return error.OutOfMemory;
        }
        if (n == 0) return;
        w.writer.writeByte('.') catch return error.OutOfMemory;
        try b.put(.dates, null, w.written());
    }

    /// Text columns of digits alone, kept as text: a leading zero, or more
    /// digits than a number holds.
    fn digitCodes(b: *Builder, cols: []const report.Column) Allocator.Error!void {
        const padded = try b.matching(cols, zeroPadded);
        if (padded.len > 0) try b.add(.digit_codes, null, "{f} {s} digits only, kept as text so leading zeros stay: a code, not a number.", .{ Names{ .names = padded }, verb(padded, "holds", "hold") });
        const long = try b.matching(cols, tooLong);
        if (long.len > 0) try b.add(.digit_codes, null, "{f} {s} more digits than a number keeps, so {s} kept as text.", .{ Names{ .names = long }, verb(long, "holds", "hold"), verb(long, "it is", "they are") });
    }

    /// The first column different in every row, and any others.
    fn key(b: *Builder, cols: []const report.Column) Allocator.Error!void {
        const names = try b.matching(cols, isKey);
        if (names.len == 0) return;
        const first: Name = .{ .s = names[0] };
        if (names.len == 1) return b.add(.key, null, "{f} is different in every row: likely the key.", .{first});
        return b.add(.key, null, "{f} is different in every row: likely the key (so {s} {f}).", .{ first, verb(names[1..], "is", "are"), Names{ .names = names[1..] } });
    }

    /// The columns that hold one value, and when it is one, the value.
    fn oneValue(b: *Builder, cols: []const report.Column) Allocator.Error!void {
        const names = try b.matching(cols, isOneValue);
        if (names.len == 0) return;
        if (names.len == 1) for (cols) |c| {
            if (c.name.ptr != names[0].ptr or c.stats.?.top.len == 0) continue;
            return b.add(.one_value, null, "{f} holds one value throughout: \"{s}\".", .{ Name{ .s = c.name }, c.stats.?.top[0].value });
        };
        try b.add(.one_value, null, "{f} {s} one value throughout.", .{ Names{ .names = names }, verb(names, "holds", "each hold") });
    }

    /// The names of the columns that are so, in their order.
    fn matching(b: *Builder, cols: []const report.Column, is: *const fn (report.Column) bool) Allocator.Error![]const []const u8 {
        var names: std.ArrayList([]const u8) = .empty;
        for (cols) |c| if (is(c)) try names.append(b.a, c.name);
        return names.items;
    }
};

/// one for a single name, more for several.
fn verb(names: []const []const u8, one: []const u8, more: []const u8) []const u8 {
    return if (names.len == 1) one else more;
}

/// The most reasons the text gives rows set aside; --json has every one.
const max_reasons = 5;

/// How a stop's finding starts.
const stopped_prefix = "Stopped: ";

/// The code of f's problem, when it has one.
fn stopCode(f: report.File) ?[]const u8 {
    const p = f.outcome.problem orelse return null;
    return @tagName(p);
}

/// d, read again as w did, as the text says it: a header of another width
/// read as a row is still the file's header, so the file is said to have
/// one, and its columns are not said to want names it has.
fn asShown(w: reread.Worked, d: lib.Description) lib.Description {
    var s = d;
    if (w == .header) if (s.file.verdict) |*v| {
        v.dialect.header = true;
    };
    return s;
}

/// Why the file was read again so, and what the read found.
fn writeAgain(w: *Io.Writer, worked: reread.Worked, second: Explanation) Io.Writer.Error!void {
    const g = worked.again().?;
    switch (worked) {
        .encoding => |r| {
            try writeBytes(w, r.bytes);
            try w.print(" Read as {s} ({f})", .{ encodingName(@tagName(r.again.with.encoding)), g.with });
        },
        .header => try w.print("Read with row 1 as data ({f}), its names left out", .{g.with}),
        .mixed, .neither => unreachable,
    }
    const h = second.headline orelse {
        const rows = g.description.file.outcome.rows;
        return w.print(", it is fine: {d} row{s}, none set aside.", .{ rows, plural(rows) });
    };
    const x = second.findings[h];
    if (x.kind == .stopped) return w.print(", it stops too: {s}", .{x.text[stopped_prefix.len..]});
    try w.print(": {s}", .{x.text});
}

/// "Its 16 bytes past ASCII are each a letter or mark in Windows-1252 (’
/// and é); Latin-1 reads 8 of them as control codes."
fn writeBytes(w: *Io.Writer, t: reread.Bytes) Io.Writer.Error!void {
    const n = t.high();
    if (n == 1) try w.writeAll("Its one byte past ASCII is a letter or mark in Windows-1252") else try w.print("Its {d} bytes past ASCII are each a letter or mark in Windows-1252", .{n});
    const c1 = t.c1();
    if (c1 == 0) try w.writeAll(" and Latin-1 alike");
    var buf: [3]u8 = undefined;
    const common = t.common(&buf);
    if (common.len > 0) try w.print(" ({f}{s})", .{ Chars{ .bytes = common }, if (t.distinct() > common.len) " most often" else "" });
    if (c1 > 0 and n == 1) try w.writeAll("; Latin-1 reads it as a control code");
    if (c1 > 0 and n > 1) try w.print("; Latin-1 reads {d} of them as control codes", .{c1});
    try w.writeByte('.');
}

/// Bytes past ASCII as Windows-1252 reads them, listed: "’, é and –".
const Chars = struct {
    bytes: []const u8,

    pub fn format(c: Chars, w: *Io.Writer) Io.Writer.Error!void {
        for (c.bytes, 0..) |b, i| {
            if (i > 0) try w.writeAll(if (i + 1 == c.bytes.len) " and " else ", ");
            try w.print("{u}", .{types.codepoint(.cp1252, b)});
        }
    }
};

/// A problem that means the file could not be opened or read, as against
/// one that stopped it once read.
fn unreadable(p: Problem) bool {
    return switch (p) {
        .no_such_file, .permission_denied, .is_directory, .binary, .utf16_untranscoded => true,
        .out_of_memory, .output_closed, .io_error, .interrupted, .not_reached => true,
        else => false,
    };
}

fn resultOf(f: report.File) report.Result {
    const r = f.read orelse return f.outcome.result;
    if (f.outcome.result == .pass and r.rows_rejected > 0) return .fail;
    return f.outcome.result;
}

/// The finding the summary says: the first problem, or a file with no rows.
fn headlineOf(findings: []const Finding) ?usize {
    for (findings, 0..) |f, i| if (f.level == .problem) return i;
    for (findings, 0..) |f, i| if (f.kind == .no_rows) return i;
    return null;
}

fn fine(a: Allocator, rows: u64) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "Fine: {d} row{s}, none set aside.", .{ rows, plural(rows) });
}

fn plural(n: u64) []const u8 {
    return if (n == 1) "" else "s";
}

/// The line of the first row the report kept that was set aside whole
/// for reason.
fn firstLine(lines: []const report.Line, reason: types.Reason) ?u64 {
    for (lines) |l| {
        for (l.errors) |e| if (e.column == null and e.code == reason) return l.row;
    }
    return null;
}

/// Why a value does not fit, in plain words where the reason's own name
/// is a type's.
fn valueReason(r: types.Reason) []const u8 {
    return switch (r) {
        .null_value => "empty, and the schema needs a value",
        .not_bool => "not a yes/no",
        .not_int => "not a whole number",
        .int_overflow => "too big for a whole number",
        .not_float => "not a number",
        else => r.text(),
    };
}

/// Column names as a list: "a", "a and b", "a, b and c", and past five
/// "a, b, c, d, e and 3 more".
const Names = struct {
    names: []const []const u8,

    const shown = 5;

    pub fn format(n: Names, w: *Io.Writer) Io.Writer.Error!void {
        const total = n.names.len;
        const named = if (total > shown) shown else total;
        for (n.names[0..named], 0..) |name, i| {
            const last = i + 1 == named and total == named;
            if (i > 0) try w.writeAll(if (last) " and " else ", ");
            try w.print("{f}", .{Name{ .s = name }});
        }
        if (total > named) try w.print(" and {d} more", .{total - named});
    }
};

/// A column's name as the text says it: in quotes when a space or a
/// punctuation mark in it would run it into the words around it.
const Name = struct {
    s: []const u8,

    pub fn format(n: Name, w: *Io.Writer) Io.Writer.Error!void {
        for (n.s) |c| if (!bare(c)) return w.print("'{s}'", .{n.s});
        if (n.s.len == 0) return w.writeAll("''");
        try w.writeAll(n.s);
    }

    /// A byte a name can hold and still read as one word: letters, digits,
    /// _ - . and the bytes of a character past ASCII.
    fn bare(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.' or c >= 0x80;
    }
};

/// "Comma-separated, with a header row; Unix line ends (LF); UTF-8."
fn writeDialect(w: *Io.Writer, d: dialect.Dialect, encoding: []const u8, bom: bool) Io.Writer.Error!void {
    try writeSeparator(w, d.delimiter);
    try w.writeAll(if (d.header) ", with a header row" else ", with no header row");
    if (d.quote) |q| {
        if (q != '"') try w.print(", fields quoted with {c}", .{q});
    } else try w.writeAll(", no quoting");
    if (d.escape == .backslash) try w.writeAll(", a backslash before a quote inside one");
    try w.writeAll(switch (d.newline) {
        .lf => "; Unix line ends (LF); ",
        .crlf => "; Windows line ends (CRLF); ",
        .cr => "; old Mac line ends (CR); ",
    });
    try w.writeAll(encodingName(encoding));
    if (bom) try w.writeAll(" with a byte order mark");
    try w.writeByte('.');
}

fn writeSeparator(w: *Io.Writer, c: u8) Io.Writer.Error!void {
    const name: ?[]const u8 = switch (c) {
        ',' => "Comma",
        '\t' => "Tab",
        '|' => "Pipe",
        ';' => "Semicolon",
        ' ' => "Space",
        ':' => "Colon",
        else => null,
    };
    if (name) |n| return w.print("{s}-separated", .{n});
    if (std.ascii.isPrint(c)) return w.print("Separated by {c}", .{c});
    try w.print("Separated by the byte \\x{x:0>2}", .{c});
}

fn encodingName(e: []const u8) []const u8 {
    const names = [_][2][]const u8{
        .{ "utf8", "UTF-8" },
        .{ "utf16le", "UTF-16, little-endian" },
        .{ "utf16be", "UTF-16, big-endian" },
        .{ "cp1252", "Windows-1252" },
        .{ "latin1", "Latin-1" },
    };
    for (names) |n| if (std.mem.eql(u8, n[0], e)) return n[1];
    return e;
}

/// The types in the order a reader expects them, numbers first.
const type_order = [_]schema.Type{ .int64, .decimal, .float64, .bool, .date, .timestamp, .time, .@"enum", .string, .binary };

/// "7 columns: 2 whole numbers, 1 decimal, 1 yes/no, 1 date and 2 text.",
/// or of one type, "4 columns, all text."
fn writeTypes(w: *Io.Writer, cols: []const report.Column) Io.Writer.Error!void {
    var counts: std.EnumArray(schema.Type, usize) = .initFill(0);
    for (cols) |c| counts.getPtr(c.type).* += 1;
    var kinds: usize = 0;
    for (type_order) |t| kinds += @intFromBool(counts.get(t) > 0);
    if (cols.len == 1) return w.print("1 column: {s}.", .{typeWords(cols[0].type, true)});
    if (kinds == 1) return w.print("{d} columns, all {s}.", .{ cols.len, typeWords(cols[0].type, false) });
    try w.print("{d} columns: ", .{cols.len});
    var i: usize = 0;
    for (type_order) |t| {
        const n = counts.get(t);
        if (n == 0) continue;
        if (i > 0) try w.writeAll(if (i + 1 == kinds) " and " else ", ");
        try w.print("{d} {s}", .{ n, typeWords(t, n == 1) });
        i += 1;
    }
    try w.writeByte('.');
}

/// Each type as the text says it: of one column, and of several.
const type_words: std.EnumArray(schema.Type, [2][]const u8) = .init(.{
    .bool = .{ "yes/no", "yes/no" },
    .int64 = .{ "whole number", "whole numbers" },
    .float64 = .{ "number", "numbers" },
    .decimal = .{ "decimal", "decimals" },
    .date = .{ "date", "dates" },
    .timestamp = .{ "date and time", "dates and times" },
    .time = .{ "time", "times" },
    .string = .{ "text", "text" },
    .@"enum" = .{ "from a list", "from a list" },
    .binary = .{ "binary", "binary" },
});

fn typeWords(t: schema.Type, one: bool) []const u8 {
    return type_words.get(t)[@intFromBool(!one)];
}

/// "Dates: picked_on as YYYY-MM-DD", the nth date column of the sentence.
fn writeDate(w: *Io.Writer, c: report.Column, nth: usize) Io.Writer.Error!void {
    try w.writeAll(if (nth == 1) "Dates: " else ", ");
    try w.print("{f}", .{Name{ .s = c.name }});
    const format = c.format orelse return w.writeAll(" in more than one way");
    try w.writeAll(" as ");
    try writePicture(w, format);
    if (dayMonth(format)) |order| try w.print(" ({s} first)", .{order});
}

/// A strftime format as a person reads one: %m/%d/%Y is MM/DD/YYYY.
fn writePicture(w: *Io.Writer, format: []const u8) Io.Writer.Error!void {
    var i: usize = 0;
    while (i < format.len) : (i += 1) {
        if (format[i] != '%' or i + 1 == format.len) {
            try w.writeByte(format[i]);
            continue;
        }
        i += 1;
        try w.writeAll(directive(format[i]) orelse format[i - 1 .. i + 1]);
    }
}

/// Each strftime directive dateparsa writes, as a reader sees its field.
const directives = [_]struct { u8, []const u8 }{
    .{ 'Y', "YYYY" }, .{ 'G', "YYYY" },   .{ 'y', "YY" },   .{ 'm', "MM" },      .{ 'd', "DD" },  .{ 'e', "D" },
    .{ 'b', "Mon" },  .{ 'B', "Month" },  .{ 'a', "Day" },  .{ 'A', "Weekday" }, .{ 'j', "DDD" }, .{ 'V', "WW" },
    .{ 'u', "N" },    .{ 'H', "hh" },     .{ 'I', "hh" },   .{ 'M', "mm" },      .{ 'S', "ss" },  .{ 'f', "fff" },
    .{ 'p', "AM" },   .{ 'z', "+hh:mm" }, .{ 'Z', "zone" }, .{ '%', "%" },
};

fn directive(c: u8) ?[]const u8 {
    for (directives) |d| if (d[0] == c) return d[1];
    return null;
}

/// Which of day and month a numeric date's format puts first, when the
/// year does not come first: what a reader of 03/04 needs told.
fn dayMonth(format: []const u8) ?[]const u8 {
    const month = std.mem.find(u8, format, "%m") orelse return null;
    const day = std.mem.find(u8, format, "%d") orelse std.mem.find(u8, format, "%e") orelse return null;
    if (yearAt(format)) |year| if (year < @min(day, month)) return null;
    return if (day < month) "day" else "month";
}

fn yearAt(format: []const u8) ?usize {
    return std.mem.find(u8, format, "%Y") orelse std.mem.find(u8, format, "%y");
}

/// Statistics over every value, not a sample, with distinct counted
/// exactly: what a claim about every row needs.
fn exact(c: report.Column) ?stats.Summary {
    const st = c.stats orelse return null;
    if (st.sampled != null or st.distinct_at_least == true) return null;
    return st;
}

fn isKey(c: report.Column) bool {
    if (c.type != .int64 and c.type != .string) return false;
    const st = exact(c) orelse return false;
    return st.empty == 0 and st.values >= 2 and st.distinct == st.values;
}

fn isOneValue(c: report.Column) bool {
    const st = exact(c) orelse return false;
    return st.values >= 2 and st.distinct == 1;
}

fn isEmpty(c: report.Column) bool {
    const st = c.stats orelse return false;
    return st.values == 0 and st.empty > 0;
}

/// A text column whose every value is digits: kept as text by inference
/// for a leading zero, or for more digits than a decimal holds.
fn digitsOnly(c: report.Column) bool {
    if (c.type != .string) return false;
    const st = c.stats orelse return false;
    if (st.sampled != null or st.shapes_estimated == true) return false;
    return st.values > 0 and st.shapes.len == 1 and std.mem.eql(u8, st.shapes[0].shape, "9");
}

/// The most digits a decimal holds: a value of digits alone longer than
/// that is text for its length, not for a leading zero.
const decimal_digits = 38;

fn zeroPadded(c: report.Column) bool {
    return digitsOnly(c) and c.stats.?.length.?.max <= decimal_digits;
}

fn tooLong(c: report.Column) bool {
    return digitsOnly(c) and c.stats.?.length.?.max > decimal_digits;
}

const testing = std.testing;

/// The explanation of the file at path, read as main.zig reads it:
/// described, and read again where its stop can be worked out.
fn explained(a: Allocator, path: []const u8, o: lib.Options) !struct { Explanation, lib.Description } {
    const env: lib.Env = .{ .io = testing.io, .gpa = testing.allocator };
    const d = try lib.describe(env, a, path, null, o);
    const worked = try reread.of(env, a, .{ .path = path, .options = o }, d);
    return .{ try of(a, d, .{ .day_first = o.day_first, .worked = worked }), d };
}

fn expectFinding(e: Explanation, kind: Kind, text: []const u8) !void {
    for (e.findings) |f| if (f.kind == kind) {
        if (std.mem.eql(u8, f.text, text)) return;
        std.debug.print("{t}: \"{s}\", not \"{s}\"\n", .{ kind, f.text, text });
        return error.TestUnexpectedResult;
    };
    std.debug.print("no {t} finding\n", .{kind});
    return error.TestUnexpectedResult;
}

fn hasKind(e: Explanation, kind: Kind) bool {
    for (e.findings) |f| if (f.kind == kind) return true;
    return false;
}

test "a clean file: fine, how it is written, its columns, its key" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const e, _ = try explained(arena.allocator(), "examples/data/harvest.csv", .{});
    try testing.expectEqual(report.Result.pass, e.result);
    try testing.expectEqualStrings("Fine: 40 rows, none set aside.", e.summary);
    try testing.expectEqual(@as(?usize, null), e.headline);
    try expectFinding(e, .written, "Comma-separated, with a header row; Unix line ends (LF); UTF-8.");
    try expectFinding(e, .columns, "7 columns: 1 whole number, 1 decimal, 1 yes/no, 1 date and 3 text.");
    try expectFinding(e, .dates, "Dates: picked_on as YYYY-MM-DD.");
    try expectFinding(e, .key, "lug_id is different in every row: likely the key.");
    for (e.findings) |f| try testing.expectEqual(Level.info, f.level);
}

test "rows set aside: how many, why, and the file fails" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e, const d = try explained(a, "examples/data/harvest_dirty.csv", .{});
    try testing.expectEqual(report.Result.fail, e.result);
    try testing.expectEqualStrings("1 of 30 rows has a problem and was set aside; the other 29 are fine.", e.summary);
    try expectFinding(e, .set_aside, "Line 22: a different number of fields from the 7 columns.");
    try testing.expectEqualStrings("ragged", e.findings[1].code.?);
    // What --threshold allows decides the types; any row set aside is
    // still a problem, though describe calls the file a pass.
    const t, const td = try explained(a, "examples/data/harvest_dirty.csv", .{ .threshold = 0.9 });
    try testing.expectEqual(report.Result.pass, td.file.outcome.result);
    try testing.expectEqual(report.Result.fail, t.result);
    try testing.expectEqualStrings("4 of 30 rows have a problem and were set aside; the other 26 are fine.", t.summary);
    try expectFinding(t, .set_aside, "Line 22: a different number of fields from the 7 columns.");
    try testing.expect(d.file.read.?.rows_rejected == 1);
}

test "a value that does not fit, one column at a time" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e, _ = try explained(a, "examples/data/harvest_dirty.csv", .{ .threshold = 0.9 });
    var said: std.ArrayList([]const u8) = .empty;
    for (e.findings) |f| if (f.kind == .set_aside) try said.append(a, f.text);
    try testing.expectEqual(@as(usize, 4), said.items.len);
    try testing.expect(std.mem.startsWith(u8, said.items[1], "picked_on, line 9: \""));
    try testing.expect(std.mem.endsWith(u8, said.items[2], "\", not a decimal."));
    try testing.expect(std.mem.endsWith(u8, said.items[3], "\", not a yes/no."));
}

test "files that stop, or cannot be read, say why in their summary" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const u8, Kind, []const u8 }{
        .{ "examples/data/header_short.csv", .stopped, "header_width" },
        .{ "examples/data/bins.txt", .stopped, "quote_is_data" },
        .{ "examples/data/windows.csv", .stopped, "column_not_utf8" },
        .{ "examples/data/remarks.csv", .stopped, "dialect_unsettled" },
        .{ "examples/data/none.csv", .unreadable, "no_such_file" },
    };
    for (cases) |c| {
        const e, _ = try explained(a, c[0], .{});
        try testing.expectEqual(report.Result.@"error", e.result);
        const head = e.findings[e.headline.?];
        try testing.expectEqual(c[1], head.kind);
        try testing.expectEqualStrings(c[2], head.code.?);
        try testing.expectEqualStrings(head.text, e.summary);
        try testing.expect(std.mem.startsWith(u8, e.summary, if (c[1] == .stopped) "Stopped: " else "Cannot be read: "));
        // An unsettled dialect is not said as if it were settled.
        if (std.mem.eql(u8, c[2], "dialect_unsettled")) try testing.expect(!hasKind(e, .written));
    }
}

test "a file not UTF-8, read again as Windows-1252: the stop, then what the read found" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e, const d = try explained(a, "examples/data/windows.csv", .{});
    try testing.expectEqual(report.Result.@"error", e.result);
    try testing.expectEqualStrings("Stopped: column 'remark' is not UTF-8 (row 1); read the file with --encoding cp1252 (Windows) or latin1.", e.summary);
    try testing.expectEqual(Kind.read_again, e.findings[1].kind);
    try testing.expectEqualStrings("column_not_utf8", e.findings[1].code.?);
    try testing.expectEqualStrings("Its 16 bytes past ASCII are each a letter or mark in Windows-1252 (’ and é); Latin-1 reads 8 of them as control codes. Read as Windows-1252 (--encoding cp1252), it is fine: 30 rows, none set aside.", e.findings[1].text);
    // What follows is the read again's.
    try expectFinding(e, .written, "Comma-separated, with a header row; Windows line ends (CRLF); Windows-1252.");
    try expectFinding(e, .key, "lug_id is different in every row: likely the key.");
    try testing.expectEqual(report.Result.pass, e.again.?.result);
    // The JSON: the first description, then the read again.
    var w: Io.Writer.Allocating = .init(a);
    try writeJson(&w.writer, e, d, true);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, w.written(), .{});
    try testing.expectEqualStrings("utf8", v.object.get("description").?.object.get("encoding").?.string);
    const again = v.object.get("read_again").?.object;
    try testing.expectEqualStrings("cp1252", again.get("with").?.object.get("encoding").?.string);
    try testing.expectEqualStrings("pass", again.get("result").?.string);
    try testing.expectEqualStrings("cp1252", again.get("description").?.object.get("encoding").?.string);
}

test "a header of another width, read again with row 1 as data: the types from the rows" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e, const d = try explained(a, "examples/data/header_short.csv", .{});
    try testing.expectEqual(report.Result.@"error", e.result);
    try testing.expect(std.mem.startsWith(u8, e.summary, "Stopped: row 1 is a header of 3 names over rows of 4 fields"));
    try expectFinding(e, .read_again, "Read with row 1 as data (--header no), its names left out: 1 of 31 rows has a problem and was set aside; the other 30 are fine.");
    try testing.expectEqualStrings("header_width", e.findings[1].code.?);
    try expectFinding(e, .set_aside, "Line 1: a different number of fields from the 4 columns.");
    // The file has a header row, if not one that fits: it is not said to
    // want names.
    try expectFinding(e, .written, "Pipe-separated, with a header row; Unix line ends (LF); UTF-8.");
    try testing.expect(!hasKind(e, .no_header));
    try expectFinding(e, .columns, "4 columns: 1 whole number, 1 decimal, 1 date and 1 text.");
    try testing.expectEqual(report.Result.fail, e.again.?.result);
    // The JSON's read again is as read: no header.
    var w: Io.Writer.Allocating = .init(a);
    try writeJson(&w.writer, e, d, true);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, w.written(), .{});
    const again = v.object.get("read_again").?.object;
    try testing.expectEqualStrings("no", again.get("with").?.object.get("header").?.string);
    try testing.expect(!again.get("description").?.object.get("dialect").?.object.get("header").?.bool);
}

/// The path of a file holding data, made in tmp.
fn tmpFile(a: Allocator, tmp: testing.TmpDir, name: []const u8, data: []const u8) ![]const u8 {
    try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = data });
    return std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
}

test "not UTF-8: in part, in no encoding, or read again with a row set aside" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // UTF-8's e acute, then Windows-1252's.
    const mixed, _ = try explained(a, try tmpFile(a, tmp, "mixed.csv", "id,name\n1,caf\xc3\xa9\n2,caf\xe9\n"), .{});
    try testing.expectEqual(@as(?ReadAgain, null), mixed.again);
    try testing.expect(std.mem.startsWith(u8, mixed.findings[1].text, "Some of it is UTF-8 (1 character past ASCII) and some is not (1 byte), as where files"));
    try testing.expectEqual(Kind.encoding_mixed, mixed.findings[1].kind);
    // 0x81 is a control code in both.
    const odd, _ = try explained(a, try tmpFile(a, tmp, "odd.csv", "id,name\n1,a\x81b\n2,caf\xe9\n"), .{});
    try expectFinding(odd, .encoding_unknown, "1 of its bytes is a control code in Windows-1252 and Latin-1 alike (0x81), so neither reads it, and it is not read again.");
    // Read again, a row is a field short: the stop, then the row. Enough
    // rows for the dialect to settle.
    var data: Io.Writer.Allocating = .init(a);
    try data.writer.writeAll("id,name\n");
    for (1..21) |i| if (i == 7) try data.writer.writeAll("7\n") else try data.writer.print("{d},caf\xe9 {d}\n", .{ i, i });
    const short, _ = try explained(a, try tmpFile(a, tmp, "short.csv", data.written()), .{});
    try testing.expectEqual(report.Result.@"error", short.result);
    try testing.expectEqualStrings("Its 19 bytes past ASCII are each a letter or mark in Windows-1252 and Latin-1 alike (é). Read as Windows-1252 (--encoding cp1252): 1 of 20 rows has a problem and was set aside; the other 19 are fine.", short.findings[1].text);
    try expectFinding(short, .set_aside, "Line 8: a different number of fields from the 2 columns.");
    try testing.expectEqual(report.Result.fail, short.again.?.result);
}

test "what to notice: no header, the header again, no rows" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nh, _ = try explained(a, "test/cli/noheader.csv", .{});
    try testing.expectEqual(report.Result.pass, nh.result);
    try expectFinding(nh, .no_header, "No header row, so the 3 columns have no names; a loader needs them (thresh calls them column1 to column3).");
    try expectFinding(nh, .written, "Comma-separated, with no header row; Unix line ends (LF); UTF-8.");
    const joined, _ = try explained(a, "examples/data/joined.csv", .{});
    try testing.expect(hasKind(joined, .header_repeated));
    const empty, _ = try explained(a, "examples/data/empty_extract.txt", .{});
    try testing.expectEqual(report.Result.pass, empty.result);
    try testing.expectEqualStrings("No rows: a header and nothing under it.", empty.summary);
}

test "columns that stand out: one value, empty, digits kept as text" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var data: Io.Writer.Allocating = .init(a);
    try data.writer.writeAll("crate,bay,grade,tag,note\n");
    for (0..20) |i| try data.writer.print("{d},0{d},A,{d}2345678901234567890123456789012345678901,\n", .{ i + 1, i % 9 + 1, i + 1 });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "crates.csv", .data = data.written() });
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/crates.csv", .{tmp.sub_path});
    const e, _ = try explained(a, path, .{});
    try expectFinding(e, .one_value, "grade holds one value throughout: \"A\".");
    try expectFinding(e, .empty_columns, "note is empty in every row.");
    try expectFinding(e, .key, "crate is different in every row: likely the key (so is tag).");
    var codes: usize = 0;
    for (e.findings) |f| if (f.kind == .digit_codes) {
        codes += 1;
        try testing.expect(std.mem.startsWith(u8, f.text, if (codes == 1) "bay holds digits only" else "tag holds more digits"));
    };
    try testing.expectEqual(@as(usize, 2), codes);
}

test "date pictures and their order" {
    var buf: [64]u8 = undefined;
    const cases = [_][3][]const u8{
        .{ "%Y-%m-%d", "YYYY-MM-DD", "" },
        .{ "%m/%d/%Y %H:%M:%S", "MM/DD/YYYY hh:mm:ss", "month" },
        .{ "%d.%m.%y", "DD.MM.YY", "day" },
        .{ "%e %b %Y", "D Mon YYYY", "" },
        .{ "100%% %q", "100% %q", "" },
    };
    for (cases) |c| {
        var w: Io.Writer = .fixed(&buf);
        try writePicture(&w, c[0]);
        try testing.expectEqualStrings(c[1], w.buffered());
        try testing.expectEqualStrings(c[2], dayMonth(c[0]) orelse "");
    }
}

test "names listed: one, two, many, past five" {
    var buf: [128]u8 = undefined;
    const cases = [_]struct { []const []const u8, []const u8 }{
        .{ &.{"a"}, "a" },
        .{ &.{ "a", "b" }, "a and b" },
        .{ &.{ "a", "b", "c" }, "a, b and c" },
        .{ &.{ "a", "b", "c", "d", "e", "f", "g" }, "a, b, c, d, e and 2 more" },
        .{ &.{ "Run ID", "zip_4", "K-12.total", "", "año" }, "'Run ID', zip_4, K-12.total, '' and año" },
    };
    for (cases) |c| try testing.expectEqualStrings(c[1], try std.fmt.bufPrint(&buf, "{f}", .{Names{ .names = c[0] }}));
}

test "the JSON: the explanation, then the description whole" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e, const d = try explained(a, "examples/data/harvest_dirty.csv", .{});
    var w: Io.Writer.Allocating = .init(a);
    try writeJson(&w.writer, e, d, true);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, w.written(), .{});
    try testing.expectEqualStrings("fail", v.object.get("result").?.string);
    try testing.expectEqualStrings(e.summary, v.object.get("summary").?.string);
    const first = v.object.get("findings").?.array.items[0].object;
    try testing.expectEqualStrings("rows_set_aside", first.get("kind").?.string);
    try testing.expectEqualStrings("problem", first.get("level").?.string);
    try testing.expect(first.get("code") == null);
    // The description, as describe --json writes it, is the last field.
    var described: Io.Writer.Allocating = .init(a);
    try lib.writeDescription(&described.writer, d, true);
    const inner = std.mem.trimEnd(u8, described.written(), "\n");
    try testing.expect(std.mem.endsWith(u8, w.written(), try std.fmt.allocPrint(a, "\"description\":{s}}}\n", .{inner})));
}
