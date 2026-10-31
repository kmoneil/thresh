//! Inference: a schema from known-good files, so the rest can be
//! validated against it.
//!
//! Pass 1 reads the whole file, not a sample, because a guess that meets
//! "N/A" on row four million cannot be undone once output is on disk. Each
//! column starts at the top of the lattice and only moves down:
//!
//!   null -> bool -> int64 -> decimal -> float64 -> date -> timestamp -> string
//!
//! A value the column's type refuses moves it to the next type down that
//! takes the value and every value before it. The lattice is two chains
//! that meet at string: numbers (bool, when its values are 0 and 1, then
//! int64, decimal, float64) and times (date, timestamp). A value from the
//! other chain, or "true" in a column of numbers, can only go to string,
//! and a column at string is not looked at again. So the type a column
//! ends with takes every value it saw: validating the file against the
//! inferred schema finds no mismatch, which the corpus tests check.
//!
//! A number spelled with a leading zero (0614141000012, 02134, 00.5) sends
//! its column to string. It is an identifier, a ZIP code or a padded field,
//! and as an int64 it would lose the zero in Arrow, where only the value is
//! kept: inference never proposes a type that loses text. So does a value
//! of digits alone too long for a decimal, that float64 would round (a
//! 48-digit key).
//!
//! An empty date as fixed-format exports write one ("  /  /    ") is set
//! aside. A column that ends a date or timestamp takes it as a null, its
//! spelling one of the column's nulls in the schema; any other column takes
//! it as a value, which only a string can.
//!
//! Exact is not always what a file means: a few rows of another kind (a
//! second header where two exports were joined) send a column of eight
//! million numbers to string. So when a value sends a typed column to
//! string, the column as it stood is kept beside it, reading every value
//! after as a column does, but counting, not taking, the ones that would
//! send it to string too. When few did, infer says which type the rest
//! fit; under --threshold the column takes that type, those values its
//! rejected ones.
//!
//! The schema is written for the next file, not only this one, so two
//! types are written wider than the lattice left them: a decimal gets at
//! least 18 digits of precision (the scale stays the one seen), and a bool
//! of nothing but 0s and 1s is an int64, a bool being for true/false,
//! yes/no and t/f. A typed column read from fewer than few_values values is
//! a guess the next file can break, and infer names it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const dp = @import("dateparsa");
const schema = @import("schema.zig");
const stats = @import("stats.zig");
const types = @import("types.zig");

/// The lattice, top first.
pub const Kind = enum(u8) {
    null,
    bool,
    int64,
    decimal,
    float64,
    date,
    timestamp,
    string,

    fn numeric(k: Kind) bool {
        return switch (k) {
            .bool, .int64, .decimal, .float64 => true,
            else => false,
        };
    }

    fn temporal(k: Kind) bool {
        return k == .date or k == .timestamp;
    }
};

/// The most decimal digits Arrow's Decimal128 holds.
const max_precision = 38;

/// The most significant digits every integer of that length keeps as a
/// float64 (2^53 is 9007199254740992, sixteen digits).
const float_exact_digits = 15;

/// The precision an inferred decimal has at least: an exact one, such as
/// decimal(5,5) from 0.00000, fails the next file's first 1.5, and 18
/// digits hold any amount or measure an export writes.
const widened_precision = 18;

/// Fewer non-null values than this behind a type other than string, and
/// the type is a guess.
pub const few_values = 10;

/// Whether col, inferred from state, is typed from too few values to trust.
pub fn thin(state: ColumnState, col: schema.Column) bool {
    return col.type != .string and state.values < few_values;
}

/// What pass 1 knows about one column.
pub const ColumnState = struct {
    name: []const u8,
    kind: Kind = .null,
    /// A bool column has had true/false, yes/no or t/f, not only 1 and 0:
    /// it can only go to string.
    bool_words: bool = false,
    nulls: u64 = 0,
    values: u64 = 0,
    max_len: u64 = 0,
    /// Digits before and after the point, the most of any value: a decimal
    /// column's precision and scale.
    int_digits: u8 = 0,
    scale: u8 = 0,
    /// The strftime format every date or timestamp value is spelled in, or
    /// null once two differ or one cannot be spelled.
    format: ?[]const u8 = null,
    format_mixed: bool = false,
    /// A value that is not UTF-8, read as UTF-8, and the first row it is
    /// in: worker.inferFile refuses the file, naming the encodings to try.
    invalid_utf8: bool = false,
    invalid_row: u64 = 0,
    samples: [3]?[]const u8 = .{ null, null, null },
    widened_by: ?[]const u8 = null,
    /// The spellings of an empty date the column has held, at most two (a
    /// date's and a timestamp's): its nulls if it ends one, values if not.
    blanks: [2]?[]const u8 = .{ null, null },
    /// The column as it stood before the value that sent it to string,
    /// reading every value since and counting, not taking, the ones only a
    /// string takes; null once there are more than max_misfits of them.
    rest: ?*ColumnState = null,
    /// The values rest refused, the first being the one that sent the
    /// column to string, and that one's row.
    misfits: u64 = 0,
    misfit_row: u64 = 0,
    /// Values a --threshold let the column refuse: its conformance.
    tolerated: u64 = 0,
    /// What its values are like (stats.zig), in the inferrer's arena.
    stats: ?*stats.Column = null,
};

/// The most values the rest of a column may refuse and still be followed.
const max_misfits = 100_000;

