//! The FlatBuffers subset Arrow IPC metadata needs: tables of scalars and
//! offsets, strings, vectors of offsets and of structs. No dependency and
//! no generated code.
//!
//! Objects are described first, as a tree, and laid out in one pass that
//! writes each object before the ones it points at, so every offset is
//! positive (FlatBuffers offsets only point forward) and every scalar sits
//! at an address aligned to its size from the buffer's start, as the
//! verifier Arrow's readers run demands. A vtable goes just before its
//! table; tables are not deduplicated.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Ref = u32;

pub const Value = union(enum) {
    u8: u8,
    bool: bool,
    i16: i16,
    i32: i32,
    i64: i64,
    ref: Ref,

    fn size(v: Value) usize {
        return switch (v) {
            .u8, .bool => 1,
            .i16 => 2,
            .i32, .ref => 4,
            .i64 => 8,
        };
    }
};

/// A table field: its slot (the field's id in the schema) and value.
pub const Field = struct { slot: u16, value: Value };

const Node = union(enum) {
    table: []const Field,
    string: []const u8,
    /// Offsets to tables or strings.
    refs: []const Ref,
    /// Structs inline: count elements of bytes.len / count bytes each,
    /// aligned to alignment.
    structs: struct { bytes: []const u8, count: u32, alignment: u8 },
};

pub const Builder = struct {
    arena: Allocator,
    nodes: std.ArrayList(Node) = .empty,

    pub fn init(arena: Allocator) Builder {
        return .{ .arena = arena };
    }

    fn add(b: *Builder, n: Node) Allocator.Error!Ref {
        try b.nodes.append(b.arena, n);
        return @intCast(b.nodes.items.len - 1);
    }

    pub fn table(b: *Builder, fields: []const Field) Allocator.Error!Ref {
        return b.add(.{ .table = try b.arena.dupe(Field, fields) });
    }

    pub fn string(b: *Builder, s: []const u8) Allocator.Error!Ref {
        return b.add(.{ .string = try b.arena.dupe(u8, s) });
    }

    pub fn vector(b: *Builder, refs: []const Ref) Allocator.Error!Ref {
        return b.add(.{ .refs = try b.arena.dupe(Ref, refs) });
    }

    /// A vector of structs, each an extern struct of T laid out as
    /// FlatBuffers lays it (little-endian, the platforms thresh targets).
    pub fn structs(b: *Builder, comptime T: type, items: []const T) Allocator.Error!Ref {
        return b.add(.{ .structs = .{
            .bytes = try b.arena.dupe(u8, std.mem.sliceAsBytes(items)),
            .count = @intCast(items.len),
            .alignment = @alignOf(T),
        } });
    }

    /// The buffer with root as its root table, into out (which it clears).
    pub fn finish(b: *Builder, gpa: Allocator, root: Ref, out: *std.ArrayList(u8)) Allocator.Error!void {
        out.clearRetainingCapacity();
        try out.appendNTimes(gpa, 0, 4);
        const pos = try b.write(gpa, root, out);
        std.mem.writeInt(u32, out.items[0..4], @intCast(pos), .little);
        try pad(gpa, out, 8);
    }

    /// Writes node and, after it, everything it points at; its position.
    fn write(b: *Builder, gpa: Allocator, ref: Ref, out: *std.ArrayList(u8)) Allocator.Error!usize {
        switch (b.nodes.items[ref]) {
            .string => |s| {
                try pad(gpa, out, 4);
                const pos = out.items.len;
                try appendInt(gpa, out, u32, @intCast(s.len));
                try out.appendSlice(gpa, s);
                try out.append(gpa, 0);
                return pos;
            },
            .structs => |v| {
                // The elements, after the length, aligned as a struct is.
                while ((out.items.len + 4) % v.alignment != 0) try out.append(gpa, 0);
                const pos = out.items.len;
                try appendInt(gpa, out, u32, v.count);
                try out.appendSlice(gpa, v.bytes);
                return pos;
            },
            .refs => |refs| {
                try pad(gpa, out, 4);
                const pos = out.items.len;
                try appendInt(gpa, out, u32, @intCast(refs.len));
                const slots = out.items.len;
                try out.appendNTimes(gpa, 0, 4 * refs.len);
                for (refs, 0..) |child, i| {
                    const at = slots + 4 * i;
                    const child_pos = try b.write(gpa, child, out);
                    std.mem.writeInt(u32, out.items[at..][0..4], @intCast(child_pos - at), .little);
                }
                return pos;
            },
            .table => |fields| return b.writeTable(gpa, fields, out),
        }
    }

    fn writeTable(b: *Builder, gpa: Allocator, fields: []const Field, out: *std.ArrayList(u8)) Allocator.Error!usize {
        // Widest fields first, so each is aligned once the first is.
        var order: [32]Field = undefined;
        std.debug.assert(fields.len <= order.len);
        @memcpy(order[0..fields.len], fields);
        std.mem.sort(Field, order[0..fields.len], {}, struct {
            fn wider(_: void, x: Field, y: Field) bool {
                return x.value.size() > y.value.size();
            }
        }.wider);
        const sorted = order[0..fields.len];
        var slots: u16 = 0;
        for (fields) |f| slots = @max(slots, f.slot + 1);
        const has8 = for (sorted) |f| {
            if (f.value.size() == 8) break true;
        } else false;

        // The vtable: its size, the table's, then each slot's offset.
        try pad(gpa, out, 2);
        const vtable_pos = out.items.len;
        const vtable_len = 4 + 2 * @as(usize, slots);
        try out.appendNTimes(gpa, 0, vtable_len);
        // The table: 4-aligned, and its 8-byte fields (right after the
        // soffset) 8-aligned.
        try pad(gpa, out, 4);
        if (has8 and (out.items.len + 4) % 8 != 0) try out.appendNTimes(gpa, 0, 4);
        const table_pos = out.items.len;
        try appendInt(gpa, out, i32, @intCast(table_pos - vtable_pos));
        var refs: [32]struct { at: usize, ref: Ref } = undefined;
        var nrefs: usize = 0;
        for (sorted) |f| {
            const at = out.items.len;
            std.mem.writeInt(u16, out.items[vtable_pos + 4 + 2 * @as(usize, f.slot) ..][0..2], @intCast(at - table_pos), .little);
            switch (f.value) {
                .u8 => |x| try out.append(gpa, x),
                .bool => |x| try out.append(gpa, @intFromBool(x)),
                .i16 => |x| try appendInt(gpa, out, i16, x),
                .i32 => |x| try appendInt(gpa, out, i32, x),
                .i64 => |x| try appendInt(gpa, out, i64, x),
                .ref => |r| {
                    refs[nrefs] = .{ .at = at, .ref = r };
                    nrefs += 1;
                    try out.appendNTimes(gpa, 0, 4);
                },
            }
        }
        std.mem.writeInt(u16, out.items[vtable_pos..][0..2], @intCast(vtable_len), .little);
        std.mem.writeInt(u16, out.items[vtable_pos + 2 ..][0..2], @intCast(out.items.len - table_pos), .little);
        for (refs[0..nrefs]) |r| {
            const child_pos = try b.write(gpa, r.ref, out);
            std.mem.writeInt(u32, out.items[r.at..][0..4], @intCast(child_pos - r.at), .little);
        }
        return table_pos;
    }
};

