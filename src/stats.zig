//! Column statistics: what lets a person or an AI reason about a column
//! without reading it. A column's memory is bounded whatever the file's
//! size, and its work comes at two costs:
//!
//! - Every value: how many are empty, the shortest and longest, and the
//!   least and greatest of an ordered type (numbers, dates, timestamps,
//!   times). A comparison or two a value.
//! - A sample of rows: distinct values (exact up to max_distinct), the
//!   most common values and the most common shapes (Space-Saving: exact
//!   counts until more values than its slots are seen, upper bounds
//!   after). The sample is every row of a file of up to sample_target
//!   rows, and rows spread evenly through a larger one (strideFor).
//!
//! Summary is what the report and the schema carry.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const types = @import("types.zig");
const date = @import("types/date.zig");

/// Distinct values counted exactly; past it the count says "at least".
pub const max_distinct = 1000;
/// The values and shapes kept count of, and how many are shown.
pub const top_slots = 64;
pub const top_shown = 5;
pub const shape_slots = 16;
pub const shapes_shown = 3;
/// A value longer than this is not one of the most common; a shape is cut
/// to shape_bytes.
pub const value_bytes = 64;
pub const shape_bytes = 32;
/// About how many rows the sampled counts are over.
pub const sample_target = 65_536;

/// Every stride-th row is sampled, for a file of bytes whose first
/// sample_len bytes held records rows: about sample_target rows.
pub fn strideFor(bytes: u64, records: usize, sample_len: usize) u64 {
    if (records == 0 or sample_len == 0) return 1;
    const rows = @as(u128, bytes) * records / sample_len;
    return @max(1, std.math.cast(u64, rows / sample_target) orelse std.math.maxInt(u64));
}

/// A column's least or greatest ordered value: an integer (an int64, a
/// decimal scaled by 10^scale, a date, timestamp or time in microseconds)
/// while every value has been one, a float once one is not.
pub const Extreme = union(enum) { int: i128, float: f64 };

/// How a column's min and max are written.
pub const Format = union(enum) {
    /// Not an ordered type: no min or max.
    none,
    int,
    float,
    /// A decimal of this scale.
    decimal: u8,
    date,
    timestamp,
    time,
};

/// Distinct values, by their 64-bit hash, up to max_distinct.
const Distinct = struct {
    slots: [2048]u64 = @splat(0),
    count: u32 = 0,
    full: bool = false,

    fn add(d: *Distinct, h: u64) void {
        if (d.full) return;
        const key = if (h == 0) 1 else h;
        var i: usize = @intCast(key & (d.slots.len - 1));
        while (true) : (i = (i + 1) & (d.slots.len - 1)) {
            if (d.slots[i] == key) return;
            if (d.slots[i] != 0) continue;
            d.slots[i] = key;
            d.count += 1;
            d.full = d.count >= max_distinct;
            return;
        }
    }

    fn merge(d: *Distinct, o: *const Distinct) void {
        if (o.full) d.full = true;
        for (o.slots) |k| if (k != 0) d.add(k);
    }
};

