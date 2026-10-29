//! A file's bytes for the scanner: mapped read-only where the platform can
//! (a 20 GB file costs page cache, not memory), or read into a buffer that
//! holds from the oldest record still in use. Both hand the scanner a slice
//! and the absolute offset it starts at; only the buffered one ever needs
//! a refill.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const posix = std.posix;

const page_size_min = std.heap.page_size_min;

pub const Options = struct {
    /// Read through a buffer even where the file could be mapped.
    no_mmap: bool = false,
    /// The buffer's starting size; it grows for a record that will not fit.
    buffer: usize = 8 << 20,
};

pub const Input = struct {
    file: Io.File,
    size: u64,
    source: union(enum) {
        mapped: []align(page_size_min) const u8,
        buffered: struct {
            buf: []u8,
            /// Bytes of buf holding file data.
            len: usize = 0,
        },
        /// An empty file, which cannot be mapped.
        empty,
    },
    /// The absolute offset of data()[0].
    base: u64 = 0,
    eof: bool = false,

    pub fn open(io: Io, gpa: Allocator, path: []const u8, options: Options) !Input {
        const file = try Io.Dir.cwd().openFile(io, path, .{});
        errdefer file.close(io);
        const stat = try file.stat(io);
        if (stat.kind == .directory) return error.IsDir;
        var in: Input = .{ .file = file, .size = stat.size, .source = .empty, .eof = true };
        if (stat.size == 0) return in;
        if (!options.no_mmap and can_map) {
            if (map(file, stat.size)) |m| {
                in.source = .{ .mapped = m };
                return in;
            } else |_| {}
        }
        in.source = .{ .buffered = .{ .buf = try gpa.alloc(u8, @intCast(@min(options.buffer, stat.size))) } };
        in.eof = false;
        try in.refill(io, gpa, 0);
        return in;
    }

    pub fn close(in: *Input, io: Io, gpa: Allocator) void {
        switch (in.source) {
            .mapped => |m| posix.munmap(m),
            .buffered => |b| gpa.free(b.buf),
            .empty => {},
        }
        in.file.close(io);
    }

    /// The bytes on hand, from base.
    pub fn data(in: *const Input) []const u8 {
        return switch (in.source) {
            .mapped => |m| m,
            .buffered => |b| b.buf[0..b.len],
            .empty => &.{},
        };
    }

    pub fn mapped(in: *const Input) bool {
        return in.source == .mapped;
    }

    /// Drops the bytes before absolute offset keep and reads on after what
    /// is held, growing the buffer when keep is where it already starts.
    /// Nothing before keep may be in use after this.
    pub fn refill(in: *Input, io: Io, gpa: Allocator, keep: u64) !void {
        const b = &in.source.buffered;
        std.debug.assert(keep >= in.base and keep <= in.base + b.len);
        const drop: usize = @intCast(keep - in.base);
        if (drop > 0) {
            std.mem.copyForwards(u8, b.buf, b.buf[drop..b.len]);
            b.len -= drop;
            in.base = keep;
        } else if (b.len == b.buf.len) {
            b.buf = try gpa.realloc(b.buf, b.buf.len * 2);
        }
        const n = try in.file.readPositionalAll(io, b.buf[b.len..], in.base + b.len);
        b.len += n;
        in.eof = in.base + b.len >= in.size or n == 0;
    }
};

const can_map = switch (builtin.os.tag) {
    .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly, .illumos => true,
    else => false,
};

fn map(file: Io.File, size: u64) ![]align(page_size_min) const u8 {
    const len = std.math.cast(usize, size) orelse return error.FileTooBig;
    const m = try posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, file.handle, 0);
    // Advice: the scanner reads front to back, once.
    posix.madvise(m.ptr, m.len, posix.MADV.SEQUENTIAL) catch {};
    return m;
}

const testing = std.testing;

test "mapped and buffered inputs hold the same bytes" {
    const io = testing.io;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var content: [5000]u8 = undefined;
    for (&content, 0..) |*c, i| c.* = @truncate(i * 7);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.csv", .data = &content });
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/a.csv", .{tmp.sub_path});

    var m: Input = try .open(io, gpa, path, .{});
    defer m.close(io, gpa);
    try testing.expectEqual(can_map, m.mapped());
    try testing.expect(m.eof);
    try testing.expectEqualSlices(u8, &content, m.data());

    var b: Input = try .open(io, gpa, path, .{ .no_mmap = true, .buffer = 1000 });
    defer b.close(io, gpa);
    try testing.expect(!b.mapped());
    try testing.expectEqualSlices(u8, content[0..1000], b.data());
    // Keep from 600: the buffer slides along.
    try b.refill(io, gpa, 600);
    try testing.expectEqual(@as(u64, 600), b.base);
    try testing.expectEqualSlices(u8, content[600..1600], b.data());
    // Keep from where it starts: the buffer grows.
    try b.refill(io, gpa, 600);
    try testing.expectEqualSlices(u8, content[600..2600], b.data());
    while (!b.eof) try b.refill(io, gpa, b.base + b.data().len);
    try testing.expectEqual(@as(u64, 5000), b.base + b.data().len);
}

test "an empty file is an empty input" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "e.csv", .data = "" });
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/e.csv", .{tmp.sub_path});
    var in: Input = try .open(io, testing.allocator, path, .{});
    defer in.close(io, testing.allocator);
    try testing.expect(in.eof);
    try testing.expectEqual(@as(usize, 0), in.data().len);
}
