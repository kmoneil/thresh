//! The C ABI over lib.zig, as include/thresh.h declares it: the root of
//! libthresh, static and shared. Each call converts its arguments, calls
//! lib, and returns JSON in the versioned formats (docs/REPORT.md) or
//! Arrow C streams; a status other than THRESH_OK leaves its sentence in
//! the handle. A test holds the header's layout to the structs here.
//!
//! The library owns what it reads with: an Io (std.Io.Threaded's
//! single-threaded one, which installs no signal handler in the host
//! process, and whose blocking calls are safe from several threads) and
//! libc's allocator, which is thread-safe, as what a call returns may be
//! freed or released on any thread.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const build_options = @import("build_options");
const lib = @import("lib.zig");
const arrow_c = @import("write/arrow_c.zig");
const report = @import("report.zig");
const types = @import("types.zig");
const Problem = @import("problem.zig").Problem;

var threaded: Io.Threaded = .init_single_threaded;
// Tests check that the library frees what it allocates.
const gpa = if (builtin.is_test) std.testing.allocator else std.heap.c_allocator;

fn env() lib.Env {
    return .{ .io = threaded.io(), .gpa = gpa };
}

const Status = enum(c_int) { ok = 0, argument = 1, schema = 2, io = 3, memory = 4, interrupted = 5 };

pub const quote_none: i32 = -1;
pub const want_rows: u32 = 1;
pub const want_rejects: u32 = 2;

pub const Flag = struct {
    pub const keep_empty: u32 = 1;
    pub const day_first: u32 = 2;
    pub const strict: u32 = 4;
    pub const no_mmap: u32 = 8;
    pub const threshold: u32 = 16;
    const all: u32 = 31;
};

/// thresh_options, as the header lays it out.
pub const Options = extern struct {
    size: usize,
    flags: u32,
    quote: i32,
    delimiter: u8,
    escape: u8,
    newline: u8,
    header: u8,
    comment: u8,
    ragged: u8,
    encoding: ?[*:0]const u8,
    nulls: ?[*]const ?[*:0]const u8,
    nulls_len: usize,
    sample_bytes: u64,
    sample_rows: u64,
    threshold: f64,
    jobs: u32,
    cancel: ?*const volatile u8,
};

/// A call's sentence, kept in its handle until the next call.
const Message = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,

    fn clear(m: *Message) void {
        m.len = 0;
        m.buf[0] = 0;
    }

    fn set(m: *Message, comptime fmt: []const u8, args: anytype) void {
        var w: Io.Writer = .fixed(m.buf[0 .. m.buf.len - 1]);
        w.print(fmt, args) catch {};
        m.len = w.buffered().len;
        m.buf[m.len] = 0;
    }

    fn ptr(m: *const Message) [*:0]const u8 {
        return @ptrCast(&m.buf);
    }
};

/// A call made wrongly: the message says how.
const Misuse = error{Misuse};

fn misuse(m: *Message, comptime fmt: []const u8, args: anytype) Misuse {
    m.set(fmt, args);
    return error.Misuse;
}

/// err as a status, its sentence in m unless the code that returned it
/// put one there.
fn statusOf(m: *Message, err: anyerror) c_int {
    const s: Status = switch (err) {
        error.Misuse => .argument,
        error.InvalidSchema => .schema,
        error.OutOfMemory => .memory,
        error.Interrupted => .interrupted,
        else => .io,
    };
    if (m.len == 0) m.set("{f}", .{Problem.of(err)});
    return @backingInt(s);
}

const Thresh = struct { message: Message = .{} };

const Reader = struct {
    message: Message = .{},
    stream: *lib.ArrowExport,
};

/// Runs f(m, args...) and makes what comes of it a status.
fn call(m: *Message, comptime f: anytype, args: anytype) c_int {
    m.clear();
    @call(.auto, f, .{m} ++ args) catch |err| return statusOf(m, err);
    return @backingInt(Status.ok);
}

fn spanOf(m: *Message, comptime what: []const u8, p: ?[*:0]const u8) Misuse![:0]const u8 {
    return std.mem.span(p orelse return misuse(m, what ++ " is NULL", .{}));
}

fn outOf(m: *Message, comptime what: []const u8, comptime T: type, p: ?*?T) Misuse!*?T {
    const out = p orelse return misuse(m, what ++ " is NULL", .{});
    out.* = null;
    return out;
}