pub const Options = struct {
    /// Strings read as null: "" and --null's.
    nulls: []const []const u8 = &.{""},
    encoding: types.Encoding = .utf8,
    day_first: bool = false,
    /// Every stats_stride-th row is sampled for the columns' distinct,
    /// most common values and shapes (stats.strideFor).
    stats_stride: u64 = 1,
};

/// One file's pass 1.
pub const Inferrer = struct {
    arena: Allocator,
    options: Options,
    columns: std.ArrayList(ColumnState) = .empty,
    rows: u64 = 0,
    /// The source line of the record being read, which the caller sets for
    /// the rows it names; 0 names the data row instead.
    line: u64 = 0,
    /// The file has a header, which says how many columns it has.
    named: bool = false,
    /// Records wider than the header, left out, and the first one's line:
    /// ragged rows, which validate rejects, not columns.
    wide_rows: u64 = 0,
    wide_line: u64 = 0,
    format_buf: [128]u8 = undefined,
    /// The row being read is one the columns' statistics sample.
    sampled: bool = false,
    /// The instant time last read, in microseconds, and the number
    /// numberFrom last read, for the column's least and greatest.
    last_time: i64 = 0,
    last_number: ?stats.Extreme = null,

    pub fn init(arena: Allocator, options: Options) Inferrer {
        return .{ .arena = arena, .options = options };
    }

    /// Names the columns: the header's (trimmed, a blank or repeated one
    /// numbered), or column1, column2... for width columns without one.
    pub fn header(f: *Inferrer, names: ?[]const []const u8, width: usize) Allocator.Error!void {
        if (names) |ns| {
            f.named = true;
            for (try schema.headerNames(f.arena, ns)) |name| try f.addColumn(name);
            return;
        }
        for (0..width) |i| try f.addColumn(try std.fmt.allocPrint(f.arena, "column{d}", .{i + 1}));
    }

    fn addColumn(f: *Inferrer, name: []const u8) Allocator.Error!void {
        const s = try f.arena.create(stats.Column);
        s.* = try .init(f.arena, f.options.encoding);
        try f.columns.append(f.arena, .{ .name = name, .stats = s });
    }

    /// One record's values, in the header's order. A record wider than a
    /// header is counted and left out, as validate rejects it; one wider
    /// than the columns of a file without a header adds columns, since
    /// nothing else says how many it has.
    pub fn record(f: *Inferrer, values: []const []const u8) Allocator.Error!void {
        if (f.named and values.len > f.columns.items.len) {
            if (f.wide_rows == 0) f.wide_line = f.line;
            f.wide_rows += 1;
            return;
        }
        f.rows += 1;
        f.sampled = (f.rows - 1) % f.options.stats_stride == 0;
        while (f.columns.items.len < values.len) {
            try f.addColumn(try std.fmt.allocPrint(f.arena, "column{d}", .{f.columns.items.len + 1}));
        }
        for (values, f.columns.items[0..values.len]) |v, *c| try f.observe(c, v);
    }

    fn isNull(f: *const Inferrer, v: []const u8) bool {
        for (f.options.nulls) |n| if (std.mem.eql(u8, n, v)) return true;
        return false;
    }

    fn observe(f: *Inferrer, c: *ColumnState, v: []const u8) Allocator.Error!void {
        if (c.stats) |s| s.field(v);
        if (f.isNull(v)) {
            c.nulls += 1;
            return;
        }
        if (c.rest) |r| try f.follow(c, r, v);
        if ((c.kind == .null or c.kind.temporal()) and blankDate(v) and try keepBlank(f.arena, c, v)) return;
        c.values += 1;
        c.max_len = @max(c.max_len, v.len);
        try f.sample(c, v);
        if (c.stats) |s| s.value(v, f.sampled);
        if (c.kind == .string) return f.noteString(c, v);
        const t = std.mem.trim(u8, v, " \t");
        const before = Lattice.of(c);
        f.last_number = null;
        c.kind = f.narrow(c, t);
        if (c.stats) |s| f.extreme(s, c.kind, t);
        if (c.kind == .string and before.kind != .null) {
            // Sent to string: keep the column as it stood, to follow the rest.
            const r = c.rest orelse try f.arena.create(ColumnState);
            r.* = c.*;
            before.restore(r);
            r.rest = null;
            r.stats = null;
            c.rest = r;
            c.misfits = 1;
            c.misfit_row = if (f.line != 0) f.line else f.rows;
        }
        if (c.kind == .string) f.noteString(c, v);
    }

    /// Reads v into r, c's rest, moving it down as a column moves (an
    /// exponent takes a decimal to float64), or counts it refused when only
    /// a string would take it.
    fn follow(f: *Inferrer, c: *ColumnState, r: *ColumnState, v: []const u8) Allocator.Error!void {
        if ((r.kind == .null or r.kind.temporal()) and blankDate(v) and try keepBlank(f.arena, r, v)) return;
        const before = Lattice.of(r);
        r.kind = f.narrow(r, std.mem.trim(u8, v, " \t"));
        if (r.kind != .string) return;
        before.restore(r);
        c.misfits += 1;
        if (c.misfits > max_misfits) c.rest = null;
    }

    /// t, a value the column now has kind for, into its least and
    /// greatest. A number counts from a bool column's first values on, as
    /// 1 and 0 are the start of an int64 column too; a date or timestamp
    /// as the instant it was read as.
    fn extreme(f: *const Inferrer, s: *stats.Column, kind: Kind, t: []const u8) void {
        switch (kind) {
            // A bool column's 1s and 0s may be the start of an int64's.
            .bool => if (t.len == 1 and (t[0] == '0' or t[0] == '1')) s.int(t[0] - '0'),
            .int64, .decimal, .float64 => if (f.last_number) |x| switch (x) {
                .int => |n| s.int(n),
                .float => |v| s.float(v),
            },
            .date, .timestamp => s.int(f.last_time),
            .null, .string => {},
        }
    }

    fn noteString(f: *const Inferrer, c: *ColumnState, v: []const u8) void {
        if (f.options.encoding == .utf8 and !c.invalid_utf8 and !types.utf8.valid(v)) {
            c.invalid_utf8 = true;
            c.invalid_row = f.rows;
        }
    }

    fn sample(f: *Inferrer, c: *ColumnState, v: []const u8) Allocator.Error!void {
        for (&c.samples) |*s| {
            if (s.*) |have| {
                if (std.mem.eql(u8, have, v)) return;
                continue;
            }
            s.* = try f.arena.dupe(u8, v[0..@min(v.len, 64)]);
            return;
        }
    }

    /// The type the column moves to for v, recording what that type keeps.
    fn narrow(f: *Inferrer, c: *ColumnState, v: []const u8) Kind {
        if (zeroPadded(v)) return .string;
        switch (c.kind) {
            .null => return f.first(c, v),
            .bool => {
                if (types.boolean.parse(v, null, null) != null) {
                    if (!isBoolDigit(v)) c.bool_words = true;
                    return .bool;
                }
                // 1s and 0s are int64s; true and yes are not numbers.
                if (c.bool_words) return .string;
                c.int_digits = 1;
                return numberFrom(c, v, .int64, &f.last_number);
            },
            .int64, .decimal, .float64 => return numberFrom(c, v, c.kind, &f.last_number),
            .date, .timestamp => return f.time(c, v) orelse .string,
            .string => return .string,
        }
    }

    /// A column's first value: the first type down the lattice that takes it.
    fn first(f: *Inferrer, c: *ColumnState, v: []const u8) Kind {
        if (types.boolean.parse(v, null, null) != null) {
            c.bool_words = !isBoolDigit(v);
            // A lone digit could be the start of an int64 column as well;
            // the lattice says bool, and the next value settles it.
            return .bool;
        }
        const k = numberFrom(c, v, .int64, &f.last_number);
        if (k != .string) return k;
        return f.time(c, v) orelse .string;
    }

    /// The date or timestamp v is, the column's format updated, or null.
    fn time(f: *Inferrer, c: *ColumnState, v: []const u8) ?Kind {
        const r = dp.parseWith(v, .{ .prefer_day_first = f.options.day_first }) catch return null;
        if (r.kind != .absolute or r.layout.source != .program) return null;
        f.last_time = types.date.micros(r.time);
        var w: std.Io.Writer = .fixed(&f.format_buf);
        r.layout.formatString(.strftime, v, &w) catch {
            c.format_mixed = true;
        };
        const spelled = w.buffered();
        const has_time = hasTimeDirective(spelled);
        if (!c.format_mixed) {
            if (c.format) |have| {
                if (!std.mem.eql(u8, have, spelled)) c.format_mixed = true;
            } else if (spelled.len > 0) {
                c.format = f.arena.dupe(u8, spelled) catch null;
            }
        }
        // A date column takes a timestamp by becoming one; a timestamp
        // column takes a date as midnight.
        if (has_time or c.kind == .timestamp) return .timestamp;
        return .date;
    }
};

