//! The C entry points' fuzz target: libthresh called through
//! include/thresh.h, as a C or Python host calls it, on any bytes and any
//! options. Whatever the file and the options, each call returns a status
//! and keeps the header's word on it: THRESH_OK with its JSON (valid JSON,
//! valid UTF-8) or its reader, anything else with nothing out and a
//! sentence in the handle. A panic here is a host process brought down.
//!
//! Its input, as the target's Smith reads it: the file's bytes, a schema's
//! text, then the choices, eight bytes each as fuzz_test.seed writes them
//! (optionsOf and capiOne say which is which).

const std = @import("std");
const h = @import("thresh_h");
const seed = @import("fuzz_test.zig").seed;

comptime {
    // The exports the header's declarations link to.
    _ = @import("capi.zig");
}

const Allocator = std.mem.Allocator;
const Smith = std.testing.Smith;
const testing = std.testing;

const max_input = 2048;

/// Where each input is written, in a directory the test makes.
const Context = struct {
    dir: std.Io.Dir,
    path: [:0]const u8,
};

/// The options a byte of choices picks for each field, past zero (which
/// leaves it to thresh) to values each refused by name.
fn optionsOf(smith: *Smith, cancel: *const volatile u8) h.thresh_options {
    var o = std.mem.zeroes(h.thresh_options);
    o.size = @sizeOf(h.thresh_options);
    const flags = smith.value(u8);
    o.flags = flags & 0x7f;
    // A byte: 0 sniffs, 1 is none, any other is the quote.
    const quote = smith.value(u8);
    o.quote = if (quote == 1) h.THRESH_QUOTE_NONE else quote;
    o.delimiter = smith.value(u8);
    o.comment = smith.value(u8);
    // Each 0 to 3: 3 is refused, but for newline's CR.
    const kinds = smith.value(u8);
    o.escape = kinds & 3;
    o.newline = (kinds >> 2) & 3;
    o.header = (kinds >> 4) & 3;
    o.ragged = kinds >> 6;
    const sizes = smith.value(u8);
    o.encoding = ([_]?[*:0]const u8{ null, "utf8", "latin1", "cp1252", "utf16", null, "cp1252", "latin1" })[sizes & 7];
    o.sample_bytes = ([_]u64{ 0, 1, 64, std.math.maxInt(u64) })[(sizes >> 3) & 3];
    o.sample_rows = ([_]u64{ 0, 1, 3, std.math.maxInt(u64) })[(sizes >> 5) & 3];
    o.jobs = sizes >> 7;
    const rest = smith.value(u8);
    o.threshold = ([_]f64{ 0, 0.5, 1, std.math.nan(f64) })[rest & 3];
    const nulls = [_][]const ?[*:0]const u8{ &.{}, &.{""}, &.{ "NA", "-" }, &.{null} };
    const n = nulls[(rest >> 2) & 3];
    o.nulls = @ptrCast(@constCast(n.ptr));
    o.nulls_len = n.len;
    // A cancel already set: every call stops, and says it was interrupted.
    if (flags & 0x80 != 0 and rest & 0x10 != 0) o.cancel = cancel;
    return o;
}

/// Until t75, JSON may carry a file's bytes that are not UTF-8: checked
/// with every byte past ASCII read as 'x'.
const strict_utf8 = false;

/// s as the checks read it: as it is, or under strict_utf8 false, with
/// every byte past ASCII an 'x'.
fn checkable(gpa: Allocator, s: []const u8) ![]u8 {
    const out = try gpa.dupe(u8, s);
    if (!strict_utf8) for (out) |*c| if (c.* >= 0x80) {
        c.* = 'x';
    };
    return out;
}

