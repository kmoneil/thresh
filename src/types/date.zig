//! date and timestamp, read by dateparsa.
//!
//! With a format in the schema, the column's values are read with one
//! reusable Layout and no detection: the fast path. dateparsa builds a
//! layout by detecting a value, not from a format string, so the layout is
//! the one detected from the first value whose strftime spelling is the
//! schema's format, detected under the preferences that format implies
//! (%d before %m reads day first). Every value after it is layout.parse.
//! A numeric format whose field order dateparsa resolves per value
//! (%d/%m/%Y) has no reusable layout: each value is detected under the
//! format's order and must be spelled the format.
//!
//! Without a format, each column keeps a dateparsa.Parser, which detects
//! on the first value and again only when the cached layout refuses one,
//! and a dateparsa.Column, which gathers the orders (month first, day
//! first, year first) the ambiguous values still fit.
//!
//! No base time is ever given, so a relative form ("3 days ago") fails
//! with NoBaseTime: the right answer for a data file.

const std = @import("std");
const dp = @import("dateparsa");

pub const Kind = enum { date, timestamp };

pub const Problem = enum {
    /// Not a date dateparsa reads.
    not_date,
    /// A relative form or "now", which needs a base time a file never has.
    relative,
    /// Not in the schema's format.
    not_in_format,
    /// Read only by guessing the field order (--strict refuses it).
    ambiguous,
};

pub const Column = struct {
    format: ?[]const u8,
    options: dp.Options,
    strict: bool,
    /// The format's layout, once a value has shown it.
    layout: ?dp.Layout = null,
    parser: dp.Parser,
    orders: dp.Column,
    /// Values read with the format's layout, without detection.
    fast: u64 = 0,
    /// Values read by guessing their field order.
    ambiguous: u64 = 0,

    pub fn init(format: ?[]const u8, day_first: bool, strict: bool) Column {
        var options: dp.Options = .{ .prefer_day_first = day_first };
        if (format) |f| options = formatOptions(f, options);
        return .{
            .format = format,
            .options = options,
            .strict = strict,
            .parser = .init(options),
            .orders = .init(options),
        };
    }

    /// The value read, or why not.
    pub fn read(c: *Column, v: []const u8) union(enum) { ok: dp.DateTime, bad: Problem } {
        if (c.format) |f| {
            if (c.layout) |*l| {
                const t = l.parse(v) catch return .{ .bad = .not_in_format };
                c.fast += 1;
                return .{ .ok = t };
            }
            const r = dp.parseWith(v, c.options) catch |e| return .{ .bad = problemOf(e) };
            if (r.kind != .absolute) return .{ .bad = .relative };
            if (!spells(&r.layout, v, f)) return .{ .bad = .not_in_format };
            if (r.layout.reusable()) c.layout = r.layout;
            return .{ .ok = r.time };
        }
        const r = c.parser.parse(v) catch |e| return .{ .bad = problemOf(e) };
        if (r.kind != .absolute) return .{ .bad = .relative };
        if (r.layout.ambiguity_prone) c.orders.add(v);
        if (r.ambiguous) {
            c.ambiguous += 1;
            if (c.strict) return .{ .bad = .ambiguous };
        }
        return .{ .ok = r.time };
    }

    /// The orders every value whose order is decided per value fits.
    pub fn fits(c: *const Column) dp.Column.Orders {
        return c.orders.report().fits;
    }
};

fn problemOf(e: dp.ParseError) Problem {
    return switch (e) {
        error.NoBaseTime => .relative,
        error.NoMatch, error.Ambiguous => .not_date,
    };
}

/// Whether the layout detected from v is spelled format in strftime.
fn spells(l: *const dp.Layout, v: []const u8, format: []const u8) bool {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    l.formatString(.strftime, v, &w) catch return false;
    return std.mem.eql(u8, w.buffered(), format);
}

/// The preferences a strftime format implies: day first when %d (or %e)
/// comes before %m, year first when %Y or %y comes before both.
fn formatOptions(format: []const u8, base: dp.Options) dp.Options {
    var o = base;
    const day = firstOf(format, &.{ "%d", "%e" });
    const month = firstOf(format, &.{ "%m", "%b", "%B" });
    const year = firstOf(format, &.{ "%Y", "%y" });
    if (day != null and month != null) o.prefer_day_first = day.? < month.?;
    if (year != null and month != null) o.prefer_year_first = year.? < month.?;
    return o;
}

