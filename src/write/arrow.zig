//! Arrow IPC output, pure Zig: the stream format (.arrows) by default, the
//! file format (.arrow, with a footer) under --arrow-file. One record batch
//! a parse batch; an enum column is dictionary-encoded (Int32 indices into
//! its values), its dictionary sent once before the first record batch.
//! Buffers are 8-byte aligned, with validity bitmaps; no compression.
//!
//! An encapsulated message is 0xFFFFFFFF, the metadata's length, the
//! Message flatbuffer padded to 8, then the body its bodyLength says.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fb = @import("flatbuf.zig");
const schema = @import("../schema.zig");
const builders = @import("../builders.zig");

// Ints, floats, decimals and the flatbuffers' structs are written in the
// machine's byte order, and the schema declares little-endian.
comptime {
    if (builtin.cpu.arch.endian() != .little) @compileError("the Arrow writer writes little-endian only");
}

const continuation: u32 = 0xFFFF_FFFF;
const magic = "ARROW1";

// The enum values Arrow's .fbs files give these.
const metadata_v5: i16 = 4;
const header_schema: u8 = 1;
const header_dictionary: u8 = 2;
const header_record_batch: u8 = 3;
const type_int: u8 = 2;
const type_float: u8 = 3;
const type_binary: u8 = 4;
const type_utf8: u8 = 5;
const type_bool: u8 = 6;
const type_decimal: u8 = 7;
const type_date: u8 = 8;
const type_time: u8 = 9;
const type_timestamp: u8 = 10;
const precision_double: i16 = 2;
const date_day: i16 = 0;
const unit_microsecond: i16 = 2;

const FieldNode = extern struct { length: i64, null_count: i64 };
const Buffer = extern struct { offset: i64, length: i64 };
/// A message in the file format's footer: where it starts, the length of
/// its prefix and metadata, and of its body.
const Block = extern struct { offset: i64, meta_data_length: i32, _pad: i32 = 0, body_length: i64 };

pub const Options = struct {
    /// The file format, with a footer, rather than the stream format.
    file: bool = false,
};