/// What f writes, as a string the caller frees with thresh_string_free.
fn jsonOf(comptime f: anytype, args: anytype) Allocator.Error![*:0]u8 {
    var w: Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    // An allocating writer fails only when it cannot allocate.
    @call(.auto, f, .{&w.writer} ++ args) catch return error.OutOfMemory;
    return (try w.toOwnedSliceSentinel(0)).ptr;
}

/// The caller's options as lib's, with what they point at copied into a.
/// A struct from an older header has fewer bytes, read as zero; one from
/// a newer header may be longer, if it leaves the fields past this one's
/// zero.
fn optionsOf(m: *Message, a: Allocator, given: ?*const Options) !lib.Options {
    var c = std.mem.zeroes(Options);
    if (given) |g| {
        if (g.size < @sizeOf(usize)) return misuse(m, "thresh_options.size is {d}: set it to sizeof(thresh_options)", .{g.size});
        const bytes: [*]const u8 = @ptrCast(g);
        const n = @min(g.size, @sizeOf(Options));
        @memcpy(std.mem.asBytes(&c)[0..n], bytes[0..n]);
        if (g.size > @sizeOf(Options)) for (bytes[@sizeOf(Options)..g.size], @sizeOf(Options)..) |b, i| if (b != 0)
            return misuse(m, "thresh_options sets byte {d}, past the {d} that thresh {s} knows: it is from a newer thresh", .{ i, @sizeOf(Options), build_options.version });
    }
    var o: lib.Options = .{ .jobs = c.jobs };
    o.pins.delimiter = if (c.delimiter == 0) null else c.delimiter;
    o.pins.comment = if (c.comment == 0) null else c.comment;
    o.pins.quote = switch (c.quote) {
        0 => null,
        quote_none => .none,
        1...255 => .{ .byte = @intCast(c.quote) },
        else => return misuse(m, "thresh_options.quote is {d}: a byte, THRESH_QUOTE_NONE, or 0 to sniff it", .{c.quote}),
    };
    o.pins.escape = switch (c.escape) {
        0 => null,
        1 => .doubled,
        2 => .backslash,
        else => return misuse(m, "thresh_options.escape is {d}: THRESH_ESCAPE_DOUBLED, THRESH_ESCAPE_BACKSLASH, or 0 to sniff it", .{c.escape}),
    };
    o.pins.newline = switch (c.newline) {
        0 => null,
        1 => .lf,
        2 => .crlf,
        3 => .cr,
        else => return misuse(m, "thresh_options.newline is {d}: THRESH_NEWLINE_LF, _CRLF, _CR, or 0 to sniff it", .{c.newline}),
    };
    o.pins.header = switch (c.header) {
        0 => .auto,
        1 => .yes,
        2 => .no,
        else => return misuse(m, "thresh_options.header is {d}: THRESH_HEADER_YES, THRESH_HEADER_NO, or 0 to sniff it", .{c.header}),
    };
    o.ragged = switch (c.ragged) {
        0 => .reject,
        1 => .pad,
        2 => .truncate,
        else => return misuse(m, "thresh_options.ragged is {d}: THRESH_RAGGED_PAD, THRESH_RAGGED_TRUNCATE, or 0 to reject", .{c.ragged}),
    };
    if (c.flags & ~Flag.all != 0) return misuse(m, "thresh_options.flags is 0x{x}: 0x{x} is no flag of thresh {s}", .{ c.flags, c.flags & ~Flag.all, build_options.version });
    o.keep_empty = c.flags & Flag.keep_empty != 0;
    o.day_first = c.flags & Flag.day_first != 0;
    o.strict = c.flags & Flag.strict != 0;
    o.mmap = c.flags & Flag.no_mmap == 0;
    if (c.flags & Flag.threshold != 0) {
        if (!(c.threshold >= 0 and c.threshold <= 1)) return misuse(m, "thresh_options.threshold is {d}: a fraction from 0 to 1", .{c.threshold});
        o.threshold = c.threshold;
    }
    if (c.encoding) |e| o.encoding = std.meta.stringToEnum(types.Encoding, std.mem.span(e)) orelse
        return misuse(m, "thresh_options.encoding is \"{s}\": utf8, latin1 or cp1252", .{std.mem.span(e)});
    if (c.sample_bytes != 0) o.sample_bytes = std.math.cast(usize, c.sample_bytes) orelse
        return misuse(m, "thresh_options.sample_bytes is {d}: more than this machine can hold", .{c.sample_bytes});
    if (c.sample_rows != 0) o.sample_rows = c.sample_rows;
    if (c.nulls_len > 0) {
        const list = c.nulls orelse return misuse(m, "thresh_options.nulls is NULL, with nulls_len {d}", .{c.nulls_len});
        const nulls = try a.alloc([]const u8, c.nulls_len);
        for (nulls, list[0..c.nulls_len], 0..) |*n, p, i| n.* = try a.dupe(u8, std.mem.span(p orelse return misuse(m, "thresh_options.nulls[{d}] is NULL", .{i})));
        o.nulls = nulls;
    }
    // Set to 1 from another thread: a bool's byte.
    if (c.cancel) |p| o.cancel = @ptrCast(@volatileCast(p));
    return o;
}