/// An empty date as fixed-format exports (FoxPro, dBase, COBOL) write one:
/// its separators, with spaces where the digits go, as "  /  /    " or
/// "  /  /       :  :  ". At least one / or :, and nothing else but
/// spaces, - and .: so a lone "-" is not one.
fn blankDate(v: []const u8) bool {
    var separator = false;
    for (v) |ch| switch (ch) {
        '/', ':' => separator = true,
        ' ', '-', '.' => {},
        else => return false,
    };
    return separator;
}

/// Sets v aside as one of c's empty dates, or says it is a third spelling,
/// which the column must take as a value.
fn keepBlank(arena: Allocator, c: *ColumnState, v: []const u8) Allocator.Error!bool {
    for (&c.blanks) |*slot| {
        if (slot.*) |have| {
            if (std.mem.eql(u8, have, v)) return true;
            continue;
        }
        slot.* = try arena.dupe(u8, v);
        return true;
    }
    return false;
}

/// The fields narrow may change: a column's place in the lattice.
const Lattice = struct {
    kind: Kind,
    bool_words: bool,
    int_digits: u8,
    scale: u8,
    format: ?[]const u8,
    format_mixed: bool,

    fn of(c: *const ColumnState) Lattice {
        return .{ .kind = c.kind, .bool_words = c.bool_words, .int_digits = c.int_digits, .scale = c.scale, .format = c.format, .format_mixed = c.format_mixed };
    }

    fn restore(l: Lattice, c: *ColumnState) void {
        c.kind = l.kind;
        c.bool_words = l.bool_words;
        c.int_digits = l.int_digits;
        c.scale = l.scale;
        c.format = l.format;
        c.format_mixed = l.format_mixed;
    }
};

