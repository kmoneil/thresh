//! The CLI's files for each input: its report (--report), its rejected
//! rows (--reject) and its output (convert and run: --to, --out), written
//! as it is read through lib.read; the output under a dot-named temporary
//! until it is whole, then renamed into place. The library itself writes
//! no file: these are the CLI's way of rendering what it returns.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const lib = @import("lib.zig");
const Env = lib.Env;
const Options = lib.Options;
const dialect = @import("dialect.zig");
const report = @import("report.zig");
const Schema = @import("schema.zig").Schema;
const builders = @import("builders.zig");
const csv = @import("write/csv.zig");
const arrow = @import("write/arrow.zig");
const Encoding = @import("types.zig").Encoding;

fn now(io: Io) Io.Timestamp {
    return Io.Timestamp.now(io, .awake);
}

fn since(io: Io, t: Io.Timestamp) u64 {
    return @intCast(@max(0, t.durationTo(now(io)).nanoseconds));
}

/// The run-wide settings a file's validation takes from the command line
/// and the schema.
pub const Plan = struct {
    options: Options,
    schema: *const Schema,

    /// Leave timing out of reports (tests).
    timing: bool = true,
    /// convert and run: where the accepted rows go, and as what.
    output: ?OutputPlan = null,
    /// --report and --reject: where the file's report and rejected rows go.
    report_dir: ?[]const u8 = null,
    reject_dir: ?[]const u8 = null,
};

pub const Format = enum { csv, arrow };

pub const OutputPlan = struct {
    to: Format,
    dir: []const u8,
    /// arrow: the file format, with a footer, not the stream.
    arrow_file: bool = false,
    /// csv: the field separator, the line break, and dates as RFC 3339.
    delimiter: u8 = ',',
    newline: dialect.Dialect.Newline = .lf,
    normalize_dates: bool = false,
};

/// What an output file keeps of a name: all before its last dot.
pub fn stem(name: []const u8) []const u8 {
    return name[0 .. std.mem.findScalarLast(u8, name, '.') orelse name.len];
}

/// A file's output: written to a dot-named temporary beside where it goes
/// and renamed there when the file is done, so a crash or a Ctrl-C leaves
/// no partial file under the real name.
const Output = struct {
    final_path: []const u8,
    tmp_path: []const u8,
    sink: Sink,
    batch: builders.Batch,
    format: union(enum) { csv: csv.Writer, arrow: arrow.Writer },

    /// name is the file's from pool.uniqueNames, whose stem is the run's alone.
    fn create(env: Env, arena: Allocator, plan: OutputPlan, encoding: Encoding, s: *const Schema, name: []const u8) !Output {
        const name_stem = stem(name);
        const ext: []const u8 = switch (plan.to) {
            .csv => ".csv",
            .arrow => if (plan.arrow_file) ".arrow" else ".arrows",
        };
        const dir = std.mem.trimEnd(u8, plan.dir, "/");
        try Io.Dir.cwd().createDirPath(env.io, dir);
        const final_path = try std.fmt.allocPrint(arena, "{s}/{s}{s}", .{ dir, name_stem, ext });
        // Random, so two runs writing the same name do not share one.
        var nonce: [8]u8 = undefined;
        env.io.random(&nonce);
        const tmp_path = try std.fmt.allocPrint(arena, "{s}/.{s}{s}.{x}.tmp", .{ dir, name_stem, ext, &nonce });
        var sink: Sink = try .open(env.io, env.gpa, tmp_path);
        errdefer sink.close(env.io, env.gpa);
        var batch: builders.Batch = try .init(env.gpa, s, encoding);
        errdefer batch.deinit();
        return .{
            .final_path = final_path,
            .tmp_path = tmp_path,
            .sink = sink,
            .batch = batch,
            .format = switch (plan.to) {
                .csv => .{ .csv = .{
                    .options = .{ .delimiter = plan.delimiter, .newline = plan.newline },
                    .normalize_dates = plan.normalize_dates,
                } },
                .arrow => .{ .arrow = .init(env.gpa, s, .{ .file = plan.arrow_file }) },
            },
        };
    }

    /// Writes the column names (CSV) or the schema message (Arrow).
    fn header(o: *Output, s: *const Schema, arena: Allocator) !void {
        const names = try arena.alloc([]const u8, s.columns.len);
        for (names, s.columns) |*n, c| n.* = c.name;
        const out = &o.sink.writer.interface;
        switch (o.format) {
            .csv => |*w| try w.header(out, names),
            .arrow => |*w| try w.header(out),
        }
    }

    /// Writes what the batch holds, then empties it.
    fn write(o: *Output) !void {
        const out = &o.sink.writer.interface;
        switch (o.format) {
            .csv => |*w| try w.batch(out, &o.batch),
            // An empty batch is no record batch.
            .arrow => |*w| if (o.batch.rows > 0) try w.batch(out, &o.batch),
        }
        o.batch.reset();
    }

    /// Flushes and closes the file, and renames it into place, or with
    /// keep false deletes it. Releases everything, and leaves no
    /// temporary, whether or not it succeeds, so it is called once.
    fn finish(o: *Output, env: Env, keep: bool) !void {
        defer o.batch.deinit();
        defer switch (o.format) {
            .arrow => |*w| w.deinit(),
            .csv => {},
        };
        // Deleted after it is closed (the defer below runs first).
        errdefer Io.Dir.cwd().deleteFile(env.io, o.tmp_path) catch {};
        defer o.sink.close(env.io, env.gpa);
        if (keep) switch (o.format) {
            .arrow => |*w| try w.end(&o.sink.writer.interface),
            .csv => {},
        };
        if (keep) try o.sink.writer.interface.flush();
        o.sink.close(env.io, env.gpa);
        if (keep) {
            try Io.Dir.cwd().rename(o.tmp_path, Io.Dir.cwd(), o.final_path, env.io);
        } else {
            // Best effort: one left behind is dot-named, not the output.
            Io.Dir.cwd().deleteFile(env.io, o.tmp_path) catch {};
        }
    }
};

