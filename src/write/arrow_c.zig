//! Arrow's C Data Interface: a batch handed to another library in the same
//! process as Arrow arrays, with no IPC stream between
//! (https://arrow.apache.org/docs/format/CDataInterface.html). The structs
//! are the spec's, laid out as its C header has them, and a schema's types
//! are the ones the IPC writer declares: int64, float64, decimal128, bool,
//! date32 (days), time64 and timestamp (microseconds, UTC), utf8 and
//! binary with int32 offsets, and an enum as int32 indices into a utf8
//! dictionary of its values. A batch is a struct array of its columns.
//!
//! The values move out of the builders, not copied: ints, floats,
//! decimals, days, enum indices and string bytes. Validity and bool
//! bitmaps and int32 string offsets are made for the batch. Every array
//! and schema (the struct, each column, each dictionary) owns its memory
//! and has its own release, since the spec lets a consumer move a child
//! out and release it after its parent.
//!
//! The release callbacks free with the allocator given, from whichever
//! thread the consumer calls them on: an allocator that is not thread-safe
//! needs a consumer that releases on the thread it reads on.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const schema = @import("../schema.zig");
const builders = @import("../builders.zig");

// The values are handed over in the machine's byte order, which the C Data
// Interface takes as the platform's own; the IPC writer's types assume
// little-endian too.
comptime {
    if (builtin.cpu.arch.endian() != .little) @compileError("the Arrow export is little-endian only");
}

pub const flag_dictionary_ordered: i64 = 1;
pub const flag_nullable: i64 = 2;

pub const Schema = extern struct {
    format: [*:0]const u8 = "",
    name: ?[*:0]const u8 = null,
    metadata: ?[*]const u8 = null,
    flags: i64 = 0,
    n_children: i64 = 0,
    children: ?[*]*Schema = null,
    dictionary: ?*Schema = null,
    release: ?*const fn (*Schema) callconv(.c) void = null,
    private_data: ?*anyopaque = null,
};

pub const Array = extern struct {
    length: i64 = 0,
    null_count: i64 = 0,
    offset: i64 = 0,
    n_buffers: i64 = 0,
    n_children: i64 = 0,
    buffers: ?[*]?*const anyopaque = null,
    children: ?[*]*Array = null,
    dictionary: ?*Array = null,
    release: ?*const fn (*Array) callconv(.c) void = null,
    private_data: ?*anyopaque = null,
};

pub const ArrayStream = extern struct {
    get_schema: ?*const fn (*ArrayStream, *Schema) callconv(.c) c_int = null,
    get_next: ?*const fn (*ArrayStream, *Array) callconv(.c) c_int = null,
    get_last_error: ?*const fn (*ArrayStream) callconv(.c) ?[*:0]const u8 = null,
    release: ?*const fn (*ArrayStream) callconv(.c) void = null,
    private_data: ?*anyopaque = null,
};

pub const Error = Allocator.Error || error{StringColumnTooLong};

/// Where a buffer of no bytes points: some consumers take a null for one
/// as a missing buffer.
const empty: [64]u8 align(64) = @splat(0);

