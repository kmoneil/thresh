//! Tests over the fixture corpus (test/gen/corpus.py), which the build
//! generates and hands over as build_options.corpus_index, its index.txt.
//! A module of its own, so the unit tests run without Python.

const std = @import("std");
const build_options = @import("build_options");
const dialect = @import("dialect.zig");
const Dialect = dialect.Dialect;
const cli = @import("cli.zig");
const render = @import("render.zig");
const schema = @import("schema.zig");
const worker = @import("worker.zig");
const report = @import("report.zig");
const infer = @import("infer.zig");
const types = @import("types.zig");
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
        var bytes = try c.dir.readFileAlloc(io, name, gpa, .unlimited);
        errdefer gpa.free(bytes);
        const json = try c.sibling(io, gpa, name, ".dialect.json");
        defer gpa.free(json);
        // alloc_always: the strings must outlive json, freed below.
        const expected = try std.json.parseFromSlice(Expected, gpa, json, .{ .allocate = .alloc_always });
        errdefer expected.deinit();
        if (std.mem.eql(u8, expected.value.encoding, "utf16")) {
            // The text thresh reads, decoded by std rather than by input.zig,
            // whose transcoding the tests that open the file then check.
            const units = try gpa.alloc(u16, (bytes.len - 2) / 2);
            defer gpa.free(units);
            for (units, 0..) |*u, i| u.* = std.mem.readInt(u16, bytes[2 + 2 * i ..][0..2], .little);
            const utf8 = try std.unicode.utf16LeToUtf8Alloc(gpa, units);
            gpa.free(bytes);
            bytes = utf8;
        }
        return .{ .name = name, .bytes = bytes, .expected = expected };
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

test "the sniffer settles every corpus file's dialect" {
    const io = testing.io;
    const gpa = testing.allocator;
    var corpus: Corpus = try .open(io, gpa);
    defer corpus.close(io, gpa);
    var it = corpus.names();
    var wrong: usize = 0;
    while (it.next()) |name| {
        var fx = try corpus.load(io, gpa, name);
        defer fx.deinit(gpa);
        const e = fx.expected.value;
        const v = try dialect.sniff(gpa, fx.bytes, true, .{});
        const want = e.dialect();
        // A UTF-8 file is never taken for another encoding, and a
        // Windows-1252 one always is: it has punctuation in 0x80 to 0x9f.
        const not_utf8_right = switch (encodingOf(e)) {
            .utf8 => !v.warnings.not_utf8,
            .cp1252 => v.warnings.not_utf8,
            .latin1 => true,
        };
        const right = std.meta.eql(want, v.dialect) and v.warnings.utf8_bom == e.bom and v.start == @as(usize, if (e.bom) 3 else 0) and not_utf8_right;
        // Every ordinary file, right and sure of it. The adversarial files
        // may stump it, as long as it says so.
        if (right and (e.adversarial or v.confidence == .high)) continue;
        if (e.adversarial and v.confidence == .low) continue;
        wrong += 1;
        std.debug.print("{s}: want {f}, sniffed {f} (confidence {t}, score {d:.2}, consistency {d:.2}, {d} records)\n", .{
            name, want, v.dialect, v.confidence, v.score, v.consistency, v.records,
        });
    }
    try testing.expectEqual(@as(usize, 0), wrong);
}