/// Each call that writes takes the writer to write to, so a Writer moved
/// by value holds no pointer into where it was made.
pub const Writer = struct {
    gpa: Allocator,
    schema: *const schema.Schema,
    options: Options,
    /// Bytes written so far: a block's offset in the file format.
    written: u64 = 0,
    dictionaries_sent: bool = false,
    dictionary_blocks: std.ArrayList(Block) = .empty,
    batch_blocks: std.ArrayList(Block) = .empty,
    meta: std.ArrayList(u8) = .empty,
    body: std.ArrayList(u8) = .empty,
    nodes: std.ArrayList(FieldNode) = .empty,
    buffers: std.ArrayList(Buffer) = .empty,

    pub fn init(gpa: Allocator, s: *const schema.Schema, options: Options) Writer {
        return .{ .gpa = gpa, .schema = s, .options = options };
    }

    pub fn deinit(w: *Writer) void {
        inline for (.{ "dictionary_blocks", "batch_blocks", "meta", "body", "nodes", "buffers" }) |f| @field(w, f).deinit(w.gpa);
    }

    /// The file's magic (file format) and the schema message.
    pub fn header(w: *Writer, out: *Io.Writer) !void {
        if (w.options.file) try w.raw(out, magic ++ "\x00\x00");
        var arena: std.heap.ArenaAllocator = .init(w.gpa);
        defer arena.deinit();
        var b: fb.Builder = .init(arena.allocator());
        const s = try schemaTable(&b, w.schema);
        w.body.clearRetainingCapacity();
        _ = try w.message(out, &b, header_schema, s);
    }

    /// One record batch from b, after the dictionaries the first time.
    pub fn batch(w: *Writer, out: *Io.Writer, b: *const builders.Batch) !void {
        if (!w.dictionaries_sent) {
            w.dictionaries_sent = true;
            try w.dictionaries(out);
        }
        w.body.clearRetainingCapacity();
        w.nodes.clearRetainingCapacity();
        w.buffers.clearRetainingCapacity();
        for (b.columns, w.schema.columns) |*c, sc| try w.column(c, sc, b.rows);
        var arena: std.heap.ArenaAllocator = .init(w.gpa);
        defer arena.deinit();
        var f: fb.Builder = .init(arena.allocator());
        const rb = try w.recordBatch(&f, b.rows);
        const block = try w.message(out, &f, header_record_batch, rb);
        try w.batch_blocks.append(w.gpa, block);
    }

    /// The end: the stream's end-of-stream marker, and in the file format
    /// the footer, its length and the magic.
    pub fn end(w: *Writer, out: *Io.Writer) !void {
        if (!w.dictionaries_sent) {
            w.dictionaries_sent = true;
            try w.dictionaries(out);
        }
        var eos: [8]u8 = undefined;
        std.mem.writeInt(u32, eos[0..4], continuation, .little);
        std.mem.writeInt(u32, eos[4..8], 0, .little);
        try w.raw(out, &eos);
        if (!w.options.file) return;
        var arena: std.heap.ArenaAllocator = .init(w.gpa);
        defer arena.deinit();
        var b: fb.Builder = .init(arena.allocator());
        const footer = try b.table(&.{
            .{ .slot = 0, .value = .{ .i16 = metadata_v5 } },
            .{ .slot = 1, .value = .{ .ref = try schemaTable(&b, w.schema) } },
            .{ .slot = 2, .value = .{ .ref = try b.structs(Block, w.dictionary_blocks.items) } },
            .{ .slot = 3, .value = .{ .ref = try b.structs(Block, w.batch_blocks.items) } },
        });
        try b.finish(w.gpa, footer, &w.meta);
        try w.raw(out, w.meta.items);
        var len: [4]u8 = undefined;
        std.mem.writeInt(i32, &len, @intCast(w.meta.items.len), .little);
        try w.raw(out, &len);
        try w.raw(out, magic);
    }

    fn raw(w: *Writer, out: *Io.Writer, bytes: []const u8) !void {
        try out.writeAll(bytes);
        w.written += bytes.len;
    }

    /// Writes the message with header as its header and w.body as its body.
    fn message(w: *Writer, out: *Io.Writer, b: *fb.Builder, header_type: u8, header_ref: fb.Ref) !Block {
        try padBody(w.gpa, &w.body);
        const m = try b.table(&.{
            .{ .slot = 0, .value = .{ .i16 = metadata_v5 } },
            .{ .slot = 1, .value = .{ .u8 = header_type } },
            .{ .slot = 2, .value = .{ .ref = header_ref } },
            .{ .slot = 3, .value = .{ .i64 = @intCast(w.body.items.len) } },
        });
        try b.finish(w.gpa, m, &w.meta);
        const block: Block = .{
            .offset = @intCast(w.written),
            .meta_data_length = @intCast(8 + w.meta.items.len),
            .body_length = @intCast(w.body.items.len),
        };
        var prefix: [8]u8 = undefined;
        std.mem.writeInt(u32, prefix[0..4], continuation, .little);
        std.mem.writeInt(i32, prefix[4..8], @intCast(w.meta.items.len), .little);
        try w.raw(out, &prefix);
        try w.raw(out, w.meta.items);
        try w.raw(out, w.body.items);
        return block;
    }

    /// The enum columns' values, a dictionary batch each, id the column's
    /// index.
    fn dictionaries(w: *Writer, out: *Io.Writer) !void {
        for (w.schema.columns, 0..) |c, i| {
            if (c.type != .@"enum") continue;
            w.body.clearRetainingCapacity();
            w.nodes.clearRetainingCapacity();
            w.buffers.clearRetainingCapacity();
            var offsets: std.ArrayList(u8) = .empty;
            defer offsets.deinit(w.gpa);
            var data: std.ArrayList(u8) = .empty;
            defer data.deinit(w.gpa);
            try appendLe(w.gpa, &offsets, i32, 0);
            for (c.values) |v| {
                try data.appendSlice(w.gpa, v);
                try appendLe(w.gpa, &offsets, i32, @intCast(data.items.len));
            }
            try w.nodes.append(w.gpa, .{ .length = @intCast(c.values.len), .null_count = 0 });
            try w.addBuffer(&.{});
            try w.addBuffer(offsets.items);
            try w.addBuffer(data.items);
            var arena: std.heap.ArenaAllocator = .init(w.gpa);
            defer arena.deinit();
            var b: fb.Builder = .init(arena.allocator());
            const rb = try w.recordBatch(&b, c.values.len);
            const db = try b.table(&.{
                .{ .slot = 0, .value = .{ .i64 = @intCast(i) } },
                .{ .slot = 1, .value = .{ .ref = rb } },
                .{ .slot = 2, .value = .{ .bool = false } },
            });
            try w.dictionary_blocks.append(w.gpa, try w.message(out, &b, header_dictionary, db));
        }
    }

    fn recordBatch(w: *Writer, b: *fb.Builder, rows: usize) !fb.Ref {
        return b.table(&.{
            .{ .slot = 0, .value = .{ .i64 = @intCast(rows) } },
            .{ .slot = 1, .value = .{ .ref = try b.structs(FieldNode, w.nodes.items) } },
            .{ .slot = 2, .value = .{ .ref = try b.structs(Buffer, w.buffers.items) } },
        });
    }

    /// Appends bytes to the body as the next buffer, 8-byte aligned.
    fn addBuffer(w: *Writer, bytes: []const u8) !void {
        try padBody(w.gpa, &w.body);
        try w.buffers.append(w.gpa, .{ .offset = @intCast(w.body.items.len), .length = @intCast(bytes.len) });
        try w.body.appendSlice(w.gpa, bytes);
    }

    /// One column's node and buffers: validity, then its values.
    fn column(w: *Writer, c: *const builders.Column, sc: schema.Column, rows: usize) !void {
        const gpa = w.gpa;
        var nulls: usize = 0;
        for (c.valid.items) |v| nulls += @intFromBool(!v);
        try w.nodes.append(gpa, .{ .length = @intCast(rows), .null_count = @intCast(nulls) });
        var scratch: std.ArrayList(u8) = .empty;
        defer scratch.deinit(gpa);
        // No nulls: no validity bitmap, which a buffer of length 0 says.
        if (nulls == 0) try w.addBuffer(&.{}) else {
            try bitmap(gpa, &scratch, c.valid.items);
            try w.addBuffer(scratch.items);
        }
        scratch.clearRetainingCapacity();
        switch (sc.type) {
            .int64, .timestamp, .time => try w.addBuffer(std.mem.sliceAsBytes(c.ints.items)),
            .date => try w.addBuffer(std.mem.sliceAsBytes(c.days.items)),
            .float64 => try w.addBuffer(std.mem.sliceAsBytes(c.floats.items)),
            .decimal => try w.addBuffer(std.mem.sliceAsBytes(c.decimals.items)),
            .bool => {
                try bitmap(gpa, &scratch, c.bools.items);
                try w.addBuffer(scratch.items);
            },
            .@"enum" => try w.addBuffer(std.mem.sliceAsBytes(c.indices.items)),
            .string, .binary => {
                for (c.offsets.items) |o| {
                    // A batch is at most 64 MiB of field bytes; one field
                    // over 2 GiB is not written (it would need LargeUtf8).
                    try appendLe(gpa, &scratch, i32, std.math.cast(i32, o) orelse return error.StringColumnTooLong);
                }
                try w.addBuffer(scratch.items);
                try w.addBuffer(c.bytes.items);
            },
        }
    }
};