/// The most common of a stream of texts, Space-Saving: each text seen has
/// a slot while there is one; a new text when they are full takes a least
/// counted slot and its count, plus one, so a count is exact until a slot
/// is taken over and an upper bound after. A hash index finds a text's
/// slot in a probe or two, and a cursor over the slots at the least count
/// finds the one to take in about one step: counts only grow, so a slot
/// passed over stays above it until every slot is.
fn Counter(comptime slots: usize, comptime bytes: usize) type {
    return struct {
        const Self = @This();
        const empty_slot = std.math.maxInt(u8);
        const index_len = slots * 4;
        comptime {
            std.debug.assert(slots < empty_slot and std.math.isPowerOfTwo(index_len));
        }

        hashes: [slots]u64 = undefined,
        counts: [slots]u64 = undefined,
        lens: [slots]u8 = undefined,
        texts: [slots][bytes]u8 = undefined,
        used: usize = 0,
        estimated: bool = false,
        /// Slot numbers by hash, linear probing. A slot taken over leaves
        /// its old entry, which a probe passes (its slot's hash differs)
        /// until the index is rebuilt, every slots takeovers.
        index: [index_len]u8 = @splat(empty_slot),
        stale: usize = 0,
        /// No count is below least; the cursor's slot is the next to look
        /// at for one that is it.
        least: u64 = 0,
        cursor: usize = 0,

        fn find(c: *const Self, text: []const u8, h: u64) ?usize {
            var i: usize = @intCast(h & (index_len - 1));
            while (true) : (i = (i + 1) & (index_len - 1)) {
                const s = c.index[i];
                if (s == empty_slot) return null;
                if (c.hashes[s] == h and std.mem.eql(u8, c.texts[s][0..c.lens[s]], text)) return s;
            }
        }

        fn link(c: *Self, s: usize, h: u64) void {
            var i: usize = @intCast(h & (index_len - 1));
            while (c.index[i] != empty_slot) i = (i + 1) & (index_len - 1);
            c.index[i] = @intCast(s);
        }

        fn add(c: *Self, text: []const u8, h: u64) void {
            if (c.find(text, h)) |s| {
                c.counts[s] += 1;
                return;
            }
            c.put(text, h, 1);
        }

        /// text, with count more than it had; a new text takes a slot.
        fn put(c: *Self, text: []const u8, h: u64, count: u64) void {
            var s = c.used;
            var base: u64 = 0;
            if (s < slots) {
                c.used += 1;
            } else {
                s = c.takeLeast();
                base = c.counts[s];
                c.estimated = true;
                c.stale += 1;
                if (c.stale == slots) c.rebuild();
            }
            c.hashes[s] = h;
            c.counts[s] = base + count;
            c.lens[s] = @intCast(text.len);
            @memcpy(c.texts[s][0..text.len], text);
            c.link(s, h);
        }

        /// A slot at the least count, the cursor moved past it.
        fn takeLeast(c: *Self) usize {
            while (true) {
                while (c.cursor < slots) : (c.cursor += 1) {
                    if (c.counts[c.cursor] == c.least) {
                        c.cursor += 1;
                        return c.cursor - 1;
                    }
                }
                c.least = std.mem.min(u64, &c.counts);
                c.cursor = 0;
            }
        }

        fn rebuild(c: *Self) void {
            @memset(&c.index, empty_slot);
            for (0..c.used) |s| c.link(s, c.hashes[s]);
            c.stale = 0;
        }

        fn merge(c: *Self, o: *const Self) void {
            if (o.estimated) c.estimated = true;
            for (0..o.used) |j| {
                const text = o.texts[j][0..o.lens[j]];
                if (c.find(text, o.hashes[j])) |s| {
                    c.counts[s] += o.counts[j];
                } else {
                    c.put(text, o.hashes[j], o.counts[j]);
                }
            }
        }

        /// The slots' indexes, the most counted first, at most n of them,
        /// each counted at least least times.
        fn top(c: *const Self, out: []usize, at_least: u64) []usize {
            var n: usize = 0;
            for (0..c.used) |i| {
                if (c.counts[i] < at_least) continue;
                // Insertion into the n kept, most counted first; a tie keeps
                // the one seen first.
                var at = n;
                while (at > 0 and c.counts[out[at - 1]] < c.counts[i]) at -= 1;
                if (at >= out.len) continue;
                if (n < out.len) n += 1;
                var k = n - 1;
                while (k > at) : (k -= 1) out[k] = out[k - 1];
                out[at] = i;
            }
            return out[0..n];
        }
    };
}

/// v's shape: digits as 9, ASCII letters as a, any other non-ASCII
/// character as U, a run of one of those as one, and every other byte as
/// it is: "0614141000012" is "9", "AB_CD_12" is "a_a_9". Cut at
/// shape_bytes.
pub fn shape(buf: *[shape_bytes]u8, v: []const u8) []const u8 {
    var n: usize = 0;
    var last: u8 = 0;
    var i: usize = 0;
    while (i < v.len and n < buf.len) {
        const c = shapeOf(v[i]);
        i += c.step;
        if (c.s == last and (c.s == '9' or c.s == 'a' or c.s == 'U')) continue;
        buf[n] = c.s;
        n += 1;
        last = c.s;
    }
    return buf[0..n];
}

/// What the byte b stands for in a shape, and how many bytes on its
/// character is: a non-ASCII character's lead byte stands for all of it.
pub fn shapeOf(b: u8) struct { s: u8, step: usize } {
    if (std.ascii.isDigit(b)) return .{ .s = '9', .step = 1 };
    if (std.ascii.isAlphabetic(b)) return .{ .s = 'a', .step = 1 };
    if (b < 0x80) return .{ .s = b, .step = 1 };
    return .{ .s = 'U', .step = @max(1, std.unicode.utf8ByteSequenceLength(b) catch 1) };
}