test "validate: every clean corpus file passes, every dirty one reports what was put in it" {
    const io = testing.io;
    const gpa = testing.allocator;
    const corpus_dir = std.fs.path.dirname(build_options.corpus_index).?;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const reports = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/reports", .{tmp.sub_path});

    var corpus: Corpus = try .open(io, gpa);
    defer corpus.close(io, gpa);
    var it = corpus.names();
    while (it.next()) |name| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const o = (try validateOne(io, gpa, arena.allocator(), &corpus, corpus_dir, name, null)).outcome;
        if (o.result != .pass or o.rows_rejected != 0) {
            std.debug.print("{s}: {t}, {d} of {d} rows rejected, {?f}\n", .{ name, o.result, o.rows_rejected, o.rows, o.problem });
            return error.TestUnexpectedResult;
        }
    }

    const dirty = try corpus.dir.readFileAlloc(io, "dirty.txt", gpa, .unlimited);
    defer gpa.free(dirty);
    var names = std.mem.tokenizeScalar(u8, dirty, '\n');
    var files: usize = 0;
    while (names.next()) |name| : (files += 1) {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const one = try validateOne(io, gpa, a, &corpus, corpus_dir, name, reports);
        var rp_buf: [512]u8 = undefined;
        const report_path = try std.fmt.bufPrint(&rp_buf, "{s}/{s}.report.json", .{ reports, name });
        const got_text = try Io.Dir.cwd().readFileAlloc(io, report_path, a, .unlimited);
        const want_text = try corpus.sibling(io, a, name, ".expect.json");
        try expectReport(a, name, got_text, want_text);
        // The counts only mean something under the file's own dialect.
        const sniffed = try std.json.parseFromSliceLeaky(std.json.Value, a, got_text, .{});
        const d = sniffed.object.get("dialect").?.object;
        const q: ?u8 = if (d.get("quote").? == .string) d.get("quote").?.string[0] else null;
        if (d.get("delimiter").?.string[0] != one.want.delimiter or q != one.want.quote) {
            std.debug.print("{s}: sniffed {s} and {f}, want {f}\n", .{ name, d.get("delimiter").?.string, std.json.fmt(d.get("quote").?, .{}), one.want });
            return error.TestUnexpectedResult;
        }
        try expectGolden(io, a, name, got_text);
    }
    try testing.expect(files >= 5);
}

/// Validates one corpus file against its .schema.json, under the encoding
/// its .dialect.json names, writing its report to reports if given.
fn validateOne(io: Io, gpa: Allocator, arena: Allocator, corpus: *const Corpus, dir: []const u8, name: []const u8, reports: ?[]const u8) !struct { outcome: report.Outcome, want: Dialect } {
    var fx = try corpus.load(io, gpa, name);
    defer fx.deinit(gpa);
    const stem = name[0 .. std.mem.findScalarLast(u8, name, '.') orelse name.len];
    const schema_path = try std.fmt.allocPrint(arena, "{s}/{s}.schema.json", .{ dir, stem });
    var diag: schema.Diagnostic = .{};
    var owned = try schema.load(io, gpa, schema_path, &diag);
    defer owned.deinit();
    const plan: render.Plan = .{
        .options = .{ .encoding = encodingOf(fx.expected.value) },
        .report_dir = reports,
        .schema = &owned.schema,
        .timing = false,
    };
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name });
    return .{
        .outcome = try render.validateFile(.{ .io = io, .gpa = gpa }, plan, path, arena),
        .want = fx.expected.value.dialect(),
    };
}

/// The report holds the counts the generator worked out.
fn expectReport(a: Allocator, name: []const u8, got_text: []const u8, want_text: []const u8) !void {
    const got = try std.json.parseFromSliceLeaky(std.json.Value, a, got_text, .{});
    const want = try std.json.parseFromSliceLeaky(std.json.Value, a, want_text, .{});
    const g = got.object;
    const w = want.object;
    inline for (.{ "result", "rows", "rows_rejected", "rejected_sample", "problems" }) |key| {
        if (!jsonEql(g.get(key).?, w.get(key).?)) {
            std.debug.print("{s}: {s} is {f}, the generator says {f}\n", .{ name, key, std.json.fmt(g.get(key).?, .{}), std.json.fmt(w.get(key).?, .{}) });
            return error.TestUnexpectedResult;
        }
    }
    // The rejected lines are the rejected rows, the first twenty, each
    // with a reason: the sample's lines first.
    const lines = g.get("rejected_lines").?.array.items;
    const sample = g.get("rejected_sample").?.array.items;
    const rejected: usize = @intCast(g.get("rows_rejected").?.integer);
    try std.testing.expectEqual(@min(rejected, 20), lines.len);
    for (sample, lines[0..sample.len]) |s, l| try std.testing.expectEqual(s.integer, l.object.get("row").?.integer);
    for (lines) |l| try std.testing.expect(l.object.get("errors").?.array.items.len > 0);
    for (w.get("columns").?.array.items, g.get("columns").?.array.items) |wc, gc| {
        inline for (.{ "name", "mismatches", "nulls" }) |key| {
            if (!jsonEql(wc.object.get(key).?, gc.object.get(key).?)) {
                std.debug.print("{s}: column {s}: {s} is {f}, the generator says {f}\n", .{
                    name, wc.object.get("name").?.string, key, std.json.fmt(gc.object.get(key).?, .{}), std.json.fmt(wc.object.get(key).?, .{}),
                });
                return error.TestUnexpectedResult;
            }
        }
    }
}