/// A status as the header promises it: a known one, and out what it says.
fn expectKept(t: ?*h.thresh, status: h.thresh_status, json: [*c]u8) !void {
    if (status > h.THRESH_ERROR_INTERRUPTED) return error.UnknownStatus;
    if (status == h.THRESH_OK) {
        const s = std.mem.span(json orelse return error.OkWithoutJson);
        const c = try checkable(testing.allocator, s);
        defer testing.allocator.free(c);
        if (!try std.json.validate(testing.allocator, c)) {
            std.debug.print("not JSON: {f}\n", .{std.zig.fmtString(s)});
            return error.NotJson;
        }
        return;
    }
    if (json != null) return error.JsonWithError;
    const said = std.mem.span(h.thresh_error(t));
    if (said.len == 0) return error.ErrorWithoutSentence;
    // The file is there and small: no read fails partway, so whatever
    // thresh makes of it is a report, or the call's own fault.
    if (status == h.THRESH_ERROR_IO) {
        std.debug.print("THRESH_ERROR_IO: {s}\n", .{said});
        return error.IoStatus;
    }
}

/// One input's calls: the handle, the file and the options.
const Call = struct {
    t: *h.thresh,
    path: [:0]const u8,
    o: *const h.thresh_options,

    /// A call's status and JSON as the header promises them, the JSON
    /// freed.
    fn expect(c: Call, status: h.thresh_status, json: [*c]u8) !void {
        defer if (status == h.THRESH_OK) h.thresh_string_free(json);
        try expectKept(c.t, status, json);
    }
};

/// The schema inference gives the file, as its own JSON, or null.
fn inferred(gpa: Allocator, c: Call) !?[:0]u8 {
    var json: [*c]u8 = null;
    const paths = [_][*c]const u8{c.path.ptr};
    const status = h.thresh_infer(c.t, &paths, paths.len, c.o, &json);
    defer if (status == h.THRESH_OK) h.thresh_string_free(json);
    try expectKept(c.t, status, json);
    if (status != h.THRESH_OK) return null;
    const text = try checkable(gpa, std.mem.span(json));
    defer gpa.free(text);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    defer parsed.deinit();
    const schema = parsed.value.object.get("schema") orelse return null;
    if (schema == .null) return null;
    const s = try std.json.Stringify.valueAlloc(gpa, schema, .{});
    defer gpa.free(s);
    return try gpa.dupeSentinel(u8, s, 0);
}

/// The schema to hold the file to, by a choice: inferred from it, the
/// text as inline columns, or the text as schema JSON.
fn schemaFor(gpa: Allocator, c: Call, text: []const u8, choice: u8) !?[:0]u8 {
    switch (choice & 3) {
        0 => return inferred(gpa, c),
        1 => {
            const spec = try gpa.dupeSentinel(u8, text, 0);
            defer gpa.free(spec);
            var json: [*c]u8 = null;
            const status = h.thresh_columns(c.t, spec, &json);
            defer if (status == h.THRESH_OK) h.thresh_string_free(json);
            try expectKept(c.t, status, json);
            if (status != h.THRESH_OK) return null;
            return try gpa.dupeSentinel(u8, std.mem.span(json), 0);
        },
        else => return try gpa.dupeSentinel(u8, text, 0),
    }
}

/// Every batch of a stream, then its end or its error, released.
fn drain(s: *h.struct_ArrowArrayStream) !void {
    defer s.release.?(s);
    var schema: h.struct_ArrowSchema = undefined;
    if (s.get_schema.?(s, &schema) != 0) return expectLastError(s);
    schema.release.?(&schema);
    while (true) {
        var a: h.struct_ArrowArray = undefined;
        if (s.get_next.?(s, &a) != 0) return expectLastError(s);
        const release = a.release orelse return;
        release(&a);
    }
}

fn expectLastError(s: *h.struct_ArrowArrayStream) !void {
    const e = s.get_last_error.?(s) orelse return error.StreamFailedSilently;
    if (std.mem.span(e).len == 0) return error.StreamFailedSilently;
}

/// thresh_read: a reader, its streams drained, or no reader and its JSON.
fn readAll(c: Call, schema: [:0]const u8, choice: u8) !void {
    const want: u32 = 1 + choice % 3;
    var reader: ?*h.thresh_reader = null;
    var json: [*c]u8 = null;
    const status = h.thresh_read(c.t, c.path, schema.ptr, c.o, want, &reader, &json);
    const r = reader orelse {
        if (status == h.THRESH_OK and json == null) return error.OkWithoutReaderOrJson;
        return c.expect(status, json);
    };
    defer h.thresh_reader_free(r);
    if (status != h.THRESH_OK) return error.ReaderWithError;
    if (json != null) return error.ReaderAndJson;
    // Each stream in an order a choice picks, then the report.
    const rows_first = choice & 4 == 0;
    try takeStream(r, rows_first, want, choice);
    try takeStream(r, !rows_first, want, choice);
    try expectReport(r);
}