/// What one exported array or schema owns, freed by its release: its
/// arena (its children's structs and pointer arrays, its strings, the
/// buffers made for it) and the buffers moved out of a builder.
const Node = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    moved: std.ArrayList(Moved) = .empty,

    const Moved = struct { bytes: []u8, alignment: std.mem.Alignment };

    fn create(gpa: Allocator) Allocator.Error!*Node {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        const n = arena.allocator().create(Node) catch |e| {
            arena.deinit();
            return e;
        };
        n.* = .{ .gpa = gpa, .arena = arena };
        return n;
    }

    fn allocator(n: *Node) Allocator {
        return n.arena.allocator();
    }

    fn destroy(n: *Node) void {
        for (n.moved.items) |m| n.gpa.rawFree(m.bytes, m.alignment, @returnAddress());
        // The node lives in its arena: copied out before it is freed.
        const arena = n.arena;
        arena.deinit();
    }

    /// list's values, moved to the node, which frees them. list is left
    /// empty, with room for as many again, so the next batch does not
    /// grow from nothing.
    fn take(n: *Node, comptime T: type, list: *std.ArrayList(T)) Allocator.Error!*const anyopaque {
        const len = list.items.len;
        if (list.capacity == 0) return &empty;
        try n.moved.ensureUnusedCapacity(n.allocator(), 1);
        const all = list.allocatedSlice();
        n.moved.appendAssumeCapacity(.{ .bytes = std.mem.sliceAsBytes(all), .alignment = .of(T) });
        list.* = .empty;
        try list.ensureTotalCapacity(n.gpa, len);
        return all.ptr;
    }

    /// bits as an Arrow bitmap: bit i of byte i / 8, least significant
    /// first.
    fn bitmap(n: *Node, bits: []const bool) Allocator.Error!*const anyopaque {
        const bytes = try n.allocator().alignedAlloc(u8, .@"64", @max(1, (bits.len + 7) / 8));
        @memset(bytes, 0);
        for (bits, 0..) |b, i| bytes[i / 8] |= @as(u8, @intFromBool(b)) << @intCast(i % 8);
        return bytes.ptr;
    }

    /// offsets as int32, rows + 1 of them; an empty list is a single 0.
    fn offsets32(n: *Node, offsets: []const u64, rows: usize) Error!*const anyopaque {
        const out = try n.allocator().alignedAlloc(i32, .@"64", rows + 1);
        if (offsets.len == 0) {
            out[0] = 0;
            return out.ptr;
        }
        // A batch is at most 64 MiB of field bytes; one string column over
        // 2 GiB would need large_utf8.
        for (out, offsets[0 .. rows + 1]) |*o, x| o.* = std.math.cast(i32, x) orelse return error.StringColumnTooLong;
        return out.ptr;
    }
};

fn nodeOf(private_data: ?*anyopaque) *Node {
    return @ptrCast(@alignCast(private_data.?));
}

fn releaseSchema(s: *Schema) callconv(.c) void {
    if (s.children) |cs| for (cs[0..@intCast(s.n_children)]) |c| if (c.release) |r| r(c);
    if (s.dictionary) |d| if (d.release) |r| r(d);
    const n = nodeOf(s.private_data);
    s.release = null;
    n.destroy();
}

fn releaseArray(a: *Array) callconv(.c) void {
    if (a.children) |cs| for (cs[0..@intCast(a.n_children)]) |c| if (c.release) |r| r(c);
    if (a.dictionary) |d| if (d.release) |r| r(d);
    const n = nodeOf(a.private_data);
    a.release = null;
    n.destroy();
}

/// Blank structs for a node's children, in its arena.
fn blanks(comptime T: type, a: Allocator, count: usize) Allocator.Error!?[*]*T {
    if (count == 0) return null;
    const ptrs = try a.alloc(*T, count);
    const structs = try a.alloc(T, count);
    for (ptrs, structs) |*p, *s| {
        s.* = .{};
        p.* = s;
    }
    return ptrs.ptr;
}

/// out as a schema node of its own, with count blank children to fill.
fn schemaNode(gpa: Allocator, out: *Schema, format: []const u8, name: ?[]const u8, flags: i64, count: usize) Allocator.Error!*Node {
    const n = try Node.create(gpa);
    errdefer n.destroy();
    const a = n.allocator();
    out.* = .{
        .format = try a.dupeSentinel(u8, format, 0),
        .name = if (name) |s| try a.dupeSentinel(u8, s, 0) else null,
        .flags = flags,
        .n_children = @intCast(count),
        .children = try blanks(Schema, a, count),
        .release = releaseSchema,
        .private_data = n,
    };
    return n;
}

