//! Throughput of each stage, in MB/s of input, on synthetic input built in
//! memory, so the disk is not what is measured (the page cache serves a
//! mapped file the same way).
//!
//!   zig build bench -- [--size BYTES] [--runs N] [--profile narrow|wide|text] [--json]
//!
//! Profiles: narrow (six short numeric and code columns), wide (thirty
//! mixed columns, some quoted with embedded delimiters and doubled
//! quotes), text (four columns, one of them 1 to 20 KB of quoted prose with
//! line breaks). Stages, each including those before it:
//!
//!   stage1    the structural index alone
//!   parse     stages 1 and 2: records and fields, in batches
//!   validate  every cell checked against the profile's schema
//!   report    the same, with each column's statistics, as --report has
//!   infer     every value's type inferred, with the columns' statistics
//!   csv       validated rows built into typed columns and written as CSV
//!   arrow     the same, written as Arrow IPC
//!   reference the scalar reference parser, for scale
//!
//! Each runs --runs times and the fastest counts. --json prints one object,
//! profile to stage to MB/s, for tools/bench_gate.sh.

const std = @import("std");
const thresh = @import("thresh");
const scan = thresh.scan;
const records = thresh.records;
const schema = thresh.schema;
const Dialect = thresh.Dialect;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const Profile = enum { narrow, wide, text };
pub const Stage = enum { stage1, parse, validate, report, infer, csv, arrow, reference };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var size: usize = 1 << 30;
    var runs: usize = 3;
    var json = false;
    var profiles: []const Profile = &.{ .narrow, .wide, .text };
    var one: [1]Profile = undefined;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--json")) {
            json = true;
            continue;
        }
        if (i + 1 == args.len) return usage();
        i += 1;
        if (std.mem.eql(u8, a, "--size")) {
            size = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, a, "--runs")) {
            runs = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, a, "--profile")) {
            one[0] = std.meta.stringToEnum(Profile, args[i]) orelse return usage();
            profiles = &one;
        } else return usage();
    }

    var out_buf: [4096]u8 = undefined;
    var out = Io.File.stdout().writerStreaming(io, &out_buf);
    const w = &out.interface;
    if (json) try w.writeByte('{') else {
        try w.print("{s:<8} {s:>6}", .{ "profile", "MB" });
        for (std.enums.values(Stage)) |s| try w.print(" {s:>10}", .{@tagName(s)});
        try w.writeAll("   (MB/s)\n");
    }
    for (profiles, 0..) |p, pi| {
        const data = try generate(gpa, p, size);
        defer gpa.free(data);
        const mb = @as(f64, @floatFromInt(data.len)) / 1e6;
        const s = schemaOf(p);
        if (json) try w.print("{s}\"{t}\":{{", .{ if (pi > 0) "," else "", p }) else try w.print("{t:<8} {d:>6.0}", .{ p, mb });
        for (std.enums.values(Stage), 0..) |stage, si| {
            const seconds = try best(io, gpa, runs, data, &s, stage);
            if (json) try w.print("{s}\"{t}\":{d:.0}", .{ if (si > 0) "," else "", stage, mb / seconds }) else try w.print(" {d:>10.0}", .{mb / seconds});
        }
        try w.writeAll(if (json) "}" else "\n");
        try w.flush();
    }
    if (json) try w.writeAll("}\n");
    try w.flush();
}

fn usage() error{Usage} {
    std.debug.print("usage: bench [--size BYTES] [--runs N] [--profile narrow|wide|text] [--json]\n", .{});
    return error.Usage;
}

/// The fastest of runs runs of the stage over data, in seconds.
fn best(io: Io, gpa: Allocator, runs: usize, data: []const u8, s: *const schema.Schema, stage: Stage) !f64 {
    var fastest: f64 = std.math.inf(f64);
    var check: ?u64 = null;
    for (0..runs) |_| {
        const start = Io.Timestamp.now(io, .awake);
        const n = switch (stage) {
            .stage1 => try stage1(gpa, data),
            .parse => try parse(gpa, data),
            .reference => try referenceParse(gpa, data),
            .infer => try inferStage(gpa, data, s),
            .validate, .report, .csv, .arrow => try pipeline(gpa, data, s, stage),
        };
        const ns = start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds;
        // Every run must find the same; it also keeps the work from being
        // optimized away.
        if (check) |c| std.debug.assert(c == n);
        check = n;
        fastest = @min(fastest, @as(f64, @floatFromInt(ns)) / 1e9);
    }
    return fastest;
}