/// Whether few of c's values, against all it holds, moved it from a type
/// the rest fit, written otherwise: at most 10, or under one in ten
/// thousand, and never more than one in a hundred, so the ordinary
/// narrowing of a column's first values (1, then 42) is not called that.
pub fn fewMisfits(c: ColumnState) bool {
    if (!restDiffers(c)) return false;
    const rows = c.values + c.nulls;
    return c.misfits <= @max(10, rows / 10_000) and c.misfits * 100 <= rows;
}

/// Whether c has a rest whose type the schema writes differently.
fn restDiffers(c: ColumnState) bool {
    const r = c.rest orelse return false;
    return typeOf(r.*) != typeOf(c);
}

/// The type c's rest fits, as the schema would write it.
pub fn restType(c: ColumnState) ?schema.Type {
    const r = c.rest orelse return null;
    return typeOf(r.*);
}

/// Gives c the type its rest fits when the values that refused it are at
/// most (1 - threshold) of the column, counting them as its rejected ones.
pub fn tolerate(c: *ColumnState, threshold: f64) bool {
    if (!restDiffers(c.*)) return false;
    const r = c.rest.?;
    const rows: f64 = @floatFromInt(c.values + c.nulls);
    if (@as(f64, @floatFromInt(c.misfits)) > (1.0 - threshold) * rows) return false;
    Lattice.of(r).restore(c);
    c.blanks = r.blanks;
    c.tolerated = c.misfits;
    c.rest = null;
    return true;
}

fn isBoolDigit(v: []const u8) bool {
    return std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "1");
}

/// A number whose integer part has a zero before another digit: 007,
/// -0123, 00.5. Not 0, 0.5 or 10.
fn zeroPadded(v: []const u8) bool {
    if (decimalShape(v) == null) return false;
    const digits = if (v.len > 0 and (v[0] == '-' or v[0] == '+')) v[1..] else v;
    return digits.len > 1 and digits[0] == '0' and std.ascii.isDigit(digits[1]);
}

fn hasTimeDirective(format: []const u8) bool {
    var i: usize = 0;
    while (std.mem.findScalarPos(u8, format, i, '%')) |p| : (i = p + 2) {
        if (p + 1 >= format.len) break;
        switch (format[p + 1]) {
            'H', 'I', 'M', 'S', 'p', 'z', 'f', 'T' => return true,
            else => {},
        }
    }
    return false;
}

/// The digits of a decimal: before the point (leading zeros not counted)
/// and after it. Null when v is not one.
fn decimalShape(v: []const u8) ?struct { int: usize, frac: usize, value: ?f64 } {
    var i: usize = 0;
    var negative = false;
    if (v.len > 0 and (v[0] == '-' or v[0] == '+')) {
        negative = v[0] == '-';
        i = 1;
    }
    var int: usize = 0;
    var frac: usize = 0;
    var any = false;
    var significant = false;
    // The digits as an integer while they fit one exactly, for the value.
    var mantissa: u64 = 0;
    var digits: usize = 0;
    while (i < v.len and std.ascii.isDigit(v[i])) : (i += 1) {
        any = true;
        if (v[i] != '0') significant = true;
        if (significant) int += 1;
        digits += 1;
        if (digits <= 18) mantissa = mantissa * 10 + (v[i] - '0');
    }
    if (i < v.len and v[i] == '.') {
        i += 1;
        while (i < v.len and std.ascii.isDigit(v[i])) : (i += 1) {
            any = true;
            frac += 1;
            digits += 1;
            if (digits <= 18) mantissa = mantissa * 10 + (v[i] - '0');
        }
    }
    if (!any or i != v.len) return null;
    const pow10 = [_]f64{ 1, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18 };
    // One division of exact numbers, as parseFloat rounds it, while the
    // digits fit; past 18 of them, parseFloat itself.
    const value: ?f64 = if (digits <= 18) blk: {
        const m: f64 = @floatFromInt(mantissa);
        break :blk (if (negative) -m else m) / pow10[frac];
    } else std.fmt.parseFloat(f64, v) catch null;
    return .{ .int = int, .frac = frac, .value = value };
}

/// The numeric type, at least from, that takes v as well as every value the
/// column has had: int64, then a decimal of up to 38 digits, then float64.
/// number is v's value, read on the way, for the column's statistics.
fn numberFrom(c: *ColumnState, v: []const u8, from: Kind, number: *?stats.Extreme) Kind {
    if (from == .int64) {
        if (types.int.parse(v)) |n| {
            const shape = decimalShape(v).?;
            c.int_digits = @intCast(@max(c.int_digits, shape.int));
            number.* = .{ .int = n };
            return .int64;
        } else |_| {}
    }
    if (from == .int64 or from == .decimal) {
        if (decimalShape(v)) |shape| {
            const int: u8 = @intCast(@min(@max(c.int_digits, shape.int), 255));
            const scale: u8 = @intCast(@min(@max(c.scale, shape.frac), 255));
            if (@as(usize, int) + scale <= max_precision) {
                c.int_digits = int;
                c.scale = scale;
                if (shape.value) |x| number.* = .{ .float = x };
                return .decimal;
            }
        }
    }
    if (types.float.parse(v)) |x| {
        // Digits alone, more than a float64 keeps: a key, not a quantity.
        if (integerDigits(v)) |n| if (n > float_exact_digits) return .string;
        number.* = .{ .float = x };
        return .float64;
    }
    return .string;
}

