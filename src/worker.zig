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
const infer = @import("infer.zig");
const builders = @import("builders.zig");
const csv = @import("write/csv.zig");
const arrow = @import("write/arrow.zig");
const interrupt = @import("interrupt.zig");

pub const Env = struct {
    io: Io,
    gpa: Allocator,
    /// A worker's index buffer, reused from file to file.
    positions: ?[]u32 = null,
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
    /// convert and run: where the accepted rows go, and as what.
    output: ?OutputPlan = null,
};

pub const OutputPlan = struct {
    to: cli.Format,
    dir: []const u8,
};

/// A file's output: written to a dot-named temporary beside where it goes
/// and renamed there when the file is done, so a crash or a Ctrl-C leaves
/// no partial file under the real name.
const Output = struct {
    final_path: []const u8,
    tmp_path: []const u8,
    sink: Sink,
    batch: builders.Batch,
    format: union(enum) { csv: csv.Writer, arrow: arrow.Writer },

    fn create(env: Env, arena: Allocator, plan: OutputPlan, cfg: *const cli.Config, s: *const Schema, source: []const u8) !Output {
        const base = std.fs.path.basename(source);
        const stem = base[0 .. std.mem.findScalarLast(u8, base, '.') orelse base.len];
        const ext: []const u8 = switch (plan.to) {
            .csv => ".csv",
            .arrow => if (cfg.arrow_file) ".arrow" else ".arrows",
            .parquet => unreachable,
        };
        const dir = std.mem.trimEnd(u8, plan.dir, "/");
        try Io.Dir.cwd().createDirPath(env.io, dir);
        const final_path = try std.fmt.allocPrint(arena, "{s}/{s}{s}", .{ dir, stem, ext });
        // Random, so two runs writing the same name do not share one.
        var nonce: [8]u8 = undefined;
        env.io.random(&nonce);
        const tmp_path = try std.fmt.allocPrint(arena, "{s}/.{s}{s}.{x}.tmp", .{ dir, stem, ext, &nonce });
        var sink: Sink = try .open(env.io, env.gpa, tmp_path);
        errdefer sink.close(env.io, env.gpa);
        var batch: builders.Batch = try .init(env.gpa, s, encodingOf(cfg));
        errdefer batch.deinit();
        return .{
            .final_path = final_path,
            .tmp_path = tmp_path,
            .sink = sink,
            .batch = batch,
            .format = switch (plan.to) {
                .csv => .{ .csv = .{
                    .out = undefined,
                    .options = .{ .delimiter = cfg.out_delimiter, .newline = cfg.out_newline },
                    .normalize_dates = cfg.normalize_dates,
                } },
                .arrow => .{ .arrow = .init(env.gpa, undefined, s, .{ .file = cfg.arrow_file }) },
                .parquet => unreachable,
            },
        };
    }

    /// Writes what the batch holds, then empties it.
    fn header(o: *Output, s: *const Schema, arena: Allocator) !void {
        const names = try arena.alloc([]const u8, s.columns.len);
        for (names, s.columns) |*n, c| n.* = c.name;
        switch (o.format) {
            .csv => |*w| {
                w.out = &o.sink.writer.interface;
                try w.header(names);
            },
            .arrow => |*w| {
                w.out = &o.sink.writer.interface;
                try w.header();
            },
        }
    }

    fn write(o: *Output) !void {
        switch (o.format) {
            .csv => |*w| {
                w.out = &o.sink.writer.interface;
                try w.batch(&o.batch);
            },
            // An empty batch is no record batch.
            .arrow => |*w| if (o.batch.rows > 0) {
                w.out = &o.sink.writer.interface;
                try w.batch(&o.batch);
            },
        }
        o.batch.reset();
    }

    /// Flushes and closes the file, and renames it into place, or with
    /// keep false deletes it.
    fn finish(o: *Output, env: Env, keep: bool) !void {
        defer o.batch.deinit();
        defer switch (o.format) {
            .arrow => |*w| w.deinit(),
            .csv => {},
        };
        if (keep) switch (o.format) {
            .arrow => |*w| {
                w.out = &o.sink.writer.interface;
                try w.end();
            },
            .csv => {},
        };
        if (keep) try o.sink.writer.interface.flush();
        o.sink.close(env.io, env.gpa);
        if (keep) {
            try Io.Dir.cwd().rename(o.tmp_path, Io.Dir.cwd(), o.final_path, env.io);
        } else Io.Dir.cwd().deleteFile(env.io, o.tmp_path) catch {};
    }
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
    return validateNamed(env, plan, path, std.fs.path.basename(path), arena);
}