/// out as an array node of its own, with buffers to fill and count blank
/// children.
fn arrayNode(gpa: Allocator, out: *Array, length: usize, null_count: usize, buffers: usize, count: usize) Allocator.Error!*Node {
    const n = try Node.create(gpa);
    errdefer n.destroy();
    const a = n.allocator();
    const bufs = try a.alloc(?*const anyopaque, buffers);
    @memset(bufs, null);
    out.* = .{
        .length = @intCast(length),
        .null_count = @intCast(null_count),
        .n_buffers = @intCast(buffers),
        .n_children = @intCast(count),
        .buffers = bufs.ptr,
        .children = try blanks(Array, a, count),
        .release = releaseArray,
        .private_data = n,
    };
    return n;
}

/// Fills out by build(out), and releases what it made of out if build fails.
fn whole(out: anytype, build: anytype, args: anytype) Error!void {
    out.* = .{};
    errdefer if (out.release) |r| r(out);
    try @call(.auto, build, .{out} ++ args);
}

/// s as an ArrowSchema: a struct of its columns.
pub fn exportSchema(gpa: Allocator, s: *const schema.Schema, out: *Schema) Error!void {
    return whole(out, buildSchema, .{ gpa, s });
}

fn buildSchema(out: *Schema, gpa: Allocator, s: *const schema.Schema) Error!void {
    _ = try schemaNode(gpa, out, "+s", "", 0, s.columns.len);
    for (s.columns, 0..) |c, i| try columnSchema(gpa, out.children.?[i], c);
}

fn columnSchema(gpa: Allocator, out: *Schema, c: schema.Column) Error!void {
    var buf: [16]u8 = undefined;
    const format: []const u8 = switch (c.type) {
        .bool => "b",
        .int64 => "l",
        .float64 => "g",
        .decimal => std.fmt.bufPrint(&buf, "d:{d},{d}", .{ c.precision, c.scale }) catch unreachable,
        .date => "tdD",
        .time => "ttu",
        .timestamp => "tsu:UTC",
        // A string column whose bytes may not be UTF-8 is binary.
        .string => if (c.utf8 == .binary) "z" else "u",
        .binary => "z",
        .@"enum" => "i",
    };
    const n = try schemaNode(gpa, out, format, c.name, if (c.nullable) flag_nullable else 0, 0);
    if (c.type != .@"enum") return;
    const d = try n.allocator().create(Schema);
    d.* = .{};
    out.dictionary = d;
    _ = try schemaNode(gpa, d, "u", null, 0, 0);
}

/// b's rows as a struct array of its columns, as exportSchema(s) declares
/// them. b is left empty whether or not this succeeds: its values have
/// moved to out.
pub fn exportBatch(gpa: Allocator, s: *const schema.Schema, b: *builders.Batch, out: *Array) Error!void {
    defer b.reset();
    return whole(out, buildBatch, .{ gpa, s, b });
}

fn buildBatch(out: *Array, gpa: Allocator, s: *const schema.Schema, b: *builders.Batch) Error!void {
    _ = try arrayNode(gpa, out, b.rows, 0, 1, b.columns.len);
    for (b.columns, s.columns, 0..) |*c, sc, i| try columnArray(gpa, out.children.?[i], c, sc, b.rows);
}

fn nullsIn(valid: []const bool) usize {
    var n: usize = 0;
    for (valid) |v| n += @intFromBool(!v);
    return n;
}

fn columnArray(gpa: Allocator, out: *Array, c: *builders.Column, sc: schema.Column, rows: usize) Error!void {
    const nulls = nullsIn(c.valid.items);
    const text = sc.type == .string or sc.type == .binary;
    const n = try arrayNode(gpa, out, rows, nulls, if (text) 3 else 2, 0);
    const bufs = out.buffers.?;
    // No nulls: no validity bitmap, which a null pointer says.
    if (nulls > 0) bufs[0] = try n.bitmap(c.valid.items);
    switch (sc.type) {
        .int64, .time, .timestamp => bufs[1] = try n.take(i64, &c.ints),
        .date => bufs[1] = try n.take(i32, &c.days),
        .float64 => bufs[1] = try n.take(f64, &c.floats),
        .decimal => bufs[1] = try n.take(i128, &c.decimals),
        .bool => bufs[1] = try n.bitmap(c.bools.items),
        .@"enum" => {
            // The indices are below 2^31, so as int32 they are the same.
            bufs[1] = try n.take(u32, &c.indices);
            const d = try n.allocator().create(Array);
            d.* = .{};
            out.dictionary = d;
            try dictionaryArray(gpa, d, sc.values);
        },
        .string, .binary => {
            bufs[1] = try n.offsets32(c.offsets.items, rows);
            bufs[2] = try n.take(u8, &c.bytes);
        },
    }
}