/// The significant digits of v when it is an integer (a sign and digits
/// alone), or null.
fn integerDigits(v: []const u8) ?usize {
    const digits = if (v.len > 0 and (v[0] == '-' or v[0] == '+')) v[1..] else v;
    if (digits.len == 0) return null;
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    return digits.len - (std.mem.findNone(u8, digits, "0") orelse digits.len);
}

/// The kind a column is written as: its lattice point, with empty dates
/// and 0-and-1 bools settled.
fn finalKind(s: ColumnState) Kind {
    var blank_time = false;
    var blank = false;
    for (s.blanks) |x| if (x) |v| {
        blank = true;
        blank_time = blank_time or std.mem.findScalar(u8, v, ':') != null;
    };
    var kind: Kind = if (!blank) s.kind else switch (s.kind) {
        // Nothing but empty dates: a date column, a timestamp's if they
        // have a time's colons.
        .null => if (blank_time) .timestamp else .date,
        .date, .timestamp, .string => s.kind,
        // Numbers and empty dates: only a string takes both.
        else => .string,
    };
    // 0s and 1s alone: a count or a flag that may yet hold a 2.
    if (kind == .bool and !s.bool_words) kind = .int64;
    return kind;
}

/// The type the schema writes for s.
pub fn typeOf(s: ColumnState) schema.Type {
    return switch (finalKind(s)) {
        // A column of nothing but nulls: a string, the type that takes
        // anything a later file has.
        .null, .string => .string,
        .bool => .bool,
        .int64 => .int64,
        .decimal => .decimal,
        .float64 => .float64,
        .date => .date,
        .timestamp => .timestamp,
    };
}

/// The columns as a schema's, for infer's output: allocated in arena.
pub fn columnsOf(arena: Allocator, states: []const ColumnState) Allocator.Error![]schema.Column {
    const out = try arena.alloc(schema.Column, states.len);
    for (out, states) |*o, s| {
        var samples: std.ArrayList([]const u8) = .empty;
        for (s.samples) |x| if (x) |v| try samples.append(arena, v);
        var blanks: std.ArrayList([]const u8) = .empty;
        for (s.blanks) |x| if (x) |v| try blanks.append(arena, v);
        const kind = finalKind(s);
        const rows: f64 = @floatFromInt(@max(1, s.values + s.nulls));
        o.* = .{
            .name = s.name,
            .type = typeOf(s),
            .inferred = true,
            .conformance = 1.0 - @as(f64, @floatFromInt(s.tolerated)) / rows,
            .samples = try samples.toOwnedSlice(arena),
            .widened_by = s.widened_by,
        };
        switch (kind) {
            .decimal => {
                o.precision = @max(widened_precision, s.int_digits + s.scale);
                o.scale = s.scale;
            },
            .date, .timestamp => {
                if (!s.format_mixed) o.format = s.format;
                o.nulls = blanks.items;
            },
            .string => if (s.invalid_utf8) {
                o.utf8 = .replace;
            },
            else => {},
        }
        if (s.stats) |st| {
            // A decimal's integers here are its values, not scaled ones as
            // validate's are.
            if (o.type == .decimal and st.order == .int) st.float(@floatFromInt(st.imin));
            o.stats = try st.summary(arena, o.statsFormat());
        }
    }
    return out;
}

/// The column a merge across files comes to: the lowest point either
/// reached, where "lowest" respects the chains (a number and a date meet
/// at string). file is the one b came from, named when it widened a.
pub fn merge(a: *ColumnState, b: ColumnState, file: []const u8) void {
    const before = a.kind;
    if (a.stats) |x| if (b.stats) |y| x.merge(y);
    a.nulls += b.nulls;
    a.values += b.values;
    a.tolerated += b.tolerated;
    // Which type the rest fits is a file's question, asked before a merge.
    a.rest = null;
    a.max_len = @max(a.max_len, b.max_len);
    a.invalid_utf8 = a.invalid_utf8 or b.invalid_utf8;
    for (b.samples) |s| if (s) |v| for (&a.samples) |*slot| {
        if (slot.* == null) {
            slot.* = v;
            break;
        }
    };
    // b's empty dates join a's; a third spelling is a value no date takes.
    var blank_overflow = false;
    for (b.blanks) |x| if (x) |v| {
        const kept = for (&a.blanks) |*slot| {
            if (slot.*) |have| {
                if (std.mem.eql(u8, have, v)) break true;
                continue;
            }
            slot.* = v;
            break true;
        } else false;
        if (!kept) blank_overflow = true;
    };
    const a_temporal = before.temporal();
    a.kind = if (blank_overflow) .string else join(a, b);
    if (a.kind.temporal() and b.kind.temporal()) {
        // One format between them, or none: a column read in two formats
        // keeps no format and is detected value by value.
        if (!a_temporal) {
            a.format = b.format;
            a.format_mixed = b.format_mixed;
        } else if (b.format_mixed or a.format == null or b.format == null or !std.mem.eql(u8, a.format.?, b.format.?)) {
            a.format_mixed = true;
        }
    }
    if (a.kind.numeric()) {
        a.int_digits = @max(a.int_digits, b.int_digits);
        a.scale = @max(a.scale, b.scale);
        a.bool_words = a.bool_words or b.bool_words;
        if (a.kind == .decimal and @as(usize, a.int_digits) + a.scale > max_precision) a.kind = .float64;
    }
    if (@backingInt(a.kind) > @backingInt(before) and before != .null) a.widened_by = file;
}

