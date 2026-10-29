//! Records and fields as the parsers emit them: byte ranges into the input
//! with flags, never copies. A field's value is materialized only when
//! something needs it, and only a field with an escape in it is copied.

const std = @import("std");
const Dialect = @import("dialect.zig").Dialect;

/// One field: where its content is in the input, 16 bytes.
pub const Field = struct {
    /// Offset of the content, inside the quotes for a quoted field.
    start: u64,
    /// Length of the content, escapes not yet undone.
    len: u32,
    flags: Flags = .{},

    pub const Flags = packed struct(u32) {
        quoted: bool = false,
        /// The content holds an escaped quote or backslash to undo.
        needs_unescape: bool = false,
        _: u30 = 0,
    };

    pub fn raw(f: Field, input: []const u8) []const u8 {
        return input[@intCast(f.start)..][0..f.len];
    }

    /// The field's value: its bytes when there is nothing to undo, and
    /// otherwise the bytes with their escapes undone, written into scratch,
    /// which must hold `f.len` bytes.
    pub fn value(f: Field, input: []const u8, d: Dialect, scratch: []u8) []const u8 {
        const bytes = f.raw(input);
        if (!f.flags.needs_unescape) return bytes;
        return unescape(bytes, d, scratch);
    }
};

comptime {
    std.debug.assert(@sizeOf(Field) == 16);
}

/// Why a record is rejected before any column sees it.
pub const Problem = enum {
    /// A quoted field still open at the end of the input.
    unterminated_quote,
    /// Something other than a delimiter or line break after a closing quote.
    bad_quote,
    /// A field longer than the parser takes (4 GiB by default).
    field_too_long,
};

/// One record: its byte range, where it starts in the source, and what
/// was wrong or unusual about it. The fields are the parser's to hand out.
pub const Record = struct {
    /// Offset of the record's first byte.
    start: u64,
    /// Offset just past its line break, or the end of the input.
    end: u64,
    /// The source line it starts on, from 1, counting line breaks inside
    /// quoted fields too, the way an editor numbers them.
    line: u64,
    problem: ?Problem = null,
    /// Quote characters inside unquoted fields: data, and a warning.
    stray_quotes: u32 = 0,
    /// It ended in a line break other than the dialect's.
    foreign_newline: bool = false,
};

/// The bytes with their escapes undone: a doubled quote to one, and under
/// backslash escaping a backslash and the byte after it to that byte (a
/// backslash dialect takes doubled quotes too). out must hold bytes.len.
pub fn unescape(bytes: []const u8, d: Dialect, out: []u8) []u8 {
    const q = d.quote orelse {
        @memcpy(out[0..bytes.len], bytes);
        return out[0..bytes.len];
    };
    var n: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];
        if (d.escape == .backslash and c == '\\' and i + 1 < bytes.len) {
            i += 1;
        } else if (c == q and i + 1 < bytes.len and bytes[i + 1] == q) {
            i += 1;
        }
        out[n] = bytes[i];
        n += 1;
    }
    return out[0..n];
}

test "unescape" {
    var buf: [32]u8 = undefined;
    var d = Dialect.rfc4180;
    try std.testing.expectEqualStrings("a\"b", unescape("a\"\"b", d, &buf));
    try std.testing.expectEqualStrings("\"", unescape("\"\"", d, &buf));
    try std.testing.expectEqualStrings("a\\\"b", unescape("a\\\"\"b", d, &buf));
    d.escape = .backslash;
    try std.testing.expectEqualStrings("a\"b\\c", unescape("a\\\"b\\\\c", d, &buf));
    try std.testing.expectEqualStrings("a\"b", unescape("a\"\"b", d, &buf));
    d.quote = '\'';
    try std.testing.expectEqualStrings("it's", unescape("it\\'s", d, &buf));
}

test "value copies only what needs it" {
    const input = "x\"a\"\"b\"";
    var scratch: [8]u8 = undefined;
    const plain: Field = .{ .start = 0, .len = 1 };
    try std.testing.expectEqual(@as([*]const u8, input.ptr), plain.value(input, .rfc4180, &scratch).ptr);
    const escaped: Field = .{ .start = 2, .len = 4, .flags = .{ .quoted = true, .needs_unescape = true } };
    try std.testing.expectEqualStrings("a\"b", escaped.value(input, .rfc4180, &scratch));
}
