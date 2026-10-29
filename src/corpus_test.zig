//! Tests over the fixture corpus (test/gen/corpus.py), which the build
//! generates and hands over as build_options.corpus_index, its index.txt.
//! A module of its own, so the unit tests run without Python.

const std = @import("std");
const build_options = @import("build_options");
const Dialect = @import("dialect.zig").Dialect;
const reference = @import("reference.zig");
const records = @import("records.zig");
const Field = records.Field;
const Record = records.Record;
const Scanner = records.Scanner;

const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// A file's .dialect.json.
pub const Expected = struct {
    delimiter: []const u8,
    quote: ?[]const u8,
    escape: Dialect.Escape,
    newline: Dialect.Newline,
    header: bool,
    encoding: []const u8,
    bom: bool,
    adversarial: bool,

    pub fn dialect(e: Expected) Dialect {
        return .{
            .delimiter = e.delimiter[0],
            .quote = if (e.quote) |q| q[0] else null,
            .escape = e.escape,
            .newline = e.newline,
            .header = e.header,
        };
    }
};

/// One corpus file, read whole, with its expected answers.
pub const Fixture = struct {
    name: []const u8,
    bytes: []u8,
    expected: std.json.Parsed(Expected),

    pub fn deinit(f: *Fixture, gpa: Allocator) void {
        gpa.free(f.bytes);
        f.expected.deinit();
    }
};

/// The corpus directory and its index.txt.
pub const Corpus = struct {
    dir: Io.Dir,
    index: []u8,

    pub fn open(io: Io, gpa: Allocator) !Corpus {
        const path = std.fs.path.dirname(build_options.corpus_index).?;
        const dir = try Io.Dir.cwd().openDir(io, path, .{});
        errdefer dir.close(io);
        return .{ .dir = dir, .index = try dir.readFileAlloc(io, "index.txt", gpa, .unlimited) };
    }

    pub fn close(c: *Corpus, io: Io, gpa: Allocator) void {
        gpa.free(c.index);
        c.dir.close(io);
    }

    pub fn names(c: *const Corpus) std.mem.TokenIterator(u8, .scalar) {
        return std.mem.tokenizeScalar(u8, c.index, '\n');
    }

    pub fn load(c: *const Corpus, io: Io, gpa: Allocator, name: []const u8) !Fixture {
        const bytes = try c.dir.readFileAlloc(io, name, gpa, .unlimited);
        errdefer gpa.free(bytes);
        const json = try c.sibling(io, gpa, name, ".dialect.json");
        defer gpa.free(json);
        return .{
            .name = name,
            .bytes = bytes,
            // alloc_always: the strings must outlive json, freed below.
            .expected = try std.json.parseFromSlice(Expected, gpa, json, .{ .allocate = .alloc_always }),
        };
    }

    /// NAME.csv's NAME<ext>.
    pub fn sibling(c: *const Corpus, io: Io, gpa: Allocator, name: []const u8, ext: []const u8) ![]u8 {
        var buf: [256]u8 = undefined;
        const stem = name[0 .. std.mem.findScalarLast(u8, name, '.') orelse name.len];
        const path = try std.fmt.bufPrint(&buf, "{s}{s}", .{ stem, ext });
        return c.dir.readFileAlloc(io, path, gpa, .unlimited);
    }
};

test "the reference parser finds every corpus field where the generator put it" {
    const io = testing.io;
    const gpa = testing.allocator;
    var corpus: Corpus = try .open(io, gpa);
    defer corpus.close(io, gpa);
    var files: usize = 0;
    var total_fields: usize = 0;
    var it = corpus.names();
    while (it.next()) |name| : (files += 1) {
        var fx = try corpus.load(io, gpa, name);
        defer fx.deinit(gpa);
        const want = try corpus.sibling(io, gpa, name, ".fields");
        defer gpa.free(want);
        const e = fx.expected.value;
        var p: reference.Parser = .init(fx.bytes, e.dialect(), .{ .start = if (e.bom) 3 else 0 });
        var fields: std.ArrayList(Field) = .empty;
        defer fields.deinit(gpa);
        var check: FieldCheck = .init(name, want);
        while (try p.next(gpa, &fields)) |rec| try check.add(rec, fields.items);
        total_fields += try check.finish();
    }
    try testing.expect(files >= 40);
    try testing.expect(total_fields > 50_000);
}