fn join(a: *const ColumnState, b: ColumnState) Kind {
    if (a.kind == .null) return b.kind;
    if (b.kind == .null) return a.kind;
    if (a.kind == b.kind) return a.kind;
    if (a.kind == .string or b.kind == .string) return .string;
    if (a.kind.temporal() and b.kind.temporal()) return .timestamp;
    if (a.kind.numeric() and b.kind.numeric()) {
        // A bool with words meets a number at string.
        if ((a.kind == .bool and a.bool_words) or (b.kind == .bool and b.bool_words)) return .string;
        return @fromBackingInt(@max(@backingInt(a.kind), @backingInt(b.kind)));
    }
    return .string;
}

const testing = std.testing;

test "decimalShape's value is parseFloat's" {
    try testing.expectEqual(@as(?f64, -17.5), decimalShape("-17.50").?.value);
    try testing.expectEqual(@as(?f64, 0.25), decimalShape("+.25").?.value);
    // Past 18 digits, parseFloat's own.
    try testing.expectEqual(@as(?f64, 1234567890.1234567891), decimalShape("1234567890.1234567891").?.value);
    var buf: [16]u8 = undefined;
    for (0..3000) |n| {
        const v = try std.fmt.bufPrint(&buf, "{d}.{d:0>3}", .{ n / 7, n % 1000 });
        try testing.expectEqual(try std.fmt.parseFloat(f64, v), decimalShape(v).?.value.?);
    }
}

fn inferOne(arena: Allocator, values: []const []const u8) !ColumnState {
    var f: Inferrer = .init(arena, .{});
    try f.header(&.{"c"}, 1);
    for (values) |v| try f.record(&.{v});
    return f.columns.items[0];
}

test "statistics follow the column's type as it widens" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 1 is read as a bool first, then the column is an int64: 1 counts.
    const ids = (try columnsOf(a, &.{try inferOne(a, &.{ "1", "40", "", "7" })}))[0];
    try testing.expectEqual(schema.Type.int64, ids.type);
    try testing.expectEqualStrings("1", ids.stats.?.min.?);
    try testing.expectEqualStrings("40", ids.stats.?.max.?);
    try testing.expectEqual(@as(u64, 3), ids.stats.?.values);
    try testing.expectEqual(@as(u64, 1), ids.stats.?.empty);
    // int64, then a decimal: written at the decimal's scale.
    const kg = (try columnsOf(a, &.{try inferOne(a, &.{ "12", "3.5", "-100.25" })}))[0];
    try testing.expectEqualStrings("-100.25", kg.stats.?.min.?);
    try testing.expectEqualStrings("12.00", kg.stats.?.max.?);
    const days = (try columnsOf(a, &.{try inferOne(a, &.{ "2026-09-14", "2026-01-02", "2026-12-31" })}))[0];
    try testing.expectEqual(schema.Type.date, days.type);
    try testing.expectEqualStrings("2026-01-02", days.stats.?.min.?);
    try testing.expectEqualStrings("2026-12-31", days.stats.?.max.?);
    // A string column has lengths, not a least and greatest.
    const words = (try columnsOf(a, &.{try inferOne(a, &.{ "pear", "fig", "pear" })}))[0];
    try testing.expectEqual(@as(?[]const u8, null), words.stats.?.min);
    try testing.expectEqual(stats.Summary.Range{ .min = 3, .max = 4 }, words.stats.?.length.?);
    try testing.expectEqualStrings("pear", words.stats.?.top[0].value);
}

test "the lattice moves down and only down" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(Kind.bool, (try inferOne(a, &.{ "1", "0", "", "1" })).kind);
    try testing.expectEqual(Kind.bool, (try inferOne(a, &.{ "true", "no", "T" })).kind);
    try testing.expectEqual(Kind.int64, (try inferOne(a, &.{ "1", "0", "42", "-7" })).kind);
    // true and then 2: no numeric type reads true.
    try testing.expectEqual(Kind.string, (try inferOne(a, &.{ "true", "2" })).kind);
    const d = try inferOne(a, &.{ "12", "3.5", "-100.25" });
    try testing.expectEqual(Kind.decimal, d.kind);
    try testing.expectEqual(@as(u8, 3), d.int_digits);
    try testing.expectEqual(@as(u8, 2), d.scale);
    try testing.expectEqual(Kind.float64, (try inferOne(a, &.{ "1.5", "2e-5" })).kind);
    try testing.expectEqual(Kind.decimal, (try inferOne(a, &.{"99999999999999999999"})).kind);
    try testing.expectEqual(Kind.float64, (try inferOne(a, &.{"1.00000000000000000000000000000000000001"})).kind);
    try testing.expectEqual(Kind.string, (try inferOne(a, &.{ "12", "N/A" })).kind);
    try testing.expectEqual(Kind.string, (try inferOne(a, &.{ "12", "2024-01-02" })).kind);
    try testing.expectEqual(Kind.null, (try inferOne(a, &.{ "", "" })).kind);
}

