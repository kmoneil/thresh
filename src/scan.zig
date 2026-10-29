//! Stage 1: the structural index. Each 64-byte block becomes bitmasks, one
//! bit a byte, from which come the offsets of every delimiter and line
//! break outside quotes, and a mask of the bytes stage 2 has to look at.
//!
//! This is the Langdale and Lemire design ("Parsing Gigabytes of CSV per
//! Second"): the in-quote mask is the prefix XOR of the quote mask, so a
//! quote toggles it and a doubled quote toggles it twice. Under backslash
//! escaping, a quote after an odd run of backslashes does not toggle
//! (simdjson's escape scanner). A quote anywhere toggles, which is not the
//! reference parser's rule (only a field's first byte opens a quote), so
//! the index is only right for records whose quotes are well formed;
//! stage 2 checks each record with `special` and hands any other to the
//! reference parser.

const std = @import("std");
const Dialect = @import("dialect.zig").Dialect;

pub const block = 64;
const Block = @Vector(block, u8);

/// What one block leaves for the next.
pub const Carry = struct {
    /// All ones when the block ended inside quotes.
    in_quote: u64 = 0,
    /// 1 when the block's last byte is a backslash that escapes the next.
    escape_next: u64 = 0,
};

/// What `index` found in data.
pub const Index = struct {
    /// Bytes of data indexed, a multiple of 64 unless it is all of data.
    len: usize,
    /// Entries written to positions.
    count: usize,
};

/// Indexes data from its start: the offset of every delimiter, LF and CR
/// outside quotes into positions, and into special (a u64 per 64 bytes) a
/// bit for every quote byte, and for every LF, CR and (under backslash
/// escaping) backslash inside quotes. Stops early, at a block boundary,
/// when positions could not take another block's worth.
pub fn index(data: []const u8, d: Dialect, carry: *Carry, positions: []u32, special: []u64) Index {
    std.debug.assert(data.len <= std.math.maxInt(u32));
    const delim: Block = @splat(d.delimiter);
    const lf: Block = @splat('\n');
    const cr: Block = @splat('\r');
    const quote: Block = @splat(d.quote orelse 0);
    const backslash: Block = @splat('\\');
    const quoting = d.quote != null;
    const escaping = quoting and d.escape == .backslash;

    var count: usize = 0;
    var off: usize = 0;
    while (off < data.len) : (off += block) {
        if (positions.len - count < block) break;
        const n = @min(block, data.len - off);
        const v: Block = if (n == block) data[off..][0..block].* else tail: {
            var buf: [block]u8 = @splat(0);
            @memcpy(buf[0..n], data[off..][0..n]);
            break :tail buf;
        };
        const valid: u64 = if (n == block) ~@as(u64, 0) else (@as(u64, 1) << @intCast(n)) - 1;

        const breaks = (bits(v == lf) | bits(v == cr)) & valid;
        var q: u64 = 0;
        var in_quote: u64 = 0;
        var inner_bs: u64 = 0;
        if (quoting) {
            q = bits(v == quote) & valid;
            var toggles = q;
            if (escaping) {
                const bs = bits(v == backslash) & valid;
                toggles &= ~escaped(bs, &carry.escape_next);
                inner_bs = bs;
            }
            in_quote = prefixXor(toggles) ^ carry.in_quote;
            carry.in_quote = @bitCast(@as(i64, @bitCast(in_quote)) >> 63);
        }
        special[off / block] = q | ((breaks | inner_bs) & in_quote);

        var structural = ((bits(v == delim) & valid) | breaks) & ~in_quote;
        while (structural != 0) : (structural &= structural - 1) {
            positions[count] = @intCast(off + @ctz(structural));
            count += 1;
        }
    }
    return .{ .len = @min(off, data.len), .count = count };
}

/// The vector's lanes as a mask, lane 0 in bit 0 (pinned by a test, since
/// 0.17 changed what @bitCast does with vectors).
inline fn bits(m: @Vector(block, bool)) u64 {
    return @bitCast(m);
}

/// Bit i set when an odd number of set bits are at or below i: the bytes
/// from an opening quote up to, not including, its closing one.
pub fn prefixXor(x0: u64) u64 {
    var x = x0;
    x ^= x << 1;
    x ^= x << 2;
    x ^= x << 4;
    x ^= x << 8;
    x ^= x << 16;
    x ^= x << 32;
    return x;
}

