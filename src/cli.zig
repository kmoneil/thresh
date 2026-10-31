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
    \\      --shapes-only      reports, lines and the schema infer writes give
    \\                         every value as its shape (digits 9, letters a),
    \\                         to share without the data; not with --reject
    \\      --shape-names      --shapes-only, and the column names too
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
    /// What the run says of a file gives its values as shapes, and with
    /// shape_names its column names too.
    shapes_only: bool = false,
    shape_names: bool = false,
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
    shapes_only,
    shape_names,
    quiet,
    progress,
    help,
    version,

    fn takesValue(f: Flag) bool {
        return switch (f) {
            .day_first, .strict, .keep_empty, .pad, .truncate, .normalize_dates => false,
            .arrow_file, .no_mmap, .json, .shapes_only, .shape_names, .quiet, .progress, .help, .version => false,
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
    var p: Parser = .{ .gpa = gpa, .args = args, .diag = diag };
    // A defer, not an errdefer: --help after a file returns early too.
    defer p.files.deinit(gpa);
    while (p.i < args.len) : (p.i += 1) if (try p.one()) |action| return action;
    p.cfg.command = p.command orelse return diag.fail("no command: sniff, infer, validate, convert or run", .{});
    try check(&p.cfg, p.seen, p.files.items.len, diag);
    p.cfg.files = try p.files.toOwnedSlice(gpa);
    return .{ .run = p.cfg };
}

/// The arguments, read one at a time into a Config.
const Parser = struct {
    gpa: std.mem.Allocator,
    args: []const []const u8,
    diag: *Diagnostic,
    i: usize = 0,
    cfg: Config = .{ .command = .sniff },
    command: ?Command = null,
    files: std.ArrayList([]const u8) = .empty,
    seen: std.EnumSet(Flag) = .empty,
    /// After a lone "--", every argument is a command or a file.
    positional_only: bool = false,

    /// args[i]: a flag and, for one that takes it, its value (args[i] moves
    /// on to it); or the command or a file. An action to take now (--help,
    /// --version), or null to read on.
    fn one(p: *Parser) error{ Usage, OutOfMemory }!?Action {
        const arg = p.args[p.i];
        if (p.positional_only or arg.len < 2 or arg[0] != '-') return p.positional(arg);
        if (std.mem.eql(u8, arg, "--")) {
            p.positional_only = true;
            return null;
        }
        const named = split(arg);
        const flag = flags.get(named.name) orelse return p.diag.fail("no option {s}", .{named.name});
        if (flag == .help) return .help;
        if (flag == .version) return .version;
        if (p.seen.contains(flag)) return p.diag.fail("{s} given twice", .{named.name});
        p.seen.insert(flag);
        if (!flag.takesValue()) {
            if (named.value != null) return p.diag.fail("{s} takes no value", .{named.name});
            setSwitch(&p.cfg, flag);
            return null;
        }
        const value = named.value orelse try p.nextValue(named.name);
        if (!setValue(&p.cfg, flag, value)) return p.diag.fail("{s} {s}: {s}", .{ named.name, value, hint(flag) });
        return null;
    }

    /// The command, the first argument that is not a flag, or a file.
    fn positional(p: *Parser, arg: []const u8) error{ Usage, OutOfMemory }!?Action {
        if (p.command != null) {
            try p.files.append(p.gpa, arg);
            return null;
        }
        if (std.mem.eql(u8, arg, "help")) return .help;
        p.command = std.meta.stringToEnum(Command, arg) orelse
            return p.diag.fail("no command '{s}': sniff, infer, validate, convert or run", .{arg});
        return null;
    }

    /// The argument after a flag that takes a value, as its value.
    fn nextValue(p: *Parser, name: []const u8) error{Usage}![]const u8 {
        p.i += 1;
        if (p.i == p.args.len) return p.diag.fail("{s} needs a value", .{name});
        return p.args[p.i];
    }
};

/// "--name=value" as its name and value; any other argument, a name alone.
fn split(arg: []const u8) struct { name: []const u8, value: ?[]const u8 } {
    if (!std.mem.startsWith(u8, arg, "--")) return .{ .name = arg, .value = null };
    const eq = std.mem.findScalar(u8, arg, '=') orelse return .{ .name = arg, .value = null };
    return .{ .name = arg[0..eq], .value = arg[eq + 1 ..] };
}

/// A flag that takes no value, set.
fn setSwitch(cfg: *Config, flag: Flag) void {
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
        .shapes_only => cfg.shapes_only = true,
        .shape_names => cfg.shape_names = true,
        .quiet => cfg.quiet = true,
        .progress => cfg.progress = true,
        else => unreachable,
    }
}