/// Stage 1 alone: index the whole input a megabyte at a time, as the
/// scanner does, counting entries.
fn stage1(gpa: Allocator, data: []const u8) !u64 {
    const window = 1 << 20;
    const positions = try gpa.alloc(u32, window);
    defer gpa.free(positions);
    const special = try gpa.alloc(u64, window / scan.block + 1);
    defer gpa.free(special);
    var total: u64 = 0;
    var off: usize = 0;
    while (off < data.len) {
        const len = @min(window, data.len - off);
        var carry: scan.Carry = .{};
        const got = scan.index(data[off..][0..len], .rfc4180, &carry, positions, special);
        total += got.count;
        off += got.len;
    }
    return total;
}

/// Stages 1 and 2: records and fields into batches, counting fields.
fn parse(gpa: Allocator, data: []const u8) !u64 {
    var s: records.Scanner = try .init(gpa, .rfc4180, .{});
    defer s.deinit();
    s.feed(data, 0, true);
    var batch: records.Batch = .{};
    defer batch.deinit(gpa);
    var total: u64 = 0;
    while (true) {
        batch.clear();
        const state = try batch.fill(gpa, &s, .{});
        total += batch.fields.items.len;
        if (state == .end) break;
    }
    if (s.stats.scalar != 0) return error.LeftTheIndex;
    return total;
}

/// Parse and validate against the profile's schema, and with a writer,
/// build each batch's accepted rows into typed columns and write them to
/// a writer that discards (so the disk is not measured). Counts rows.
fn pipeline(gpa: Allocator, data: []const u8, s: *const schema.Schema, stage: Stage) !u64 {
    var v: thresh.validate.Validator = try .init(gpa, s, .rfc4180, .{ .stats = stage == .report, .stats_stride = strideOf(data) });
    defer v.deinit();
    try v.columns(null, s.columns.len, data, 0);
    var typed: ?thresh.builders.Batch = if (stage == .validate or stage == .report) null else try .init(gpa, s, .utf8);
    defer if (typed) |*t| t.deinit();
    if (typed) |*t| v.batch = t;
    var sink_buf: [1 << 20]u8 = undefined;
    var sink: Io.Writer.Discarding = .init(&sink_buf);
    var csv_w: thresh.csv.Writer = .{ .options = .{} };
    var arrow_w: thresh.arrow.Writer = .init(gpa, s, .{});
    defer arrow_w.deinit();
    if (stage == .arrow) try arrow_w.header(&sink.writer);

    var scanner: records.Scanner = try .init(gpa, .rfc4180, .{});
    defer scanner.deinit();
    scanner.feed(data, 0, true);
    var batch: records.Batch = .{};
    defer batch.deinit(gpa);
    while (true) {
        batch.clear();
        const state = try batch.fill(gpa, &scanner, .{});
        for (0..batch.len()) |i| try v.record(batch.records.items[i], batch.recordFields(i), data, 0);
        if (typed) |*t| {
            if (stage == .csv) try csv_w.batch(&sink.writer, t) else if (t.rows > 0) try arrow_w.batch(&sink.writer, t);
            t.reset();
        }
        if (state == .end) break;
    }
    if (stage == .arrow) try arrow_w.end(&sink.writer);
    if (v.rejected != 0) return error.Rejected;
    return v.rows;
}

/// The stride a read of data samples its columns' statistics at, as the
/// reader works it out from its first 64 KiB.
fn strideOf(data: []const u8) u64 {
    const head = data[0..@min(data.len, 1 << 16)];
    return thresh.stats.strideFor(data.len, std.mem.countScalar(u8, head, '\n'), head.len);
}

/// Infer's pass over the data, as inferFile makes it: each record's values
/// into the inferrer. Counts rows.
fn inferStage(gpa: Allocator, data: []const u8, s: *const schema.Schema) !u64 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var f: thresh.infer.Inferrer = .init(arena.allocator(), .{ .stats_stride = strideOf(data) });
    try f.header(null, s.columns.len);
    var scanner: records.Scanner = try .init(gpa, .rfc4180, .{});
    defer scanner.deinit();
    scanner.feed(data, 0, true);
    var batch: records.Batch = .{};
    defer batch.deinit(gpa);
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(gpa);
    var values: std.ArrayList([]const u8) = .empty;
    defer values.deinit(gpa);
    while (true) {
        batch.clear();
        const state = try batch.fill(gpa, &scanner, .{});
        for (0..batch.len()) |i| {
            try records.values(gpa, batch.recordFields(i), data, 0, .rfc4180, &scratch, &values);
            try f.record(values.items);
        }
        if (state == .end) break;
    }
    return f.rows;
}

