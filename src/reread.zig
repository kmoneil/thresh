//! A file that stopped, worked out for explain: what the stop points at is
//! weighed against the file, and when the weighing settles it, the file is
//! described again that way. Two stops so far:
//!
//! A header of another width than its rows (header_width) is read with row
//! 1 as data, as its problem suggests. Its names cannot be put to columns,
//! but infer leaves row 1 out, being of another width, so the columns are
//! typed from the rows alone.
//!
//! A file that is not UTF-8 (column_not_utf8) is weighed by its bytes past
//! ASCII. Its problem suggests cp1252 or latin1. Windows-1252 has a letter or a
//! mark for 27 of the 32 bytes 0x80 to 0x9f, where Latin-1 has control
//! codes, and the two agree on every other byte, so Windows-1252 is read
//! whenever every byte is a character in it. Either way a file part UTF-8
//! is garbled, so one with UTF-8 characters in it is not read again.

const std = @import("std");
const Allocator = std.mem.Allocator;
const dialect = @import("dialect.zig");
const input = @import("input.zig");
const lib = @import("lib.zig");
const schema = @import("schema.zig");
const types = @import("types.zig");

/// The bytes past ASCII in a file, and how many of them UTF-8 reads.
pub const Bytes = struct {
    /// Each byte past ASCII by value, 0x80 first, as Windows-1252 would
    /// read them.
    counts: [128]u64 = @splat(0),
    /// Characters of more than one byte that read as UTF-8.
    utf8: u64 = 0,
    /// Bytes past ASCII that are in no such character.
    lone: u64 = 0,
    /// The bytes of a character begun, and how many more it needs.
    open: u3 = 0,
    need: u3 = 0,

    /// Weighs chunk, the next of the file's bytes.
    pub fn add(t: *Bytes, chunk: []const u8) void {
        for (chunk) |c| {
            if (c < 0x80 and t.need == 0) continue;
            t.step(c);
        }
    }

    fn step(t: *Bytes, c: u8) void {
        if (t.need > 0) {
            if (c & 0xc0 == 0x80) return t.more(c);
            t.lone += t.open;
            t.open = 0;
            t.need = 0;
            if (c < 0x80) return;
        }
        t.counts[c - 0x80] += 1;
        t.need = switch (c) {
            0xc2...0xdf => 1,
            0xe0...0xef => 2,
            0xf0...0xf4 => 3,
            else => 0,
        };
        if (t.need == 0) t.lone += 1 else t.open = 1;
    }

    /// c carries on the character begun.
    fn more(t: *Bytes, c: u8) void {
        t.counts[c - 0x80] += 1;
        t.open += 1;
        t.need -= 1;
        if (t.need > 0) return;
        t.utf8 += 1;
        t.open = 0;
    }

    /// The file's end: a character begun and not ended is lone bytes.
    pub fn finish(t: *Bytes) void {
        t.lone += t.open;
        t.open = 0;
        t.need = 0;
    }

    /// Every byte past ASCII.
    pub fn high(t: Bytes) u64 {
        var n: u64 = 0;
        for (t.counts) |c| n += c;
        return n;
    }

    /// Bytes 0x80 to 0x9f: punctuation in Windows-1252, control codes in
    /// Latin-1.
    pub fn c1(t: Bytes) u64 {
        var n: u64 = 0;
        for (t.counts[0..0x20]) |c| n += c;
        return n;
    }

    /// The bytes that are control codes in Windows-1252 too.
    pub fn controls(t: Bytes) u64 {
        var n: u64 = 0;
        for (undefined_in_cp1252) |b| n += t.counts[b - 0x80];
        return n;
    }

    /// The lowest of them in the file.
    pub fn firstControl(t: Bytes) ?u8 {
        for (undefined_in_cp1252) |b| if (t.counts[b - 0x80] > 0) return b;
        return null;
    }

    pub fn fit(t: Bytes) Fit {
        if (t.utf8 > 0 and t.lone > 0) return .mixed;
        if (t.lone == 0 or t.controls() > 0) return .neither;
        return .cp1252;
    }

    /// The most common bytes past ASCII that show, at most out.len, the
    /// most common first and the lower of two as common.
    pub fn common(t: *const Bytes, out: []u8) []u8 {
        var order: [128]u8 = undefined;
        for (&order, 0..) |*o, i| o.* = @intCast(i);
        std.sort.pdq(u8, &order, t, moreCommon);
        var n: usize = 0;
        for (order) |i| {
            if (n == out.len or t.counts[i] == 0) break;
            if (!shows(i + 0x80)) continue;
            out[n] = i + 0x80;
            n += 1;
        }
        return out[0..n];
    }

    fn moreCommon(t: *const Bytes, x: u8, y: u8) bool {
        return t.counts[x] > t.counts[y] or (t.counts[x] == t.counts[y] and x < y);
    }

    /// How many different bytes past ASCII that show are in it.
    pub fn distinct(t: *const Bytes) usize {
        var n: usize = 0;
        for (t.counts, 0..) |c, i| {
            if (c > 0 and shows(@intCast(i + 0x80))) n += 1;
        }
        return n;
    }
};