fn padBody(gpa: Allocator, body: *std.ArrayList(u8)) Allocator.Error!void {
    while (body.items.len % 8 != 0) try body.append(gpa, 0);
}

fn appendLe(gpa: Allocator, out: *std.ArrayList(u8), comptime T: type, x: T) Allocator.Error!void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, x, .little);
    try out.appendSlice(gpa, &buf);
}

/// bits as an Arrow bitmap: bit i of byte i / 8, least significant first.
fn bitmap(gpa: Allocator, out: *std.ArrayList(u8), bits: []const bool) Allocator.Error!void {
    const start = out.items.len;
    try out.appendNTimes(gpa, 0, (bits.len + 7) / 8);
    for (bits, 0..) |b, i| {
        if (b) out.items[start + i / 8] |= @as(u8, 1) << @intCast(i % 8);
    }
}

fn schemaTable(b: *fb.Builder, s: *const schema.Schema) Allocator.Error!fb.Ref {
    const fields = try b.arena.alloc(fb.Ref, s.columns.len);
    for (fields, s.columns, 0..) |*f, c, i| f.* = try fieldTable(b, c, i);
    return b.table(&.{
        .{ .slot = 0, .value = .{ .i16 = 0 } }, // little-endian
        .{ .slot = 1, .value = .{ .ref = try b.vector(fields) } },
    });
}