/// An enum's values, a utf8 array: every batch has its own, as each
/// array owns its dictionary.
fn dictionaryArray(gpa: Allocator, out: *Array, values: []const []const u8) Error!void {
    const n = try arrayNode(gpa, out, values.len, 0, 3, 0);
    const a = n.allocator();
    const offsets = try a.alignedAlloc(i32, .@"64", values.len + 1);
    var len: usize = 0;
    for (values) |v| len += v.len;
    const data = try a.alignedAlloc(u8, .@"64", len);
    offsets[0] = 0;
    var at: usize = 0;
    for (values, 1..) |v, i| {
        @memcpy(data[at..][0..v.len], v);
        at += v.len;
        offsets[i] = std.math.cast(i32, at) orelse return error.StringColumnTooLong;
    }
    out.buffers.?[1] = offsets.ptr;
    out.buffers.?[2] = if (len == 0) &empty else data.ptr;
}

/// The rejects' schema: a nullable utf8 for each of the file's fields,
/// named as the reject file's header names them, then _row (int64),
/// _errors (a list of struct {column: utf8, null for the whole row; code:
/// utf8}) and _extra (a nullable utf8).
pub fn exportRejectsSchema(gpa: Allocator, names: []const []const u8, out: *Schema) Error!void {
    return whole(out, buildRejectsSchema, .{ gpa, names });
}

fn buildRejectsSchema(out: *Schema, gpa: Allocator, names: []const []const u8) Error!void {
    _ = try schemaNode(gpa, out, "+s", "", 0, names.len + 3);
    const ch = out.children.?;
    for (names, 0..) |name, i| _ = try schemaNode(gpa, ch[i], "u", name, flag_nullable, 0);
    _ = try schemaNode(gpa, ch[names.len], "l", "_row", 0, 0);
    const errors = ch[names.len + 1];
    _ = try schemaNode(gpa, errors, "+l", "_errors", 0, 1);
    const item = errors.children.?[0];
    _ = try schemaNode(gpa, item, "+s", "item", 0, 2);
    _ = try schemaNode(gpa, item.children.?[0], "u", "column", flag_nullable, 0);
    _ = try schemaNode(gpa, item.children.?[1], "u", "code", 0, 0);
    _ = try schemaNode(gpa, ch[names.len + 2], "u", "_extra", flag_nullable, 0);
}

/// r's rows as a struct array, as exportRejectsSchema declares them for
/// width fields. r is left empty whether or not this succeeds.
pub fn exportRejects(gpa: Allocator, r: *builders.Rejects, width: usize, out: *Array) Error!void {
    defer r.reset();
    return whole(out, buildRejects, .{ gpa, r, width });
}

fn buildRejects(out: *Array, gpa: Allocator, r: *builders.Rejects, width: usize) Error!void {
    // No row yet: the builder has no fields, and every column is empty.
    std.debug.assert(r.rows == 0 or r.fields.len == width);
    var none: builders.Text = .{};
    _ = try arrayNode(gpa, out, r.rows, 0, 1, width + 3);
    const ch = out.children.?;
    for (0..width) |i| try textArray(gpa, ch[i], if (r.rows > 0) &r.fields[i] else &none, r.rows);
    const lines = try arrayNode(gpa, ch[width], r.rows, 0, 2, 0);
    ch[width].buffers.?[1] = try lines.take(i64, &r.lines);
    const errors = ch[width + 1];
    const list = try arrayNode(gpa, errors, r.rows, 0, 2, 1);
    errors.buffers.?[1] = try list.offsets32(r.error_offsets.items, r.rows);
    const count = r.error_codes.valid.items.len;
    const item = errors.children.?[0];
    _ = try arrayNode(gpa, item, count, 0, 1, 2);
    try textArray(gpa, item.children.?[0], &r.error_columns, count);
    try textArray(gpa, item.children.?[1], &r.error_codes, count);
    try textArray(gpa, ch[width + 2], &r.extra, r.rows);
}

