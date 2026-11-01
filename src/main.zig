//! thresh: works out a delimited file's dialect, validates every column
//! against a schema, and writes RFC 4180 CSV or Arrow IPC.
//!
//!   thresh sniff exports/*.txt --json
//!   thresh run inbox/*.csv --schema orders.schema.json --to arrow --out staged/
//!
//! This file is the entry point: arguments, subcommand dispatch and the
//! exit status. Each stage lives in its own file.

const std = @import("std");
const build_options = @import("build_options");
const cli = @import("cli.zig");
const dialect = @import("dialect.zig");
const report = @import("report.zig");
const problem = @import("problem.zig");
const types = @import("types.zig");
const Problem = problem.Problem;
const lib = @import("lib.zig");
const render = @import("render.zig");
const pool = @import("pool.zig");
const interrupt = @import("interrupt.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// The exit status, dateparsa's convention.
pub const Exit = enum(u8) {
    /// Every file passed.
    ok = 0,
    /// A file failed validation, but every file was processed.
    failed = 1,
    /// A file could not be read, or its dialect could not be settled.
    unreadable = 2,
    usage = 3,
    /// Ctrl-C, as shells number it (128 + SIGINT).
    interrupted = 130,

    /// The worse of two outcomes.
    fn worst(a: Exit, b: Exit) Exit {
        return if (@backingInt(b) > @backingInt(a)) b else a;
    }
};

pub fn main(init: std.process.Init) u8 {
    var out_buf: [1 << 16]u8 = undefined;
    var out = Io.File.stdout().writerStreaming(init.io, &out_buf);
    var err_buf: [4096]u8 = undefined;
    var err = Io.File.stderr().writerStreaming(init.io, &err_buf);
    const env: Env = .{ .io = init.io, .gpa = init.gpa, .arena = init.arena.allocator() };

    const code: Exit = blk: {
        const args = init.minimal.args.toSlice(env.arena) catch |e| break :blk e;
        break :blk execute(env, args[1..], &out.interface, &err.interface);
    } catch |e| blk: {
        const cause: anyerror = switch (e) {
            error.WriteFailed => out.err orelse e,
            else => e,
        };
        err.interface.print("thresh: {f}\n", .{Problem.of(cause)}) catch {};
        break :blk .unreadable;
    };
    out.interface.flush() catch |e| {
        err.interface.print("thresh: cannot write the output: {f}\n", .{Problem.of(out.err orelse e)}) catch {};
        err.interface.flush() catch {};
        return @backingInt(Exit.unreadable);
    };
    err.interface.flush() catch {};
    return @backingInt(code);
}

/// What the process works with, apart from its arguments and output.
const Env = struct {
    io: Io,
    gpa: Allocator,
    /// For what lasts the whole run: the arguments and the Config.
    arena: Allocator,
};

/// Runs what args ask for, writing to out and err, and returns the exit
/// status. An error is one about the run itself, not about one file.
fn execute(env: Env, args: []const []const u8, out: *Io.Writer, err: *Io.Writer) !Exit {
    var diag: cli.Diagnostic = .{};
    const action = cli.parse(env.arena, args, &diag) catch |e| switch (e) {
        error.Usage => {
            try err.print("thresh: {s}\n(thresh --help lists the commands and options)\n", .{diag.message});
            return .usage;
        },
        error.OutOfMemory => return e,
    };
    const cfg = switch (action) {
        .help => {
            try out.writeAll(cli.usage);
            return .ok;
        },
        .version => {
            try out.print("thresh {s}\n", .{build_options.version});
            return .ok;
        },
        .run => |cfg| cfg,
    };
    return switch (cfg.command) {
        .sniff => sniff(env, cfg, out, err),
        .validate => validateFiles(env, &cfg, out, err),
        .infer => inferFiles(env, &cfg, out, err),
        .run => validateFiles(env, &cfg, out, err),
        .convert => convertFiles(env, &cfg, out, err),
        .describe => describeFiles(env, &cfg, out, err),
    };
}

/// convert: against the schema given, or each file's own, inferred.
fn convertFiles(env: Env, cfg: *const cli.Config, out: *Io.Writer, err: *Io.Writer) !Exit {
    if (cfg.schema != null or cfg.columns != null) return validateFiles(env, cfg, out, err);
    return convertInferred(env, cfg, out, err);
}

/// describe: each file's description (lib.describe, files in parallel),
/// on stdout in the order given: indented, or a line apiece with --json,
/// which then is all stdout holds. The exit is the worst file's.
fn describeFiles(env: Env, cfg: *const cli.Config, out: *Io.Writer, err: *Io.Writer) !Exit {
    var owned: ?lib.OwnedSchema = if (cfg.schema != null or cfg.columns != null) (try loadSchema(env, cfg, err)) orelse return .usage else null;
    defer if (owned) |*o| o.deinit();
    const Ctx = struct {
        options: lib.Options,
        schema: ?*const lib.Schema,
        files: []const []const u8,
        texts: [][]const u8,
        compact: bool,

        fn run(ctx: *anyopaque, w: *pool.Worker, i: usize) anyerror!report.Outcome {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            const d = try lib.describe(w.env, w.scratch.allocator(), c.files[i], c.schema, c.options);
            // The text outlives the file: the run's arena.
            var text: Io.Writer.Allocating = .init(w.keep);
            lib.writeDescription(&text.writer, d, c.compact) catch return error.OutOfMemory;
            c.texts[i] = text.written();
            return d.file.outcome;
        }
    };
    var ctx: Ctx = .{
        .options = try optionsOf(env.arena, cfg),
        .schema = if (owned) |*o| &o.schema else null,
        .files = cfg.files,
        .texts = try env.arena.alloc([]const u8, cfg.files.len),
        .compact = cfg.json,
    };
    @memset(ctx.texts, "");
    const outcomes = try runPool(env, cfg, .{ .ctx = &ctx, .files = cfg.files, .run = Ctx.run }, out, err, cfg.json);
    if (interrupt.requested()) return interrupted(err);
    for (ctx.texts) |t| try out.writeAll(t);
    var code: Exit = .ok;
    for (outcomes) |o| code = code.worst(@fromBackingInt(o.result.exitCode()));
    return code;
}

/// How each file is read, from the flags; Ctrl-C (interrupt) cancels.
fn optionsOf(a: Allocator, cfg: *const cli.Config) Allocator.Error!lib.Options {
    var nulls: std.ArrayList([]const u8) = .empty;
    if (cfg.nulls) |list| {
        var it = std.mem.splitScalar(u8, list, ',');
        while (it.next()) |n| try nulls.append(a, n);
    }
    return .{
        .pins = cfg.pins,
        .sample_bytes = cfg.sample_bytes,
        .encoding = cfg.encoding,
        .mmap = !cfg.no_mmap,
        .keep_empty = cfg.keep_empty,
        .day_first = cfg.day_first,
        .strict = cfg.strict,
        .ragged = cfg.ragged,
        .sample_rows = cfg.sample_rows,
        .nulls = nulls.items,
        .threshold = cfg.threshold,
        .cancel = &interrupt.flag,
        // A report is where they go.
        .stats = cfg.report_dir != null,
        .shapes = if (cfg.shape_names) .names else if (cfg.shapes_only) .values else .none,
    };
}

/// The schema --schema or --columns names; null, with the reason printed,
/// when it cannot be read.
fn loadSchema(env: Env, cfg: *const cli.Config, err: *Io.Writer) !?lib.OwnedSchema {
    var diag: lib.SchemaDiagnostic = .{};
    if (cfg.columns) |spec| return lib.parseColumns(env.gpa, spec, &diag) catch |e| switch (e) {
        error.InvalidSchema => {
            try err.print("thresh: {s}\n", .{diag.message});
            return null;
        },
        error.OutOfMemory => return e,
    };
    const path = cfg.schema.?;
    return lib.loadSchema(env.io, env.gpa, path, &diag) catch |e| switch (e) {
        error.InvalidSchema => {
            try err.print("thresh: {s}: {s}\n", .{ path, diag.message });
            return null;
        },
        error.OutOfMemory => return e,
        else => {
            try err.print("thresh: {s}: {f}\n", .{ path, Problem.of(e) });
            return null;
        },
    };
}

/// infer: each file's columns (in parallel, pass 1), merged by name into
/// one schema (lib.merge), written to --out or stdout. On stderr, a line
/// per file and the notes that follow it, in the order the files were
/// given, then the run's.
fn inferFiles(env: Env, cfg: *const cli.Config, out: *Io.Writer, err: *Io.Writer) !Exit {
    const a = env.arena;
    const Ctx = struct {
        options: lib.Options,
        files: []const []const u8,
        results: []lib.Columns,

        fn run(ctx: *anyopaque, w: *pool.Worker, i: usize) anyerror!report.Outcome {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            // The columns outlive the file: the worker's keep arena.
            c.results[i] = try lib.inferFile(w.env, w.keep, c.files[i], c.options);
            return c.results[i].outcome;
        }
    };
    var ctx: Ctx = .{
        .options = try optionsOf(a, cfg),
        .files = cfg.files,
        .results = try a.alloc(lib.Columns, cfg.files.len),
    };
    for (ctx.results, cfg.files) |*r, f| r.* = .{ .outcome = .{ .file = f, .result = .@"error", .problem = .not_reached } };
    const outcomes = try runPool(env, cfg, .{ .ctx = &ctx, .files = cfg.files, .run = Ctx.run }, out, err, true);
    if (interrupt.requested()) return interrupted(err);
    // What the run made of each file, a failure included.
    for (ctx.results, outcomes) |*r, o| r.outcome = o;

    // What is said of the files: as shapes, when asked.
    const said = try lib.shaped(a, ctx.results, try lib.merge(a, ctx.results, ctx.options), ctx.options.shapes);
    const m = said.merged;
    var code = try sayFiles(err, cfg.quiet, said);
    if (m.stop) |p| {
        try err.print("thresh: {f}\n", .{p});
        return code.worst(.unreadable);
    }
    if (!cfg.quiet) try printNotes(err, m.notes, null);
    if (m.disagreement) |p| {
        try err.print("thresh: {f}\n", .{p});
        code = code.worst(.failed);
    }
    const s = m.schema.?;
    if (cfg.out) |path| {
        var buf: [1 << 16]u8 = undefined;
        const file = try Io.Dir.cwd().createFile(env.io, path, .{});
        defer file.close(env.io);
        var fw = file.writer(env.io, &buf);
        try lib.writeSchema(s, &fw.interface);
        try fw.interface.flush();
    } else try lib.writeSchema(s, out);
    return code;
}

/// infer's line for each file on stderr, and the notes that follow it;
/// the worst exit of them.
fn sayFiles(err: *Io.Writer, quiet: bool, said: lib.Shaped) !Exit {
    var code: Exit = .ok;
    for (said.files, 0..) |r, i| {
        const path = r.outcome.file;
        if (r.outcome.result == .@"error") {
            code = code.worst(.unreadable);
            if (!quiet) try err.print("error {s}  {?f}\n", .{ path, r.outcome.problem });
            continue;
        }
        if (quiet) continue;
        try err.print("infer {s}  {d} rows  {d} columns\n", .{ path, r.outcome.rows, r.columns.len });
        try printNotes(err, said.merged.notes, i);
    }
    return code;
}

/// The notes that follow file after, or with null the run's.
fn printNotes(err: *Io.Writer, notes: []const lib.Note, after: ?usize) !void {
    for (notes) |n| if (n.after == after) try printNote(err, n);
}

/// A note of infer's: its file first, unless the problem names it.
fn printNote(err: *Io.Writer, n: lib.Note) !void {
    if (n.file) |f| return err.print("thresh: {s}: {f}\n", .{ f, n.problem });
    try err.print("thresh: {f}\n", .{n.problem});
}

fn outputOf(cfg: *const cli.Config) ?render.OutputPlan {
    return switch (cfg.command) {
        .convert, .run => .{
            .to = switch (cfg.to.?) {
                .csv => .csv,
                .arrow => .arrow,
                // cli.parse refuses it.
                .parquet => unreachable,
            },
            .dir = cfg.out.?,
            .arrow_file = cfg.arrow_file,
            .delimiter = cfg.out_delimiter,
            .newline = cfg.out_newline,
            .normalize_dates = cfg.normalize_dates,
        },
        else => null,
    };
}

/// convert with no schema: each file's own, inferred from all of it
/// (pass 1), then the file read again and written through validation
/// (pass 2), the page cache making the second read cheap.
fn convertInferred(env: Env, cfg: *const cli.Config, out: *Io.Writer, err: *Io.Writer) !Exit {
    const Ctx = struct {
        cfg: *const cli.Config,
        options: lib.Options,
        names: []const []const u8,

        fn run(ctx: *anyopaque, w: *pool.Worker, i: usize) anyerror!report.Outcome {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            const a = w.scratch.allocator();
            const path = c.cfg.files[i];
            const inferred = try lib.inferFile(w.env, a, path, c.options);
            if (inferred.outcome.result == .@"error") return inferred.outcome;
            // The schema infer would write for this file alone.
            const s = try a.create(lib.Schema);
            s.* = (try lib.merge(a, &.{inferred}, c.options)).schema.?;
            const plan: render.Plan = .{
                .options = c.options,
                .schema = s,
                .output = outputOf(c.cfg),
                .report_dir = c.cfg.report_dir,
                .reject_dir = c.cfg.reject_dir,
            };
            return render.validateNamed(w.env, plan, path, c.names[i], a);
        }
    };
    var ctx: Ctx = .{
        .cfg = cfg,
        .options = try optionsOf(env.arena, cfg),
        .names = try pool.uniqueNames(env.arena, cfg.files),
    };
    const outcomes = try runPool(env, cfg, .{ .ctx = &ctx, .files = cfg.files, .run = Ctx.run }, out, err, false);
    return finishRun(env, cfg, outcomes, err);
}

/// validate, and run and convert with a schema: each file against it,
/// in parallel, a line apiece on stderr as each finishes (or a JSON object
/// on stdout under --json), reports, reject files and output as asked.
fn validateFiles(env: Env, cfg: *const cli.Config, out: *Io.Writer, err: *Io.Writer) !Exit {
    var owned = (try loadSchema(env, cfg, err)) orelse return .usage;
    defer owned.deinit();
    const s = &owned.schema;
    const Ctx = struct {
        plan: render.Plan,
        files: []const []const u8,
        names: []const []const u8,

        fn run(ctx: *anyopaque, w: *pool.Worker, i: usize) anyerror!report.Outcome {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            return render.validateNamed(w.env, c.plan, c.files[i], c.names[i], w.scratch.allocator());
        }
    };
    var ctx: Ctx = .{
        .plan = .{
            .options = try optionsOf(env.arena, cfg),
            .schema = s,
            .output = outputOf(cfg),
            .report_dir = cfg.report_dir,
            .reject_dir = cfg.reject_dir,
        },
        .files = cfg.files,
        .names = try pool.uniqueNames(env.arena, cfg.files),
    };
    const outcomes = try runPool(env, cfg, .{ .ctx = &ctx, .files = cfg.files, .run = Ctx.run }, out, err, false);
    return finishRun(env, cfg, outcomes, err);
}

/// Runs task over the files on --jobs workers, with Ctrl-C routed to the
/// workers and, with --progress, a progress display. silent: the task's
/// command prints its own lines afterwards.
fn runPool(env: Env, cfg: *const cli.Config, task: pool.Task, out: *Io.Writer, err: *Io.Writer, silent: bool) ![]report.Outcome {
    interrupt.install();
    const outcomes = try env.arena.alloc(report.Outcome, cfg.files.len);
    var lines: pool.Lines = .{
        .err = err,
        .out = out,
        .json = cfg.json and !silent,
        // The progress display has stderr; a line per file would tear it.
        .quiet = silent or cfg.quiet or cfg.progress,
    };
    const progress: std.Progress.Node = if (cfg.progress)
        std.Progress.start(env.io, .{ .root_name = "thresh", .estimated_total_items = cfg.files.len })
    else
        .none;
    defer progress.end();
    const jobs = jobsFor(cfg.jobs, std.Thread.getCpuCount() catch 1, cfg.files.len);
    if (jobs.capped and !cfg.quiet) try err.print("thresh: --jobs {d}: capped at {d} a CPU, since each worker holds a thread and a 4 MiB index\n", .{ cfg.jobs.?, max_jobs_per_cpu });
    try pool.run(env.io, env.gpa, task, outcomes, &lines, .{
        .jobs = jobs.n,
        .progress = progress,
        .keep = env.arena,
    });
    return outcomes;
}

/// The most workers a CPU gets, whatever --jobs asks: each holds a thread
/// and a 4 MiB index from the start, so --jobs 1000 would commit 4 GB.
const max_jobs_per_cpu = 4;

/// The workers a run gets: --jobs, or a CPU apiece, no more than files or
/// max_jobs_per_cpu a CPU. capped: --jobs asked for more than that allows.
fn jobsFor(requested: ?usize, cpus: usize, inputs: usize) struct { n: usize, capped: bool } {
    const want = @min(requested orelse cpus, inputs);
    const most = max_jobs_per_cpu * cpus;
    return .{ .n = @max(1, @min(want, most)), .capped = want > most };
}

test jobsFor {
    try std.testing.expectEqual(@as(usize, 8), jobsFor(null, 8, 100).n);
    try std.testing.expectEqual(@as(usize, 3), jobsFor(null, 8, 3).n);
    try std.testing.expectEqual(@as(usize, 20), jobsFor(20, 8, 100).n);
    const big = jobsFor(1000, 8, 1000);
    try std.testing.expectEqual(@as(usize, 32), big.n);
    try std.testing.expect(big.capped);
    // Asked for more workers than files: no more workers than files, and
    // nothing capped that the files would not have.
    try std.testing.expect(!jobsFor(1000, 8, 10).capped);
}

/// summary.json with --report, and the run's exit status.
fn finishRun(env: Env, cfg: *const cli.Config, outcomes: []const report.Outcome, err: *Io.Writer) !Exit {
    if (interrupt.requested()) return interrupted(err);
    var code: Exit = .ok;
    for (outcomes) |o| code = code.worst(@fromBackingInt(o.result.exitCode()));
    if (cfg.report_dir) |dir| {
        var sink: render.Sink = try .create(env.io, env.gpa, dir, "summary", ".json");
        defer sink.close(env.io, env.gpa);
        try report.writeSummary(&sink.writer.interface, outcomes, @backingInt(code));
        try sink.writer.interface.flush();
    }
    if (cfg.progress and !cfg.quiet) {
        var counts: std.EnumArray(report.Result, usize) = .initFill(0);
        for (outcomes) |o| counts.getPtr(o.result).* += 1;
        try err.print("thresh: {d} files: {d} passed, {d} failed, {d} errors\n", .{ outcomes.len, counts.get(.pass), counts.get(.fail), counts.get(.@"error") });
    }
    return code;
}

fn interrupted(err: *Io.Writer) !Exit {
    try err.writeAll("thresh: interrupted; files not finished left no output\n");
    return .interrupted;
}

/// Each file's dialect, a line apiece: text, or JSON under --json.
fn sniff(env: Env, cfg: cli.Config, out: *Io.Writer, err: *Io.Writer) !Exit {
    var code: Exit = .ok;
    const options = try optionsOf(env.arena, &cfg);
    for (cfg.files) |path| {
        const sniffed = try lib.sniff(.{ .io = env.io, .gpa = env.gpa }, path, options);
        const v = sniffed.verdict orelse {
            try err.print("thresh: {s}: {f}\n", .{ path, sniffed.outcome.problem.? });
            code = code.worst(.unreadable);
            continue;
        };
        const stop = sniffed.outcome.problem;
        if (cfg.json) {
            try report.writeSniffLine(out, try types.asUtf8(env.arena, path), v, if (stop) |*p| p[0..1] else &.{});
        } else {
            try out.print("{s}: {f} confidence={t}", .{ path, v.dialect, v.confidence });
            if (@as(u8, @bitCast(v.warnings)) != 0) {
                try out.writeAll(" warnings=");
                var first = true;
                inline for (dialect.Warnings.names) |name| {
                    if (@field(v.warnings, name)) {
                        if (!first) try out.writeByte(',');
                        try out.writeAll(name);
                        first = false;
                    }
                }
            }
            try out.writeByte('\n');
        }
        if (stop) |p| {
            try err.print("thresh: {s}: {f}\n", .{ path, p });
            code = code.worst(.unreadable);
        }
    }
    return code;
}

test {
    _ = cli;
    _ = dialect;
    _ = @import("records.zig");
    _ = @import("reference.zig");
    _ = @import("scan.zig");
    _ = @import("input.zig");
    _ = @import("schema.zig");
    _ = @import("types.zig");
    _ = @import("validate.zig");
    _ = @import("write/csv.zig");
    _ = @import("write/arrow.zig");
    _ = @import("write/arrow_c.zig");
    _ = @import("write/flatbuf.zig");
    _ = @import("builders.zig");
    _ = @import("stats.zig");
    _ = @import("shapes.zig");
    _ = report;
    _ = problem;
    _ = @import("problems_doc_test.zig");
    _ = @import("format_test.zig");
    _ = @import("worker.zig");
    _ = render;
    _ = @import("infer.zig");
    _ = lib;
    _ = pool;
    _ = interrupt;
    _ = @import("types/date.zig");
}

/// What one run of the CLI said: stdout, stderr and every file it wrote
/// into the report directory, end to end.
fn everythingSaid(tmp: std.testing.TmpDir, args: []const []const u8) ![]const u8 {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    var err: Io.Writer.Allocating = .init(t.allocator);
    defer err.deinit();
    _ = try execute(.{ .io = t.io, .gpa = t.allocator, .arena = a }, args, &out.writer, &err.writer);
    var all: std.ArrayList(u8) = .empty;
    try all.appendSlice(t.allocator, out.written());
    try all.appendSlice(t.allocator, err.written());
    for ([_][]const u8{ "reports/markers.csv.report.json", "reports/summary.json", "markers.schema.json" }) |name| {
        const text = tmp.dir.readFileAlloc(t.io, name, a, .limited(1 << 20)) catch continue;
        try all.appendSlice(t.allocator, text);
        try tmp.dir.deleteFile(t.io, name);
    }
    return all.toOwnedSlice(t.allocator);
}

test "--shapes-only: none of a file's values leaves thresh; --shape-names, none of its names" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    // Every field holds a marker: the names qxname, the values qxval or
    // 777, in samples, rejected lines, statistics and problems.
    var data: Io.Writer.Allocating = .init(t.allocator);
    defer data.deinit();
    try data.writer.writeAll("qxname_id,qxname_kg,qxname_day,qxname_word\n");
    // Enough whole rows that the dialect is settled.
    for (0..20) |i| try data.writer.print("{d},777999{d}.25,2026-09-{d:0>2},qxvalone\n", .{ i + 10, i, i % 28 + 1 });
    try data.writer.writeAll("2,777999.50,2026-09-15,qxvalone\n" ++
        "bad777999,18.00,2026-09-16,qxvaltwo\n" ++
        "4,19.50,qxvalnotaday,qxvalthree\n" ++
        "5,20.00,2026-09-17,\"qxval, quoted\"\n" ++
        "6,21.00,2026-09-18,qxvalone,qxvalextra\n");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "markers.csv", .data = data.written() });
    var buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var paths: [4][]const u8 = undefined;
    var names: [4][128]u8 = undefined;
    for ([_][]const u8{ "markers.csv", "reports", "out", "markers.schema.json" }, &paths, &names) |n, *p, *b| p.* = try std.fmt.bufPrint(b, "{s}/{s}", .{ dir, n });
    const file, const reports, const outdir, const schema_out = paths;
    // One column the file lacks: a problem that names it.
    const columns = "qxname_id:int64,qxname_kg:decimal(9,2),qxname_day:date,qxname_word:string,qxname_gone:string";
    const runs = [_][]const []const u8{
        &.{ "validate", file, "--columns", columns, "--report", reports, "--json" },
        &.{ "run", file, "--columns", columns[0 .. columns.len - ",qxname_gone:string".len], "--to", "csv", "--out", outdir, "--report", reports },
        &.{ "infer", file, "--out", schema_out },
        &.{ "infer", file },
        &.{ "sniff", file, "--json" },
        &.{ "describe", file },
        &.{ "describe", file, "--columns", columns, "--json" },
    };
    for (runs) |args| {
        // Without the flags the markers are there: the test sees them.
        const plain = try everythingSaid(tmp, args);
        defer t.allocator.free(plain);
        if (std.mem.find(u8, plain, "qxname") == null and !std.mem.eql(u8, args[0], "sniff")) {
            std.debug.print("{s}: no names in what it said:\n{s}\n", .{ args[0], plain[0..@min(plain.len, 600)] });
            return error.TestUnexpectedResult;
        }
        if (!std.mem.eql(u8, args[0], "sniff")) try t.expect(std.mem.find(u8, plain, "qxval") != null);

        var with: [16][]const u8 = undefined;
        for ([_][]const u8{ "--shapes-only", "--shape-names" }) |flag| {
            @memcpy(with[0..args.len], args);
            with[args.len] = flag;
            const shaped = try everythingSaid(tmp, with[0 .. args.len + 1]);
            defer t.allocator.free(shaped);
            for ([_][]const u8{ "qxval", "777999" }) |marker| if (std.mem.find(u8, shaped, marker)) |at| {
                std.debug.print("{s} {s}: {s} at {d}: {s}\n", .{ args[0], flag, marker, at, shaped[at -| 80..@min(shaped.len, at + 40)] });
                return error.TestUnexpectedResult;
            };
            if (std.mem.eql(u8, flag, "--shape-names")) if (std.mem.find(u8, shaped, "qxname")) |at| {
                std.debug.print("{s} {s}: a name at {d}: {s}\n", .{ args[0], flag, at, shaped[at -| 80..@min(shaped.len, at + 40)] });
                return error.TestUnexpectedResult;
            };
        }
    }
}

test "describe --json: stdout is a description a line, one a file, in their order" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    var err: Io.Writer.Allocating = .init(t.allocator);
    defer err.deinit();
    const files = [_][]const u8{ "test/c/lugs.csv", "test/cli/orders.csv", "test/c/none.csv" };
    const code = try execute(.{ .io = t.io, .gpa = t.allocator, .arena = a }, &.{ "describe", files[0], files[1], files[2], "--json" }, &out.writer, &err.writer);
    try t.expectEqual(Exit.unreadable, code);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out.written(), "\n"), '\n');
    for (files) |f| {
        const d = try std.json.parseFromSliceLeaky(std.json.Value, a, lines.next().?, .{});
        try t.expectEqualStrings(f, d.object.get("file").?.string);
    }
    try t.expectEqual(@as(?[]const u8, null), lines.next());
}

test "worst keeps the higher status" {
    try std.testing.expectEqual(Exit.unreadable, Exit.ok.worst(.unreadable));
    try std.testing.expectEqual(Exit.unreadable, Exit.unreadable.worst(.failed));
}