fn schemaOf(m: *Message, text_c: ?[*:0]const u8) !lib.OwnedSchema {
    const text = try spanOf(m, "schema_json", text_c);
    var diag: lib.SchemaDiagnostic = .{};
    return lib.parseSchema(gpa, text, &diag) catch |e| {
        if (e == error.InvalidSchema) m.set("the schema: {s}", .{diag.message});
        return e;
    };
}

const version_z = std.fmt.comptimePrint("{s}", .{build_options.version});

export fn thresh_version() [*:0]const u8 {
    return version_z;
}

export fn thresh_new() ?*Thresh {
    const t = gpa.create(Thresh) catch return null;
    t.* = .{};
    t.message.clear();
    return t;
}

export fn thresh_free(t: ?*Thresh) void {
    if (t) |h| gpa.destroy(h);
}

export fn thresh_error(t: ?*const Thresh) [*:0]const u8 {
    const h = t orelse return "the handle is NULL";
    return h.message.ptr();
}

export fn thresh_string_free(s: ?[*:0]u8) void {
    const p = s orelse return;
    gpa.free(p[0 .. std.mem.len(p) + 1]);
}

export fn thresh_sniff(t: ?*Thresh, path: ?[*:0]const u8, o: ?*const Options, json: ?*?[*:0]u8) c_int {
    const h = t orelse return @backingInt(Status.argument);
    return call(&h.message, sniff, .{ path, o, json });
}

fn sniff(m: *Message, path_c: ?[*:0]const u8, o: ?*const Options, json: ?*?[*:0]u8) !void {
    const out = try outOf(m, "json", [*:0]u8, json);
    const path = try spanOf(m, "path", path_c);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const s = try lib.sniff(env(), path, try optionsOf(m, arena.allocator(), o));
    out.* = try jsonOf(report.writeSniffLine, .{ path, s.verdict, if (s.outcome.problem) |*p| p[0..1] else &[_]Problem{} });
}

export fn thresh_infer(t: ?*Thresh, paths: ?[*]const ?[*:0]const u8, paths_len: usize, o: ?*const Options, json: ?*?[*:0]u8) c_int {
    const h = t orelse return @backingInt(Status.argument);
    return call(&h.message, infer, .{ paths, paths_len, o, json });
}

fn infer(m: *Message, paths_c: ?[*]const ?[*:0]const u8, len: usize, o: ?*const Options, json: ?*?[*:0]u8) !void {
    const out = try outOf(m, "json", [*:0]u8, json);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const opts = try optionsOf(m, a, o);
    const paths = try a.alloc([]const u8, len);
    if (len > 0) {
        const list = paths_c orelse return misuse(m, "paths is NULL, with paths_len {d}", .{len});
        for (paths, list[0..len], 0..) |*p, c, i| p.* = std.mem.span(c orelse return misuse(m, "paths[{d}] is NULL", .{i}));
    }
    const files = try lib.inferFiles(env(), a, paths, opts);
    out.* = try jsonOf(lib.writeInferResult, .{ files, try lib.merge(a, files, opts) });
}

export fn thresh_columns(t: ?*Thresh, columns: ?[*:0]const u8, schema_json: ?*?[*:0]u8) c_int {
    const h = t orelse return @backingInt(Status.argument);
    return call(&h.message, inlineSchema, .{ columns, schema_json });
}