/// The reference parser over the same input, for scale.
fn referenceParse(gpa: Allocator, data: []const u8) !u64 {
    var p: thresh.reference.Parser = .init(data, .rfc4180, .{});
    var fields: std.ArrayList(records.Field) = .empty;
    defer fields.deinit(gpa);
    var total: u64 = 0;
    while (try p.next(gpa, &fields)) |_| total += fields.items.len;
    return total;
}

const codes = [_][]const u8{ "open", "closed", "pending" };

fn schemaOf(p: Profile) schema.Schema {
    return switch (p) {
        .narrow => .{ .columns = &.{
            .{ .name = "id", .type = .int64, .nullable = false },
            .{ .name = "code", .type = .@"enum", .values = &codes },
            .{ .name = "amount", .type = .decimal, .precision = 12, .scale = 2 },
            .{ .name = "qty", .type = .int64 },
            .{ .name = "flag", .type = .bool },
            .{ .name = "day", .type = .date, .format = "%Y-%m-%d" },
        } },
        .wide => .{ .columns = &wide_columns },
        .text => .{ .columns = &.{
            .{ .name = "id", .type = .int64, .nullable = false },
            .{ .name = "title", .type = .string },
            .{ .name = "body", .type = .string },
            .{ .name = "n", .type = .int64 },
        } },
    };
}

const wide_columns = blk: {
    @setEvalBranchQuota(100_000);
    var cols: [30]schema.Column = undefined;
    for (&cols, 0..) |*c, i| {
        const name = std.fmt.comptimePrint("c{d}", .{i});
        c.* = switch (i % 5) {
            0 => .{ .name = name, .type = .int64 },
            1 => .{ .name = name, .type = .decimal, .precision = 10, .scale = 3 },
            else => .{ .name = name, .type = .string },
        };
    }
    break :blk cols;
};

/// About size bytes of CSV in the profile, from a fixed seed.
fn generate(gpa: Allocator, profile: Profile, size: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, size + (64 << 10));
    errdefer out.deinit();
    const w = &out.writer;
    var rng: std.Random.DefaultPrng = .init(0x6265_6e63_68);
    const r = rng.random();
    const words = [_][]const u8{ "order", "invoice", "pallet", "refund", "ledger", "café", "crème", "the", "of", "a" };
    var row: u64 = 0;
    while (out.written().len < size) : (row += 1) {
        switch (profile) {
            .narrow => try w.print("{d},{s},{d}.{d:0>2},{d},{s},2026-{d:0>2}-{d:0>2}\n", .{
                row,
                codes[r.uintLessThan(usize, 3)],
                r.uintLessThan(u32, 100000),
                r.uintLessThan(u32, 100),
                r.uintLessThan(u32, 1000),
                if (r.boolean()) "true" else "false",
                1 + r.uintLessThan(u32, 12),
                1 + r.uintLessThan(u32, 28),
            }),
            .wide => {
                for (0..30) |col| {
                    if (col > 0) try w.writeByte(',');
                    switch (col % 5) {
                        0 => try w.print("{d}", .{r.int(u32)}),
                        1 => try w.print("{d}.{d}", .{ r.uintLessThan(u32, 1000), r.uintLessThan(u32, 1000) }),
                        2 => try w.print("\"{s}, {s}\"", .{ words[r.uintLessThan(usize, words.len)], words[r.uintLessThan(usize, words.len)] }),
                        3 => try w.print("\"{s} \"\"{s}\"\"\"", .{ words[r.uintLessThan(usize, words.len)], words[r.uintLessThan(usize, words.len)] }),
                        else => try w.writeAll(words[r.uintLessThan(usize, words.len)]),
                    }
                }
                try w.writeByte('\n');
            },
            .text => {
                try w.print("{d},\"{s} {s}\",\"", .{ row, words[r.uintLessThan(usize, words.len)], words[r.uintLessThan(usize, words.len)] });
                const n = 1000 + r.uintLessThan(usize, 19000);
                var written: usize = 0;
                while (written < n) {
                    const word = words[r.uintLessThan(usize, words.len)];
                    try w.writeAll(word);
                    const sep = switch (r.uintLessThan(u8, 40)) {
                        0 => "\n",
                        1 => ", ",
                        2 => " \"\"quoted\"\" ",
                        else => " ",
                    };
                    try w.writeAll(sep);
                    written += word.len + sep.len;
                }
                try w.print("\",{d}\n", .{r.uintLessThan(u32, 1000)});
            },
        }
    }
    return out.toOwnedSlice();
}