fn textArray(gpa: Allocator, out: *Array, t: *builders.Text, rows: usize) Error!void {
    const nulls = nullsIn(t.valid.items);
    const n = try arrayNode(gpa, out, rows, nulls, 3, 0);
    const bufs = out.buffers.?;
    if (nulls > 0) bufs[0] = try n.bitmap(t.valid.items);
    bufs[1] = try n.offsets32(t.offsets.items, rows);
    bufs[2] = try n.take(u8, &t.bytes);
}

const testing = std.testing;
const types = @import("../types.zig");

fn bufferOf(comptime T: type, a: *const Array, i: usize, len: usize) []const T {
    const p: [*]const T = @ptrCast(@alignCast(a.buffers.?[i].?));
    return p[0..len];
}

fn bit(a: *const Array, buffer: usize, i: usize) bool {
    const p: [*]const u8 = @ptrCast(a.buffers.?[buffer].?);
    return p[i / 8] & (@as(u8, 1) << @intCast(i % 8)) != 0;
}

fn textAt(a: *const Array, i: usize) []const u8 {
    const offsets = bufferOf(i32, a, 1, @intCast(a.length + 1));
    const data: [*]const u8 = @ptrCast(a.buffers.?[2].?);
    return data[@intCast(offsets[i])..@intCast(offsets[i + 1])];
}

const every_type: schema.Schema = .{ .columns = &.{
    .{ .name = "lug_id", .type = .int64, .nullable = false },
    .{ .name = "brix", .type = .float64 },
    .{ .name = "lug_kg", .type = .decimal, .precision = 6, .scale = 2 },
    .{ .name = "bruised", .type = .bool },
    .{ .name = "picked_on", .type = .date },
    .{ .name = "picked_at", .type = .time },
    .{ .name = "weighed", .type = .timestamp },
    .{ .name = "remark", .type = .string },
    .{ .name = "tag", .type = .binary },
    .{ .name = "cultivar", .type = .@"enum", .values = &.{ "Starfall", "Quillon" } },
} };

fn fillEveryType(b: *builders.Batch) !void {
    try b.append(
        &.{ "1", "12.5", "17.25", "true", "2026-09-14", "06:30", "2026-09-14 07:00", "frost", "a1", "Quillon" },
        &.{ .{ .int = 1 }, .{ .float = 12.5 }, .{ .decimal = 1725 }, .{ .bool = true }, .{ .date = 20345 }, .{ .time = 23_400_000_000 }, .{ .timestamp = 1_789_369_200_000_000 }, .{ .string = "frost" }, .{ .binary = "a1" }, .{ .enumeration = 1 } },
    );
    try b.append(
        &.{ "2", "", "", "", "", "", "", "", "", "" },
        &.{ .{ .int = 2 }, null, null, null, null, null, null, null, null, null },
    );
}

test "a schema says each type as the IPC writer declares it" {
    var s: Schema = undefined;
    try exportSchema(testing.allocator, &every_type, &s);
    defer s.release.?(&s);
    try testing.expectEqualStrings("+s", std.mem.span(s.format));
    try testing.expectEqual(@as(i64, 10), s.n_children);
    const want = [_][]const u8{ "l", "g", "d:6,2", "b", "tdD", "ttu", "tsu:UTC", "u", "z", "i" };
    for (want, s.children.?[0..10], every_type.columns) |f, c, sc| {
        try testing.expectEqualStrings(f, std.mem.span(c.format));
        try testing.expectEqualStrings(sc.name, std.mem.span(c.name.?));
        try testing.expectEqual(if (sc.nullable) flag_nullable else 0, c.flags);
    }
    const cultivar = s.children.?[9];
    try testing.expectEqualStrings("u", std.mem.span(cultivar.dictionary.?.format));
}