fn inlineSchema(m: *Message, columns: ?[*:0]const u8, json: ?*?[*:0]u8) !void {
    const out = try outOf(m, "schema_json", [*:0]u8, json);
    var diag: lib.SchemaDiagnostic = .{};
    var owned = lib.parseColumns(gpa, try spanOf(m, "columns", columns), &diag) catch |e| {
        if (e == error.InvalidSchema) m.set("the columns: {s}", .{diag.message});
        return e;
    };
    defer owned.deinit();
    out.* = try jsonOf(writeSchema, .{owned.schema});
}

fn writeSchema(w: *Io.Writer, s: lib.Schema) Io.Writer.Error!void {
    return lib.writeSchema(s, w);
}

export fn thresh_validate(t: ?*Thresh, path: ?[*:0]const u8, schema_json: ?[*:0]const u8, o: ?*const Options, json: ?*?[*:0]u8) c_int {
    const h = t orelse return @backingInt(Status.argument);
    return call(&h.message, validate, .{ path, schema_json, o, json });
}

fn validate(m: *Message, path_c: ?[*:0]const u8, schema_json: ?[*:0]const u8, o: ?*const Options, json: ?*?[*:0]u8) !void {
    const out = try outOf(m, "json", [*:0]u8, json);
    const path = try spanOf(m, "path", path_c);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const opts = try optionsOf(m, a, o);
    var owned = try schemaOf(m, schema_json);
    defer owned.deinit();
    const f = try lib.validate(env(), a, path, &owned.schema, opts, null);
    out.* = try jsonOf(report.writeFileReport, .{ f, true });
}

export fn thresh_read(t: ?*Thresh, path: ?[*:0]const u8, schema_json: ?[*:0]const u8, o: ?*const Options, want: u32, reader: ?*?*Reader, json: ?*?[*:0]u8) c_int {
    const h = t orelse return @backingInt(Status.argument);
    return call(&h.message, read, .{ path, schema_json, o, want, reader, json });
}

fn read(m: *Message, path_c: ?[*:0]const u8, schema_json: ?[*:0]const u8, o: ?*const Options, want: u32, reader: ?*?*Reader, json: ?*?[*:0]u8) !void {
    const out = try outOf(m, "json", [*:0]u8, json);
    const r_out = try outOf(m, "reader", *Reader, reader);
    const path = try spanOf(m, "path", path_c);
    if (want == 0 or want & ~(want_rows | want_rejects) != 0)
        return misuse(m, "want is {d}: THRESH_WANT_ROWS, THRESH_WANT_REJECTS, or both", .{want});
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const opts = try optionsOf(m, a, o);
    // The export takes its own copy.
    var owned = try schemaOf(m, schema_json);
    defer owned.deinit();
    switch (try lib.readArrow(env(), a, path, &owned.schema, opts, .{ .rows = want & want_rows != 0, .rejects = want & want_rejects != 0 })) {
        .stopped => |st| {
            const f = try report.fileOf(a, st.outcome, .{ .verdict = st.verdict, .encoding = opts.encoding });
            out.* = try jsonOf(report.writeFileReport, .{ f, true });
        },
        .ready => |e| {
            errdefer e.release();
            const r = try gpa.create(Reader);
            r.* = .{ .stream = e };
            r.message.clear();
            r_out.* = r;
        },
    }
}

export fn thresh_reader_rows(r: ?*Reader, out: ?*arrow_c.ArrayStream) c_int {
    const h = r orelse return @backingInt(Status.argument);
    return call(&h.message, take, .{ h.stream, out, false });
}

export fn thresh_reader_rejects(r: ?*Reader, out: ?*arrow_c.ArrayStream) c_int {
    const h = r orelse return @backingInt(Status.argument);
    return call(&h.message, take, .{ h.stream, out, true });
}

fn take(m: *Message, e: *lib.ArrowExport, out_c: ?*arrow_c.ArrayStream, rejects: bool) !void {
    const out = out_c orelse return misuse(m, "out is NULL", .{});
    const which = if (rejects) "rejects" else "rows";
    (if (rejects) e.rejectsStream(out) else e.rowsStream(out)) catch |err| return switch (err) {
        error.NotWanted => misuse(m, "the {s} were not wanted: thresh_read's want did not have THRESH_WANT_{s}", .{ which, if (rejects) "REJECTS" else "ROWS" }),
        error.AlreadyTaken => misuse(m, "the {s} stream was taken already", .{which}),
    };
}

export fn thresh_reader_report(r: ?*Reader, json: ?*?[*:0]u8) c_int {
    const h = r orelse return @backingInt(Status.argument);
    return call(&h.message, readerReport, .{ h.stream, json });
}