/// The bytes a backslash escapes: each one right after a backslash that is
/// not itself escaped. simdjson's json_escape_scanner, with the carry for
/// a block whose last byte escapes the next block's first.
pub fn escaped(backslash: u64, escape_next: *u64) u64 {
    const odd_bits: u64 = 0xAAAA_AAAA_AAAA_AAAA;
    if (backslash == 0) {
        const e = escape_next.*;
        escape_next.* = 0;
        return e;
    }
    const potential = backslash & ~escape_next.*;
    const maybe_escaped = potential << 1;
    const codes = ((maybe_escaped | odd_bits) -% potential) ^ odd_bits;
    const result = codes ^ (backslash | escape_next.*);
    const escape = codes & backslash;
    escape_next.* = escape >> 63;
    return result;
}

const testing = std.testing;

test "a @Vector(64, bool) lands lane 0 in bit 0" {
    var bytes: [block]u8 = @splat('a');
    bytes[0] = ',';
    bytes[5] = ',';
    bytes[63] = ',';
    const v: Block = bytes;
    try testing.expectEqual(@as(u64, 1 | 1 << 5 | 1 << 63), bits(v == @as(Block, @splat(','))));
}

test "prefixXor marks from each opening quote to before its close" {
    try testing.expectEqual(@as(u64, 0b0111), prefixXor(0b1001));
    try testing.expectEqual(@as(u64, 0b0010_0011), prefixXor(0b0110_0101));
    try testing.expectEqual(@as(u64, 0b11) | ~@as(u64, 0) << 6, prefixXor(0b0100_0101));
    try testing.expectEqual(~@as(u64, 0), prefixXor(1));
}

/// The escaped bytes, one at a time, for checking escaped against.
fn escapedScalar(backslash: u64, escape_next: *u64) u64 {
    var out: u64 = 0;
    var next = escape_next.* != 0;
    for (0..64) |i| {
        const is_bs = backslash >> @intCast(i) & 1 != 0;
        if (next) {
            out |= @as(u64, 1) << @intCast(i);
            next = false;
        } else if (is_bs) {
            next = true;
        }
    }
    escape_next.* = @intFromBool(next);
    return out;
}

test "escaped agrees with a byte-at-a-time walk, carry and all" {
    var rng: std.Random.DefaultPrng = .init(0x7468_7265_7368);
    const r = rng.random();
    var fast: u64 = 0;
    var slow: u64 = 0;
    for (0..100_000) |i| {
        // Long runs of backslashes as well as scattered ones.
        const m = switch (i % 4) {
            0 => r.int(u64),
            1 => r.int(u64) & r.int(u64) & r.int(u64),
            2 => r.int(u64) | r.int(u64),
            else => ~@as(u64, 0) >> @intCast(r.uintLessThan(u7, 64)),
        };
        try testing.expectEqual(escapedScalar(m, &slow), escaped(m, &fast));
        try testing.expectEqual(slow, fast);
    }
}

test "index finds what is outside quotes, across blocks" {
    var data: [150]u8 = @splat('x');
    data[3] = ',';
    data[10] = '"';
    data[70] = ','; // inside quotes
    data[71] = '\n'; // inside quotes
    data[100] = '"';
    data[101] = ',';
    data[149] = '\n';
    var positions: [256]u32 = undefined;
    var special: [3]u64 = undefined;
    var carry: Carry = .{};
    const got = index(&data, .rfc4180, &carry, &positions, &special);
    try testing.expectEqual(@as(usize, 150), got.len);
    try testing.expectEqualSlices(u32, &.{ 3, 101, 149 }, positions[0..got.count]);
    try testing.expectEqual(@as(u64, 1) << 10, special[0]);
    try testing.expectEqual(@as(u64, 1) << (71 - 64) | @as(u64, 1) << (100 - 64), special[1]);
    try testing.expectEqual(@as(u64, 0), special[2]);
    try testing.expectEqual(@as(u64, 0), carry.in_quote);
}

test "index skips escaped quotes under backslash escaping" {
    const data = "\"a\\\",b\",c\\\\\"d,e\"\n";
    var d = Dialect.rfc4180;
    d.escape = .backslash;
    var positions: [64]u32 = undefined;
    var special: [1]u64 = undefined;
    var carry: Carry = .{};
    const got = index(data, d, &carry, &positions, &special);
    // "a\",b" is one field; then c\\ is unquoted data whose quote opens
    // "d,e": the index toggles there, and stage 2 sends the record on.
    try testing.expectEqualSlices(u32, &.{ 7, 16 }, positions[0..got.count]);
}

test "index stops at a block boundary when positions would overflow" {
    const data: [200]u8 = @splat(',');
    var positions: [100]u32 = undefined;
    var special: [4]u64 = undefined;
    var carry: Carry = .{};
    const got = index(&data, .rfc4180, &carry, &positions, &special);
    try testing.expectEqual(@as(usize, 64), got.len);
    try testing.expectEqual(@as(usize, 64), got.count);
}