/// value into cfg for flag, one that takes a value; false when it is not
/// a value the flag takes, which hint(flag) then says.
fn setValue(cfg: *Config, flag: Flag, value: []const u8) bool {
    return setDialect(cfg, flag, value) orelse setSchema(cfg, flag, value) orelse setRun(cfg, flag, value) orelse unreachable;
}

/// The dialect's pins; null for another flag.
fn setDialect(cfg: *Config, flag: Flag, value: []const u8) ?bool {
    switch (flag) {
        .delimiter => cfg.pins.delimiter = parseByte(value) orelse return false,
        .quote => cfg.pins.quote = quoteOf(value) orelse return false,
        .escape => cfg.pins.escape = std.meta.stringToEnum(Dialect.Escape, value) orelse return false,
        .newline => cfg.pins.newline = std.meta.stringToEnum(Dialect.Newline, value) orelse return false,
        .header => cfg.pins.header = std.meta.stringToEnum(HeaderMode, value) orelse return false,
        .comment => cfg.pins.comment = parseByte(value) orelse return false,
        else => return null,
    }
    return true;
}

/// The schema and how a file is read against it; null for another flag.
fn setSchema(cfg: *Config, flag: Flag, value: []const u8) ?bool {
    switch (flag) {
        .schema => cfg.schema = value,
        .columns => cfg.columns = value,
        .null => cfg.nulls = value,
        .encoding => cfg.encoding = encodingOf(value) orelse return false,
        .threshold => cfg.threshold = parseFraction(value) orelse return false,
        .sample_bytes => cfg.sample_bytes = parseSize(value) orelse return false,
        else => return null,
    }
    return true;
}

/// What a run writes and how; null for another flag.
fn setRun(cfg: *Config, flag: Flag, value: []const u8) ?bool {
    switch (flag) {
        .report => cfg.report_dir = value,
        .reject => cfg.reject_dir = value,
        .sample => cfg.sample_rows = parsePositive(u64, value) orelse return false,
        .to => cfg.to = std.meta.stringToEnum(Format, value) orelse return false,
        .out => cfg.out = value,
        .out_delimiter => cfg.out_delimiter = parseByte(value) orelse return false,
        .out_newline => cfg.out_newline = outNewline(value) orelse return false,
        .jobs => cfg.jobs = parsePositive(usize, value) orelse return false,
        else => return null,
    }
    return true;
}

fn quoteOf(value: []const u8) ?Pins.Quote {
    if (std.mem.eql(u8, value, "none")) return .none;
    return .{ .byte = parseByte(value) orelse return null };
}

fn encodingOf(value: []const u8) ?Encoding {
    if (std.ascii.eqlIgnoreCase(value, "windows-1252")) return .cp1252;
    return std.meta.stringToEnum(Encoding, value);
}

/// What a flag's value must be, for the message when it is not.
fn hint(flag: Flag) []const u8 {
    return switch (flag) {
        .delimiter, .comment, .out_delimiter => "one ASCII byte, tab, \\t or \\xHH",
        .quote => "one ASCII byte, or none",
        .escape => "doubled or backslash",
        .newline => "lf, crlf or cr",
        .header => "auto, yes or no",
        .sample_bytes => "a size such as 65536, 64K or 1M",
        .encoding => "utf8, cp1252 or latin1",
        .threshold => "a fraction from 0 to 1",
        .sample => "a row count above 0",
        .jobs => "a count above 0",
        .to => "csv or arrow",
        .out_newline => "lf or crlf",
        else => "",
    };
}

