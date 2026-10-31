//! What thresh says about a file, as data: a stable code, the numbers and
//! names that go with it, and the fix where there is one. The CLI prints
//! each as a sentence (format); reports write each as an object with that
//! sentence in it (jsonStringify). docs/PROBLEMS.md lists every code, and a
//! test holds it to this union.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const infer = @import("infer.zig");
const schema = @import("schema.zig");

/// A column and how many of the run's files have it.
pub const Presence = struct { column: []const u8, files: u32 };

pub const Problem = union(enum) {
    // The file cannot be read.
    no_such_file,
    permission_denied,
    is_directory,
    /// A NUL byte in the first 8 KiB, and no UTF-16 BOM to explain it.
    binary,
    /// UTF-16 bytes reached the sniffer without being transcoded.
    utf16_untranscoded,
    /// A UTF-16 file, which is transcoded, read under an --encoding.
    utf16_with_encoding,
    /// The pins leave no dialect to score.
    unscorable,
    out_of_memory,
    /// What thresh writes to was closed (a pipe whose reader left).
    output_closed,
    /// Any other failure to read or write, by the error's name.
    io_error: struct { @"error": []const u8 },
    interrupted,
    /// Ctrl-C came before the run reached the file.
    not_reached,

    // The dialect.
    /// The sniffer is not sure enough to read the file.
    dialect_unsettled: struct { score: f64 },
    /// Row 1 is a header of another width than the rows.
    header_width: struct { header_fields: usize, fields: usize },
    /// Quotes that are data (records.QuoteCheck): values that start with
    /// one folded lines into records, so the rows are not the file's.
    quote_is_data: struct { records: u64, lines: u64, line: u64 },

    // The file against its schema: each fails it.
    match_needs_header,
    column_missing: struct { column: []const u8 },
    /// With --strict.
    column_extra: struct { column: []const u8 },
    width_mismatch: struct { columns: usize, schema_columns: usize },
    cut_off_in_quote,
    cut_off: struct { fields: usize, width: usize },
    /// Records that are the header again, skipped: files joined.
    header_repeated: struct { line: u64, count: u64 },

    // What infer found.
    /// Read as UTF-8 and it is not; a guess would garble every accent.
    column_not_utf8: struct { column: []const u8, row: u64 },
    rows_wider: struct { rows: u64, line: u64 },
    utf16_replaced: struct { units: u64 },
    /// A later file took a merged column to a lower type.
    column_widened: struct { column: []const u8, from: infer.Kind, to: infer.Kind, file: []const u8 },
    /// --threshold let a column keep a type some values refuse.
    column_tolerated: struct { column: []const u8, type: schema.Type, misfits: u64, values: u64, row: u64 },
    /// A few values hold a column at a lower type than the rest have.
    column_misfits: struct { column: []const u8, type: schema.Type, misfits: u64, values: u64, row: u64, rest: schema.Type, threshold: f64 },
    /// Typed columns read from too few values to trust: the first five.
    columns_thin: struct { columns: []const []const u8, count: usize, few_values: usize },
    /// Some of the files have a header and some do not.
    files_mixed_headers: struct { headless: u32, files: u32, first: []const u8 },
    /// Headerless files of different widths.
    files_widths: struct { min: usize, max: usize },
    /// Columns not in every file: the first three.
    files_columns: struct { missing: usize, columns: usize, files: u32, first: []const Presence },
    nothing_to_infer,

    pub const Code = std.meta.Tag(Problem);

    /// The fix, as the options that make it: each one set, and for
    /// encoding any of the list.
    pub const Suggest = struct {
        header: ?enum { yes, no } = null,
        quote: ?enum { none } = null,
        encoding: ?[]const []const u8 = null,
        threshold: ?f64 = null,

        pub fn jsonStringify(sg: Suggest, s: *Stringify) Stringify.Error!void {
            try s.beginObject();
            if (sg.header) |h| {
                try s.objectField("header");
                try s.write(h);
            }
            if (sg.quote) |q| {
                try s.objectField("quote");
                try s.write(q);
            }
            if (sg.encoding) |e| {
                try s.objectField("encoding");
                try s.write(e);
            }
            if (sg.threshold) |t| {
                try s.objectField("threshold");
                try s.print("{d}", .{t});
            }
            try s.endObject();
        }
    };

    pub fn suggest(p: Problem) ?Suggest {
        return switch (p) {
            .utf16_with_encoding => .{ .encoding = &.{"utf8"} },
            .header_width => .{ .header = .no },
            .quote_is_data => .{ .quote = .none },
            .column_not_utf8 => .{ .encoding = &.{ "cp1252", "latin1" } },
            .column_misfits => |m| .{ .threshold = m.threshold },
            else => null,
        };
    }

    /// The problem in an error's place: why a file could not be read.
    pub fn of(e: anyerror) Problem {
        return switch (e) {
            error.FileNotFound => .no_such_file,
            error.AccessDenied, error.PermissionDenied => .permission_denied,
            error.IsDir => .is_directory,
            error.OutOfMemory => .out_of_memory,
            error.BrokenPipe => .output_closed,
            error.Utf16 => .utf16_untranscoded,
            error.Binary => .binary,
            error.Unscorable => .unscorable,
            error.Interrupted => .interrupted,
            else => .{ .io_error = .{ .@"error" = @errorName(e) } },
        };
    }

    /// The sentence the CLI prints.
    pub fn format(p: Problem, w: *Io.Writer) Io.Writer.Error!void {
        switch (p) {
            .no_such_file => try w.writeAll("no such file"),
            .permission_denied => try w.writeAll("permission denied"),
            .is_directory => try w.writeAll("is a directory"),
            .binary => try w.writeAll("binary data (a NUL byte in the first 8 KiB)"),
            .utf16_untranscoded => try w.writeAll("UTF-16 data (a UTF-16 byte order mark) where UTF-8 was expected"),
            .utf16_with_encoding => try w.writeAll("the file is UTF-16 (it starts with a byte order mark) and is read as such; leave out --encoding"),
            .unscorable => try w.writeAll("the pinned quote and escape leave no dialect to score"),
            .out_of_memory => try w.writeAll("out of memory"),
            .output_closed => try w.writeAll("the output was closed"),
            .io_error => |x| try w.writeAll(x.@"error"),
            .interrupted => try w.writeAll("interrupted"),
            .not_reached => try w.writeAll("not reached: interrupted"),
            .dialect_unsettled => |x| try w.print("the dialect is not settled (confidence low, score {d:.2}); pin it with --delimiter, --quote, --escape, --newline and --header", .{x.score}),
            .header_width => |x| try w.print("row 1 is a header of {d} names over rows of {d} fields, and which names go with which columns cannot be told; fix the header, or pin --header no to read row 1 as data", .{ x.header_fields, x.fields }),
            .quote_is_data => |x| try w.print("the quotes look like data: {d} record{s} {s} {d} lines inside quotes, the first on line {d}, and each of those lines is a whole row without them; pin --quote none to read quotes as data", .{ x.records, plural(x.records), if (x.records == 1) "holds" else "hold", x.lines, x.line }),
            .match_needs_header => try w.writeAll("match by name needs a header"),
            .column_missing => |x| try w.print("the schema's column '{s}' is not in the header", .{x.column}),
            .column_extra => |x| try w.print("the header's column '{s}' is not in the schema", .{x.column}),
            .width_mismatch => |x| try w.print("the file has {d} columns, the schema {d}", .{ x.columns, x.schema_columns }),
            .cut_off_in_quote => try w.writeAll("the file ends mid-record, inside a quoted field and with no line break: was it cut off?"),
            .cut_off => |x| try w.print("the file ends mid-record: its last line has no line break and {d} of {d} fields; was it cut off?", .{ x.fields, x.width }),
            .header_repeated => |x| if (x.count == 1)
                try w.print("the header repeats at row {d}: files joined? It is skipped", .{x.line})
            else
                try w.print("the header repeats at row {d} and {d} more: files joined? They are skipped", .{ x.line, x.count - 1 }),
            .column_not_utf8 => |x| try w.print("column '{s}' is not UTF-8 (row {d}); read the file with --encoding cp1252 (Windows) or latin1", .{ x.column, x.row }),
            .rows_wider => |x| try w.print("{d} row{s} wider than the header left out, the first on line {d}: ragged rows, which validate rejects", .{ x.rows, plural(x.rows), x.line }),
            .utf16_replaced => |x| try w.print("{d} UTF-16 code unit{s} made no character, read as U+FFFD", .{ x.units, plural(x.units) }),
            .column_widened => |x| try w.print("column '{s}': {t} until {s} made it {t}", .{ x.column, x.from, x.file, x.to }),
            .column_tolerated => |x| try w.print("column '{s}' inferred {t} with {d} of {d} values refusing it (row {d} first), as --threshold allows: validate rejects them", .{ x.column, x.type, x.misfits, x.values, x.row }),
            .column_misfits => |x| try w.print("column '{s}' is {t} because of {d} of {d} values (row {d} first); the rest are {t}: --threshold {d} infers {t} and rejects them", .{ x.column, x.type, x.misfits, x.values, x.row, x.rest, x.threshold, x.rest }),
            .columns_thin => |x| {
                for (x.columns, 0..) |c, i| try w.print("{s}{s}", .{ if (i == 0) "" else ", ", c });
                if (x.count > x.columns.len) try w.print(" and {d} more", .{x.count - x.columns.len});
                try w.print(": typed from fewer than {d} values; check {s} before reusing the schema", .{ x.few_values, if (x.count == 1) "it" else "them" });
            },
            .files_mixed_headers => |x| try w.print("the files disagree: {d} of {d} have no header (the first: {s}), so the schema matches columns by position; infer them apart, or pin --header", .{ x.headless, x.files, x.first }),
            .files_widths => |x| try w.print("the files disagree: they are {d} to {d} columns wide, and validate fails a file narrower than its schema", .{ x.min, x.max }),
            .files_columns => |x| {
                try w.print("the files disagree: {d} of the schema's {d} columns {s} not in every file: ", .{ x.missing, x.columns, if (x.missing == 1) "is" else "are" });
                for (x.first, 0..) |c, i| try w.print("{s}'{s}' ({d} of {d})", .{ if (i == 0) "" else ", ", c.column, c.files, x.files });
                if (x.missing > x.first.len) try w.print(" and {d} more", .{x.missing - x.first.len});
                try w.writeAll("; validate fails a file without one");
            },
            .nothing_to_infer => try w.writeAll("no file to infer a schema from"),
        }
    }

    /// {"code": ..., "message": the sentence, each parameter, "suggest": the fix}.
    pub fn jsonStringify(p: Problem, s: *Stringify) Stringify.Error!void {
        try s.beginObject();
        try s.objectField("code");
        try s.write(@tagName(p));
        try s.objectField("message");
        try p.writeMessage(s);
        switch (p) {
            inline else => |x| if (@TypeOf(x) != void) {
                inline for (@typeInfo(@TypeOf(x)).@"struct".field_names) |name| {
                    try s.objectField(name);
                    const v = @field(x, name);
                    if (@TypeOf(v) == f64) try s.print("{d}", .{v}) else try s.write(v);
                }
            },
        }
        if (p.suggest()) |sg| {
            try s.objectField("suggest");
            try s.write(sg);
        }
        try s.endObject();
    }

    /// The sentence as a JSON string, escaped as it is formatted.
    pub fn writeMessage(p: Problem, s: *Stringify) Stringify.Error!void {
        try s.beginWriteRaw();
        try s.writer.writeByte('"');
        var buf: [256]u8 = undefined;
        var e: Escaped = .{ .out = s.writer, .writer = .{ .vtable = &.{ .drain = Escaped.drain }, .buffer = &buf } };
        try p.format(&e.writer);
        try e.writer.flush();
        try s.writer.writeByte('"');
        s.endWriteRaw();
    }

    /// A copy whose names live in a.
    pub fn dupe(p: Problem, a: Allocator) Allocator.Error!Problem {
        switch (p) {
            inline else => |x, tag| {
                if (@TypeOf(x) == void) return p;
                var c = x;
                inline for (@typeInfo(@TypeOf(x)).@"struct".field_names) |name| {
                    const v = @field(x, name);
                    const T = @TypeOf(v);
                    if (T == []const u8) {
                        @field(c, name) = try a.dupe(u8, v);
                    } else if (T == []const []const u8) {
                        const names = try a.alloc([]const u8, v.len);
                        for (names, v) |*n, s| n.* = try a.dupe(u8, s);
                        @field(c, name) = names;
                    } else if (T == []const Presence) {
                        const ps = try a.alloc(Presence, v.len);
                        for (ps, v) |*n, s| n.* = .{ .column = try a.dupe(u8, s.column), .files = s.files };
                        @field(c, name) = ps;
                    }
                }
                return @unionInit(Problem, @tagName(tag), c);
            },
        }
    }
};

