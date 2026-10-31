//! For test/arrow/check.py: a file read through lib.readArrow, its rows
//! and its rejected rows handed to pyarrow as Arrow C streams through one
//! C call, which it loads with ctypes. A test's harness, not thresh's C
//! ABI.

const std = @import("std");
const lib = @import("thresh").lib;

// The streams read after the call returns, so the Io is the library's: the
// single-threaded one, which leaves the host's signal handlers alone.
var threaded: std.Io.Threaded = .init_single_threaded;
// libc's malloc: thread-safe, as pyarrow may release a batch on another
// thread, and with libc linked a library loaded into another process
// (Python) keeps its thread-local storage the way that process does.
const gpa = std.heap.c_allocator;

/// Reads path against the schema at schema_path, or with none, one
/// inferred from the file as convert infers it; encoding is --encoding's
/// name. 0: rows and rejects are the streams; 1: the file stopped before
/// it was read, and they are untouched; 2: anything else.
export fn thresh_test_read(path: [*:0]const u8, schema_path: ?[*:0]const u8, encoding: [*:0]const u8, rows: *lib.ArrowArrayStream, rejects: *lib.ArrowArrayStream) c_int {
    return read(std.mem.span(path), if (schema_path) |p| std.mem.span(p) else null, std.mem.span(encoding), rows, rejects) catch 2;
}

fn read(path: []const u8, schema_path: ?[]const u8, encoding: []const u8, rows: *lib.ArrowArrayStream, rejects: *lib.ArrowArrayStream) !c_int {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const env: lib.Env = .{ .io = threaded.io(), .gpa = gpa };
    const o: lib.Options = .{ .encoding = std.meta.stringToEnum(@FieldType(lib.Options, "encoding"), encoding) orelse return error.UnknownEncoding };
    var owned: ?lib.OwnedSchema = null;
    defer if (owned) |*s| s.deinit();
    const s: lib.Schema = if (schema_path) |p| blk: {
        var diag: lib.SchemaDiagnostic = .{};
        owned = try lib.loadSchema(env.io, gpa, p, &diag);
        break :blk owned.?.schema;
    } else (try lib.infer(env, a, &.{path}, o)).schema orelse return 1;
    const e = switch (try lib.readArrow(env, a, path, &s, o, .{ .rejects = true })) {
        .stopped => return 1,
        .ready => |e| e,
    };
    // The streams hold the export, which has its own schema.
    defer e.release();
    try e.rowsStream(rows);
    try e.rejectsStream(rejects);
    return 0;
}
