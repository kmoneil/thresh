//! Shapes-only output (--shapes-only, --shape-names): what thresh says of
//! a file with every value in it written as its shape, so a report can be
//! handed to an AI or pasted into an issue without the data. The file's
//! structure and its problems stay; its contents do not: digits are 9,
//! letters a, any other non-ASCII character U, a run of one of those one
//! (stats.shape's rules, uncut). With names too, the column names are
//! shapes as well.
//!
//! Applied where thresh says something, never to what it reads: the
//! schema infer uses to read a file keeps its names; the one it writes is
//! shaped. Rows thresh writes (--to, the Arrow streams) are the data asked
//! for, and stay as they are; a reject file is nothing but rows, and the
//! CLI refuses --reject with shapes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Problem = @import("problem.zig").Problem;
const Presence = @import("problem.zig").Presence;
const schema = @import("schema.zig");
const stats = @import("stats.zig");
const Outcome = @import("report.zig").Outcome;

/// What is written as shapes: nothing, values, or values and column names.
pub const Shapes = enum { none, values, names };

/// v's shape, whole: as stats.shape, with no cut.
pub fn text(a: Allocator, v: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var last: u8 = 0;
    var i: usize = 0;
    while (i < v.len) {
        const c = stats.shapeOf(v[i]);
        i += c.step;
        if (c.s == last and (c.s == '9' or c.s == 'a' or c.s == 'U')) continue;
        try out.append(a, c.s);
        last = c.s;
    }
    return out.toOwnedSlice(a);
}

/// A column name as s says: its shape when names are.
pub fn name(a: Allocator, n: []const u8, s: Shapes) Allocator.Error![]const u8 {
    return if (s == .names) text(a, n) else n;
}

/// p with the column names it holds written as s says. A problem holds no
/// value of the file's, only names, counts and paths.
pub fn problem(a: Allocator, p: Problem, s: Shapes) Allocator.Error!Problem {
    if (s != .names) return p;
    var out = p;
    switch (out) {
        inline .column_missing, .column_extra, .column_not_utf8, .column_widened, .column_tolerated, .column_misfits => |*x| x.column = try text(a, x.column),
        .columns_thin => |*x| {
            const columns = try a.alloc([]const u8, x.columns.len);
            for (columns, x.columns) |*c, n| c.* = try text(a, n);
            x.columns = columns;
        },
        .files_columns => |*x| {
            const first = try a.alloc(Presence, x.first.len);
            for (first, x.first) |*f, y| f.* = .{ .column = try text(a, y.column), .files = y.files };
            x.first = first;
        },
        else => {},
    }
    return out;
}

/// A column's statistics with its values as shapes: its least and
/// greatest, and its most common values. Shapes and counts are as they were.
pub fn summary(a: Allocator, st: stats.Summary) Allocator.Error!stats.Summary {
    var out = st;
    if (st.min) |m| out.min = try text(a, m);
    if (st.max) |m| out.max = try text(a, m);
    const top = try a.alloc(stats.Summary.Value, st.top.len);
    for (top, st.top) |*t, x| t.* = .{ .value = try text(a, x.value), .count = x.count };
    out.top = top;
    return out;
}

/// A schema as infer writes it, with its values as shapes (the samples it
/// read, its statistics), and with s names, its column names too.
pub fn schemaOf(a: Allocator, sc: schema.Schema, s: Shapes) Allocator.Error!schema.Schema {
    if (s == .none) return sc;
    const columns = try a.alloc(schema.Column, sc.columns.len);
    for (columns, sc.columns) |*c, x| {
        c.* = x;
        c.name = try name(a, x.name, s);
        if (x.samples) |samples| {
            const out = try a.alloc([]const u8, samples.len);
            for (out, samples) |*o, v| o.* = try text(a, v);
            c.samples = out;
        }
        if (x.stats) |st| c.stats = try summary(a, st);
    }
    var out = sc;
    out.columns = columns;
    return out;
}

/// o with its problem's names as s says.
pub fn outcome(a: Allocator, o: Outcome, s: Shapes) Allocator.Error!Outcome {
    var out = o;
    if (o.problem) |p| out.problem = try problem(a, p, s);
    return out;
}

const testing = std.testing;

test "a value is its shape, whole" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("a_a_9", try text(a, "AB_CD_12"));
    try testing.expectEqualStrings("9,a,9.9,\"a a\"", try text(a, "4,Brookwood,16.25,\"two wrong\""));
    // Uncut: past the 32 bytes the statistics keep of a shape.
    var buf: [60]u8 = undefined;
    for (0..20) |i| @memcpy(buf[i * 3 ..][0..3], "a1 ");
    try testing.expectEqual(@as(usize, 60), (try text(a, &buf)).len);
}

test "a problem's column names, only with names" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p: Problem = .{ .column_missing = .{ .column = "lug_kg" } };
    try testing.expectEqualStrings("lug_kg", (try problem(a, p, .values)).column_missing.column);
    try testing.expectEqualStrings("a_a", (try problem(a, p, .names)).column_missing.column);
    const thin: Problem = .{ .columns_thin = .{ .columns = &.{ "brix", "picked_on" }, .count = 2, .few_values = 10 } };
    const masked = (try problem(a, thin, .names)).columns_thin;
    try testing.expectEqualStrings("a_a", masked.columns[1]);
    // The original is left as it was.
    try testing.expectEqualStrings("picked_on", thin.columns_thin.columns[1]);
}