fn plural(n: u64) []const u8 {
    return if (n == 1) "" else "s";
}

/// A writer that writes what it is given to out as JSON string characters.
const Escaped = struct {
    out: *Io.Writer,
    writer: Io.Writer,

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const e: *Escaped = @alignCast(@fieldParentPtr("writer", w));
        try Stringify.encodeJsonStringChars(w.buffered(), .{}, e.out);
        w.end = 0;
        const slice = data[0 .. data.len - 1];
        const pattern = data[slice.len];
        var n: usize = 0;
        for (slice) |bytes| {
            try Stringify.encodeJsonStringChars(bytes, .{}, e.out);
            n += bytes.len;
        }
        for (0..splat) |_| try Stringify.encodeJsonStringChars(pattern, .{}, e.out);
        return n + pattern.len * splat;
    }
};

const testing = std.testing;

fn sentence(buf: []u8, p: Problem) ![]const u8 {
    var w: Io.Writer = .fixed(buf);
    try p.format(&w);
    return w.buffered();
}

fn json(buf: []u8, p: Problem) ![]const u8 {
    var w: Io.Writer = .fixed(buf);
    try Stringify.value(p, .{}, &w);
    return w.buffered();
}

test "every code says what the CLI has always said" {
    const cases = [_]struct { Problem, []const u8 }{
        .{ .no_such_file, "no such file" },
        .{ .permission_denied, "permission denied" },
        .{ .is_directory, "is a directory" },
        .{ .binary, "binary data (a NUL byte in the first 8 KiB)" },
        .{ .utf16_untranscoded, "UTF-16 data (a UTF-16 byte order mark) where UTF-8 was expected" },
        .{ .utf16_with_encoding, "the file is UTF-16 (it starts with a byte order mark) and is read as such; leave out --encoding" },
        .{ .unscorable, "the pinned quote and escape leave no dialect to score" },
        .{ .out_of_memory, "out of memory" },
        .{ .output_closed, "the output was closed" },
        .{ .{ .io_error = .{ .@"error" = "NoSpaceLeft" } }, "NoSpaceLeft" },
        .{ .interrupted, "interrupted" },
        .{ .not_reached, "not reached: interrupted" },
        .{ .{ .dialect_unsettled = .{ .score = 0.9234 } }, "the dialect is not settled (confidence low, score 0.92); pin it with --delimiter, --quote, --escape, --newline and --header" },
        .{ .{ .header_width = .{ .header_fields = 69, .fields = 70 } }, "row 1 is a header of 69 names over rows of 70 fields, and which names go with which columns cannot be told; fix the header, or pin --header no to read row 1 as data" },
        .{ .{ .quote_is_data = .{ .records = 1, .lines = 3, .line = 82 } }, "the quotes look like data: 1 record holds 3 lines inside quotes, the first on line 82, and each of those lines is a whole row without them; pin --quote none to read quotes as data" },
        .{ .match_needs_header, "match by name needs a header" },
        .{ .{ .column_missing = .{ .column = "amount" } }, "the schema's column 'amount' is not in the header" },
        .{ .{ .column_extra = .{ .column = "note" } }, "the header's column 'note' is not in the schema" },
        .{ .{ .width_mismatch = .{ .columns = 2, .schema_columns = 3 } }, "the file has 2 columns, the schema 3" },
        .{ .cut_off_in_quote, "the file ends mid-record, inside a quoted field and with no line break: was it cut off?" },
        .{ .{ .cut_off = .{ .fields = 2, .width = 3 } }, "the file ends mid-record: its last line has no line break and 2 of 3 fields; was it cut off?" },
        .{ .{ .header_repeated = .{ .line = 4, .count = 1 } }, "the header repeats at row 4: files joined? It is skipped" },
        .{ .{ .column_not_utf8 = .{ .column = "name", .row = 7 } }, "column 'name' is not UTF-8 (row 7); read the file with --encoding cp1252 (Windows) or latin1" },
        .{ .{ .rows_wider = .{ .rows = 1, .line = 9 } }, "1 row wider than the header left out, the first on line 9: ragged rows, which validate rejects" },
        .{ .{ .utf16_replaced = .{ .units = 2 } }, "2 UTF-16 code units made no character, read as U+FFFD" },
        .{ .{ .column_widened = .{ .column = "id", .from = .int64, .to = .string, .file = "b.csv" } }, "column 'id': int64 until b.csv made it string" },
        .{ .{ .column_tolerated = .{ .column = "id", .type = .int64, .misfits = 3, .values = 5000, .row = 12 } }, "column 'id' inferred int64 with 3 of 5000 values refusing it (row 12 first), as --threshold allows: validate rejects them" },
        .{ .{ .column_misfits = .{ .column = "id", .type = .string, .misfits = 3, .values = 5000, .row = 12, .rest = .int64, .threshold = 0.9994 } }, "column 'id' is string because of 3 of 5000 values (row 12 first); the rest are int64: --threshold 0.9994 infers int64 and rejects them" },
        .{ .{ .columns_thin = .{ .columns = &.{"qty"}, .count = 1, .few_values = 10 } }, "qty: typed from fewer than 10 values; check it before reusing the schema" },
        .{ .{ .files_mixed_headers = .{ .headless = 1, .files = 3, .first = "c.csv" } }, "the files disagree: 1 of 3 have no header (the first: c.csv), so the schema matches columns by position; infer them apart, or pin --header" },
        .{ .{ .files_widths = .{ .min = 3, .max = 4 } }, "the files disagree: they are 3 to 4 columns wide, and validate fails a file narrower than its schema" },
        .{ .{ .files_columns = .{ .missing = 1, .columns = 4, .files = 2, .first = &.{.{ .column = "note", .files = 1 }} } }, "the files disagree: 1 of the schema's 4 columns is not in every file: 'note' (1 of 2); validate fails a file without one" },
        .{ .nothing_to_infer, "no file to infer a schema from" },
    };
    // Every code is in the table.
    comptime {
        var seen: [std.enums.values(Problem.Code).len]bool = @splat(false);
        for (cases) |c| seen[@backingInt(std.meta.activeTag(c[0]))] = true;
        for (seen, 0..) |s, i| if (!s) @compileError("no case for " ++ @tagName(@as(Problem.Code, @fromBackingInt(@intCast(i)))));
    }
    var buf: [512]u8 = undefined;
    for (cases) |c| try testing.expectEqualStrings(c[1], try sentence(&buf, c[0]));
}