/// The rows or the rejects: refused when not wanted, else drained, with a
/// report midway when a choice says.
fn takeStream(r: *h.thresh_reader, rows: bool, want: u32, choice: u8) !void {
    var out: h.struct_ArrowArrayStream = undefined;
    const taken = if (rows) h.thresh_reader_rows(r, &out) else h.thresh_reader_rejects(r, &out);
    const wanted = want & @as(u32, if (rows) h.THRESH_WANT_ROWS else h.THRESH_WANT_REJECTS) != 0;
    if (!wanted) {
        if (taken != h.THRESH_ERROR_ARGUMENT) return error.UnwantedStreamTaken;
        return;
    }
    if (taken != h.THRESH_OK) return error.WantedStreamRefused;
    if (choice & 8 != 0) try expectReport(r);
    try drain(&out);
}

/// thresh_reader_report as the header promises it.
fn expectReport(r: *h.thresh_reader) !void {
    var report: [*c]u8 = null;
    const s = h.thresh_reader_report(r, &report);
    defer if (s == h.THRESH_OK) h.thresh_string_free(report);
    if (s > h.THRESH_ERROR_INTERRUPTED or (s == h.THRESH_OK) != (report != null)) return error.ReportBroken;
    if (s != h.THRESH_OK and std.mem.span(h.thresh_reader_error(r)).len == 0) return error.ErrorWithoutSentence;
}

fn capiOne(ctx: *const Context, smith: *Smith) anyerror!void {
    const gpa = testing.allocator;
    var buf: [max_input]u8 = undefined;
    const bytes = buf[0..smith.slice(&buf)];
    var text_buf: [512]u8 = undefined;
    const text = text_buf[0..smith.slice(&text_buf)];
    var cancel: u8 = 1;
    const o = optionsOf(smith, &cancel);
    const choice = smith.value(u8);
    try ctx.dir.writeFile(testing.io, .{ .sub_path = "f.csv", .data = bytes });

    const t = h.thresh_new() orelse return error.OutOfMemory;
    defer h.thresh_free(t);
    const c: Call = .{ .t = t, .path = ctx.path, .o = &o };
    var json: [*c]u8 = null;
    var status = h.thresh_sniff(t, c.path, c.o, &json);
    try c.expect(status, json);
    const schema = try schemaFor(gpa, c, text, choice);
    defer if (schema) |s| gpa.free(s);
    const schema_c: [*c]const u8 = if (schema) |s| s.ptr else null;
    // describe infers a schema when given none.
    status = h.thresh_describe(t, c.path, schema_c, c.o, &json);
    try c.expect(status, json);
    const s = schema orelse return;
    status = h.thresh_validate(t, c.path, s.ptr, c.o, &json);
    try c.expect(status, json);
    try readAll(c, s, choice >> 2);
}

const files = [_][]const u8{
    "lug_id,cultivar,lug_kg,picked_on\n1,Starfall,17.50,2026-09-14\n2,Quillon,18.00,2026-09-14\nx,Quillon,18.00,2026-09-15\n4,Brookwood,,15/09/2026\n",
    "id;when;at;ok;score\n1;2026-10-01T08:00:00Z;08:00;yes;1.5e3\n2;2026-10-02 09:30;9:30;no;-0.25\n3;;;maybe;NaN\n",
    "a|b\n\"x\"\"y\"|1\n\"un\nclosed|2\n",
    "\xff\xfei\x00d\x00\n\x001\x00\n\x00",
    "\xef\xbb\xbfcaf\xe9,l\x92\x9cuvre\n1,2\n",
    "k\tv\n1\t99999999999999999999.123456789012345678901234567\n2\t-0000000000000000000000001\n",
    "",
    "\n\n\r\n",
    "#c\nx,y,z\n1,2\n3,4,5,6\n",
};

