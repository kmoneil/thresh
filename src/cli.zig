//! The command line: arguments into a Config, or a usage error with its
//! message. Nothing here does I/O.

const std = @import("std");
const Io = std.Io;
const dialect = @import("dialect.zig");
const Dialect = dialect.Dialect;

pub const usage =
    \\usage: thresh <command> <file>... [options]
    \\
    \\Commands:
    \\  sniff      each file's dialect, confidence and header verdict
    \\  infer      two-pass type inference; writes a schema (--out FILE)
    \\  validate   check each file against --schema; report and reject file
    \\  convert    write each file --to csv or arrow; infers types with no --schema
    \\  run        validate and convert in one pass (--schema, --to, --out)
    \\
    \\Dialect (each pins one dimension; the sniffer scores the rest):
    \\      --delimiter C      one ASCII byte, tab, \t or \xHH
    \\      --quote C          one ASCII byte, or none
    \\      --escape E         doubled or backslash
    \\      --newline N        lf, crlf or cr
    \\      --header H         auto (the default), yes or no
    \\      --comment C        skip records that start with this byte
    \\      --sample-bytes N   initial sniff window (default 64K; grows to 16M)
    \\
    \\Schema and validation:
    \\      --schema FILE      column names, types, nulls and formats (JSON)
    \\      --columns SPEC     inline schema: "id:int64,amount:decimal(18,2)"
    \\      --null LIST        comma-separated strings read as null
    \\      --day-first        read ambiguous numeric dates as DD/MM
    \\      --encoding E       utf8 (the default), cp1252 (Windows-1252) or
    \\                         latin1; a file with a UTF-16 byte order mark is
    \\                         read as UTF-16, with no --encoding
    \\      --threshold F      minimum conforming fraction per column, and of
    \\                         rows read whole (default: the schema's, or 1.0)
    \\      --strict           extra columns, ragged rows and ambiguous dates fail
    \\      --keep-empty       an empty line is a one-field record, not skipped
    \\      --pad              fill a short row's missing fields with null
    \\      --truncate         drop a long row's extra fields
    \\      --report DIR       write <file>.report.json per input and summary.json
    \\      --reject DIR       write failing rows to <file>.rejects.csv
    \\      --sample N         infer: read only the first N rows
    \\
    \\Output (convert, run):
    \\      --to F             csv or arrow
    \\      --out DIR          where output goes (infer: the schema file)
    \\      --out-delimiter C  csv: the field separator (default ,)
    \\      --out-newline N    csv: lf (the default) or crlf
    \\      --normalize-dates  csv: write dates and timestamps as RFC 3339
    \\      --arrow-file       arrow: the file format with a footer, not a stream
    \\
    \\Running:
    \\      --jobs N           files processed at once (default: CPU count; at most 4 a CPU)
    \\      --no-mmap          read files through a buffer instead of mapping them
    \\      --json             one JSON object per file on stdout
    \\      --quiet            no summary on stderr
    \\      --progress         show progress
    \\  -h, --help             show this help
    \\      --version          show the version
    \\
    \\Exit status: 0 every file passed; 1 a file failed validation but every
    \\file was processed (infer: the files disagree on their columns); 2 a
    \\file could not be read or its dialect could not be settled; 3 a usage
    \\error.
    \\
;

pub const Command = enum { sniff, infer, validate, convert, run };

pub const Format = enum { csv, arrow, parquet };

pub const Encoding = @import("types.zig").Encoding;

pub const HeaderMode = dialect.HeaderMode;

pub const Ragged = @import("validate.zig").Ragged;

pub const Pins = dialect.Pins;

pub const Config = struct {
    command: Command,
    files: []const []const u8 = &.{},
    pins: Pins = .{},
    sample_bytes: usize = 64 * 1024,
    schema: ?[]const u8 = null,
    columns: ?[]const u8 = null,
    /// As given: comma-separated, split by the schema stage.
    nulls: ?[]const u8 = null,
    day_first: bool = false,
    encoding: Encoding = .utf8,
    /// Null: the schema's, or 1.0.
    threshold: ?f64 = null,
    strict: bool = false,
    keep_empty: bool = false,
    ragged: Ragged = .reject,
    report_dir: ?[]const u8 = null,
    reject_dir: ?[]const u8 = null,
    sample_rows: ?u64 = null,
    to: ?Format = null,
    /// A directory for convert and run, the schema file for infer.
    out: ?[]const u8 = null,
    out_delimiter: u8 = ',',
    out_newline: Dialect.Newline = .lf,
    normalize_dates: bool = false,
    arrow_file: bool = false,
    /// Null: one per CPU.
    jobs: ?usize = null,
    no_mmap: bool = false,
    json: bool = false,
    quiet: bool = false,
    progress: bool = false,
};

pub const Action = union(enum) { run: Config, help, version };

/// A usage error's message, kept in a buffer of its own so the caller can
/// print it after the arguments are gone.
pub const Diagnostic = struct {
    buf: [256]u8 = undefined,
    message: []const u8 = "",

    fn fail(d: *Diagnostic, comptime fmt: []const u8, args: anytype) error{Usage} {
        var w: Io.Writer = .fixed(&d.buf);
        w.print(fmt, args) catch {};
        d.message = w.buffered();
        return error.Usage;
    }
};

const Flag = enum {
    delimiter,
    quote,
    escape,
    newline,
    header,
    comment,
    sample_bytes,
    schema,
    columns,
    null,
    day_first,
    encoding,
    threshold,
    strict,
    keep_empty,
    pad,
    truncate,
    report,
    reject,
    sample,
    to,
    out,
    out_delimiter,
    out_newline,
    normalize_dates,
    arrow_file,
    jobs,
    no_mmap,
    json,
    quiet,
    progress,
    help,
    version,

    fn takesValue(f: Flag) bool {
        return switch (f) {
            .day_first, .strict, .keep_empty, .pad, .truncate, .normalize_dates => false,
            .arrow_file, .no_mmap, .json, .quiet, .progress, .help, .version => false,
            else => true,
        };
    }

    /// The commands a flag means something to; null for all of them.
    fn commands(f: Flag) ?[]const Command {
        return switch (f) {
            .sample => &.{.infer},
            .out => &.{ .infer, .convert, .run },
            .to, .out_delimiter, .out_newline, .normalize_dates, .arrow_file => &.{ .convert, .run },
            else => null,
        };
    }
};

/// Each flag's spelling: `--` and its name with `-` for `_`.
const flags: std.StaticStringMap(Flag) = blk: {
    const names = std.meta.fieldNames(Flag);
    var kvs: [names.len + 1]struct { []const u8, Flag } = undefined;
    for (names, 0..) |n, i| {
        var name: [n.len]u8 = n[0..n.len].*;
        std.mem.replaceScalar(u8, &name, '_', '-');
        const final = name;
        kvs[i] = .{ "--" ++ &final, @field(Flag, n) };
    }
    kvs[names.len] = .{ "-h", .help };
    break :blk .initComptime(kvs);
};

/// What args ask for, the program's name left off. Slices of args end up in
/// the Config, so args must outlive it.
pub fn parse(gpa: std.mem.Allocator, args: []const []const u8, diag: *Diagnostic) error{ Usage, OutOfMemory }!Action {
    var cfg: Config = .{ .command = .sniff };
    var command: ?Command = null;
    // A defer, not an errdefer: --help after a file returns early too.
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(gpa);
    var seen: std.EnumSet(Flag) = .empty;
    var positional_only = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (positional_only or arg.len < 2 or arg[0] != '-') {
            if (command == null) {
                if (std.mem.eql(u8, arg, "help")) return .help;
                command = std.meta.stringToEnum(Command, arg) orelse
                    return diag.fail("no command '{s}': sniff, infer, validate, convert or run", .{arg});
            } else try files.append(gpa, arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            positional_only = true;
            continue;
        }
        var name = arg;
        var inline_value: ?[]const u8 = null;
        if (std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.findScalar(u8, arg, '=')) |eq| {
                name = arg[0..eq];
                inline_value = arg[eq + 1 ..];
            }
        }
        const flag = flags.get(name) orelse return diag.fail("no option {s}", .{name});
        if (flag == .help) return .help;
        if (flag == .version) return .version;
        if (seen.contains(flag)) return diag.fail("{s} given twice", .{name});
        seen.insert(flag);
        if (!flag.takesValue()) {
            if (inline_value != null) return diag.fail("{s} takes no value", .{name});
            switch (flag) {
                .day_first => cfg.day_first = true,
                .strict => cfg.strict = true,
                .keep_empty => cfg.keep_empty = true,
                .pad => cfg.ragged = .pad,
                .truncate => cfg.ragged = .truncate,
                .normalize_dates => cfg.normalize_dates = true,
                .arrow_file => cfg.arrow_file = true,
                .no_mmap => cfg.no_mmap = true,
                .json => cfg.json = true,
                .quiet => cfg.quiet = true,
                .progress => cfg.progress = true,
                else => unreachable,
            }
            continue;
        }
        const value = inline_value orelse v: {
            i += 1;
            if (i == args.len) return diag.fail("{s} needs a value", .{name});
            break :v args[i];
        };
        switch (flag) {
            .delimiter => cfg.pins.delimiter = parseByte(value) orelse
                return diag.fail("--delimiter {s}: one ASCII byte, tab, \\t or \\xHH", .{value}),
            .quote => cfg.pins.quote = if (std.mem.eql(u8, value, "none"))
                .none
            else
                .{ .byte = parseByte(value) orelse
                    return diag.fail("--quote {s}: one ASCII byte, or none", .{value}) },
            .escape => cfg.pins.escape = std.meta.stringToEnum(Dialect.Escape, value) orelse
                return diag.fail("--escape {s}: doubled or backslash", .{value}),
            .newline => cfg.pins.newline = std.meta.stringToEnum(Dialect.Newline, value) orelse
                return diag.fail("--newline {s}: lf, crlf or cr", .{value}),
            .header => cfg.pins.header = std.meta.stringToEnum(HeaderMode, value) orelse
                return diag.fail("--header {s}: auto, yes or no", .{value}),
            .comment => cfg.pins.comment = parseByte(value) orelse
                return diag.fail("--comment {s}: one ASCII byte, tab, \\t or \\xHH", .{value}),
            .sample_bytes => cfg.sample_bytes = parseSize(value) orelse
                return diag.fail("--sample-bytes {s}: a size such as 65536, 64K or 1M", .{value}),
            .schema => cfg.schema = value,
            .columns => cfg.columns = value,
            .null => cfg.nulls = value,
            .encoding => cfg.encoding = std.meta.stringToEnum(Encoding, value) orelse
                if (std.ascii.eqlIgnoreCase(value, "windows-1252")) .cp1252 else return diag.fail("--encoding {s}: utf8, cp1252 or latin1", .{value}),
            .threshold => cfg.threshold = parseFraction(value) orelse
                return diag.fail("--threshold {s}: a fraction from 0 to 1", .{value}),
            .report => cfg.report_dir = value,
            .reject => cfg.reject_dir = value,
            .sample => cfg.sample_rows = parsePositive(u64, value) orelse
                return diag.fail("--sample {s}: a row count above 0", .{value}),
            .to => cfg.to = std.meta.stringToEnum(Format, value) orelse
                return diag.fail("--to {s}: csv or arrow", .{value}),
            .out => cfg.out = value,
            .out_delimiter => cfg.out_delimiter = parseByte(value) orelse
                return diag.fail("--out-delimiter {s}: one ASCII byte, tab, \\t or \\xHH", .{value}),
            .out_newline => cfg.out_newline = outNewline(value) orelse
                return diag.fail("--out-newline {s}: lf or crlf", .{value}),
            .jobs => cfg.jobs = parsePositive(usize, value) orelse
                return diag.fail("--jobs {s}: a count above 0", .{value}),
            else => unreachable,
        }
    }

    cfg.command = command orelse return diag.fail("no command: sniff, infer, validate, convert or run", .{});
    var it = seen.iterator();
    while (it.next()) |flag| {
        const allowed = flag.commands() orelse continue;
        if (std.mem.findScalar(Command, allowed, cfg.command) == null)
            return diag.fail("{s} is not an option of {t}", .{ flagName(flag), cfg.command });
    }
    if (files.items.len == 0) return diag.fail("{t}: no input files", .{cfg.command});
    if (seen.contains(.pad) and seen.contains(.truncate)) return diag.fail("--pad and --truncate together", .{});
    if (cfg.schema != null and cfg.columns != null) return diag.fail("--schema and --columns together", .{});
    if (cfg.pins.delimiter) |d| {
        if (cfg.pins.quote) |q| if (q == .byte and q.byte == d)
            return diag.fail("--delimiter and --quote are the same byte", .{});
        if (cfg.pins.comment == d) return diag.fail("--delimiter and --comment are the same byte", .{});
    }
    // A backslash escapes only inside quotes, so with none it means nothing.
    if (cfg.pins.quote) |q| if (q == .none and cfg.pins.escape == .backslash)
        return diag.fail("--quote none and --escape backslash together", .{});
    if (cfg.to == .parquet) return diag.fail("--to parquet: not in v1; write arrow and convert it", .{});
    switch (cfg.command) {
        .sniff, .infer => {},
        .validate => if (cfg.schema == null and cfg.columns == null)
            return diag.fail("validate needs --schema or --columns", .{}),
        .convert => {
            if (cfg.to == null) return diag.fail("convert needs --to", .{});
            if (cfg.out == null) return diag.fail("convert needs --out", .{});
        },
        .run => {
            if (cfg.schema == null and cfg.columns == null)
                return diag.fail("run needs --schema or --columns", .{});
            if (cfg.to == null) return diag.fail("run needs --to", .{});
            if (cfg.out == null) return diag.fail("run needs --out", .{});
        },
    }
    cfg.files = try files.toOwnedSlice(gpa);
    return .{ .run = cfg };
}