/// validateFile, with name the base of its report, reject and output
/// files' names (unique within a run when inputs share a base name).
pub fn validateNamed(env: Env, plan: Plan, path: []const u8, name: []const u8, arena: Allocator) !report.Outcome {
    const io = env.io;
    const gpa = env.gpa;
    const cfg = plan.cfg;
    var out: report.Outcome = .{ .file = path, .result = .@"error" };
    var details: report.Details = .{ .schema = plan.schema, .encoding = encodingOf(cfg), .timing = plan.timing };

    const t0 = now(io);
    var in = input.Input.open(io, gpa, path, .{ .no_mmap = cfg.no_mmap }) catch |e| {
        out.problem = describe(e);
        try writeReport(env, plan, out, name, details);
        return out;
    };
    defer in.close(io, gpa);
    out.bytes = in.size;
    if (utf16Conflict(&in, cfg)) |p| {
        out.problem = p;
        try writeReport(env, plan, out, name, details);
        return out;
    }

    const max_sample = @max(cfg.sample_bytes, 16 << 20);
    while (!in.eof and in.data().len < max_sample) try in.refill(io, gpa, in.base);
    const names = try arena.alloc([]const u8, plan.schema.columns.len);
    for (names, plan.schema.columns) |*n, c| n.* = c.name;
    const verdict = dialect.sniff(gpa, in.data(), in.eof, .{
        .pins = cfg.pins,
        .sample_bytes = cfg.sample_bytes,
        .max_sample = max_sample,
        .utf8 = cfg.encoding == .utf8,
        .schema = names,
    }) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => {
            out.problem = describe(e);
            try writeReport(env, plan, out, name, details);
            return out;
        },
    };
    details.verdict = verdict;
    details.verdict.?.warnings.utf16 = in.utf16 != null;
    out.timing.sniff_ns = since(io, t0);
    if (verdict.confidence == .low and !cfg.pins.complete()) {
        out.problem = "the dialect is not settled (confidence low); pin it with --delimiter, --quote, --escape, --newline and --header";
        try writeReport(env, plan, out, name, details);
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

    var reject: ?Sink = if (cfg.reject_dir) |dir| try .create(io, gpa, dir, name, ".rejects.csv") else null;
    defer if (reject) |*r| r.close(io, gpa);
    // Interrupted or failed: no partial reject file left behind either.
    errdefer if (reject) |*r| {
        r.close(io, gpa);
        removeSink(io, cfg.reject_dir.?, name, ".rejects.csv") catch {};
    };
    if (reject) |*r| v.reject = &r.writer.interface;

    var output: ?Output = if (plan.output) |op| try .create(env, arena, op, cfg, plan.schema, name) else null;
    var output_done = false;
    defer if (output) |*o| if (!output_done) o.finish(env, false) catch {};
    if (output) |*o| {
        v.batch = &o.batch;
        try o.header(plan.schema, arena);
    }

    var s: records.Scanner = try .init(gpa, verdict.dialect, .{
        .reference = .{ .start = verdict.start, .keep_empty = cfg.keep_empty },
        .positions_buffer = env.positions,
    });
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
        if (interrupt.requested()) return error.Interrupted;
        if (output) |*o| try o.write();
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
    if (output) |*o| {
        // A failing file's good rows are still written, unless --strict.
        const keep = out.result == .pass or !cfg.strict;
        output_done = true;
        try o.finish(env, keep);
        if (keep) out.written = o.final_path;
    }
    if (v.structural.items.len > 0) {
        out.problem = try arena.dupe(u8, v.structural.items[0]);
    } else if (v.repeated_headers > 0) {
        out.problem = try repeatedHeader(arena, v.repeated_lines.items[0], v.repeated_headers);
    }
    if (in.utf16) |u| if (u.replaced > 0) {
        details.verdict.?.warnings.utf16_invalid = true;
    };
    details.validator = &v;
    if (reject) |*r| {
        try r.writer.interface.flush();
        if (v.rejected == 0) {
            r.close(io, gpa);
            reject = null;
            try removeSink(io, cfg.reject_dir.?, name, ".rejects.csv");
        }
    }
    try writeReport(env, plan, out, name, details);
    return out;
}