test "a row wider than the header is left out and counted, not a column" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Inferrer = .init(a, .{});
    try f.header(&.{ "id", "label" }, 2);
    try f.record(&.{ "1", "ab" });
    f.line = 3;
    try f.record(&.{ "2", "ab", " cd" });
    f.line = 0;
    try f.record(&.{ "3", "ef" });
    try testing.expectEqual(@as(usize, 2), f.columns.items.len);
    try testing.expectEqual(@as(u64, 2), f.rows);
    try testing.expectEqual(@as(u64, 1), f.wide_rows);
    try testing.expectEqual(@as(u64, 3), f.wide_line);
    try testing.expectEqual(Kind.int64, f.columns.items[0].kind);
    // Without a header, the widest row says how many columns there are.
    var g: Inferrer = .init(a, .{});
    try g.header(null, 2);
    try g.record(&.{ "1", "ab", "x" });
    try testing.expectEqual(@as(usize, 3), g.columns.items.len);
    try testing.expectEqual(@as(u64, 0), g.wide_rows);
}

test "digits too many for a decimal keep their column a string, not a float" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key48 = "123456789012345678901234567890123456789012345678";
    try testing.expectEqual(Kind.string, (try inferOne(a, &.{key48})).kind);
    try testing.expectEqual(Kind.string, (try inferOne(a, &.{ "7", key48 })).kind);
    // A float column meeting an integer it would round.
    try testing.expectEqual(Kind.string, (try inferOne(a, &.{ "1.5e3", "12345678901234567890" })).kind);
    try testing.expectEqual(Kind.float64, (try inferOne(a, &.{ "1.5e3", "42", "-0.25" })).kind);
    // Up to 38 digits a decimal holds it, exactly.
    try testing.expectEqual(Kind.decimal, (try inferOne(a, &.{"99999999999999999999"})).kind);
}

test "a number with a leading zero keeps its column a string" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // GS1's example GLN, a ZIP code, a padded sequence number.
    try testing.expectEqual(Kind.string, (try inferOne(a, &.{ "4006381333931", "0614141000012" })).kind);
    try testing.expectEqual(Kind.string, (try inferOne(a, &.{"02134"})).kind);
    try testing.expectEqual(Kind.string, (try inferOne(a, &.{ "0", "1", "0000000042" })).kind);
    try testing.expectEqual(Kind.string, (try inferOne(a, &.{ "1.5", "-00.5" })).kind);
    // A lone zero, and a zero before the point, are numbers.
    try testing.expectEqual(Kind.int64, (try inferOne(a, &.{ "0", "10", "-3" })).kind);
    try testing.expectEqual(Kind.decimal, (try inferOne(a, &.{ "0.5", "-0.25" })).kind);
    // Not a number at all: dates are read as dates.
    try testing.expectEqual(Kind.date, (try inferOne(a, &.{ "01/02/2026", "03/04/2026" })).kind);
}

test "an empty date is a null in a date column, and a value in any other" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const blank = "  /  /       :  :  ";
    var f: Inferrer = .init(a, .{});
    try f.header(&.{ "at", "only", "qty", "dash", "day" }, 5);
    try f.record(&.{ "06/14/2025 07:43:20", blank, blank, "-", "  /  /    " });
    try f.record(&.{ blank, blank, "12", "3", "01/02/2024" });
    try f.record(&.{ "01/02/2024 10:00:00", blank, "7", "4", "  /  /    " });
    const cols = try columnsOf(a, f.columns.items);
    try testing.expectEqual(schema.Type.timestamp, cols[0].type);
    try testing.expectEqualStrings("%m/%d/%Y %H:%M:%S", cols[0].format.?);
    try testing.expectEqual(@as(usize, 1), cols[0].nulls.len);
    try testing.expectEqualStrings(blank, cols[0].nulls[0]);
    // Nothing but empty ones: a timestamp column, as their colons say.
    try testing.expectEqual(schema.Type.timestamp, cols[1].type);
    // In a column of numbers they are values, and only a string takes them.
    try testing.expectEqual(schema.Type.string, cols[2].type);
    // A lone "-" is not an empty date.
    try testing.expectEqual(schema.Type.string, cols[3].type);
    try testing.expectEqual(schema.Type.date, cols[4].type);
    try testing.expectEqualStrings("  /  /    ", cols[4].nulls[0]);

    // Across files: a file of only empty dates gives its spelling to the
    // column the other file settled.
    var acc = try inferOne(a, &.{ "06/14/2025 07:43:20", "01/02/2024 10:00:00" });
    merge(&acc, try inferOne(a, &.{ blank, blank }), "b.csv");
    const merged = try columnsOf(a, &.{acc});
    try testing.expectEqual(schema.Type.timestamp, merged[0].type);
    try testing.expectEqualStrings(blank, merged[0].nulls[0]);
}

test "dates, timestamps and their format" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try inferOne(a, &.{ "2024-01-02", "2025-12-31" });
    try testing.expectEqual(Kind.date, d.kind);
    try testing.expectEqualStrings("%Y-%m-%d", d.format.?);
    const t = try inferOne(a, &.{ "2024-01-02", "2024-01-02 10:20:30" });
    try testing.expectEqual(Kind.timestamp, t.kind);
    try testing.expect(t.format_mixed);
    const s = try inferOne(a, &.{ "2024-01-02", "soon" });
    try testing.expectEqual(Kind.string, s.kind);
}