test "a batch hands over its values, moved, not copied" {
    var b: builders.Batch = try .init(testing.allocator, &every_type, .utf8);
    defer b.deinit();
    try fillEveryType(&b);
    const ints = b.columns[0].ints.items.ptr;
    const bytes = b.columns[7].bytes.items.ptr;
    var a: Array = undefined;
    try exportBatch(testing.allocator, &every_type, &b, &a);
    defer a.release.?(&a);
    // The builders are empty, and ready for the next batch.
    try testing.expectEqual(@as(usize, 0), b.rows);
    try testing.expectEqual(@as(usize, 0), b.columns[0].ints.items.len);

    try testing.expectEqual(@as(i64, 2), a.length);
    const ch = a.children.?;
    try testing.expectEqual(@as(*const anyopaque, ints), ch[0].buffers.?[1].?);
    try testing.expectEqual(@as(*const anyopaque, bytes), ch[7].buffers.?[2].?);
    // lug_id has no nulls, so no bitmap; every other column has one.
    try testing.expectEqual(@as(?*const anyopaque, null), ch[0].buffers.?[0]);
    try testing.expectEqualSlices(i64, &.{ 1, 2 }, bufferOf(i64, ch[0], 1, 2));
    for (ch[1..10]) |c| {
        try testing.expectEqual(@as(i64, 1), c.null_count);
        try testing.expect(bit(c, 0, 0) and !bit(c, 0, 1));
    }
    try testing.expectEqual(@as(f64, 12.5), bufferOf(f64, ch[1], 1, 2)[0]);
    try testing.expectEqual(@as(i128, 1725), bufferOf(i128, ch[2], 1, 2)[0]);
    try testing.expect(bit(ch[3], 1, 0));
    try testing.expectEqual(@as(i32, 20345), bufferOf(i32, ch[4], 1, 2)[0]);
    try testing.expectEqual(@as(i64, 23_400_000_000), bufferOf(i64, ch[5], 1, 2)[0]);
    try testing.expectEqualStrings("frost", textAt(ch[7], 0));
    try testing.expectEqualStrings("", textAt(ch[7], 1));
    try testing.expectEqualStrings("a1", textAt(ch[8], 0));
    try testing.expectEqual(@as(i32, 1), bufferOf(i32, ch[9], 1, 2)[0]);
    const d = ch[9].dictionary.?;
    try testing.expectEqualStrings("Starfall", textAt(d, 0));
    try testing.expectEqualStrings("Quillon", textAt(d, 1));

    // The next batch fills the builders again.
    try fillEveryType(&b);
    var next: Array = undefined;
    try exportBatch(testing.allocator, &every_type, &b, &next);
    defer next.release.?(&next);
    try testing.expectEqualStrings("frost", textAt(next.children.?[7], 0));
}

test "a child moved out lives on after its parent is released" {
    var b: builders.Batch = try .init(testing.allocator, &every_type, .utf8);
    defer b.deinit();
    try fillEveryType(&b);
    var a: Array = undefined;
    try exportBatch(testing.allocator, &every_type, &b, &a);
    var s: Schema = undefined;
    try exportSchema(testing.allocator, &every_type, &s);
    // As the spec has a consumer move a child: copy it, mark the original
    // released, and release the parent.
    const remark = a.children.?[7].*;
    a.children.?[7].release = null;
    const cultivar = s.children.?[9].*;
    s.children.?[9].release = null;
    a.release.?(&a);
    s.release.?(&s);
    try testing.expectEqual(@as(?*const fn (*Array) callconv(.c) void, null), a.release);
    var moved = remark;
    try testing.expectEqualStrings("frost", textAt(&moved, 0));
    moved.release.?(&moved);
    var moved_schema = cultivar;
    try testing.expectEqualStrings("u", std.mem.span(moved_schema.dictionary.?.format));
    moved_schema.release.?(&moved_schema);
}