fn blank(v: []const u8) bool {
    return v.len == 0 or ((v[0] == ' ' or v[0] == '\t') and std.mem.trim(u8, v, " \t").len == 0);
}

/// What a column's sampled rows add to: kilobytes, so apart from what
/// every value updates, which a wide row touches column after column.
const Sampled = struct {
    distinct: Distinct = .{},
    top: Counter(top_slots, value_bytes) = .{},
    shapes: Counter(shape_slots, shape_bytes) = .{},
};

/// One column's statistics, as its values come. init allocates what the
/// sampled rows add to; deinit frees it.
pub const Column = struct {
    /// Values read, not null.
    values: u64 = 0,
    /// Values empty or only spaces, null or not.
    empty: u64 = 0,
    len_min: u64 = std.math.maxInt(u64),
    len_max: u64 = 0,
    /// The least and greatest ordered value, while there is one: as
    /// integers until a float comes (infer's numbers widen), floats after.
    order: enum { none, int, float } = .none,
    imin: i128 = 0,
    imax: i128 = 0,
    fmin: f64 = 0,
    fmax: f64 = 0,
    /// The values the distinct, top and shape counts are over.
    sampled: u64 = 0,
    /// The file's, so the most common values are made UTF-8.
    encoding: types.Encoding = .utf8,
    counts: *Sampled,

    pub fn init(gpa: Allocator, encoding: types.Encoding) Allocator.Error!Column {
        const s = try gpa.create(Sampled);
        s.* = .{};
        return .{ .counts = s, .encoding = encoding };
    }

    pub fn deinit(c: *Column, gpa: Allocator) void {
        gpa.destroy(c.counts);
    }

    /// A field of the column, null or not: is it empty.
    pub fn field(c: *Column, v: []const u8) void {
        if (blank(v)) c.empty += 1;
    }

    /// An ordered value that fits, as an integer: an int64, a decimal
    /// scaled, a date, timestamp or time in microseconds.
    pub fn int(c: *Column, x: i128) void {
        switch (c.order) {
            .int => {
                c.imin = @min(c.imin, x);
                c.imax = @max(c.imax, x);
            },
            .float => c.float(@floatFromInt(x)),
            .none => {
                c.order = .int;
                c.imin = x;
                c.imax = x;
            },
        }
    }

    /// An ordered value that fits, as a float; NaN has no place in an order.
    pub fn float(c: *Column, f: f64) void {
        if (std.math.isNan(f)) return;
        switch (c.order) {
            .float => {
                c.fmin = @min(c.fmin, f);
                c.fmax = @max(c.fmax, f);
            },
            .int => {
                c.order = .float;
                c.fmin = @min(@as(f64, @floatFromInt(c.imin)), f);
                c.fmax = @max(@as(f64, @floatFromInt(c.imax)), f);
            },
            .none => {
                c.order = .float;
                c.fmin = f;
                c.fmax = f;
            },
        }
    }

    /// A value that is not null, fitting or not; sampled when its row is.
    pub fn value(c: *Column, v: []const u8, sampled: bool) void {
        c.values += 1;
        c.len_min = @min(c.len_min, v.len);
        c.len_max = @max(c.len_max, v.len);
        if (!sampled) return;
        c.sampled += 1;
        const h = std.hash.Wyhash.hash(0, v);
        c.counts.distinct.add(h);
        if (v.len <= value_bytes) c.counts.top.add(v, h);
        var buf: [shape_bytes]u8 = undefined;
        const s = shape(&buf, v);
        c.counts.shapes.add(s, std.hash.Wyhash.hash(1, s));
    }

    /// o's counts added to c's, as infer merges a column across files.
    pub fn merge(c: *Column, o: *const Column) void {
        c.values += o.values;
        c.empty += o.empty;
        c.len_min = @min(c.len_min, o.len_min);
        c.len_max = @max(c.len_max, o.len_max);
        switch (o.order) {
            .none => {},
            .int => {
                c.int(o.imin);
                c.int(o.imax);
            },
            .float => {
                c.float(o.fmin);
                c.float(o.fmax);
            },
        }
        c.sampled += o.sampled;
        c.counts.distinct.merge(&o.counts.distinct);
        c.counts.top.merge(&o.counts.top);
        c.counts.shapes.merge(&o.counts.shapes);
    }

    /// The statistics as the report and the schema have them, the column's
    /// min and max written as format says.
    pub fn summary(c: *const Column, a: Allocator, format: Format) Allocator.Error!Summary {
        var s: Summary = .{ .values = c.values, .empty = c.empty };
        if (c.values > 0) s.length = .{ .min = c.len_min, .max = c.len_max };
        if (format != .none) switch (c.order) {
            .none => {},
            .int => {
                s.min = try textOf(a, .{ .int = c.imin }, format);
                s.max = try textOf(a, .{ .int = c.imax }, format);
            },
            .float => {
                s.min = try textOf(a, .{ .float = c.fmin }, format);
                s.max = try textOf(a, .{ .float = c.fmax }, format);
            },
        };
        if (c.sampled > 0) {
            const k = c.counts;
            s.distinct = k.distinct.count;
            if (k.distinct.full) s.distinct_at_least = true;
            var idx: [top_shown]usize = undefined;
            const tops = k.top.top(&idx, 2);
            const values = try a.alloc(Summary.Value, tops.len);
            for (values, tops) |*v, i| v.* = .{ .value = try types.utf8Of(a, k.top.texts[i][0..k.top.lens[i]], c.encoding), .count = k.top.counts[i] };
            s.top = values;
            if (k.top.estimated and tops.len > 0) s.top_estimated = true;
            var sidx: [shapes_shown]usize = undefined;
            const shapes = k.shapes.top(&sidx, 1);
            const out = try a.alloc(Summary.Shape, shapes.len);
            for (out, shapes) |*v, i| v.* = .{ .shape = try a.dupe(u8, k.shapes.texts[i][0..k.shapes.lens[i]]), .count = k.shapes.counts[i] };
            s.shapes = out;
            if (k.shapes.estimated) s.shapes_estimated = true;
        }
        if (c.sampled < c.values) s.sampled = c.sampled;
        return s;
    }
};