/// a is the report's, b the generator's: an object of the generator's
/// says the keys it knows (a problem's code and parameters, not its
/// sentence), and the report's has each of them the same.
fn jsonEql(a: std.json.Value, b: std.json.Value) bool {
    return switch (a) {
        .integer => |x| b == .integer and b.integer == x,
        .string => |x| b == .string and std.mem.eql(u8, x, b.string),
        .array => |x| b == .array and x.items.len == b.array.items.len and for (x.items, b.array.items) |p, q| {
            if (!jsonEql(p, q)) break false;
        } else true,
        .object => |x| b == .object and for (b.object.keys(), b.object.values()) |k, v| {
            const mine = x.get(k) orelse break false;
            if (!jsonEql(mine, v)) break false;
        } else true,
        else => false,
    };
}

/// The report, its "file" written as the base name, is the checked-in
/// test/golden one byte for byte; -Dupdate-golden writes it instead.
fn expectGolden(io: Io, a: Allocator, name: []const u8, got_text: []const u8) !void {
    const key = "\n  \"file\": ";
    const start = std.mem.find(u8, got_text, key).? + 1;
    const end = start + std.mem.findScalar(u8, got_text[start..], '\n').?;
    const normal = try std.fmt.allocPrint(a, "{s}  \"file\": \"{s}\",{s}", .{ got_text[0..start], name, got_text[end..] });
    const path = try std.fmt.allocPrint(a, "{s}/{s}.report.json", .{ build_options.golden_dir, name });
    if (build_options.update_golden) {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = normal });
        return;
    }
    const want = try Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
    try testing.expectEqualStrings(want, normal);
}

test "infer then validate: every clean corpus file passes against its own inferred schema" {
    const io = testing.io;
    const gpa = testing.allocator;
    const corpus_dir = std.fs.path.dirname(build_options.corpus_index).?;
    var corpus: Corpus = try .open(io, gpa);
    defer corpus.close(io, gpa);
    var it = corpus.names();
    var kinds: std.EnumArray(infer.Kind, usize) = .initFill(0);
    while (it.next()) |name| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var fx = try corpus.load(io, gpa, name);
        defer fx.deinit(gpa);
        const encoding = encodingOf(fx.expected.value);
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ corpus_dir, name });
        const nulls: []const []const u8 = &.{""};
        const r = try worker.inferFile(.{ .io = io, .gpa = gpa }, .{ .encoding = encoding }, nulls, path, a);
        try testing.expectEqual(report.Result.pass, r.outcome.result);
        for (r.columns) |c| kinds.getPtr(c.kind).* += 1;
        const s: schema.Schema = .{
            .columns = try infer.columnsOf(a, r.columns),
            .match = if (r.header) .name else .position,
        };
        const plan: render.Plan = .{ .options = .{ .encoding = encoding }, .schema = &s, .timing = false };
        const o = try render.validateFile(.{ .io = io, .gpa = gpa }, plan, path, a);
        if (o.result != .pass or o.rows_rejected != 0) {
            std.debug.print("{s}: {t} against its inferred schema, {d} of {d} rows rejected, {?f}\n", .{ name, o.result, o.rows_rejected, o.rows, o.problem });
            var buf: [8192]u8 = undefined;
            var w: Io.Writer = .fixed(&buf);
            schema.writeJson(s, &w) catch {};
            std.debug.print("{s}\n", .{w.buffered()});
            return error.TestUnexpectedResult;
        }
    }
    // The corpus's columns come out as the types the generator wrote.
    inline for (.{ .int64, .decimal, .float64, .bool, .date, .timestamp, .string }) |k| {
        try testing.expect(kinds.get(k) > 0);
    }
}