/// Validates the file at path, writes its report (with --report) and its
/// rejected rows (with --reject), and returns what came of it. An error is
/// one about the run (memory, an unwritable report), not about the file.
pub fn validateFile(env: Env, plan: Plan, path: []const u8, arena: Allocator) !report.Outcome {
    return validateNamed(env, plan, path, std.fs.path.basename(path), arena);
}

/// validateFile, with name the base of its report, reject and output
/// files' names (unique within a run when inputs share a base name).
pub fn validateNamed(env: Env, plan: Plan, path: []const u8, name: []const u8, arena: Allocator) !report.Outcome {
    const io = env.io;
    const gpa = env.gpa;
    const opts = plan.options;
    var details: report.Details = .{ .encoding = opts.encoding };

    var r = switch (try lib.read(env, arena, path, plan.schema, opts, null)) {
        .stopped => |st| {
            details.verdict = st.verdict;
            try writeReport(env, plan, arena, st.outcome, name, details);
            return st.outcome;
        },
        .reader => |x| x,
    };
    defer r.deinit();

    var reject: ?Sink = if (plan.reject_dir) |dir| try .create(io, gpa, dir, name, ".rejects.csv") else null;
    defer if (reject) |*s| s.close(io, gpa);
    // Interrupted or failed: no partial reject file left behind either,
    // as far as deleting it can; the error being returned is the news.
    errdefer if (reject) |*s| {
        s.close(io, gpa);
        removeSink(io, plan.reject_dir.?, name, ".rejects.csv") catch {};
    };
    if (reject) |*s| r.v.reject = &s.writer.interface;

    var output: ?Output = if (plan.output) |op| try .create(env, arena, op, opts.encoding, plan.schema, name) else null;
    var output_done = false;
    // Unfinished means an error is on its way out: finish only deletes,
    // and its own failure would hide that error.
    defer if (output) |*o| if (!output_done) o.finish(env, false) catch {};
    if (output) |*o| {
        r.v.batch = &o.batch;
        try o.header(plan.schema, arena);
    }

    while (try r.next()) {
        if (output) |*o| {
            const tw = now(io);
            try o.write();
            r.out.timing.write_ns += since(io, tw);
        }
    }
    var out = try r.finish(arena);
    if (output) |*o| {
        // A failing file's good rows are still written, unless --strict.
        const keep = out.result == .pass or (out.result == .fail and !opts.strict);
        // Done whether or not finish succeeds: it releases the output either way.
        output_done = true;
        const tw = now(io);
        try o.finish(env, keep);
        out.timing.write_ns += since(io, tw);
        if (keep) out.written = o.final_path;
    }
    details.verdict = r.verdict;
    details.validator = &r.v;
    if (reject) |*s| {
        try s.writer.interface.flush();
        if (r.v.rejected == 0) {
            s.close(io, gpa);
            reject = null;
            try removeSink(io, plan.reject_dir.?, name, ".rejects.csv");
        }
    }
    try writeReport(env, plan, arena, out, name, details);
    return out;
}