test "a count says how many more there are, and agrees with them" {
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings(
        "the header repeats at row 4 and 2 more: files joined? They are skipped",
        try sentence(&buf, .{ .header_repeated = .{ .line = 4, .count = 3 } }),
    );
    try testing.expectEqualStrings(
        "a, b, c, d, e and 2 more: typed from fewer than 10 values; check them before reusing the schema",
        try sentence(&buf, .{ .columns_thin = .{ .columns = &.{ "a", "b", "c", "d", "e" }, .count = 7, .few_values = 10 } }),
    );
    const first: []const Presence = &.{ .{ .column = "a", .files = 1 }, .{ .column = "b", .files = 2 }, .{ .column = "c", .files = 1 } };
    try testing.expectEqualStrings(
        "the files disagree: 5 of the schema's 9 columns are not in every file: 'a' (1 of 3), 'b' (2 of 3), 'c' (1 of 3) and 2 more; validate fails a file without one",
        try sentence(&buf, .{ .files_columns = .{ .missing = 5, .columns = 9, .files = 3, .first = first } }),
    );
}

test "the JSON object: code, message, parameters, and the fix" {
    var buf: [1024]u8 = undefined;
    try testing.expectEqualStrings(
        \\{"code":"header_width","message":"row 1 is a header of 69 names over rows of 70 fields, and which names go with which columns cannot be told; fix the header, or pin --header no to read row 1 as data","header_fields":69,"fields":70,"suggest":{"header":"no"}}
    , try json(&buf, .{ .header_width = .{ .header_fields = 69, .fields = 70 } }));
    try testing.expectEqualStrings(
        \\{"code":"column_not_utf8","message":"column 'name' is not UTF-8 (row 7); read the file with --encoding cp1252 (Windows) or latin1","column":"name","row":7,"suggest":{"encoding":["cp1252","latin1"]}}
    , try json(&buf, .{ .column_not_utf8 = .{ .column = "name", .row = 7 } }));
    try testing.expectEqualStrings(
        \\{"code":"no_such_file","message":"no such file"}
    , try json(&buf, .no_such_file));
    // A number as it is, not as the sentence rounds it; an enum by name.
    try testing.expectEqualStrings(
        \\{"code":"dialect_unsettled","message":"the dialect is not settled (confidence low, score 0.92); pin it with --delimiter, --quote, --escape, --newline and --header","score":0.9234}
    , try json(&buf, .{ .dialect_unsettled = .{ .score = 0.9234 } }));
    try testing.expectEqualStrings(
        \\{"code":"column_misfits","message":"column 'id' is string because of 3 of 5000 values (row 12 first); the rest are int64: --threshold 0.9994 infers int64 and rejects them","column":"id","type":"string","misfits":3,"values":5000,"row":12,"rest":"int64","threshold":0.9994,"suggest":{"threshold":0.9994}}
    , try json(&buf, .{ .column_misfits = .{ .column = "id", .type = .string, .misfits = 3, .values = 5000, .row = 12, .rest = .int64, .threshold = 0.9994 } }));
    try testing.expectEqualStrings(
        \\{"code":"files_columns","message":"the files disagree: 1 of the schema's 4 columns is not in every file: 'note' (1 of 2); validate fails a file without one","missing":1,"columns":4,"files":2,"first":[{"column":"note","files":1}]}
    , try json(&buf, .{ .files_columns = .{ .missing = 1, .columns = 4, .files = 2, .first = &.{.{ .column = "note", .files = 1 }} } }));
}