/// Whether b, past ASCII, shows as something: not the no-break space or
/// the soft hyphen.
fn shows(b: u8) bool {
    return b != 0xa0 and b != 0xad;
}

/// The five bytes Windows-1252 leaves as control codes.
const undefined_in_cp1252 = [_]u8{ 0x81, 0x8d, 0x8f, 0x90, 0x9d };

/// What the bytes say.
pub const Fit = enum {
    /// Every byte is a character in Windows-1252, and none is in a UTF-8
    /// character.
    cp1252,
    /// Some bytes make UTF-8 characters and some do not: written two ways.
    mixed,
    /// A byte is a control code in Windows-1252 and Latin-1 alike, or
    /// every byte is in a UTF-8 character that is not a valid one.
    neither,
};

/// What explain changed to read the file again: a setting, by its flag.
pub const With = union(enum) {
    encoding: types.Encoding,
    header: dialect.HeaderMode,

    /// "--encoding cp1252", "--header no"
    pub fn format(w: With, out: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (w) {
            .encoding => |e| try out.print("--encoding {t}", .{e}),
            .header => |h| try out.print("--header {t}", .{h}),
        }
    }
};

/// The file described again, and with what.
pub const Again = struct {
    with: With,
    description: lib.Description,
};

/// How a stop was worked out.
pub const Worked = union(enum) {
    /// Read again as Windows-1252, as the bytes say.
    encoding: struct { bytes: Bytes, again: Again },
    /// Read again with row 1 as data, its names left out.
    header: Again,
    /// Not read again: some of it is UTF-8 and some is not.
    mixed: Bytes,
    /// Not read again: no encoding reads every byte past ASCII as a
    /// character.
    neither: Bytes,

    /// The file read again, when it was.
    pub fn again(w: Worked) ?Again {
        return switch (w) {
            .encoding => |r| r.again,
            .header => |g| g,
            .mixed, .neither => null,
        };
    }
};

/// A file as explain reads it.
pub const Reading = struct {
    path: []const u8,
    schema: ?*const lib.Schema = null,
    options: lib.Options = .{},
};

/// d's stop worked out, in a, when it is one explain works out and the
/// file can still be read; null otherwise.
pub fn of(env: lib.Env, a: Allocator, r: Reading, d: lib.Description) !?Worked {
    const p = d.file.outcome.problem orelse return null;
    return switch (p) {
        .column_not_utf8 => try encoding(env, a, r),
        .header_width => if (r.options.pins.header == .no) null else .{ .header = try readWith(env, a, r, .{ .header = .no }) },
        else => null,
    };
}

/// A file not UTF-8, weighed by its bytes, and read again as Windows-1252
/// when they say so.
fn encoding(env: lib.Env, a: Allocator, r: Reading) !?Worked {
    const t = tally(env, r.path) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return null,
    };
    switch (t.fit()) {
        .mixed => return .{ .mixed = t },
        .neither => return .{ .neither = t },
        .cp1252 => {},
    }
    return .{ .encoding = .{ .bytes = t, .again = try readWith(env, a, r, .{ .encoding = .cp1252 }) } };
}

/// The file described again, with as the one setting changed.
fn readWith(env: lib.Env, a: Allocator, r: Reading, with: With) !Again {
    var o = r.options;
    switch (with) {
        .encoding => |e| o.encoding = e,
        .header => |h| o.pins.header = h,
    }
    return .{ .with = with, .description = try lib.describe(env, a, r.path, r.schema, o) };
}