test "convert --to csv: every corpus file comes out RFC 4180, re-sniffs as it, and holds the same fields" {
    const io = testing.io;
    const gpa = testing.allocator;
    const corpus_dir = std.fs.path.dirname(build_options.corpus_index).?;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const out_dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/out", .{tmp.sub_path});
    var corpus: Corpus = try .open(io, gpa);
    defer corpus.close(io, gpa);
    var it = corpus.names();
    while (it.next()) |name| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var fx = try corpus.load(io, gpa, name);
        defer fx.deinit(gpa);
        const e = fx.expected.value;
        const encoding = encodingOf(e);
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ corpus_dir, name });
        const nulls: []const []const u8 = &.{""};
        const inferred = try worker.inferFile(.{ .io = io, .gpa = gpa }, .{ .encoding = encoding }, nulls, path, a);
        const s: schema.Schema = .{ .columns = try infer.columnsOf(a, inferred.columns), .match = if (inferred.header) .name else .position };
        const plan: render.Plan = .{
            .options = .{ .encoding = encoding },
            .schema = &s,
            .timing = false,
            .output = .{ .to = .csv, .dir = out_dir },
        };
        const o = try render.validateFile(.{ .io = io, .gpa = gpa }, plan, path, a);
        try testing.expectEqual(report.Result.pass, o.result);
        const written = try Io.Dir.cwd().readFileAlloc(io, o.written.?, a, .unlimited);

        const v = try dialect.sniff(gpa, written, true, .{});
        if (!std.meta.eql(v.dialect, Dialect{ .delimiter = ',', .quote = '"', .escape = .doubled, .newline = .lf, .header = true }) or v.confidence != .high) {
            std.debug.print("{s}: the output sniffs as {f} ({t})\n", .{ name, v.dialect, v.confidence });
            return error.TestUnexpectedResult;
        }

        // The output's records, header aside, against the input's: the same
        // text, but a value the inferred schema calls a column's null (an
        // empty date, "  /  /    ") written empty, as every null is.
        var want = try recordsOf(a, fx.bytes, e.dialect(), if (e.bom) 3 else 0, encoding);
        if (e.header) want = try withoutHeader(a, want);
        const got = (try recordsOf(a, written, .rfc4180, 0, .utf8))[1..];
        try testing.expectEqual(want.len, got.len);
        for (want, got, 0..) |w, g, row| {
            if (w.len != g.len) {
                std.debug.print("{s}: record {d} has {d} fields, the output {d}\n", .{ name, row, w.len, g.len });
                return error.TestUnexpectedResult;
            }
            for (w, g, s.columns) |wv, gv, col| {
                const null_spelling = for (col.nulls) |n| {
                    if (std.mem.eql(u8, n, wv)) break true;
                } else false;
                const expect = if (null_spelling) "" else wv;
                if (std.mem.eql(u8, expect, gv)) continue;
                std.debug.print("{s}: record {d}: \"{f}\" came out \"{f}\"\n", .{ name, row, std.zig.fmtString(wv[0..@min(wv.len, 60)]), std.zig.fmtString(gv[0..@min(gv.len, 60)]) });
                return error.TestUnexpectedResult;
            }
        }
    }
}

/// The records after the header, less any that are the header again
/// (joined files), which thresh skips.
fn withoutHeader(a: Allocator, all: []const []const []const u8) ![]const []const []const u8 {
    var out: std.ArrayList([]const []const u8) = .empty;
    for (all[1..]) |rec| {
        const again = rec.len == all[0].len and for (rec, all[0]) |v, h| {
            if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, v, " \t"), std.mem.trim(u8, h, " \t"))) break false;
        } else true;
        if (!again) try out.append(a, rec);
    }
    return out.items;
}

/// A corpus file's encoding, as its .dialect.json names it: a UTF-16 one
/// is read with no --encoding, told by its byte order mark.
fn encodingOf(e: Expected) cli.Encoding {
    if (std.mem.eql(u8, e.encoding, "utf16")) return .utf8;
    return std.meta.stringToEnum(cli.Encoding, e.encoding).?;
}

/// Every record of bytes as its values, escapes undone (and a single-byte
/// encoding transcoded), in arena.
fn recordsOf(a: Allocator, bytes: []const u8, d: Dialect, start: usize, encoding: cli.Encoding) ![]const []const []const u8 {
    var p: reference.Parser = .init(bytes, d, .{ .start = start });
    var fields: std.ArrayList(Field) = .empty;
    var out: std.ArrayList([]const []const u8) = .empty;
    while (try p.next(a, &fields)) |_| {
        const rec = try a.alloc([]const u8, fields.items.len);
        for (rec, fields.items) |*r, f| {
            const scratch = try a.alloc(u8, f.len);
            const v = f.value(bytes, d, scratch);
            if (encoding == .utf8) {
                r.* = try a.dupe(u8, v);
                continue;
            }
            var utf8: std.ArrayList(u8) = .empty;
            for (v) |c| {
                var buf: [3]u8 = undefined;
                try utf8.appendSlice(a, buf[0 .. std.unicode.utf8Encode(types.codepoint(encoding, c), &buf) catch unreachable]);
            }
            r.* = utf8.items;
        }
        try out.append(a, rec);
    }
    return out.items;
}