const texts = [_][]const u8{
    "",
    "lug_id:int64,cultivar:string,lug_kg:decimal(5,2),picked_on:date",
    "id:int64,when:timestamp,at:time,ok:bool,score:float64",
    "{\"columns\":[{\"name\":\"a\",\"type\":\"enum\",\"values\":[\"x\\\"y\",\"z\"]},{\"name\":\"b\",\"type\":\"decimal\",\"precision\":38,\"scale\":38}]}",
    "{\"format_version\":1,\"columns\":[{\"name\":\"k\",\"type\":\"string\",\"max_len\":3,\"utf8\":\"binary\"},{\"name\":\"v\",\"type\":\"date\",\"format\":\"%d/%m/%Y\"}],\"match\":\"position\",\"threshold\":0.5}",
};

fn seeds(arena: Allocator) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (files) |f| for (texts, 0..) |s, i| {
        // Inferred, inline and JSON schemas, each read wanting rows,
        // rejects and both.
        const mode: u8 = if (i == 0) 0 else if (s[0] == '{') 2 else 1;
        for ([_]u8{ 0, 0x08, 0x20 }, 0..) |flags, want| {
            try out.append(arena, try seed(arena, &.{ f, s }, &.{ flags, 0, 0, 0, 0, 0, 0, mode | @as(u8, @intCast(want)) << 2 }));
        }
    };
    // Each status but THRESH_OK, and what the fuzzer found: each as the
    // file, the text and the choices.
    for (edges ++ found) |f| try out.append(arena, try seed(arena, &.{ f.file, f.text }, f.choices));
    return out.items;
}

const Seed = struct { file: []const u8, text: []const u8, choices: []const u8 };

/// Inputs that end in each status but THRESH_OK, so a replay holds them
/// to the header too. The choices: flags, quote, delimiter, comment, the
/// kinds, the sizes, the rest, and the choice capiOne makes.
const edges = [_]Seed{
    // An escape of 3, an encoding not taken, a NaN threshold, a NULL in
    // nulls: THRESH_ERROR_ARGUMENT from every call that takes options.
    .{ .file = files[0], .text = texts[1], .choices = &.{ 0, 0, 0, 0, 3, 0, 0, 1 } },
    .{ .file = files[0], .text = texts[1], .choices = &.{ 0, 0, 0, 0, 0, 4, 0, 1 } },
    .{ .file = files[0], .text = texts[1], .choices = &.{ 0x10, 0, 0, 0, 0, 0, 3, 1 } },
    .{ .file = files[0], .text = texts[1], .choices = &.{ 0, 0, 0, 0, 0, 0, 0x0c, 1 } },
    // Cancelled before the call: THRESH_ERROR_INTERRUPTED.
    .{ .file = files[0], .text = texts[1], .choices = &.{ 0x80, 0, 0, 0, 0, 0, 0x10, 0x09 } },
    // Inline columns refused, and a JSON schema with none:
    // THRESH_ERROR_SCHEMA.
    .{ .file = files[0], .text = "id:int65", .choices = &.{ 0, 0, 0, 0, 0, 0, 0, 1 } },
    .{ .file = files[0], .text = "{\"columns\":[]}", .choices = &.{ 0, 0, 0, 0, 0, 0, 0, 2 } },
};

/// Inputs the fuzzer failed on, kept as seeds once fixed.
const found = [_]Seed{
    // A byte order mark longer than sample_bytes: sniff sliced past its
    // sample's end.
    .{ .file = "\xef\xbb\xbfcaf\xe9,l\x92\x9cuvre\n1,2\n", .text = "lug_id:int64", .choices = &.{ 0, 0, 0, 0, 0, 0x2a, 0, 0 } },
    // Forty-six digits in a decimal(38, 38): decimal.parse overflowed its
    // i128 before it checked the precision.
    .{ .file = files[5], .text = texts[3], .choices = &.{ 0x20, 0xb7, 0, '_', 0x20, 0, 0, 0x0a } },
};

test "fuzz: the C calls keep the header's word on any bytes and options" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ctx: Context = .{
        .dir = tmp.dir,
        .path = try std.fmt.allocPrintSentinel(arena.allocator(), ".zig-cache/tmp/{s}/f.csv", .{tmp.sub_path}, 0),
    };
    try testing.fuzz(&ctx, capiOne, .{ .corpus = try seeds(arena.allocator()) });
}