fn flagName(flag: Flag) []const u8 {
    for (flags.keys(), flags.values()) |k, v| {
        if (v == flag and std.mem.startsWith(u8, k, "--")) return k;
    }
    unreachable;
}

/// One ASCII byte other than a line break: itself, `tab`, `\t`, or `\xHH`.
/// ASCII only, since a byte above 0x7F is part of a character in UTF-8.
fn parseByte(s: []const u8) ?u8 {
    const c: u8 = if (s.len == 1)
        s[0]
    else if (std.mem.eql(u8, s, "tab") or std.mem.eql(u8, s, "\\t"))
        '\t'
    else if (s.len == 4 and std.mem.startsWith(u8, s, "\\x"))
        std.fmt.parseInt(u8, s[2..], 16) catch return null
    else
        return null;
    return switch (c) {
        '\n', '\r', 0x80...0xff => null,
        else => c,
    };
}

/// A byte count, with an optional binary K, M or G suffix.
fn parseSize(s: []const u8) ?usize {
    if (s.len == 0) return null;
    const shift: u6 = switch (std.ascii.toUpper(s[s.len - 1])) {
        'K' => 10,
        'M' => 20,
        'G' => 30,
        else => 0,
    };
    const digits = if (shift == 0) s else s[0 .. s.len - 1];
    const n = parsePositive(usize, digits) orelse return null;
    return std.math.shlExact(usize, n, shift) catch null;
}

