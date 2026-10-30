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
//! kept: inference never proposes a type that loses text.

const std = @import("std");
const Allocator = std.mem.Allocator;
const dp = @import("dateparsa");
const schema = @import("schema.zig");
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
};

pub const Options = struct {
    /// Strings read as null: "" and --null's.
    nulls: []const []const u8 = &.{""},
    encoding: types.Encoding = .utf8,
    day_first: bool = false,
};

/// One file's pass 1.
pub const Inferrer = struct {
    arena: Allocator,
    options: Options,
    columns: std.ArrayList(ColumnState) = .empty,
    rows: u64 = 0,
    format_buf: [128]u8 = undefined,

    pub fn init(arena: Allocator, options: Options) Inferrer {
        return .{ .arena = arena, .options = options };
    }

    /// Names the columns: the header's (trimmed, a blank or repeated one
    /// numbered), or column1, column2... for width columns without one.
    pub fn header(f: *Inferrer, names: ?[]const []const u8, width: usize) Allocator.Error!void {
        const n = if (names) |ns| ns.len else width;
        for (0..n) |i| {
            var name: []const u8 = if (names) |ns| std.mem.trim(u8, ns[i], " \t") else "";
            if (name.len == 0 or f.find(name) != null) {
                name = try std.fmt.allocPrint(f.arena, "column{d}", .{i + 1});
            } else name = try f.arena.dupe(u8, name);
            try f.columns.append(f.arena, .{ .name = name });
        }
    }

    fn find(f: *const Inferrer, name: []const u8) ?usize {
        for (f.columns.items, 0..) |c, i| if (std.ascii.eqlIgnoreCase(c.name, name)) return i;
        return null;
    }

    /// One record's values, in the header's order; a record wider than the
    /// header adds columns.
    pub fn record(f: *Inferrer, values: []const []const u8) Allocator.Error!void {
        f.rows += 1;
        while (f.columns.items.len < values.len) {
            try f.columns.append(f.arena, .{ .name = try std.fmt.allocPrint(f.arena, "column{d}", .{f.columns.items.len + 1}) });
        }
        for (values, f.columns.items[0..values.len]) |v, *c| try f.observe(c, v);
    }

    fn isNull(f: *const Inferrer, v: []const u8) bool {
        for (f.options.nulls) |n| if (std.mem.eql(u8, n, v)) return true;
        return false;
    }

    fn observe(f: *Inferrer, c: *ColumnState, v: []const u8) Allocator.Error!void {
        if (f.isNull(v)) {
            c.nulls += 1;
            return;
        }
        c.values += 1;
        c.max_len = @max(c.max_len, v.len);
        try f.sample(c, v);
        if (c.kind == .string) return f.noteString(c, v);
        const t = std.mem.trim(u8, v, " \t");
        c.kind = f.narrow(c, t);
        if (c.kind == .string) f.noteString(c, v);
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
                return numberFrom(c, v, .int64);
            },
            .int64, .decimal, .float64 => return numberFrom(c, v, c.kind),
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
        const k = numberFrom(c, v, .int64);
        if (k != .string) return k;
        return f.time(c, v) orelse .string;
    }

    /// The date or timestamp v is, the column's format updated, or null.
    fn time(f: *Inferrer, c: *ColumnState, v: []const u8) ?Kind {
        const r = dp.parseWith(v, .{ .prefer_day_first = f.options.day_first }) catch return null;
        if (r.kind != .absolute or r.layout.source != .program) return null;
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
fn decimalShape(v: []const u8) ?struct { int: usize, frac: usize } {
    var i: usize = 0;
    if (v.len > 0 and (v[0] == '-' or v[0] == '+')) i = 1;
    var int: usize = 0;
    var frac: usize = 0;
    var any = false;
    var significant = false;
    while (i < v.len and std.ascii.isDigit(v[i])) : (i += 1) {
        any = true;
        if (v[i] != '0') significant = true;
        if (significant) int += 1;
    }
    if (i < v.len and v[i] == '.') {
        i += 1;
        while (i < v.len and std.ascii.isDigit(v[i])) : (i += 1) {
            any = true;
            frac += 1;
        }
    }
    if (!any or i != v.len) return null;
    return .{ .int = int, .frac = frac };
}

/// The numeric type, at least from, that takes v as well as every value the
/// column has had: int64, then a decimal of up to 38 digits, then float64.
fn numberFrom(c: *ColumnState, v: []const u8, from: Kind) Kind {
    if (from == .int64) {
        if (types.int.parse(v)) |_| {
            const shape = decimalShape(v).?;
            c.int_digits = @intCast(@max(c.int_digits, shape.int));
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
                return .decimal;
            }
        }
    }
    if (types.float.parse(v) != null) return .float64;
    return .string;
}

/// The columns as a schema's, for infer's output: allocated in arena.
pub fn columnsOf(arena: Allocator, states: []const ColumnState) Allocator.Error![]schema.Column {
    const out = try arena.alloc(schema.Column, states.len);
    for (out, states) |*o, s| {
        var samples: std.ArrayList([]const u8) = .empty;
        for (s.samples) |x| if (x) |v| try samples.append(arena, v);
        o.* = .{
            .name = s.name,
            .type = switch (s.kind) {
                // A column of nothing but nulls: a string, the type that
                // takes anything a later file has.
                .null, .string => .string,
                .bool => .bool,
                .int64 => .int64,
                .decimal => .decimal,
                .float64 => .float64,
                .date => .date,
                .timestamp => .timestamp,
            },
            .inferred = true,
            .conformance = 1.0,
            .samples = try samples.toOwnedSlice(arena),
            .widened_by = s.widened_by,
        };
        switch (s.kind) {
            .decimal => {
                o.precision = @max(1, s.int_digits + s.scale);
                o.scale = s.scale;
            },
            .date, .timestamp => if (!s.format_mixed) {
                o.format = s.format;
            },
            .string => if (s.invalid_utf8) {
                o.utf8 = .replace;
            },
            else => {},
        }
    }
    return out;
}

/// The column a merge across files comes to: the lowest point either
/// reached, where "lowest" respects the chains (a number and a date meet
/// at string). file is the one b came from, named when it widened a.
pub fn merge(a: *ColumnState, b: ColumnState, file: []const u8) void {
    const before = a.kind;
    a.nulls += b.nulls;
    a.values += b.values;
    a.max_len = @max(a.max_len, b.max_len);
    a.invalid_utf8 = a.invalid_utf8 or b.invalid_utf8;
    for (b.samples) |s| if (s) |v| for (&a.samples) |*slot| {
        if (slot.* == null) {
            slot.* = v;
            break;
        }
    };
    const a_temporal = before.temporal();
    a.kind = join(a, b);
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

fn inferOne(arena: Allocator, values: []const []const u8) !ColumnState {
    var f: Inferrer = .init(arena, .{});
    try f.header(&.{"c"}, 1);
    for (values) |v| try f.record(&.{v});
    return f.columns.items[0];
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
    try testing.expectEqual(@as(u8, 3), cols[1].precision);
    try testing.expectEqualStrings("%Y-%m-%d", cols[2].format.?);
}