fn fieldTable(b: *fb.Builder, c: schema.Column, index: usize) Allocator.Error!fb.Ref {
    const empty = try b.table(&.{});
    const type_id: u8, const type_ref: fb.Ref = switch (c.type) {
        .bool => .{ type_bool, empty },
        .int64 => .{ type_int, try intTable(b, 64) },
        .float64 => .{ type_float, try b.table(&.{.{ .slot = 0, .value = .{ .i16 = precision_double } }}) },
        .decimal => .{ type_decimal, try b.table(&.{
            .{ .slot = 0, .value = .{ .i32 = c.precision } },
            .{ .slot = 1, .value = .{ .i32 = c.scale } },
            .{ .slot = 2, .value = .{ .i32 = 128 } },
        }) },
        .date => .{ type_date, try b.table(&.{.{ .slot = 0, .value = .{ .i16 = date_day } }}) },
        .time => .{ type_time, try b.table(&.{
            .{ .slot = 0, .value = .{ .i16 = unit_microsecond } },
            .{ .slot = 1, .value = .{ .i32 = 64 } },
        }) },
        .timestamp => .{ type_timestamp, try b.table(&.{
            .{ .slot = 0, .value = .{ .i16 = unit_microsecond } },
            .{ .slot = 1, .value = .{ .ref = try b.string("UTC") } },
        }) },
        .string, .@"enum" => .{ type_utf8, empty },
        .binary => .{ type_binary, empty },
    };
    // A string column whose bytes may not be UTF-8 is Binary.
    const binary = c.type == .string and c.utf8 == .binary;
    var fields: [6]fb.Field = .{
        .{ .slot = 0, .value = .{ .ref = try b.string(c.name) } },
        .{ .slot = 1, .value = .{ .bool = c.nullable } },
        .{ .slot = 2, .value = .{ .u8 = if (binary) type_binary else type_id } },
        .{ .slot = 3, .value = .{ .ref = type_ref } },
        // Arrow's readers refuse a field with no children vector.
        .{ .slot = 5, .value = .{ .ref = try b.vector(&.{}) } },
        undefined,
    };
    var n: usize = 5;
    if (c.type == .@"enum") {
        fields[n] = .{ .slot = 4, .value = .{ .ref = try b.table(&.{
            .{ .slot = 0, .value = .{ .i64 = @intCast(index) } },
            .{ .slot = 1, .value = .{ .ref = try intTable(b, 32) } },
            .{ .slot = 2, .value = .{ .bool = false } },
        }) } };
        n += 1;
    }
    return b.table(fields[0..n]);
}

fn intTable(b: *fb.Builder, bits: i32) Allocator.Error!fb.Ref {
    return b.table(&.{
        .{ .slot = 0, .value = .{ .i32 = bits } },
        .{ .slot = 1, .value = .{ .bool = true } },
    });
}

test "a stream: schema, a dictionary, a batch, the end" {
    const gpa = std.testing.allocator;
    const s: schema.Schema = .{ .columns = &.{
        .{ .name = "id", .type = .int64, .nullable = false },
        .{ .name = "status", .type = .@"enum", .values = &.{ "open", "closed" } },
        .{ .name = "note", .type = .string },
    } };
    var b: builders.Batch = try .init(gpa, &s, .utf8);
    defer b.deinit();
    try b.append(&.{ "1", "open", "hi" }, &.{ .{ .int = 1 }, .{ .enumeration = 0 }, .{ .string = "hi" } });
    try b.append(&.{ "2", "closed", "" }, &.{ .{ .int = 2 }, .{ .enumeration = 1 }, null });
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var w: Writer = .init(gpa, &s, .{});
    defer w.deinit();
    try w.header(&out.writer);
    try w.batch(&out.writer, &b);
    try w.end(&out.writer);
    const bytes = out.written();
    try std.testing.expectEqual(@as(usize, 0), bytes.len % 8);
    try std.testing.expectEqual(continuation, std.mem.readInt(u32, bytes[0..4], .little));
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0 }, bytes[bytes.len - 8 ..]);
    try std.testing.expectEqual(@as(usize, 1), w.dictionary_blocks.items.len);
    try std.testing.expectEqual(@as(usize, 1), w.batch_blocks.items.len);
    // Every message starts 8-aligned, at a continuation marker.
    for ([_]Block{ w.dictionary_blocks.items[0], w.batch_blocks.items[0] }) |blk| {
        try std.testing.expectEqual(@as(i64, 0), @mod(blk.offset, 8));
        try std.testing.expectEqual(continuation, std.mem.readInt(u32, bytes[@intCast(blk.offset)..][0..4], .little));
    }
}

test "the file format ends in a footer and the magic" {
    const gpa = std.testing.allocator;
    const s: schema.Schema = .{ .columns = &.{.{ .name = "x", .type = .float64 }} };
    var b: builders.Batch = try .init(gpa, &s, .utf8);
    defer b.deinit();
    try b.append(&.{"1.5"}, &.{.{ .float = 1.5 }});
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var w: Writer = .init(gpa, &s, .{ .file = true });
    defer w.deinit();
    try w.header(&out.writer);
    try w.batch(&out.writer, &b);
    try w.end(&out.writer);
    const bytes = out.written();
    try std.testing.expectEqualStrings("ARROW1\x00\x00", bytes[0..8]);
    try std.testing.expectEqualStrings("ARROW1", bytes[bytes.len - 6 ..]);
}