/// The bytes past ASCII in the file at path, read through, mapped where it
/// is large.
fn tally(env: lib.Env, path: []const u8) !Bytes {
    var in: input.Input = try .open(env.io, env.gpa, path, .{ .buffer = 1 << 20 });
    defer in.close(env.io, env.gpa);
    var t: Bytes = .{};
    while (true) {
        const data = in.data();
        t.add(data);
        if (in.eof or in.mapped()) break;
        try in.refill(env.io, env.gpa, in.base + data.len);
    }
    t.finish();
    return t;
}

const testing = std.testing;

fn bytesOf(chunks: []const []const u8) Bytes {
    var t: Bytes = .{};
    for (chunks) |c| t.add(c);
    t.finish();
    return t;
}

test "bytes: Windows-1252, Latin-1 alike, part UTF-8, neither" {
    // Windows-1252's quote mark and an e acute: a lone byte each.
    const cp = bytesOf(&.{"l\x92\xe9t\xe9 caf\xe9\n"});
    try testing.expectEqual(@as(u64, 4), cp.high());
    try testing.expectEqual(@as(u64, 1), cp.c1());
    try testing.expectEqual(@as(u64, 4), cp.lone);
    try testing.expectEqual(Fit.cp1252, cp.fit());
    var buf: [3]u8 = undefined;
    try testing.expectEqualSlices(u8, "\xe9\x92", cp.common(&buf));
    // No byte from 0x80 to 0x9f: the two read it alike.
    try testing.expectEqual(@as(u64, 0), bytesOf(&.{"caf\xe9 \xb0C"}).c1());
    // UTF-8's e acute beside a lone one, the character split between chunks.
    const mixed = bytesOf(&.{ "caf\xc3", "\xa9,caf\xe9\n" });
    try testing.expectEqual(@as(u64, 1), mixed.utf8);
    try testing.expectEqual(@as(u64, 1), mixed.lone);
    try testing.expectEqual(Fit.mixed, mixed.fit());
    // 0x81 is a control code in both.
    const odd = bytesOf(&.{"a\x81b\xe9"});
    try testing.expectEqual(Fit.neither, odd.fit());
    try testing.expectEqual(@as(?u8, 0x81), odd.firstControl());
    // A character begun and not ended by the file's end is lone bytes.
    try testing.expectEqual(@as(u64, 2), bytesOf(&.{"abc\xe2\x80"}).lone);
}

test "a file not UTF-8 is read again as Windows-1252" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env: lib.Env = .{ .io = testing.io, .gpa = testing.allocator };
    const path = "examples/data/windows.csv";
    const d = try lib.describe(env, a, path, null, .{});
    const w = (try of(env, a, .{ .path = path }, d)).?;
    try testing.expectEqual(@as(u64, 16), w.encoding.bytes.high());
    try testing.expectEqual(@as(u64, 8), w.encoding.bytes.c1());
    try testing.expectEqual(types.Encoding.cp1252, w.encoding.again.with.encoding);
    const again = w.encoding.again.description;
    try testing.expect(again.file.outcome.result == .pass);
    try testing.expectEqualStrings("cp1252", again.encoding);
    // A file that stopped for something else, or did not stop, is as it was.
    const fine = try lib.describe(env, a, "examples/data/harvest.csv", null, .{});
    try testing.expect(try of(env, a, .{ .path = "examples/data/harvest.csv" }, fine) == null);
}

test "a header of another width than its rows is read again with row 1 as data" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env: lib.Env = .{ .io = testing.io, .gpa = testing.allocator };
    const path = "examples/data/header_short.csv";
    const d = try lib.describe(env, a, path, null, .{});
    const g = (try of(env, a, .{ .path = path }, d)).?.header;
    try testing.expectEqual(dialect.HeaderMode.no, g.with.header);
    // Row 1, of 3 fields, is set aside, and types none of the 4 columns.
    const read = g.description.file.read.?;
    try testing.expectEqual(@as(u64, 1), read.rows_rejected);
    const want = [_]schema.Type{ .int64, .date, .string, .decimal };
    for (read.columns, want) |c, t| try testing.expectEqual(t, c.type);
    // Pinned so already, there is nothing to read again.
    var no: lib.Options = .{};
    no.pins.header = .no;
    try testing.expect(try of(env, a, .{ .path = path, .options = no }, d) == null);
}
