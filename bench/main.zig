//! Throughput of each parsing stage, in MB/s, on synthetic input built in
//! memory, so the disk is not what is measured.
//!
//!   zig build bench -- [--size BYTES] [--runs N] [--profile narrow|wide|text]
//!
//! Profiles: narrow (six short numeric and code columns), wide (thirty
//! mixed columns, some quoted with embedded delimiters and doubled
//! quotes), text (four columns, one of them 1 to 20 KB of quoted prose
//! with line breaks). Each stage runs --runs times; the best run counts.

const std = @import("std");
const thresh = @import("thresh");
const scan = thresh.scan;
const records = thresh.records;
const Dialect = thresh.Dialect;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const Profile = enum { narrow, wide, text };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var size: usize = 1 << 30;
    var runs: usize = 3;
    var profiles: []const Profile = &.{ .narrow, .wide, .text };
    var one: [1]Profile = undefined;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
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
    try w.print("{s:<8} {s:>10} {s:>12} {s:>12} {s:>12}\n", .{ "profile", "MB", "stage 1", "stages 1+2", "reference" });
    for (profiles) |p| {
        const data = try generate(gpa, p, size);
        defer gpa.free(data);
        const mb = @as(f64, @floatFromInt(data.len)) / 1e6;
        const s1 = try best(io, runs, data, stage1, gpa);
        const s2 = try best(io, runs, data, stages12, gpa);
        const ref = try best(io, runs, data, referenceParse, gpa);
        try w.print("{t:<8} {d:>10.0} {d:>7.0} MB/s {d:>7.0} MB/s {d:>7.0} MB/s\n", .{ p, mb, mb / s1, mb / s2, mb / ref });
        try w.flush();
    }
    try w.flush();
}

fn usage() error{Usage} {
    std.debug.print("usage: bench [--size BYTES] [--runs N] [--profile narrow|wide|text]\n", .{});
    return error.Usage;
}

/// The fastest of runs runs of f over data, in seconds.
fn best(io: Io, runs: usize, data: []const u8, comptime f: fn (Allocator, []const u8) anyerror!u64, gpa: Allocator) !f64 {
    var fastest: f64 = std.math.inf(f64);
    var check: ?u64 = null;
    for (0..runs) |_| {
        const start = Io.Timestamp.now(io, .awake);
        const n = try f(gpa, data);
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
fn stages12(gpa: Allocator, data: []const u8) !u64 {
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

/// The reference parser over the same input, for scale.
fn referenceParse(gpa: Allocator, data: []const u8) !u64 {
    var p: thresh.reference.Parser = .init(data, .rfc4180, .{});
    var fields: std.ArrayList(records.Field) = .empty;
    defer fields.deinit(gpa);
    var total: u64 = 0;
    while (try p.next(gpa, &fields)) |_| total += fields.items.len;
    return total;
}

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
                ([_][]const u8{ "open", "closed", "pending" })[r.uintLessThan(usize, 3)],
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
