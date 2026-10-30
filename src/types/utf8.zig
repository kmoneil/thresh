//! UTF-8 validity for string columns: a byte loop with an ASCII fast path,
//! since most text is ASCII and std's check is per code point.

const std = @import("std");

pub fn valid(v: []const u8) bool {
    var i: usize = 0;
    while (i + 8 <= v.len) : (i += 8) {
        const word = std.mem.readInt(u64, v[i..][0..8], .little);
        if (word & 0x8080_8080_8080_8080 != 0) break;
    }
    return std.unicode.utf8ValidateSlice(v[i..]);
}

test valid {
    try std.testing.expect(valid("plain ascii, long enough to take the fast path"));
    try std.testing.expect(valid("café crème, déjà vu"));
    try std.testing.expect(!valid("caf\xe9"));
    try std.testing.expect(!valid("0123456789abcdef\xff"));
    try std.testing.expect(!valid("\xed\xa0\x80")); // a surrogate
}