/// A UTF-16 file is transcoded to UTF-8 as it is read, so an --encoding
/// for its bytes would read the UTF-8 as something else.
pub fn utf16Conflict(in: *const input.Input, cfg: *const cli.Config) ?[]const u8 {
    if (in.utf16 == null or cfg.encoding == .utf8) return null;
    return "the file is UTF-16 (it starts with a byte order mark) and is read as such; leave out --encoding";
}

fn encodingOf(cfg: *const cli.Config) @import("types.zig").Encoding {
    return switch (cfg.encoding) {
        .utf8 => .utf8,
        .latin1 => .latin1,
        .cp1252 => .cp1252,
    };
}

fn writeReport(env: Env, plan: Plan, out: report.Outcome, name: []const u8, details: report.Details) !void {
    const dir = plan.cfg.report_dir orelse return;
    var sink: Sink = try .create(env.io, env.gpa, dir, name, ".report.json");
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

pub fn describe(e: anyerror) []const u8 {
    return switch (e) {
        error.FileNotFound => "no such file",
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.IsDir => "is a directory",
        error.OutOfMemory => "out of memory",
        error.BrokenPipe => "the output was closed",
        error.Utf16 => "UTF-16 data (a UTF-16 byte order mark) where UTF-8 was expected",
        error.Binary => "binary data (a NUL byte in the first 8 KiB)",
        else => @errorName(e),
    };
}

/// What a file's repeated header says, for its line and infer's stderr.
pub fn repeatedHeader(arena: Allocator, line: u64, count: u64) Allocator.Error![]const u8 {
    if (count == 1) return std.fmt.allocPrint(arena, "the header repeats at row {d}: files joined? It is skipped", .{line});
    return std.fmt.allocPrint(arena, "the header repeats at row {d} and {d} more: files joined? They are skipped", .{ line, count - 1 });
}

/// One file's pass 1: its outcome and its columns as inference left them.
pub const Inferred = struct {
    outcome: report.Outcome,
    columns: []const infer.ColumnState = &.{},
    header: bool = false,
    /// Records that were the header again, skipped, and the first's line.
    repeated_headers: u64 = 0,
    repeated_line: u64 = 0,
};

/// Infers the file at path's columns, reading all of it, or the first
/// --sample rows. arena holds the result.
pub fn inferFile(env: Env, cfg: *const cli.Config, nulls: []const []const u8, path: []const u8, arena: Allocator) !Inferred {
    const io = env.io;
    const gpa = env.gpa;
    var out: report.Outcome = .{ .file = path, .result = .@"error" };
    const t0 = now(io);
    var in = input.Input.open(io, gpa, path, .{ .no_mmap = cfg.no_mmap }) catch |e| {
        out.problem = describe(e);
        return .{ .outcome = out };
    };
    defer in.close(io, gpa);
    out.bytes = in.size;
    if (utf16Conflict(&in, cfg)) |p| {
        out.problem = p;
        return .{ .outcome = out };
    }
    const max_sample = @max(cfg.sample_bytes, 16 << 20);
    while (!in.eof and in.data().len < max_sample) try in.refill(io, gpa, in.base);
    const verdict = dialect.sniff(gpa, in.data(), in.eof, .{
        .pins = cfg.pins,
        .sample_bytes = cfg.sample_bytes,
        .max_sample = max_sample,
        .utf8 = cfg.encoding == .utf8,
    }) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => {
            out.problem = describe(e);
            return .{ .outcome = out };
        },
    };
    out.timing.sniff_ns = since(io, t0);
    if (verdict.confidence == .low and !cfg.pins.complete()) {
        out.problem = "the dialect is not settled (confidence low); pin it with --delimiter, --quote, --escape, --newline and --header";
        return .{ .outcome = out };
    }

    const t1 = now(io);
    var f: infer.Inferrer = .init(arena, .{
        .nulls = nulls,
        .encoding = encodingOf(cfg),
        .day_first = cfg.day_first,
    });
    var s: records.Scanner = try .init(gpa, verdict.dialect, .{
        .reference = .{ .start = verdict.start, .keep_empty = cfg.keep_empty },
        .positions_buffer = env.positions,
    });
    defer s.deinit();
    s.feed(in.data(), in.base, in.eof);
    var batch: records.Batch = .{};
    defer batch.deinit(gpa);
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(gpa);
    var values: std.ArrayList([]const u8) = .empty;
    defer values.deinit(gpa);
    var header_pending = verdict.dialect.header;
    if (!header_pending) try f.header(null, verdict.fields);
    var header_names: []const []const u8 = &.{};
    var repeated: u64 = 0;
    var repeated_line: u64 = 0;
    const limit = cfg.sample_rows orelse std.math.maxInt(u64);
    read: while (f.rows < limit) {
        batch.clear();
        const state = try batch.fill(gpa, &s, .{});
        for (0..batch.len()) |i| {
            if (f.rows >= limit) break :read;
            if (batch.records.items[i].problem != null) continue;
            try records.values(gpa, batch.recordFields(i), in.data(), in.base, verdict.dialect, &scratch, &values);
            if (header_pending) {
                header_pending = false;
                try f.header(values.items, values.items.len);
                const names = try arena.alloc([]const u8, values.items.len);
                for (names, values.items) |*n, h| n.* = try arena.dupe(u8, std.mem.trim(u8, h, " \t"));
                header_names = names;
                continue;
            }
            const rec = batch.records.items[i];
            if (header_names.len > 0 and sameNames(values.items, header_names)) {
                if (repeated == 0) repeated_line = rec.line;
                repeated += 1;
                continue;
            }
            f.line = rec.line;
            try f.record(values.items);
        }
        if (interrupt.requested()) return error.Interrupted;
        switch (state) {
            .full => {},
            .end => break,
            .need_more => {
                try in.refill(io, gpa, s.keepFrom());
                s.feed(in.data(), in.base, in.eof);
            },
        }
    }
    out.timing.parse_ns = since(io, t1);
    out.rows = f.rows;
    // Read as UTF-8 and not UTF-8: a guess of replace would turn every
    // accented letter of a Windows export into U+FFFD, so say what to do.
    for (f.columns.items) |c| if (c.invalid_utf8) {
        out.problem = try std.fmt.allocPrint(arena, "column '{s}' is not UTF-8 (row {d}); read the file with --encoding cp1252 (Windows) or latin1", .{ c.name, c.invalid_row });
        return .{ .outcome = out };
    };
    out.result = .pass;
    return .{ .outcome = out, .columns = f.columns.items, .header = verdict.dialect.header, .repeated_headers = repeated, .repeated_line = repeated_line };
}

/// Whether a record's values are the header's names, trimmed and in any case.
fn sameNames(values: []const []const u8, names: []const []const u8) bool {
    if (values.len != names.len) return false;
    for (values, names) |v, n| if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, v, " \t"), n)) return false;
    return true;
}