fn firstOf(s: []const u8, needles: []const []const u8) ?usize {
    var best: ?usize = null;
    for (needles) |n| if (std.mem.find(u8, s, n)) |i| {
        if (best == null or i < best.?) best = i;
    };
    return best;
}

/// The strftime format the values are written in: detected from the first
/// value that parses, under the order the column settles, or null when
/// none parses or its format cannot be spelled. What infer writes.
pub fn formatOf(values: []const []const u8, day_first: bool, out: []u8) ?[]const u8 {
    const report = dp.detectColumn(values, .{ .prefer_day_first = day_first });
    for (values) |v| {
        const r = dp.parseWith(v, report.options) catch continue;
        if (r.kind != .absolute) continue;
        var w: std.Io.Writer = .fixed(out);
        r.layout.formatString(.strftime, v, &w) catch return null;
        return w.buffered();
    }
    return null;
}

const testing = std.testing;

test "a format's layout reads the rest of the column without detection" {
    var c: Column = .init("%Y-%m-%d %H:%M:%S", false, false);
    const values = [_][]const u8{ "2024-03-15 10:20:30", "2024-12-01 00:00:00", "1999-01-31 23:59:59" };
    for (values) |v| try testing.expect(c.read(v) == .ok);
    try testing.expectEqual(@as(u64, 2), c.fast);
    try testing.expectEqual(Problem.not_in_format, c.read("2024-03-15").bad);
    try testing.expectEqual(Problem.not_in_format, c.read("15/03/2024 10:20:30").bad);
}

test "a value in another format does not become the layout" {
    var c: Column = .init("%Y-%m-%d", false, false);
    try testing.expectEqual(Problem.not_in_format, c.read("03/15/2024").bad);
    try testing.expect(c.layout == null);
    try testing.expect(c.read("2024-03-15") == .ok);
    try testing.expect(c.layout != null);
}

test "the format says day first, so an ambiguous first value reads that way" {
    var c: Column = .init("%d/%m/%Y", false, false);
    const t = c.read("01/02/2024").ok;
    try testing.expectEqual(@as(u8, 2), t.month);
    try testing.expectEqual(@as(u8, 1), t.day);
    const u = c.read("03/04/2024").ok;
    try testing.expectEqual(@as(u8, 4), u.month);
    try testing.expect(c.read("25/12/2024") == .ok);
    try testing.expectEqual(Problem.not_in_format, c.read("2024-12-25").bad);
    // Resolved per value, so no layout to reuse.
    try testing.expectEqual(@as(u64, 0), c.fast);
}

test "without a format: detection, ambiguity counted, relative forms refused" {
    var c: Column = .init(null, false, false);
    try testing.expect(c.read("2024-03-15") == .ok);
    try testing.expect(c.read("03/04/2024") == .ok);
    try testing.expect(c.read("03/05/2024") == .ok);
    try testing.expectEqual(@as(u64, 2), c.ambiguous);
    try testing.expectEqual(Problem.relative, c.read("3 days ago").bad);
    try testing.expectEqual(Problem.not_date, c.read("not a date").bad);
    const fits = c.fits();
    try testing.expect(fits.month_first and fits.day_first);
    // A value with a day over 12 settles it.
    try testing.expect(c.read("25/05/2024") == .ok);
    try testing.expect(!c.fits().month_first);

    var strict: Column = .init(null, false, true);
    try testing.expectEqual(Problem.ambiguous, strict.read("03/04/2024").bad);
    try testing.expect(strict.read("2024-03-04") == .ok);
}

test "formatOf spells the column's format, in the order it settles" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("%Y-%m-%d %H:%M:%S", formatOf(&.{ "2024-03-15 10:20:30", "2024-12-01 00:00:00" }, false, &buf).?);
    try testing.expectEqualStrings("%d/%m/%Y", formatOf(&.{ "01/02/2024", "25/12/2024" }, false, &buf).?);
    try testing.expectEqualStrings("%m/%d/%Y", formatOf(&.{ "01/02/2024", "12/25/2024" }, false, &buf).?);
    try testing.expectEqual(@as(?[]const u8, null), formatOf(&.{ "x", "y" }, false, &buf));
}