/// m as text: a number as JSON would spell it, a decimal at its scale, a
/// date, timestamp or time as RFC 3339 has it.
fn textOf(a: Allocator, m: Extreme, format: Format) Allocator.Error![]const u8 {
    var w: Io.Writer.Allocating = .init(a);
    writeOrdered(&w.writer, m, format) catch return error.OutOfMemory;
    return w.written();
}

fn writeOrdered(w: *Io.Writer, m: Extreme, format: Format) Io.Writer.Error!void {
    // A float too large for the integer the type is written from is
    // written as the float it is.
    const whole: ?i128 = switch (m) {
        .int => |n| n,
        .float => |f| switch (format) {
            .decimal => |scale| wholeOf(@round(f * std.math.pow(f64, 10, @floatFromInt(scale)))),
            else => wholeOf(@trunc(f)),
        },
    };
    switch (format) {
        .none => {},
        .int => try w.print("{d}", .{whole orelse return writeFloat(w, m.float)}),
        .float => switch (m) {
            .int => |n| try w.print("{d}", .{n}),
            .float => |f| try writeFloat(w, f),
        },
        .decimal => |scale| {
            // validate's integers are scaled already; infer's floats, above.
            const x = whole orelse return writeFloat(w, m.float);
            const unit = std.math.powi(u128, 10, scale) catch unreachable;
            const mag: u128 = @abs(x);
            if (x < 0) try w.writeByte('-');
            try w.print("{d}", .{mag / unit});
            if (scale > 0) try w.print(".{d:0>[1]}", .{ mag % unit, scale });
        },
        .date, .timestamp => {
            const micros = std.math.cast(i64, whole orelse return writeFloat(w, m.float)) orelse return w.print("{d}", .{whole.?});
            const d = date.civil(@divFloor(micros, 86_400_000_000));
            try w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u32, @intCast(@max(d.year, 0))), d.month, d.day });
            if (format == .date) return;
            try w.writeByte('T');
            try writeTimeOfDay(w, @mod(micros, 86_400_000_000));
            try w.writeByte('Z');
        },
        .time => try writeTimeOfDay(w, std.math.cast(i64, whole orelse 0) orelse 0),
    }
}