test "an empty batch is arrays of no rows, every buffer there" {
    var b: builders.Batch = try .init(testing.allocator, &every_type, .utf8);
    defer b.deinit();
    var a: Array = undefined;
    try exportBatch(testing.allocator, &every_type, &b, &a);
    defer a.release.?(&a);
    try testing.expectEqual(@as(i64, 0), a.length);
    for (a.children.?[0..10]) |c| for (c.buffers.?[1..@intCast(c.n_buffers)]) |p| try testing.expect(p != null);
}

test "rejects: each field as text, a short row's missing as nulls, errors as codes" {
    var r: builders.Rejects = .init(testing.allocator, .latin1);
    defer r.deinit();
    try r.begin(2);
    try r.field(0, "x");
    try r.field(1, "caf\xe9");
    try r.end(3, &.{ .{ .column = "lug_id", .reason = .not_int }, .{ .column = "lug_kg", .reason = .not_decimal } }, null);
    try r.begin(2);
    try r.field(0, "4");
    try r.field(1, null);
    try r.end(5, &.{.{ .column = null, .reason = .ragged }}, null);
    try r.begin(2);
    try r.field(0, "5");
    try r.field(1, "6");
    try r.end(6, &.{.{ .column = null, .reason = .ragged }}, "7|8");
    var s: Schema = undefined;
    try exportRejectsSchema(testing.allocator, &.{ "lug_id", "lug_kg" }, &s);
    defer s.release.?(&s);
    try testing.expectEqualStrings("+l", std.mem.span(s.children.?[3].format));
    var a: Array = undefined;
    try exportRejects(testing.allocator, &r, 2, &a);
    defer a.release.?(&a);
    try testing.expectEqual(@as(usize, 0), r.rows);
    const ch = a.children.?;
    try testing.expectEqual(@as(i64, 3), a.length);
    try testing.expectEqualStrings("café", textAt(ch[1], 0));
    try testing.expect(!bit(ch[1], 0, 1));
    try testing.expectEqualSlices(i64, &.{ 3, 5, 6 }, bufferOf(i64, ch[2], 1, 3));
    try testing.expectEqualSlices(i32, &.{ 0, 2, 3, 4 }, bufferOf(i32, ch[3], 1, 4));
    const item = ch[3].children.?[0];
    try testing.expectEqual(@as(i64, 4), item.length);
    try testing.expectEqualStrings("lug_kg", textAt(item.children.?[0], 1));
    try testing.expectEqual(@as(i64, 2), item.children.?[0].null_count);
    try testing.expectEqualStrings("not_decimal", textAt(item.children.?[1], 1));
    try testing.expectEqualStrings("ragged", textAt(item.children.?[1], 2));
    try testing.expectEqualStrings("7|8", textAt(ch[4], 2));
    try testing.expectEqual(@as(i64, 2), ch[4].null_count);

    // No rows yet: every column empty, the names still there.
    var none: Array = undefined;
    try exportRejects(testing.allocator, &r, 2, &none);
    defer none.release.?(&none);
    try testing.expectEqual(@as(i64, 0), none.length);
}

fn exportAll(gpa: Allocator) !void {
    var b: builders.Batch = try .init(gpa, &every_type, .utf8);
    defer b.deinit();
    try fillEveryType(&b);
    var s: Schema = undefined;
    try exportSchema(gpa, &every_type, &s);
    defer s.release.?(&s);
    var a: Array = undefined;
    try exportBatch(gpa, &every_type, &b, &a);
    a.release.?(&a);
    var r: builders.Rejects = .init(gpa, .utf8);
    defer r.deinit();
    try r.begin(1);
    try r.field(0, "x");
    try r.end(2, &.{.{ .column = "lug_id", .reason = types.Reason.not_int }}, "y");
    var rs: Schema = undefined;
    try exportRejectsSchema(gpa, &.{"lug_id"}, &rs);
    defer rs.release.?(&rs);
    var ra: Array = undefined;
    try exportRejects(gpa, &r, 1, &ra);
    ra.release.?(&ra);
}

test "an allocation that fails frees what was made" {
    try testing.checkAllAllocationFailures(testing.allocator, exportAll, .{});
}
