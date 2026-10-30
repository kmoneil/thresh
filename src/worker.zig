//! One file's pipeline: open, sniff, scan a batch at a time, validate,
//! and write its report and reject file. The only file that imports every
//! stage, so each stage can be tested and benchmarked alone.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const cli = @import("cli.zig");
const dialect = @import("dialect.zig");
const input = @import("input.zig");
const records = @import("records.zig");
const schema_mod = @import("schema.zig");
const Schema = schema_mod.Schema;
const validate = @import("validate.zig");
const report = @import("report.zig");

pub const Env = struct {
    io: Io,
    gpa: Allocator,
};

/// The run-wide settings a file's validation takes from the command line
/// and the schema.
pub const Plan = struct {
    cfg: *const cli.Config,
    schema: *const Schema,
    /// The schema's nulls and --null's.
    nulls: []const []const u8,
    threshold: f64,
    /// Leave timing out of reports (tests).
    timing: bool = true,
};

/// The global nulls: the schema's, then --null's comma-separated ones.
pub fn nullsOf(arena: Allocator, s: *const Schema, extra: ?[]const u8) Allocator.Error![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    try list.appendSlice(arena, s.nulls);
    if (extra) |e| {
        var it = std.mem.splitScalar(u8, e, ',');
        while (it.next()) |n| try list.append(arena, n);
    }
    return list.toOwnedSlice(arena);
}

fn now(io: Io) Io.Timestamp {
    return Io.Timestamp.now(io, .awake);
}

fn since(io: Io, t: Io.Timestamp) u64 {
    return @intCast(@max(0, t.durationTo(now(io)).nanoseconds));
}

/// Validates the file at path, writes its report (with --report) and its
/// rejected rows (with --reject), and returns what came of it. An error is
/// one about the run (memory, an unwritable report), not about the file.
pub fn validateFile(env: Env, plan: Plan, path: []const u8, arena: Allocator) !report.Outcome {
    const io = env.io;
    const gpa = env.gpa;
    const cfg = plan.cfg;
    var out: report.Outcome = .{ .file = path, .result = .@"error" };
    var details: report.Details = .{ .schema = plan.schema, .encoding = encodingOf(cfg), .timing = plan.timing };

    const t0 = now(io);
    var in = input.Input.open(io, gpa, path, .{ .no_mmap = cfg.no_mmap }) catch |e| {
        out.problem = describe(e);
        try writeReport(env, plan, out, details);
        return out;
    };
    defer in.close(io, gpa);
    out.bytes = in.size;

    const max_sample = @max(cfg.sample_bytes, 16 << 20);
    while (!in.eof and in.data().len < max_sample) try in.refill(io, gpa, in.base);
    const names = try arena.alloc([]const u8, plan.schema.columns.len);
    for (names, plan.schema.columns) |*n, c| n.* = c.name;
    const verdict = dialect.sniff(gpa, in.data(), in.eof, .{
        .pins = cfg.pins,
        .sample_bytes = cfg.sample_bytes,
        .max_sample = max_sample,
        .schema = names,
    }) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => {
            out.problem = describe(e);
            try writeReport(env, plan, out, details);
            return out;
        },
    };
    details.verdict = verdict;
    out.timing.sniff_ns = since(io, t0);
    if (verdict.confidence == .low and !cfg.pins.complete()) {
        out.problem = "the dialect is not settled (confidence low); pin it with --delimiter, --quote, --escape, --newline and --header";
        try writeReport(env, plan, out, details);
        return out;
    }

    const t1 = now(io);
    var v: validate.Validator = try .init(gpa, plan.schema, verdict.dialect, .{
        .nulls = plan.nulls,
        .encoding = encodingOf(cfg),
        .threshold = plan.threshold,
        .strict = cfg.strict,
        .day_first = cfg.day_first,
        .ragged = switch (cfg.ragged) {
            .reject => .reject,
            .pad => .pad,
            .truncate => .truncate,
        },
    });
    defer v.deinit();

    var reject: ?Sink = if (cfg.reject_dir) |dir| try .create(io, gpa, dir, path, ".rejects.csv") else null;
    defer if (reject) |*r| r.close(io, gpa);
    if (reject) |*r| v.reject = &r.writer.interface;

    var s: records.Scanner = try .init(gpa, verdict.dialect, .{ .reference = .{
        .start = verdict.start,
        .keep_empty = cfg.keep_empty,
    } });
    defer s.deinit();
    s.feed(in.data(), in.base, in.eof);
    var batch: records.Batch = .{};
    defer batch.deinit(gpa);
    var header_pending = verdict.dialect.header;
    if (!header_pending) try v.columns(null, verdict.fields, in.data(), in.base);
    while (true) {
        batch.clear();
        const state = try batch.fill(gpa, &s, .{});
        for (0..batch.len()) |i| {
            const fields = batch.recordFields(i);
            if (header_pending) {
                header_pending = false;
                try v.columns(fields, fields.len, in.data(), in.base);
                continue;
            }
            try v.record(batch.records.items[i], fields, in.data(), in.base);
        }
        switch (state) {
            .full => {},
            .end => break,
            .need_more => {
                try in.refill(io, gpa, s.keepFrom());
                s.feed(in.data(), in.base, in.eof);
            },
        }
    }
    // An empty file with a header pending: no columns to match.
    if (header_pending) try v.columns(null, 0, in.data(), in.base);
    out.timing.parse_ns = since(io, t1);

    out.rows = v.rows;
    out.rows_rejected = v.rejected;
    out.result = if (v.passed()) .pass else .fail;
    if (v.structural.items.len > 0) out.problem = try arena.dupe(u8, v.structural.items[0]);
    details.validator = &v;
    if (reject) |*r| {
        try r.writer.interface.flush();
        if (v.rejected == 0) {
            r.close(io, gpa);
            reject = null;
            try removeSink(io, cfg.reject_dir.?, path, ".rejects.csv");
        }
    }
    try writeReport(env, plan, out, details);
    return out;
}

fn encodingOf(cfg: *const cli.Config) @import("types.zig").Encoding {
    return switch (cfg.encoding) {
        .utf8 => .utf8,
        .latin1 => .latin1,
    };
}

fn writeReport(env: Env, plan: Plan, out: report.Outcome, details: report.Details) !void {
    const dir = plan.cfg.report_dir orelse return;
    var sink: Sink = try .create(env.io, env.gpa, dir, out.file, ".report.json");
    defer sink.close(env.io, env.gpa);
    try report.writeFileReport(&sink.writer.interface, out, details);
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
        const buf = try gpa.alloc(u8, 1 << 20);
        errdefer gpa.free(buf);
        const file = try Io.Dir.cwd().createFile(io, name, .{});
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

pub fn describe(e: anyerror) []const u8 {
    return switch (e) {
        error.FileNotFound => "no such file",
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.IsDir => "is a directory",
        error.OutOfMemory => "out of memory",
        error.BrokenPipe => "the output was closed",
        error.Utf16 => "UTF-16 input (a UTF-16 byte order mark) is not read in v1",
        error.Binary => "binary data (a NUL byte in the first 8 KiB)",
        else => @errorName(e),
    };
}