fn parsePositive(comptime T: type, s: []const u8) ?T {
    if (s.len == 0) return null;
    for (s) |c| if (!std.ascii.isDigit(c)) return null;
    const n = std.fmt.parseInt(T, s, 10) catch return null;
    return if (n == 0) null else n;
}

fn parseFraction(s: []const u8) ?f64 {
    const f = std.fmt.parseFloat(f64, s) catch return null;
    return if (f >= 0 and f <= 1) f else null;
}

fn outNewline(s: []const u8) ?Dialect.Newline {
    const n = std.meta.stringToEnum(Dialect.Newline, s) orelse return null;
    return if (n == .cr) null else n;
}

const testing = std.testing;

fn expectConfig(args: []const []const u8) !Config {
    var diag: Diagnostic = .{};
    const action = parse(testing.allocator, args, &diag) catch |err| {
        std.debug.print("unexpected usage error: {s}\n", .{diag.message});
        return err;
    };
    return action.run;
}

fn expectUsage(args: []const []const u8, message: []const u8) !void {
    var diag: Diagnostic = .{};
    if (parse(testing.allocator, args, &diag)) |action| {
        if (action == .run) testing.allocator.free(action.run.files);
        return error.TestExpectedError;
    } else |err| {
        try testing.expectEqual(error.Usage, err);
        try testing.expectEqualStrings(message, diag.message);
    }
}