fn readerReport(m: *Message, e: *lib.ArrowExport, json: ?*?[*:0]u8) !void {
    const out = try outOf(m, "json", [*:0]u8, json);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const f = e.fileReport(arena.allocator()) catch |err| {
        if (e.lastError()) |s| m.set("{s}", .{s});
        return err;
    };
    out.* = try jsonOf(report.writeFileReport, .{ f, true });
}

export fn thresh_reader_error(r: ?*const Reader) [*:0]const u8 {
    const h = r orelse return "the reader is NULL";
    return h.message.ptr();
}

export fn thresh_reader_free(r: ?*Reader) void {
    const h = r orelse return;
    h.stream.release();
    gpa.destroy(h);
}

const testing = std.testing;

fn expectSameLayout(comptime C: type, comptime Z: type) !void {
    try testing.expectEqual(@sizeOf(C), @sizeOf(Z));
    const names = @typeInfo(Z).@"struct".field_names;
    try testing.expectEqual(names.len, @typeInfo(C).@"struct".field_names.len);
    inline for (names) |f| try testing.expectEqual(@offsetOf(C, f), @offsetOf(Z, f));
}

test "include/thresh.h lays out its structs and numbers its constants as the library does" {
    const h = @import("thresh_h");
    try expectSameLayout(h.thresh_options, Options);
    try expectSameLayout(h.struct_ArrowSchema, arrow_c.Schema);
    try expectSameLayout(h.struct_ArrowArray, arrow_c.Array);
    try expectSameLayout(h.struct_ArrowArrayStream, arrow_c.ArrayStream);
    inline for (.{
        .{ Status.ok, h.THRESH_OK },               .{ Status.argument, h.THRESH_ERROR_ARGUMENT },
        .{ Status.schema, h.THRESH_ERROR_SCHEMA }, .{ Status.io, h.THRESH_ERROR_IO },
        .{ Status.memory, h.THRESH_ERROR_MEMORY }, .{ Status.interrupted, h.THRESH_ERROR_INTERRUPTED },
    }) |pair| try testing.expectEqual(@backingInt(pair[0]), pair[1]);
    try testing.expectEqual(@typeInfo(Status).@"enum".field_names.len, 6);
    try testing.expectEqual(quote_none, h.THRESH_QUOTE_NONE);
    try testing.expectEqual(want_rows, h.THRESH_WANT_ROWS);
    try testing.expectEqual(want_rejects, h.THRESH_WANT_REJECTS);
    try testing.expectEqual(Flag.keep_empty, h.THRESH_KEEP_EMPTY);
    try testing.expectEqual(Flag.day_first, h.THRESH_DAY_FIRST);
    try testing.expectEqual(Flag.strict, h.THRESH_STRICT);
    try testing.expectEqual(Flag.no_mmap, h.THRESH_NO_MMAP);
    try testing.expectEqual(Flag.threshold, h.THRESH_THRESHOLD);
    try testing.expectEqual(@as(c_int, arrow_c.flag_nullable), h.ARROW_FLAG_NULLABLE);
}

/// A C caller's options: zero but the size.
fn defaults() Options {
    var o = std.mem.zeroes(Options);
    o.size = @sizeOf(Options);
    return o;
}

const lugs = "test/c/lugs.csv";
const lugs_columns = "lug_id:int64,cultivar:string,lug_kg:decimal(5,2),picked_on:date";

fn drain(s: *arrow_c.ArrayStream) !i64 {
    var schema: arrow_c.Schema = undefined;
    try testing.expectEqual(@as(c_int, 0), s.get_schema.?(s, &schema));
    schema.release.?(&schema);
    var rows: i64 = 0;
    while (true) {
        var a: arrow_c.Array = undefined;
        try testing.expectEqual(@as(c_int, 0), s.get_next.?(s, &a));
        const release = a.release orelse return rows;
        rows += a.length;
        release(&a);
    }
}

