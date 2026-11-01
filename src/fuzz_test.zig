//! The fuzz targets, run under Zig's fuzzer by tools/fuzz.sh and their
//! seeds replayed by `zig build test` and `zig build fuzz`.
//!
//! An input is what a target's Smith reads: strings, each a four-byte
//! little-endian length and its bytes, and then its choices, each value
//! eight bytes little-endian whatever its type (a u8's past 255 reads as
//! zero). A seed may stop before the choices, which then read as zero.

const std = @import("std");
const Dialect = @import("dialect.zig").Dialect;
const dialect = @import("dialect.zig");
const records = @import("records.zig");
const reference = @import("reference.zig");

const Allocator = std.mem.Allocator;
const Smith = std.testing.Smith;
const testing = std.testing;

comptime {
    // The C entry points' target, in a file of its own.
    _ = @import("capi_fuzz_test.zig");
}

const max_input = 2048;

/// The dialects the scanner and the sniffer are fuzzed under, chosen by a
/// byte: the sniffer's candidates, quoted three ways, and a comment byte.
fn dialectOf(bits: u8) Dialect {
    const delims = [_]u8{ ',', '\t', '|', ';', ':', '~', 0x01, ' ' };
    const quotes = [_]?u8{ '"', '\'', null, '"' };
    return .{
        .delimiter = delims[bits & 7],
        .quote = quotes[(bits >> 3) & 3],
        .escape = if (bits & 0x20 != 0) .backslash else .doubled,
        .newline = ([_]Dialect.Newline{ .lf, .crlf, .cr, .lf })[(bits >> 6) & 3],
        .header = false,
        .comment = if (bits == 0xff) '#' else null,
    };
}

const Parsed = struct {
    records: std.ArrayList(records.Record) = .empty,
    fields: std.ArrayList(records.Field) = .empty,
    counts: std.ArrayList(usize) = .empty,

    fn deinit(p: *Parsed, gpa: Allocator) void {
        p.records.deinit(gpa);
        p.fields.deinit(gpa);
        p.counts.deinit(gpa);
    }

    fn eql(a: Parsed, b: Parsed) bool {
        if (!std.mem.eql(usize, a.counts.items, b.counts.items)) return false;
        for (a.records.items, b.records.items) |x, y| if (!std.meta.eql(x, y)) return false;
        for (a.fields.items, b.fields.items) |x, y| if (!std.meta.eql(x, y)) return false;
        return a.records.items.len == b.records.items.len and a.fields.items.len == b.fields.items.len;
    }
};

fn parseReference(gpa: Allocator, input: []const u8, d: Dialect, opts: reference.Options) !Parsed {
    var out: Parsed = .{};
    errdefer out.deinit(gpa);
    var fields: std.ArrayList(records.Field) = .empty;
    defer fields.deinit(gpa);
    var p: reference.Parser = .init(input, d, opts);
    while (try p.next(gpa, &fields)) |rec| {
        try out.records.append(gpa, rec);
        try out.fields.appendSlice(gpa, fields.items);
        try out.counts.append(gpa, fields.items.len);
    }
    return out;
}

fn parseScanner(gpa: Allocator, input: []const u8, d: Dialect, opts: records.Scanner.Options, piece: usize) !Parsed {
    var out: Parsed = .{};
    errdefer out.deinit(gpa);
    var s: records.Scanner = try .init(gpa, d, opts);
    defer s.deinit();
    var have = if (piece == 0) input.len else @min(piece, input.len);
    s.feed(input[0..have], 0, have == input.len);
    while (true) {
        const before = out.fields.items.len;
        switch (try s.next(&out.fields)) {
            .record => |rec| {
                try out.records.append(gpa, rec);
                try out.counts.append(gpa, out.fields.items.len - before);
            },
            .need_more => {
                const keep: usize = @intCast(s.keepFrom());
                have = @min(have + piece, input.len);
                s.feed(input[keep..have], keep, have == input.len);
            },
            .end => return out,
        }
    }
}