test "a command and files with no options" {
    const cfg = try expectConfig(&.{ "sniff", "a.csv", "b.csv" });
    defer testing.allocator.free(cfg.files);
    try testing.expectEqual(Command.sniff, cfg.command);
    try testing.expectEqual(@as(usize, 2), cfg.files.len);
    try testing.expectEqualStrings("b.csv", cfg.files[1]);
    try testing.expectEqual(HeaderMode.auto, cfg.pins.header);
    try testing.expectEqual(@as(usize, 64 * 1024), cfg.sample_bytes);
}

test "dialect pins, in both spellings" {
    const cfg = try expectConfig(&.{
        "convert",        "weird.dat", "--delimiter", "|",    "--quote=~", "--escape", "backslash",
        "--newline=crlf", "--header",  "yes",         "--to", "csv",       "--out",    "clean/",
    });
    defer testing.allocator.free(cfg.files);
    try testing.expectEqual(@as(?u8, '|'), cfg.pins.delimiter);
    try testing.expectEqual(Pins.Quote{ .byte = '~' }, cfg.pins.quote.?);
    try testing.expectEqual(Dialect.Escape.backslash, cfg.pins.escape.?);
    try testing.expectEqual(Dialect.Newline.crlf, cfg.pins.newline.?);
    try testing.expect(cfg.pins.complete());
    try testing.expectEqual(Format.csv, cfg.to.?);
}