test "the C calls, each to its JSON, under testing.allocator" {
    const t = thresh_new().?;
    defer thresh_free(t);
    const o = defaults();
    var json: ?[*:0]u8 = null;

    try testing.expectEqual(@as(c_int, 0), thresh_sniff(t, lugs, &o, &json));
    try testing.expect(std.mem.find(u8, std.mem.span(json.?), "\"delimiter\":\",\"") != null);
    thresh_string_free(json);
    try testing.expectEqualStrings("", std.mem.span(thresh_error(t)));

    // A file that cannot be read is its sniff line, with no dialect.
    try testing.expectEqual(@as(c_int, 0), thresh_sniff(t, "test/c/none.csv", null, &json));
    try testing.expect(std.mem.find(u8, std.mem.span(json.?), "\"code\":\"no_such_file\"") != null);
    try testing.expect(std.mem.find(u8, std.mem.span(json.?), "dialect") == null);
    thresh_string_free(json);

    var schema: ?[*:0]u8 = null;
    try testing.expectEqual(@as(c_int, 0), thresh_columns(t, lugs_columns, &schema));
    defer thresh_string_free(schema);
    try testing.expectEqual(@as(c_int, 0), thresh_validate(t, lugs, schema, &o, &json));
    // The report is indented, as the CLI writes it.
    try testing.expect(std.mem.find(u8, std.mem.span(json.?), "\"rows_rejected\": 2") != null);
    thresh_string_free(json);

    // Two files on two threads: each file's outcome, then one schema.
    var two = o;
    two.jobs = 2;
    const paths = [_]?[*:0]const u8{ lugs, "test/c/none.csv", lugs };
    try testing.expectEqual(@as(c_int, 0), thresh_infer(t, &paths, paths.len, &two, &json));
    const inferred = std.mem.span(json.?);
    try testing.expect(std.mem.find(u8, inferred, "\"schema\":{") != null);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, inferred, "\"result\":"));
    try testing.expect(std.mem.find(u8, inferred, "\"code\":\"no_such_file\"") != null);
    thresh_string_free(json);
}

test "the C calls refuse what is made wrongly, and say why" {
    const t = thresh_new().?;
    defer thresh_free(t);
    var json: ?[*:0]u8 = null;
    var o = defaults();
    o.size = 0;
    try testing.expectEqual(@backingInt(Status.argument), thresh_sniff(t, lugs, &o, &json));
    try testing.expect(std.mem.startsWith(u8, std.mem.span(thresh_error(t)), "thresh_options.size is 0"));
    try testing.expectEqual(@as(?[*:0]u8, null), json);

    // From a newer header: longer, and setting what this thresh does not
    // know, refused; leaving it zero, read.
    const Newer = extern struct { o: Options, extra: u64 };
    var newer = std.mem.zeroes(Newer);
    newer.o.size = @sizeOf(Newer);
    newer.extra = 1;
    try testing.expectEqual(@backingInt(Status.argument), thresh_sniff(t, lugs, &newer.o, &json));
    try testing.expect(std.mem.find(u8, std.mem.span(thresh_error(t)), "from a newer thresh") != null);
    newer.extra = 0;
    try testing.expectEqual(@as(c_int, 0), thresh_sniff(t, lugs, &newer.o, &json));
    thresh_string_free(json);

    o = defaults();
    o.encoding = "ebcdic";
    try testing.expectEqual(@backingInt(Status.argument), thresh_sniff(t, lugs, &o, &json));
    try testing.expectEqualStrings("thresh_options.encoding is \"ebcdic\": utf8, latin1 or cp1252", std.mem.span(thresh_error(t)));
    try testing.expectEqual(@backingInt(Status.argument), thresh_sniff(t, null, null, &json));
    try testing.expectEqual(@backingInt(Status.argument), thresh_sniff(null, lugs, null, &json));

    try testing.expectEqual(@backingInt(Status.schema), thresh_validate(t, lugs, "{\"columns\":[{\"name\":\"lug_id\",\"type\":\"integer\"}]}", null, &json));
    try testing.expect(std.mem.startsWith(u8, std.mem.span(thresh_error(t)), "the schema: "));
    try testing.expectEqual(@backingInt(Status.schema), thresh_columns(t, "lug_id", &json));

    var reader: ?*Reader = null;
    try testing.expectEqual(@backingInt(Status.argument), thresh_read(t, lugs, "{\"columns\":[]}", null, 0, &reader, &json));
}