fn scannerOne(_: void, smith: *Smith) anyerror!void {
    const gpa = testing.allocator;
    var buf: [max_input]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    const d = dialectOf(smith.value(u8));
    const knobs = smith.value(u8);
    const opts: records.Scanner.Options = .{
        .reference = .{
            .keep_empty = knobs & 1 != 0,
            .max_field_len = if (knobs & 2 != 0) 7 else std.math.maxInt(u32),
        },
        .window = ([_]usize{ 1 << 20, 64, 100, 256 })[(knobs >> 2) & 3],
        .positions = ([_]usize{ 1 << 12, 64, 70, 128 })[(knobs >> 4) & 3],
    };
    const piece = ([_]usize{ 0, 1, 13, 200 })[(knobs >> 6) & 3];
    var want = try parseReference(gpa, input, d, opts.reference);
    defer want.deinit(gpa);
    var got = try parseScanner(gpa, input, d, opts, piece);
    defer got.deinit(gpa);
    if (!want.eql(got)) {
        std.debug.print("input \"{f}\", dialect {f}, knobs {x}\n", .{ std.zig.fmtString(input), d, knobs });
        return error.TestUnexpectedResult;
    }
}

/// The pins the sniffer is fuzzed under, chosen by a byte: a quote it
/// guesses and one it never does, an escape, a delimiter and a header.
fn pinsOf(bits: u8) dialect.Pins {
    const quotes = [_]?dialect.Pins.Quote{ null, .none, .{ .byte = '"' }, .{ .byte = '~' } };
    return .{
        .quote = quotes[bits & 3],
        .escape = ([_]?Dialect.Escape{ null, .doubled, .backslash, null })[(bits >> 2) & 3],
        .delimiter = ([_]?u8{ null, ',', '~', '|' })[(bits >> 4) & 3],
        .header = ([_]dialect.HeaderMode{ .auto, .auto, .yes, .no })[bits >> 6],
    };
}

/// Pins that leave the sniffer no dialect to score.
fn contradicts(p: dialect.Pins) bool {
    const q = p.quote orelse return false;
    return switch (q) {
        .none => p.escape == .backslash,
        .byte => |b| p.delimiter == b,
    };
}

fn sniffOne(_: void, smith: *Smith) anyerror!void {
    const gpa = testing.allocator;
    var buf: [max_input]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    const knobs = smith.value(u8);
    const pins = pinsOf(smith.value(u8));
    const v = dialect.sniff(gpa, input, knobs & 1 == 0, .{
        .pins = pins,
        .sample_bytes = ([_]usize{ 64 << 10, 16, 100, 1024 })[(knobs >> 1) & 3],
        .max_sample = 4096,
    }) catch |e| switch (e) {
        error.Utf16, error.Binary => return,
        error.Unscorable => return testing.expect(contradicts(pins)),
        error.OutOfMemory => return e,
    };
    try testing.expect(!contradicts(pins));
    // A pinned dimension is the verdict's.
    if (pins.quote) |q| try testing.expectEqual(@as(?u8, switch (q) {
        .none => null,
        .byte => |b| b,
    }), v.dialect.quote);
    if (pins.escape) |e| try testing.expectEqual(e, v.dialect.escape);
    if (pins.delimiter) |d| try testing.expectEqual(d, v.dialect.delimiter);
    if (pins.header != .auto) try testing.expectEqual(pins.header == .yes, v.dialect.header);
    try testing.expect(v.start <= input.len);
    // Whatever it settles, the scanner reads.
    var got = try parseScanner(gpa, input, v.dialect, .{ .reference = .{ .start = v.start } }, 0);
    got.deinit(gpa);
}

/// Records written in a dialect sniff to its delimiter, and read back to
/// themselves under what was sniffed. The fields hold the dialect's own
/// bytes and no other delimiter's, so only one reading fits them.
fn roundTripOne(_: void, smith: *Smith) anyerror!void {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const choice = smith.value(u8);
    var d = dialectOf(choice & 0x1f);
    d.escape = .doubled;
    d.comment = null;
    if (d.delimiter == ' ') d.delimiter = ',';
    d.newline = ([_]Dialect.Newline{ .lf, .crlf, .cr, .lf })[choice >> 6];
    const q = d.quote orelse return;
    const cols = 2 + smith.value(u8) % 5;
    const rows = 2 + smith.value(u8) % 40;
    // No punctuation but the dialect's: the sniffer tries a frequent
    // punctuation byte as a delimiter too, and in a short file one can
    // fairly win.
    const alphabet = [_]u8{ 'a', 'b', 'c', '1', '2', 'Z', d.delimiter, q, '\n', '\r', 'x' };
    var want: std.ArrayList([]const []const u8) = .empty;
    var out: std.Io.Writer.Allocating = .init(a);
    for (0..rows) |_| {
        const row = try a.alloc([]const u8, cols);
        for (row) |*f| {
            var bytes: [12]u8 = undefined;
            const n = smith.value(u8) % 12;
            for (bytes[0..n]) |*c| c.* = alphabet[smith.value(u8) % alphabet.len];
            f.* = try a.dupe(u8, bytes[0..n]);
        }
        try want.append(a, row);
        try writeRecord(&out.writer, row, d);
    }
    const text = out.written();
    const v = try dialect.sniff(gpa, text, true, .{});
    var p: reference.Parser = .init(text, v.dialect, .{ .start = v.start, .keep_empty = true });
    var fields: std.ArrayList(records.Field) = .empty;
    defer fields.deinit(gpa);
    var row: usize = 0;
    var ok = v.dialect.delimiter == d.delimiter;
    while (ok) : (row += 1) {
        const rec = try p.next(gpa, &fields) orelse break;
        if (row >= want.items.len or rec.problem != null or fields.items.len != cols) {
            ok = false;
            break;
        }
        for (fields.items, want.items[row]) |f, w| {
            const scratch = try a.alloc(u8, f.len);
            if (!std.mem.eql(u8, f.value(text, v.dialect, scratch), w)) ok = false;
        }
    }
    if (!ok or row != want.items.len) {
        std.debug.print("written as {f}, sniffed {f}:\n\"{f}\"\n", .{ d, v.dialect, std.zig.fmtString(text) });
        return error.TestUnexpectedResult;
    }
}