fn pad(gpa: Allocator, out: *std.ArrayList(u8), alignment: usize) Allocator.Error!void {
    while (out.items.len % alignment != 0) try out.append(gpa, 0);
}

fn appendInt(gpa: Allocator, out: *std.ArrayList(u8), comptime T: type, x: T) Allocator.Error!void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, x, .little);
    try out.appendSlice(gpa, &buf);
}

// A reader for the tests: what the verifier checks, and the values back.
const Table = struct {
    buf: []const u8,
    pos: usize,

    fn root(buf: []const u8) Table {
        return .{ .buf = buf, .pos = std.mem.readInt(u32, buf[0..4], .little) };
    }

    fn fieldPos(t: Table, slot: u16) ?usize {
        const vt = t.pos - @as(usize, @intCast(std.mem.readInt(i32, t.buf[t.pos..][0..4], .little)));
        const vlen = std.mem.readInt(u16, t.buf[vt..][0..2], .little);
        if (4 + 2 * @as(usize, slot) >= vlen) return null;
        const off = std.mem.readInt(u16, t.buf[vt + 4 + 2 * @as(usize, slot) ..][0..2], .little);
        return if (off == 0) null else t.pos + off;
    }

    fn int(t: Table, comptime T: type, slot: u16) T {
        const p = t.fieldPos(slot).?;
        std.debug.assert(p % @sizeOf(T) == 0);
        return std.mem.readInt(T, t.buf[p..][0..@sizeOf(T)], .little);
    }

    fn target(t: Table, slot: u16) usize {
        const p = t.fieldPos(slot).?;
        return p + std.mem.readInt(u32, t.buf[p..][0..4], .little);
    }

    fn table(t: Table, slot: u16) Table {
        return .{ .buf = t.buf, .pos = t.target(slot) };
    }

    fn str(t: Table, slot: u16) []const u8 {
        const p = t.target(slot);
        const n = std.mem.readInt(u32, t.buf[p..][0..4], .little);
        std.debug.assert(t.buf[p + 4 + n] == 0);
        return t.buf[p + 4 ..][0..n];
    }
};

test "tables, strings and vectors read back, aligned" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var b: Builder = .init(arena.allocator());
    const name = try b.string("amount");
    const Pair = extern struct { a: i64, b: i64 };
    const pairs = try b.structs(Pair, &.{ .{ .a = 1, .b = 2 }, .{ .a = 3, .b = 4 } });
    const child = try b.table(&.{.{ .slot = 0, .value = .{ .i32 = 128 } }});
    const kids = try b.vector(&.{ child, child });
    const root = try b.table(&.{
        .{ .slot = 0, .value = .{ .ref = name } },
        .{ .slot = 1, .value = .{ .bool = true } },
        .{ .slot = 2, .value = .{ .i64 = -5 } },
        .{ .slot = 4, .value = .{ .ref = pairs } },
        .{ .slot = 5, .value = .{ .ref = kids } },
        .{ .slot = 6, .value = .{ .i16 = 4 } },
    });
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try b.finish(std.testing.allocator, root, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len % 8);
    const t = Table.root(out.items);
    try std.testing.expectEqualStrings("amount", t.str(0));
    try std.testing.expectEqual(@as(u8, 1), out.items[t.fieldPos(1).?]);
    try std.testing.expectEqual(@as(i64, -5), t.int(i64, 2));
    try std.testing.expectEqual(@as(?usize, null), t.fieldPos(3));
    try std.testing.expectEqual(@as(i16, 4), t.int(i16, 6));
    const v = t.target(4);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, out.items[v..][0..4], .little));
    try std.testing.expectEqual(@as(usize, 0), (v + 4) % 8);
    try std.testing.expectEqual(@as(i64, 3), std.mem.readInt(i64, out.items[v + 4 + 16 ..][0..8], .little));
    const kv = t.target(5);
    const first: Table = .{ .buf = out.items, .pos = kv + 4 + std.mem.readInt(u32, out.items[kv + 4 ..][0..4], .little) };
    try std.testing.expectEqual(@as(i32, 128), first.int(i32, 0));
}