test "delimiter spellings" {
    try testing.expectEqual(@as(?u8, '\t'), parseByte("tab"));
    try testing.expectEqual(@as(?u8, '\t'), parseByte("\\t"));
    try testing.expectEqual(@as(?u8, 0x1f), parseByte("\\x1f"));
    try testing.expectEqual(@as(?u8, ' '), parseByte(" "));
    try testing.expectEqual(@as(?u8, null), parseByte("\n"));
    try testing.expectEqual(@as(?u8, null), parseByte("\\xa7"));
    try testing.expectEqual(@as(?u8, null), parseByte("||"));
}

test "sizes" {
    try testing.expectEqual(@as(?usize, 65536), parseSize("65536"));
    try testing.expectEqual(@as(?usize, 64 * 1024), parseSize("64K"));
    try testing.expectEqual(@as(?usize, 16 << 20), parseSize("16m"));
    try testing.expectEqual(@as(?usize, null), parseSize("0"));
    try testing.expectEqual(@as(?usize, null), parseSize("K"));
    try testing.expectEqual(@as(?usize, null), parseSize("-1"));
}

test "the spec's examples parse" {
    const examples = [_][]const []const u8{
        &.{ "sniff", "exports/a.txt", "--json" },
        &.{ "infer", "good/a.csv", "--out", "orders.schema.json" },
        &.{ "run", "inbox/a.csv", "--schema", "orders.schema.json", "--to", "arrow", "--out", "staged/", "--report", "reports/", "--reject", "rejects/" },
        &.{ "validate", "a.csv", "--columns", "id:int64,amount:decimal(18,2)", "--threshold", "0.995" },
    };
    for (examples) |args| {
        const cfg = try expectConfig(args);
        testing.allocator.free(cfg.files);
    }
}

test "help and version win wherever they are" {
    var diag: Diagnostic = .{};
    try testing.expectEqual(Action.help, try parse(testing.allocator, &.{ "sniff", "a.csv", "-h" }, &diag));
    try testing.expectEqual(Action.help, try parse(testing.allocator, &.{"--help"}, &diag));
    try testing.expectEqual(Action.help, try parse(testing.allocator, &.{"help"}, &diag));
    try testing.expectEqual(Action.version, try parse(testing.allocator, &.{"--version"}, &diag));
}

test "usage errors" {
    try expectUsage(&.{}, "no command: sniff, infer, validate, convert or run");
    try expectUsage(&.{"split"}, "no command 'split': sniff, infer, validate, convert or run");
    try expectUsage(&.{"sniff"}, "sniff: no input files");
    try expectUsage(&.{ "sniff", "a", "--bogus" }, "no option --bogus");
    try expectUsage(&.{ "sniff", "a", "--delimiter" }, "--delimiter needs a value");
    try expectUsage(&.{ "sniff", "a", "--json=yes" }, "--json takes no value");
    try expectUsage(&.{ "sniff", "a", "--jobs", "2", "--jobs", "3" }, "--jobs given twice");
    try expectUsage(&.{ "sniff", "a", "--to", "csv" }, "--to is not an option of sniff");
    try expectUsage(&.{ "validate", "a" }, "validate needs --schema or --columns");
    try expectUsage(&.{ "convert", "a", "--to", "csv" }, "convert needs --out");
    try expectUsage(&.{ "convert", "a", "--to", "parquet", "--out", "o" }, "--to parquet: not in v1; write arrow and convert it");
    try expectUsage(&.{ "sniff", "a", "--delimiter", "'", "--quote", "'" }, "--delimiter and --quote are the same byte");
    try expectUsage(&.{ "sniff", "a", "--quote", "none", "--escape", "backslash" }, "--quote none and --escape backslash together");
    try expectUsage(&.{ "sniff", "a", "--pad", "--truncate" }, "--pad and --truncate together");
    try expectUsage(&.{ "sniff", "a", "--threshold", "1.5" }, "--threshold 1.5: a fraction from 0 to 1");
    try expectUsage(&.{ "infer", "a", "--out-newline", "crlf" }, "--out-newline is not an option of infer");
    try expectUsage(&.{ "convert", "a", "--out-newline", "cr" }, "--out-newline cr: lf or crlf");
}

test "-- ends the options" {
    const cfg = try expectConfig(&.{ "sniff", "--", "--json" });
    defer testing.allocator.free(cfg.files);
    try testing.expectEqualStrings("--json", cfg.files[0]);
    try testing.expect(!cfg.json);
}