/// The flags given, against each other and the command.
fn check(cfg: *const Config, seen: std.EnumSet(Flag), files: usize, diag: *Diagnostic) error{Usage}!void {
    var it = seen.iterator();
    while (it.next()) |flag| {
        const allowed = flag.commands() orelse continue;
        if (std.mem.findScalar(Command, allowed, cfg.command) == null)
            return diag.fail("{s} is not an option of {t}", .{ flagName(flag), cfg.command });
    }
    if (files == 0) return diag.fail("{t}: no input files", .{cfg.command});
    if (seen.contains(.pad) and seen.contains(.truncate)) return diag.fail("--pad and --truncate together", .{});
    if (cfg.schema != null and cfg.columns != null) return diag.fail("--schema and --columns together", .{});
    // A reject file is the rows themselves, which shapes leave out.
    if (cfg.reject_dir != null and (cfg.shapes_only or cfg.shape_names))
        return diag.fail("--reject writes the rows themselves; --shapes-only leaves them out", .{});
    try checkPins(cfg.pins, diag);
    if (cfg.to == .parquet) return diag.fail("--to parquet: not in v1; write arrow and convert it", .{});
    return checkCommand(cfg, diag);
}

/// Pins that cannot hold together.
fn checkPins(pins: Pins, diag: *Diagnostic) error{Usage}!void {
    if (pins.delimiter) |d| {
        if (pins.quote) |q| if (q == .byte and q.byte == d)
            return diag.fail("--delimiter and --quote are the same byte", .{});
        if (pins.comment == d) return diag.fail("--delimiter and --comment are the same byte", .{});
    }
    // A backslash escapes only inside quotes, so with none it means nothing.
    if (pins.quote) |q| if (q == .none and pins.escape == .backslash)
        return diag.fail("--quote none and --escape backslash together", .{});
}

/// What each command needs.
fn checkCommand(cfg: *const Config, diag: *Diagnostic) error{Usage}!void {
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
    try expectUsage(&.{ "validate", "a", "--columns", "id:int64", "--reject", "r", "--shape-names" }, "--reject writes the rows themselves; --shapes-only leaves them out");
    try expectUsage(&.{ "sniff", "a", "--threshold", "1.5" }, "--threshold 1.5: a fraction from 0 to 1");
    try expectUsage(&.{ "infer", "a", "--out-newline", "crlf" }, "--out-newline is not an option of infer");
    try expectUsage(&.{ "convert", "a", "--out-newline", "cr" }, "--out-newline cr: lf or crlf");
}

test "a value a flag does not take says what it does" {
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "--delimiter", "ab", "one ASCII byte, tab, \\t or \\xHH" },
        .{ "--quote", "ab", "one ASCII byte, or none" },
        .{ "--escape", "slash", "doubled or backslash" },
        .{ "--newline", "nl", "lf, crlf or cr" },
        .{ "--header", "maybe", "auto, yes or no" },
        .{ "--comment", "ab", "one ASCII byte, tab, \\t or \\xHH" },
        .{ "--sample-bytes", "lots", "a size such as 65536, 64K or 1M" },
        .{ "--encoding", "ebcdic", "utf8, cp1252 or latin1" },
        .{ "--threshold", "2", "a fraction from 0 to 1" },
        .{ "--jobs", "0", "a count above 0" },
        .{ "--out-delimiter", "ab", "one ASCII byte, tab, \\t or \\xHH" },
        .{ "--out-newline", "cr", "lf or crlf" },
    };
    for (cases) |c| {
        var buf: [128]u8 = undefined;
        const message = try std.fmt.bufPrint(&buf, "{s} {s}: {s}", c);
        try expectUsage(&.{ "convert", "a.csv", c[0], c[1] }, message);
    }
    try expectUsage(&.{ "infer", "a.csv", "--sample", "0" }, "--sample 0: a row count above 0");
    try expectUsage(&.{ "run", "a.csv", "--to", "xml" }, "--to xml: csv or arrow");
}

test "-- ends the options" {
    const cfg = try expectConfig(&.{ "sniff", "--", "--json" });
    defer testing.allocator.free(cfg.files);
    try testing.expectEqualStrings("--json", cfg.files[0]);
    try testing.expect(!cfg.json);
}