/// A record in d, quoting what needs it and doubling the quote.
fn writeRecord(w: *std.Io.Writer, row: []const []const u8, d: Dialect) !void {
    const q = d.quote.?;
    for (row, 0..) |f, i| {
        if (i > 0) try w.writeByte(d.delimiter);
        const needs = f.len == 0 or std.mem.findAny(u8, f, &.{ d.delimiter, q, '\n', '\r' }) != null;
        if (!needs) {
            try w.writeAll(f);
            continue;
        }
        try w.writeByte(q);
        for (f) |c| {
            if (c == q) try w.writeByte(q);
            try w.writeByte(c);
        }
        try w.writeByte(q);
    }
    try w.writeAll(switch (d.newline) {
        .lf => "\n",
        .crlf => "\r\n",
        .cr => "\r",
    });
}

/// A seed as Smith reads one: each string a four-byte little-endian length
/// and its bytes, then each choice as the eight bytes Smith reads a value
/// from.
pub fn seed(arena: Allocator, strings: []const []const u8, choices: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (strings) |s| {
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(s.len), .little);
        try out.appendSlice(arena, &len);
        try out.appendSlice(arena, s);
    }
    for (choices) |c| {
        var word: [8]u8 = undefined;
        std.mem.writeInt(u64, &word, c, .little);
        try out.appendSlice(arena, &word);
    }
    return out.items;
}

/// Inputs where the scanner's and the sniffer's answers turn on details:
/// the edge-case table's rows, under the dialect bytes that matter.
const inputs = [_][]const u8{
    "a,b\nc,d\n",
    "\"a\r\nb\",c\r\nd,e\r\n",
    "ab\"c,d\n5'11\",x\n",
    "a,\"bc\nd,e",
    "\"ab\"c,d\ne,f\n",
    "\"a\"\"b\",c\n\"\",\"\"\"\"\n",
    "\"a\\\"b\\\\c\",d\n",
    "#x,\"y\na,b\n# z\nc\n",
    "\xef\xbb\xbfid;name\n1;x\n",
    "id,price,qty\n1,\"7408,07\",261\n2,\"1587,65\",323\n",
    "\n\n\r\n\r",
    "x\n\"",
};

fn seeds(arena: Allocator) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (inputs) |s| {
        for ([_]u8{ 0, 0x20, 0x08, 0x10, 0x41, 0xff }) |d| {
            for ([_]u8{ 0, 0x55, 0xaa }) |k| try out.append(arena, try seed(arena, &.{s}, &.{ d, k }));
        }
    }
    return out.items;
}

fn roundTripSeeds(arena: Allocator) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var choices: [512]u8 = undefined;
    for (0..8) |i| {
        for (&choices, 0..) |*c, j| c.* = @truncate(j * 7 + i * 31);
        try out.append(arena, try arena.dupe(u8, &choices));
    }
    return out.items;
}

test "fuzz: the scanner agrees with the reference parser on any bytes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.fuzz({}, scannerOne, .{ .corpus = try seeds(arena.allocator()) });
}

test "fuzz: the sniffer settles any bytes into a dialect the scanner reads" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.fuzz({}, sniffOne, .{ .corpus = try seeds(arena.allocator()) });
}

test "fuzz: records written in a dialect sniff back to it and read back to themselves" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.fuzz({}, roundTripOne, .{ .corpus = try roundTripSeeds(arena.allocator()) });
}