/// f as JSON would spell it: decimal digits, or an exponent for one so
/// large or small that the digits would run on.
fn writeFloat(w: *Io.Writer, f: f64) Io.Writer.Error!void {
    const mag = @abs(f);
    if (mag != 0 and (mag >= 1e21 or mag < 1e-6)) return w.print("{e}", .{f});
    return w.print("{d}", .{f});
}

/// f as an integer, when it is finite and one fits.
fn wholeOf(f: f64) ?i128 {
    if (!std.math.isFinite(f) or @abs(f) >= 1.0e38) return null;
    return @intFromFloat(f);
}

fn writeTimeOfDay(w: *Io.Writer, micros: i64) Io.Writer.Error!void {
    const secs: u64 = @intCast(@divFloor(micros, 1_000_000));
    const frac: u64 = @intCast(@mod(micros, 1_000_000));
    try w.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ secs / 3600, secs % 3600 / 60, secs % 60 });
    if (frac != 0) try w.print(".{d:0>6}", .{frac});
}

/// A column's statistics as the report and the schema carry them
/// (docs/REPORT.md has every field).
pub const Summary = struct {
    values: u64 = 0,
    empty: u64 = 0,
    length: ?Range = null,
    min: ?[]const u8 = null,
    max: ?[]const u8 = null,
    distinct: ?u64 = null,
    distinct_at_least: ?bool = null,
    top: []const Value = &.{},
    top_estimated: ?bool = null,
    shapes: []const Shape = &.{},
    shapes_estimated: ?bool = null,
    sampled: ?u64 = null,

    pub const Range = struct { min: u64, max: u64 };
    pub const Value = struct { value: []const u8, count: u64 };
    pub const Shape = struct { shape: []const u8, count: u64 };

    /// s and every string it holds, copied into a.
    pub fn dupe(s: Summary, a: Allocator) Allocator.Error!Summary {
        var out = s;
        if (s.min) |m| out.min = try a.dupe(u8, m);
        if (s.max) |m| out.max = try a.dupe(u8, m);
        const top = try a.alloc(Value, s.top.len);
        for (top, s.top) |*t, x| t.* = .{ .value = try a.dupe(u8, x.value), .count = x.count };
        out.top = top;
        const shapes = try a.alloc(Shape, s.shapes.len);
        for (shapes, s.shapes) |*t, x| t.* = .{ .shape = try a.dupe(u8, x.shape), .count = x.count };
        out.shapes = shapes;
        return out;
    }
};

const testing = std.testing;

test "shapes: digits, letters, other characters, runs as one" {
    var buf: [shape_bytes]u8 = undefined;
    try testing.expectEqualStrings("9", shape(&buf, "0614141000012"));
    try testing.expectEqualStrings("a_a_9", shape(&buf, "AB_CD_12"));
    try testing.expectEqualStrings("9/9/9 9:9:9", shape(&buf, "06/14/2025 07:43:20"));
    try testing.expectEqualStrings("aUa", shape(&buf, "caf\u{e9}s"));
    try testing.expectEqualStrings("U", shape(&buf, "\u{65e5}\u{672c}"));
    try testing.expectEqualStrings("", shape(&buf, ""));
}

test "every value: empty, lengths, min and max; a sample: distinct, top, shapes" {
    var c: Column = try .init(testing.allocator, .utf8);
    defer c.deinit(testing.allocator);
    for ([_][]const u8{ "12", "3", "", "3", "120", " ", "3" }) |v| {
        c.field(v);
        if (blank(v)) continue;
        c.value(v, true);
        c.int(try std.fmt.parseInt(i64, v, 10));
    }
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = try c.summary(arena.allocator(), .int);
    try testing.expectEqual(@as(u64, 5), s.values);
    try testing.expectEqual(@as(u64, 2), s.empty);
    try testing.expectEqual(Summary.Range{ .min = 1, .max = 3 }, s.length.?);
    try testing.expectEqualStrings("3", s.min.?);
    try testing.expectEqualStrings("120", s.max.?);
    try testing.expectEqual(@as(?u64, 3), s.distinct);
    // Only a value seen twice or more is one of the most common.
    try testing.expectEqual(@as(usize, 1), s.top.len);
    try testing.expectEqualStrings("3", s.top[0].value);
    try testing.expectEqual(@as(u64, 3), s.top[0].count);
    try testing.expectEqualStrings("9", s.shapes[0].shape);
    try testing.expectEqual(@as(u64, 5), s.shapes[0].count);
    try testing.expectEqual(@as(?bool, null), s.top_estimated);
    try testing.expectEqual(@as(?u64, null), s.sampled);
}

