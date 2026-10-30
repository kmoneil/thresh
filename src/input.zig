//! A file's bytes for the scanner: mapped read-only where the platform can
//! (a 20 GB file costs page cache, not memory), or read into a buffer that
//! holds from the oldest record still in use. Both hand the scanner a slice
//! and the absolute offset it starts at; only the buffered one ever needs
//! a refill.
//!
//! A file that starts with a UTF-16 byte order mark is read through the
//! buffer and transcoded to UTF-8 as it is read, so everything after this
//! sees UTF-8 and nothing else knows. Its offsets are the UTF-8 text's, not
//! the file's. A lone surrogate, or a last byte without its pair, is
//! written as U+FFFD and counted.

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
    /// The file's size in bytes, as it is on disk.
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
    /// Set when the file is UTF-16 and transcoded.
    utf16: ?Utf16 = null,

    pub const Utf16 = struct {
        order: std.builtin.Endian,
        /// The file offset reading has reached.
        pos: u64,
        /// The file's bytes as read, before transcoding.
        raw: []u8,
        /// Bytes read and not yet transcoded: an odd byte, or a high
        /// surrogate waiting for its low.
        carry: [3]u8 = undefined,
        carry_len: usize = 0,
        /// Code units no character could be made of, each written U+FFFD.
        replaced: u64 = 0,
    };

    pub fn open(io: Io, gpa: Allocator, path: []const u8, options: Options) !Input {
        var in: Input = .{ .file = try Io.Dir.cwd().openFile(io, path, .{}), .size = 0, .source = .empty, .eof = true };
        // close frees whatever is held by then: a buffer, UTF-16's raw bytes.
        // Each is allocated before it is stored, since a union or struct
        // literal is built in place: a failed try inside one would leave
        // close a tag set over an undefined slice.
        errdefer in.close(io, gpa);
        const stat = try in.file.stat(io);
        if (stat.kind == .directory) return error.IsDir;
        in.size = stat.size;
        if (stat.size == 0) return in;
        var bom: [2]u8 = undefined;
        if (stat.size >= 2 and try in.file.readPositionalAll(io, &bom, 0) == 2) {
            const order: ?std.builtin.Endian = if (std.mem.eql(u8, &bom, "\xff\xfe")) .little else if (std.mem.eql(u8, &bom, "\xfe\xff")) .big else null;
            if (order) |o| {
                // Two bytes give at most three of UTF-8: room for the whole of
                // a small file, the buffer's size for a large one.
                const raw_len: usize = @max(16, @as(usize, @intCast(@min(options.buffer, stat.size))));
                const raw = try gpa.alloc(u8, raw_len);
                in.utf16 = .{ .order = o, .pos = 2, .raw = raw };
                const buf = try gpa.alloc(u8, raw_len + raw_len / 2 + 16);
                in.source = .{ .buffered = .{ .buf = buf } };
                in.eof = false;
                try in.refill(io, gpa, 0);
                return in;
            }
        }
        if (!options.no_mmap and can_map) {
            if (map(in.file, stat.size)) |m| {
                in.source = .{ .mapped = m };
                return in;
            } else |_| {}
        }
        const buf = try gpa.alloc(u8, @intCast(@min(options.buffer, stat.size)));
        in.source = .{ .buffered = .{ .buf = buf } };
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
        if (in.utf16) |u| gpa.free(u.raw);
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
        } else if (if (in.utf16 != null) b.buf.len - b.len < utf16_room else b.len == b.buf.len) {
            b.buf = try gpa.realloc(b.buf, b.buf.len * 2);
        }
        if (in.utf16 != null) return in.transcode(io);
        const n = try in.file.readPositionalAll(io, b.buf[b.len..], in.base + b.len);
        b.len += n;
        in.eof = in.base + b.len >= in.size or n == 0;
    }

    /// Reads on from the file, transcoding UTF-16 into the buffer, until it
    /// is as full as the next read may safely make it or the file ends.
    fn transcode(in: *Input, io: Io) !void {
        const b = &in.source.buffered;
        const u = &in.utf16.?;
        while (b.buf.len - b.len >= utf16_room) {
            // Two bytes give at most three of UTF-8, and a final odd byte
            // three for its U+FFFD: what the slack leaves room for.
            const free = b.buf.len - b.len - utf16_slack;
            const want = @min(u.raw.len, free / 3 * 2);
            @memcpy(u.raw[0..u.carry_len], u.carry[0..u.carry_len]);
            const n = try in.file.readPositionalAll(io, u.raw[u.carry_len..want], u.pos);
            u.pos += n;
            const end = u.pos >= in.size or n == 0;
            const chunk = u.raw[0 .. u.carry_len + n];
            u.carry_len = 0;
            var i: usize = 0;
            while (i + 2 <= chunk.len) {
                const unit = std.mem.readInt(u16, chunk[i..][0..2], u.order);
                var cp: u21 = unit;
                var used: usize = 2;
                if (unit >= 0xd800 and unit < 0xdc00) {
                    if (i + 4 > chunk.len and !end) break; // its low surrogate is in the next read
                    const low: u16 = if (i + 4 <= chunk.len) std.mem.readInt(u16, chunk[i + 2 ..][0..2], u.order) else 0;
                    if (low >= 0xdc00 and low < 0xe000) {
                        cp = 0x10000 + (@as(u21, unit - 0xd800) << 10) + (low - 0xdc00);
                        used = 4;
                    } else cp = replacement(u);
                } else if (unit >= 0xdc00 and unit < 0xe000) cp = replacement(u);
                b.len += std.unicode.utf8Encode(cp, b.buf[b.len..]) catch unreachable;
                i += used;
            }
            const rest = chunk[i..];
            if (end) {
                if (rest.len > 0) b.len += std.unicode.utf8Encode(replacement(u), b.buf[b.len..]) catch unreachable;
                in.eof = true;
                return;
            }
            @memcpy(u.carry[0..rest.len], rest);
            u.carry_len = rest.len;
        }
        in.eof = false;
    }
};