test "the scanner finds every corpus field from the index alone, whole or in pieces" {
    const io = testing.io;
    const gpa = testing.allocator;
    var corpus: Corpus = try .open(io, gpa);
    defer corpus.close(io, gpa);
    var it = corpus.names();
    var indexed: u64 = 0;
    while (it.next()) |name| {
        var fx = try corpus.load(io, gpa, name);
        defer fx.deinit(gpa);
        const want = try corpus.sibling(io, gpa, name, ".fields");
        defer gpa.free(want);
        const e = fx.expected.value;
        // Whole, as a mapped file is; then 4 KiB at a time, as a buffered
        // read hands it over, with a window smaller than most text fields.
        for ([_]usize{ 0, 4096 }) |piece| {
            var s: Scanner = try .init(gpa, e.dialect(), .{
                .reference = .{ .start = if (e.bom) 3 else 0 },
                .window = if (piece == 0) 1 << 20 else 1024,
            });
            defer s.deinit();
            var have = if (piece == 0) fx.bytes.len else @min(piece, fx.bytes.len);
            s.feed(fx.bytes[0..have], 0, have == fx.bytes.len);
            var fields: std.ArrayList(Field) = .empty;
            defer fields.deinit(gpa);
            var check: FieldCheck = .init(name, want);
            while (true) {
                fields.clearRetainingCapacity();
                switch (try s.next(&fields)) {
                    .record => |rec| try check.add(rec, fields.items),
                    .need_more => {
                        const keep: usize = @intCast(s.keepFrom());
                        have = @min(have + piece, fx.bytes.len);
                        s.feed(fx.bytes[keep..have], keep, have == fx.bytes.len);
                    },
                    .end => break,
                }
            }
            _ = try check.finish();
            if (s.stats.scalar != 0) {
                std.debug.print("{s}: {d} records left the index\n", .{ name, s.stats.scalar });
                return error.TestUnexpectedResult;
            }
            indexed += s.stats.indexed;
        }
    }
    try testing.expect(indexed > 10_000);
}

/// Compares records, as a parser emits them, with a .fields file's lines,
/// "record column start length flags".
const FieldCheck = struct {
    name: []const u8,
    lines: std.mem.TokenIterator(u8, .scalar),
    record: u64 = 0,
    count: usize = 0,

    fn init(name: []const u8, want: []const u8) FieldCheck {
        return .{ .name = name, .lines = std.mem.tokenizeScalar(u8, want, '\n') };
    }

    fn add(c: *FieldCheck, rec: Record, fields: []const Field) !void {
        defer c.record += 1;
        if (rec.problem) |pr| {
            std.debug.print("{s}: record {d}: {t}\n", .{ c.name, c.record, pr });
            return error.TestUnexpectedResult;
        }
        for (fields, 0..) |f, col| {
            const line = c.lines.next() orelse {
                std.debug.print("{s}: record {d} column {d}: the generator wrote no such field\n", .{ c.name, c.record, col });
                return error.TestUnexpectedResult;
            };
            var nums: [5]u64 = undefined;
            var parts = std.mem.tokenizeScalar(u8, line, ' ');
            for (&nums) |*n| n.* = try std.fmt.parseInt(u64, parts.next().?, 10);
            const flags: u64 = @as(u64, @intFromBool(f.flags.quoted)) | @as(u64, @intFromBool(f.flags.needs_unescape)) << 1;
            const got = [5]u64{ c.record, col, f.start, f.len, flags };
            if (!std.mem.eql(u64, &nums, &got)) {
                std.debug.print("{s}: want (record column start length flags) {any}, got {any}\n", .{ c.name, nums, got });
                return error.TestUnexpectedResult;
            }
            c.count += 1;
        }
    }

    fn finish(c: *FieldCheck) !usize {
        if (c.lines.next()) |line| {
            std.debug.print("{s}: the parser stopped before the generator's field {s}\n", .{ c.name, line });
            return error.TestUnexpectedResult;
        }
        return c.count;
    }
};