test "a name is escaped in the message as in its own field" {
    var buf: [1024]u8 = undefined;
    // Longer than the escaping writer's buffer, so it drains mid-name.
    const xs: [300]u8 = @splat('x');
    const long = "a\"b\\c\td" ++ xs ++ "é";
    const got = try json(&buf, .{ .column_missing = .{ .column = long } });
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, got, .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    try testing.expectEqualStrings(long, o.get("column").?.string);
    try testing.expectEqualStrings("the schema's column '" ++ long ++ "' is not in the header", o.get("message").?.string);
}

test "dupe copies every name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var name = "note".*;
    var names = [_][]const u8{&name};
    var first = [_]Presence{.{ .column = &name, .files = 1 }};
    const ps = [_]Problem{
        .{ .column_missing = .{ .column = &name } },
        .{ .columns_thin = .{ .columns = &names, .count = 1, .few_values = 10 } },
        .{ .files_columns = .{ .missing = 1, .columns = 2, .files = 2, .first = &first } },
    };
    var copies: [ps.len]Problem = undefined;
    for (&copies, ps) |*c, p| c.* = try p.dupe(arena.allocator());
    name[0] = 'X';
    try testing.expectEqualStrings("note", copies[0].column_missing.column);
    try testing.expectEqualStrings("note", copies[1].columns_thin.columns[0]);
    try testing.expectEqualStrings("note", copies[2].files_columns.first[0].column);
}

test "of: the problem in an error's place" {
    try testing.expectEqual(Problem.no_such_file, std.meta.activeTag(Problem.of(error.FileNotFound)));
    try testing.expectEqual(Problem.interrupted, std.meta.activeTag(Problem.of(error.Interrupted)));
    try testing.expectEqualStrings("NoSpaceLeft", Problem.of(error.NoSpaceLeft).io_error.@"error");
}