test "thresh_read: the streams outlive the reader, and the reader its handle" {
    const t = thresh_new().?;
    var schema: ?[*:0]u8 = null;
    try testing.expectEqual(@as(c_int, 0), thresh_columns(t, lugs_columns, &schema));
    var reader: ?*Reader = null;
    var json: ?[*:0]u8 = null;
    try testing.expectEqual(@as(c_int, 0), thresh_read(t, lugs, schema, null, want_rows | want_rejects, &reader, &json));
    thresh_string_free(schema);
    try testing.expectEqual(@as(?[*:0]u8, null), json);
    thresh_free(t);
    const r = reader.?;
    var rows: arrow_c.ArrayStream = undefined;
    var rejects: arrow_c.ArrayStream = undefined;
    try testing.expectEqual(@as(c_int, 0), thresh_reader_rows(r, &rows));
    try testing.expectEqual(@as(c_int, 0), thresh_reader_rejects(r, &rejects));
    var again: arrow_c.ArrayStream = undefined;
    try testing.expectEqual(@backingInt(Status.argument), thresh_reader_rows(r, &again));
    try testing.expectEqualStrings("the rows stream was taken already", std.mem.span(thresh_reader_error(r)));
    try testing.expectEqual(@as(c_int, 0), thresh_reader_report(r, &json));
    try testing.expect(std.mem.find(u8, std.mem.span(json.?), "\"rows_rejected\": 2") != null);
    thresh_string_free(json);
    thresh_reader_free(r);
    try testing.expectEqual(@as(i64, 8), try drain(&rows));
    try testing.expectEqual(@as(i64, 2), try drain(&rejects));
    rows.release.?(&rows);
    rejects.release.?(&rejects);

    // A file that stops before it is read: no reader, its report.
    const h = thresh_new().?;
    defer thresh_free(h);
    try testing.expectEqual(@as(c_int, 0), thresh_read(h, "test/c/none.csv", "{\"columns\":[{\"name\":\"lug_id\",\"type\":\"int64\"}]}", null, want_rows, &reader, &json));
    try testing.expectEqual(@as(?*Reader, null), reader);
    try testing.expect(std.mem.find(u8, std.mem.span(json.?), "\"code\": \"no_such_file\"") != null);
    thresh_string_free(json);
}

test "each option reaches the call" {
    const t = thresh_new().?;
    defer thresh_free(t);
    var json: ?[*:0]u8 = null;
    var o = defaults();
    o.quote = quote_none;
    o.delimiter = ';';
    o.header = 2;
    try testing.expectEqual(@as(c_int, 0), thresh_sniff(t, lugs, &o, &json));
    const line = std.mem.span(json.?);
    for ([_][]const u8{ "\"quote\":null", "\"delimiter\":\";\"", "\"header\":false" }) |want| try testing.expect(std.mem.find(u8, line, want) != null);
    thresh_string_free(json);

    var schema: ?[*:0]u8 = null;
    try testing.expectEqual(@as(c_int, 0), thresh_columns(t, lugs_columns, &schema));
    defer thresh_string_free(schema);
    // 8 of 10 rows fit: they pass 0.7.
    o = defaults();
    o.flags = Flag.threshold;
    o.threshold = 0.7;
    try testing.expectEqual(@as(c_int, 0), thresh_validate(t, lugs, schema, &o, &json));
    try testing.expect(std.mem.find(u8, std.mem.span(json.?), "\"result\": \"pass\"") != null);
    thresh_string_free(json);
    o.threshold = 1.5;
    try testing.expectEqual(@backingInt(Status.argument), thresh_validate(t, lugs, schema, &o, &json));
    // "x" read as null: one row rejected, not two.
    o = defaults();
    const nulls = [_]?[*:0]const u8{"x"};
    o.nulls = &nulls;
    o.nulls_len = nulls.len;
    try testing.expectEqual(@as(c_int, 0), thresh_validate(t, lugs, schema, &o, &json));
    try testing.expect(std.mem.find(u8, std.mem.span(json.?), "\"rows_rejected\": 1") != null);
    thresh_string_free(json);
}

test "the cancel flag stops a call" {
    const t = thresh_new().?;
    defer thresh_free(t);
    var stop: u8 = 1;
    var o = defaults();
    o.cancel = &stop;
    var schema: ?[*:0]u8 = null;
    try testing.expectEqual(@as(c_int, 0), thresh_columns(t, lugs_columns, &schema));
    defer thresh_string_free(schema);
    var json: ?[*:0]u8 = null;
    try testing.expectEqual(@backingInt(Status.interrupted), thresh_validate(t, lugs, schema, &o, &json));
    try testing.expectEqualStrings("interrupted", std.mem.span(thresh_error(t)));
}