/// What transcoding keeps free at the buffer's end: a read's worst case
/// beyond its two-for-three is one U+FFFD.
const utf16_slack = 16;

/// The free space a transcoding read needs to make progress: the slack and
/// room for four bytes read, more than any carry. refill grows the buffer
/// below it.
const utf16_room = utf16_slack + 6;

fn replacement(u: *Input.Utf16) u21 {
    u.replaced += 1;
    return 0xfffd;
}

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

/// path's whole input, read through every refill, as one slice.
fn readAll(io: Io, gpa: Allocator, path: []const u8, options: Options) !struct { bytes: []u8, replaced: u64 } {
    var in: Input = try .open(io, gpa, path, options);
    defer in.close(io, gpa);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    while (true) {
        try out.appendSlice(gpa, in.data());
        if (in.eof) break;
        try in.refill(io, gpa, in.base + in.data().len);
    }
    return .{ .bytes = try out.toOwnedSlice(gpa), .replaced = if (in.utf16) |u| u.replaced else 0 };
}

test "a UTF-16 file is read as UTF-8, whole or a few bytes at a time" {
    const io = testing.io;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // ASCII, Latin-1, a CJK character and one beyond the BMP (a surrogate
    // pair), repeated so small buffers split every kind across reads.
    var text_buf: std.ArrayList(u8) = .empty;
    defer text_buf.deinit(gpa);
    for (0..40) |_| try text_buf.appendSlice(gpa, "id,name\r\n1,caf\u{e9} \u{6771}\u{1f389}\r\n");
    const text = text_buf.items;
    const utf16 = try std.unicode.utf8ToUtf16LeAlloc(gpa, text);
    defer gpa.free(utf16);
    var le: std.ArrayList(u8) = .empty;
    defer le.deinit(gpa);
    try le.appendSlice(gpa, "\xff\xfe");
    try le.appendSlice(gpa, std.mem.sliceAsBytes(utf16));
    var be: std.ArrayList(u8) = .empty;
    defer be.deinit(gpa);
    try be.appendSlice(gpa, "\xfe\xff");
    for (utf16) |unit| try be.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeTo(u16, std.mem.littleToNative(u16, unit), .big)));
    try tmp.dir.writeFile(io, .{ .sub_path = "le.csv", .data = le.items });
    try tmp.dir.writeFile(io, .{ .sub_path = "be.csv", .data = be.items });
    var path_buf: [256]u8 = undefined;
    for ([_][]const u8{ "le.csv", "be.csv" }) |name| {
        const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
        for ([_]usize{ 8 << 20, 7, 10, 33 }) |size| {
            const got = try readAll(io, gpa, path, .{ .buffer = size });
            defer gpa.free(got.bytes);
            try testing.expectEqualStrings(text, got.bytes);
            try testing.expectEqual(@as(u64, 0), got.replaced);
        }
    }
}

test "UTF-16 that makes no character is U+FFFD, counted" {
    const io = testing.io;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // a, a lone high surrogate, b, a lone low surrogate, then an odd byte.
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.csv", .data = "\xff\xfea\x00\x00\xd8b\x00\x00\xdcz" });
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/bad.csv", .{tmp.sub_path});
    const got = try readAll(io, gpa, path, .{});
    defer gpa.free(got.bytes);
    try testing.expectEqualStrings("a\u{fffd}b\u{fffd}\u{fffd}", got.bytes);
    try testing.expectEqual(@as(u64, 3), got.replaced);
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

/// Opens path and reads it through from its start, so each refill grows
/// the buffer.
fn openAndGrow(gpa: Allocator, io: Io, path: []const u8, options: Options) !void {
    var in: Input = try .open(io, gpa, path, options);
    defer in.close(io, gpa);
    while (!in.eof) try in.refill(io, gpa, in.base);
}

test "open and refill free what they hold when an allocation fails" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.csv", .data = "id,name\n1,apple\n2,pear\n3,plum\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "u.csv", .data = "\xff\xfei\x00d\x00,\x00x\x00\n\x001\x00,\x00\xe9\x00\n\x00" });
    var path_buf: [256]u8 = undefined;
    for ([_][]const u8{ "a.csv", "u.csv" }) |name| {
        const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
        try testing.checkAllAllocationFailures(testing.allocator, openAndGrow, .{ io, path, Options{ .no_mmap = true, .buffer = 4 } });
    }
}