test "merging files takes the lowest point and names the file that widened it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var acc = try inferOne(a, &.{ "1", "2" });
    merge(&acc, try inferOne(a, &.{ "3", "4" }), "b.csv");
    try testing.expectEqual(Kind.int64, acc.kind);
    try testing.expectEqual(@as(?[]const u8, null), acc.widened_by);
    merge(&acc, try inferOne(a, &.{"x"}), "c.csv");
    try testing.expectEqual(Kind.string, acc.kind);
    try testing.expectEqualStrings("c.csv", acc.widened_by.?);
    var dec = try inferOne(a, &.{"1.5"});
    merge(&dec, try inferOne(a, &.{"1234"}), "d.csv");
    try testing.expectEqual(Kind.decimal, dec.kind);
    try testing.expectEqual(@as(u8, 4), dec.int_digits);
    var num = try inferOne(a, &.{"1"});
    merge(&num, try inferOne(a, &.{"2024-01-01"}), "e.csv");
    try testing.expectEqual(Kind.string, num.kind);
}

test "the inferred columns are a schema validate reads" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Inferrer = .init(a, .{});
    try f.header(&.{ "id", "amount", "at", "", "id" }, 5);
    try f.record(&.{ "1", "1.50", "2024-01-02", "x", "y" });
    try f.record(&.{ "2", "", "2024-01-03", "z", "w" });
    const cols = try columnsOf(a, f.columns.items);
    try testing.expectEqualStrings("column4", cols[3].name);
    try testing.expectEqualStrings("column5", cols[4].name);
    try testing.expectEqual(schema.Type.decimal, cols[1].type);
    try testing.expectEqual(@as(u8, 18), cols[1].precision);
    try testing.expectEqualStrings("%Y-%m-%d", cols[2].format.?);
}

test "a few values of another kind: the type the rest fit, and --threshold" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Inferrer = .init(a, .{});
    try f.header(&.{ "qty", "day", "text" }, 3);
    for (0..2000) |i| {
        f.line = i + 2;
        if (i == 1500) {
            // A second header, where two exports were joined.
            try f.record(&.{ "Qty.[Qty]", "Day.[Day]", "Text" });
            continue;
        }
        var buf: [16]u8 = undefined;
        try f.record(&.{ try std.fmt.bufPrint(&buf, "{d}", .{i + 2}), "01/02/2025", if (i % 2 == 0) "12" else "word" });
    }
    const qty = f.columns.items[0];
    try testing.expectEqual(Kind.string, qty.kind);
    try testing.expect(fewMisfits(qty));
    try testing.expectEqual(@as(u64, 1), qty.misfits);
    try testing.expectEqual(@as(u64, 1502), qty.misfit_row);
    try testing.expectEqual(schema.Type.int64, restType(qty).?);
    try testing.expectEqual(schema.Type.date, restType(f.columns.items[1]).?);
    // Ordinary narrowing after it is the rest's own: an exponent takes a
    // decimal column to float64, and is not one of the few.
    var g: Inferrer = .init(a, .{});
    try g.header(&.{"x"}, 1);
    for (0..500) |i| try g.record(&.{if (i == 100) "X.[X]" else if (i == 300) "1.5E-05" else "2.25"});
    try testing.expectEqual(@as(u64, 1), g.columns.items[0].misfits);
    try testing.expectEqual(schema.Type.float64, restType(g.columns.items[0]).?);
    // Text half of the time is not a few.
    try testing.expect(!fewMisfits(f.columns.items[2]));

    // --threshold 0.999 takes the rest's type and counts the row against it.
    var tol = qty;
    try testing.expect(tolerate(&tol, 0.999));
    const cols = try columnsOf(a, &.{tol});
    try testing.expectEqual(schema.Type.int64, cols[0].type);
    try testing.expectApproxEqAbs(@as(f64, 1999.0 / 2000.0), cols[0].conformance.?, 1e-12);
    // A stricter one does not.
    var strict = qty;
    try testing.expect(!tolerate(&strict, 0.9999));
    try testing.expectEqual(schema.Type.string, (try columnsOf(a, &.{strict}))[0].type);
}

test "the schema is written for the next file: decimals widened, 0 and 1 as int64" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Inferrer = .init(a, .{});
    try f.header(&.{ "zero", "bits", "words", "wide" }, 4);
    try f.record(&.{ "0.00000", "0", "yes", "12345678901234567.25" });
    try f.record(&.{ "0.00000", "1", "no", "1.5" });
    const cols = try columnsOf(a, f.columns.items);
    // decimal(5,5) would refuse 1.5; the scale seen stays.
    try testing.expectEqual(schema.Type.decimal, cols[0].type);
    try testing.expectEqual(@as(u8, 18), cols[0].precision);
    try testing.expectEqual(@as(u8, 5), cols[0].scale);
    try testing.expectEqual(schema.Type.int64, cols[1].type);
    try testing.expectEqual(schema.Type.bool, cols[2].type);
    // More digits than 18: as many as were seen.
    try testing.expectEqual(@as(u8, 19), cols[3].precision);
    // Two values behind each: all but the strings are guesses.
    for (f.columns.items, cols) |st, c| try testing.expect(thin(st, c));
    var many: Inferrer = .init(a, .{});
    try many.header(&.{ "n", "s" }, 2);
    for (0..few_values) |_| try many.record(&.{ "4", "x" });
    const settled = try columnsOf(a, many.columns.items);
    try testing.expect(!thin(many.columns.items[0], settled[0]));
    try testing.expect(!thin(many.columns.items[1], settled[1]));
}