test "past its caps: distinct at least, counts as upper bounds, the frequent still found" {
    var c: Column = try .init(testing.allocator, .utf8);
    defer c.deinit(testing.allocator);
    var buf: [16]u8 = undefined;
    for (0..5000) |i| {
        // "often" every third value, the rest all different.
        const v = if (i % 3 == 0) "often" else try std.fmt.bufPrint(&buf, "v{d}", .{i});
        c.value(v, true);
    }
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = try c.summary(arena.allocator(), .none);
    try testing.expectEqual(@as(?u64, max_distinct), s.distinct);
    try testing.expectEqual(@as(?bool, true), s.distinct_at_least);
    try testing.expectEqualStrings("often", s.top[0].value);
    try testing.expect(s.top[0].count >= 1667);
    try testing.expectEqual(@as(?bool, true), s.top_estimated);
    try testing.expectEqual(@as(?[]const u8, null), s.min);
}

test "only sampled rows count towards distinct, top and shapes" {
    var c: Column = try .init(testing.allocator, .utf8);
    defer c.deinit(testing.allocator);
    for (0..10) |i| c.value("x", i % 5 == 0);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = try c.summary(arena.allocator(), .none);
    try testing.expectEqual(@as(u64, 10), s.values);
    try testing.expectEqual(@as(?u64, 2), s.sampled);
    try testing.expectEqual(@as(u64, 2), s.top[0].count);
}

test "min and max, written as their type" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // validate's decimals come scaled; infer's as floats.
    try testing.expectEqualStrings("-12.05", try textOf(a, .{ .int = -1205 }, .{ .decimal = 2 }));
    try testing.expectEqualStrings("7", try textOf(a, .{ .int = 7 }, .{ .decimal = 0 }));
    try testing.expectEqualStrings("17.50", try textOf(a, .{ .float = 17.5 }, .{ .decimal = 2 }));
    const day: i128 = 20710 * 86_400_000_000;
    try testing.expectEqualStrings("2026-09-14", try textOf(a, .{ .int = day }, .date));
    try testing.expectEqualStrings("2026-09-14T06:30:00Z", try textOf(a, .{ .int = day + 23_400_000_000 }, .timestamp));
    try testing.expectEqualStrings("06:30:00.500000", try textOf(a, .{ .int = 23_400_500_000 }, .time));
    try testing.expectEqualStrings("17.5", try textOf(a, .{ .float = 17.5 }, .float));
    try testing.expectEqualStrings("-3", try textOf(a, .{ .int = -3 }, .int));
    // Too large for its type's integer: the float as it is.
    try testing.expectEqualStrings("1e300", try textOf(a, .{ .float = 1e300 }, .{ .decimal = 2 }));
}

test "extremes: integers until a float comes, then floats" {
    var c: Column = try .init(testing.allocator, .utf8);
    defer c.deinit(testing.allocator);
    c.int(4);
    c.int(-2);
    try testing.expectEqual(@as(i128, -2), c.imin);
    c.float(2.5);
    c.float(std.math.nan(f64));
    c.int(9);
    try testing.expectEqual(@as(f64, -2), c.fmin);
    try testing.expectEqual(@as(f64, 9), c.fmax);
}

test "merged across files: counts add, extremes widen" {
    var a: Column = try .init(testing.allocator, .utf8);
    defer a.deinit(testing.allocator);
    var b: Column = try .init(testing.allocator, .utf8);
    defer b.deinit(testing.allocator);
    a.value("1", true);
    a.int(1);
    b.value("9", true);
    b.int(9);
    b.value("1", true);
    b.int(1);
    a.merge(&b);
    try testing.expectEqual(@as(u64, 3), a.values);
    try testing.expectEqual(@as(i128, 9), a.imax);
    try testing.expectEqual(@as(u32, 2), a.counts.distinct.count);
    try testing.expectEqual(@as(u64, 2), a.counts.top.counts[0]);
}

test strideFor {
    try testing.expectEqual(@as(u64, 1), strideFor(1 << 20, 1000, 50_000));
    // 256 MiB at 50 bytes a row: about 5.4 million rows, every 81st.
    try testing.expectEqual(@as(u64, 81), strideFor(256 << 20, 1000, 50_000));
    try testing.expectEqual(@as(u64, 1), strideFor(100, 0, 0));
}