fn writeReport(env: Env, plan: Plan, arena: Allocator, out: report.Outcome, name: []const u8, details: report.Details) !void {
    const dir = plan.report_dir orelse return;
    var sink: Sink = try .create(env.io, env.gpa, dir, name, ".report.json");
    defer sink.close(env.io, env.gpa);
    try report.writeFileReport(&sink.writer.interface, try report.fileOf(arena, out, details), plan.timing);
    try sink.writer.interface.flush();
}

/// An output file in dir named for the input: its base name and ext. The
/// buffer is on the heap, so a Sink copies safely; one inside the struct
/// would leave the writer pointing at create's frame (zigvet#125).
pub const Sink = struct {
    file: Io.File,
    writer: Io.File.Writer,
    buf: []u8,
    closed: bool = false,

    pub fn create(io: Io, gpa: Allocator, dir: []const u8, source: []const u8, ext: []const u8) !Sink {
        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        const name = try sinkPath(&name_buf, dir, source, ext);
        try Io.Dir.cwd().createDirPath(io, dir);
        return open(io, gpa, name);
    }

    /// The file at path, created, behind a 1 MiB buffer.
    pub fn open(io: Io, gpa: Allocator, path: []const u8) !Sink {
        const buf = try gpa.alloc(u8, 1 << 20);
        errdefer gpa.free(buf);
        const file = try Io.Dir.cwd().createFile(io, path, .{});
        return .{ .file = file, .writer = file.writer(io, buf), .buf = buf };
    }

    pub fn close(s: *Sink, io: Io, gpa: Allocator) void {
        if (s.closed) return;
        s.closed = true;
        s.file.close(io);
        gpa.free(s.buf);
    }
};

fn sinkPath(buf: []u8, dir: []const u8, source: []const u8, ext: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}{s}", .{ std.mem.trimEnd(u8, dir, "/"), std.fs.path.basename(source), ext });
}

fn removeSink(io: Io, dir: []const u8, source: []const u8, ext: []const u8) !void {
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    try Io.Dir.cwd().deleteFile(io, try sinkPath(&name_buf, dir, source, ext));
}

const testing = std.testing;

/// Whether dir/sub_path holds a temporary output (a name ending .tmp).
fn hasTemporary(io: Io, dir: Io.Dir, sub_path: []const u8) !bool {
    var d = try dir.openDir(io, sub_path, .{ .iterate = true });
    defer d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |e| if (std.mem.endsWith(u8, e.name, ".tmp")) return true;
    return false;
}

const test_schema: Schema = .{ .columns = &.{ .{ .name = "id", .type = .int64 }, .{ .name = "name", .type = .string } } };

test "an output that cannot be renamed into place leaves no temporary" {
    const io = testing.io;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.writeFile(io, .{ .sub_path = "orders.csv", .data = "id,name\n1,apple\n" });
    // Where the output goes is a directory, and not an empty one.
    try tmp.dir.createDirPath(io, "out/orders.csv/x");
    const out_dir = try std.fmt.allocPrint(a, "{s}/out", .{root});
    const plan: Plan = .{
        .options = .{},
        .schema = &test_schema,

        .timing = false,
        .output = .{ .to = .csv, .dir = out_dir },
    };
    const path = try std.fmt.allocPrint(a, "{s}/orders.csv", .{root});
    try testing.expectError(error.IsDir, validateFile(.{ .io = io, .gpa = gpa }, plan, path, a));
    try testing.expect(!try hasTemporary(io, tmp.dir, "out"));
}

test "an output whose last write fails is closed and leaves no temporary" {
    const io = testing.io;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const out_dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/out", .{tmp.sub_path});
    const env: Env = .{ .io = io, .gpa = gpa };
    var o: Output = try .create(env, a, .{ .to = .csv, .dir = out_dir }, .utf8, &test_schema, "orders.csv");
    try o.header(&test_schema, a);
    // The file under the buffered header turns read-only, as a full disk
    // would fail it: the flush in finish is refused. testing.allocator
    // reports the Sink's buffer if finish does not free it.
    o.sink.file.close(io);
    o.sink.file = try Io.Dir.cwd().openFile(io, o.tmp_path, .{});
    o.sink.writer.file = o.sink.file;
    try testing.expectError(error.WriteFailed, o.finish(env, true));
    try testing.expect(o.sink.closed);
    try testing.expect(!try hasTemporary(io, tmp.dir, "out"));
}
