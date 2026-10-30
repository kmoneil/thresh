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
const input = @import("input.zig");
const schema = @import("schema.zig");
const report = @import("report.zig");
const worker = @import("worker.zig");
const infer = @import("infer.zig");
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
        err.interface.print("thresh: {s}\n", .{worker.describe(cause)}) catch {};
        break :blk .unreadable;
    };
    out.interface.flush() catch |e| {
        err.interface.print("thresh: cannot write the output: {s}\n", .{worker.describe(out.err orelse e)}) catch {};
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
        .convert => if (cfg.schema != null or cfg.columns != null)
            validateFiles(env, &cfg, out, err)
        else
            convertInferred(env, &cfg, out, err),
    };
}

/// The schema --schema or --columns names; null, with the reason printed,
/// when it cannot be read.
fn loadSchema(env: Env, cfg: *const cli.Config, err: *Io.Writer) !?schema.Owned {
    var diag: schema.Diagnostic = .{};
    if (cfg.columns) |spec| return schema.parseInline(env.gpa, spec, &diag) catch |e| switch (e) {
        error.InvalidSchema => {
            try err.print("thresh: {s}\n", .{diag.message});
            return null;
        },
        error.OutOfMemory => return e,
    };
    const path = cfg.schema.?;
    return schema.load(env.io, env.gpa, path, &diag) catch |e| switch (e) {
        error.InvalidSchema => {
            try err.print("thresh: {s}: {s}\n", .{ path, diag.message });
            return null;
        },
        error.OutOfMemory => return e,
        else => {
            try err.print("thresh: {s}: {s}\n", .{ path, worker.describe(e) });
            return null;
        },
    };
}

/// infer: each file's columns (in parallel, pass 1), merged by name into
/// one schema (the lowest type any file reached), written to --out or
/// stdout. A line per file on stderr, and one per column a later file
/// widened, in the order the files were given.
fn inferFiles(env: Env, cfg: *const cli.Config, out: *Io.Writer, err: *Io.Writer) !Exit {
    const a = env.arena;
    const default_nulls: schema.Schema = .{ .columns = &.{} };
    const Ctx = struct {
        cfg: *const cli.Config,
        nulls: []const []const u8,
        results: []worker.Inferred,

        fn run(ctx: *anyopaque, w: *pool.Worker, i: usize) anyerror!report.Outcome {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            // The columns outlive the file: the worker's keep arena.
            c.results[i] = try worker.inferFile(w.env, c.cfg, c.nulls, c.cfg.files[i], w.keep);
            return c.results[i].outcome;
        }
    };
    var ctx: Ctx = .{
        .cfg = cfg,
        .nulls = try worker.nullsOf(a, &default_nulls, cfg.nulls),
        .results = try a.alloc(worker.Inferred, cfg.files.len),
    };
    for (ctx.results, cfg.files) |*r, f| r.* = .{ .outcome = .{ .file = f, .result = .@"error", .problem = "not reached" } };
    const outcomes = try runPool(env, cfg, .{ .ctx = &ctx, .files = cfg.files, .run = Ctx.run }, out, err, true);
    if (interrupt.requested()) return interrupted(err);

    var merged: std.ArrayList(infer.ColumnState) = .empty;
    var all_headers = true;
    var code: Exit = .ok;
    for (ctx.results, outcomes, cfg.files) |r, o, path| {
        if (o.result == .@"error") {
            code = code.worst(.unreadable);
            if (!cfg.quiet) try err.print("error {s}  {s}\n", .{ path, o.problem orelse "" });
            continue;
        }
        if (!r.header) all_headers = false;
        if (!cfg.quiet) try err.print("infer {s}  {d} rows  {d} columns\n", .{ path, o.rows, r.columns.len });
        if (r.repeated_headers > 0 and !cfg.quiet)
            try err.print("thresh: {s}: {s}\n", .{ path, try worker.repeatedHeader(a, r.repeated_line, r.repeated_headers) });
        const columns = try a.dupe(infer.ColumnState, r.columns);
        for (columns) |*c| try restOf(err, cfg, path, c);
        for (columns) |c| {
            for (merged.items) |*m| {
                if (!std.ascii.eqlIgnoreCase(m.name, c.name)) continue;
                const before = m.kind;
                infer.merge(m, c, path);
                if (m.kind != before and before != .null and !cfg.quiet)
                    try err.print("thresh: column '{s}': {t} until {s} made it {t}\n", .{ m.name, before, path, m.kind });
                break;
            } else try merged.append(a, c);
        }
    }
    if (merged.items.len == 0) {
        try err.print("thresh: no file to infer a schema from\n", .{});
        return code.worst(.unreadable);
    }
    const s: schema.Schema = .{
        .columns = try infer.columnsOf(a, merged.items),
        .nulls = ctx.nulls,
        .match = if (all_headers) .name else .position,
        .sampled = if (cfg.sample_rows != null) true else null,
        // The threshold the types were inferred to: what validate needs
        // to pass this file again.
        .threshold = cfg.threshold,
    };
    if (!cfg.quiet) try warnThin(err, merged.items, s.columns);
    if (cfg.out) |path| {
        var buf: [1 << 16]u8 = undefined;
        const file = try Io.Dir.cwd().createFile(env.io, path, .{});
        defer file.close(env.io);
        var fw = file.writer(env.io, &buf);
        try schema.writeJson(s, &fw.interface);
        try fw.interface.flush();
    } else try schema.writeJson(s, out);
    return code;
}

/// What a column's rest says: under --threshold, that it took the rest's
/// type, those values its rejected ones; without, when few values moved
/// it, which type the rest fit and the --threshold that would take it.
fn restOf(err: *Io.Writer, cfg: *const cli.Config, path: []const u8, c: *infer.ColumnState) !void {
    const rest = infer.restType(c.*) orelse return;
    const rows = c.values + c.nulls;
    const misfits = c.misfits;
    const row = c.misfit_row;
    if (cfg.threshold) |t| if (infer.tolerate(c, t)) {
        if (!cfg.quiet) try err.print("thresh: {s}: column '{s}' inferred {t} with {d} of {d} values refusing it (row {d} first), as --threshold allows: validate rejects them\n", .{ path, c.name, rest, misfits, rows, row });
        return;
    };
    if (cfg.quiet or !infer.fewMisfits(c.*)) return;
    // The threshold that takes the rest's type, to four places.
    const fit = @floor((1.0 - @as(f64, @floatFromInt(misfits)) / @as(f64, @floatFromInt(rows))) * 10_000) / 10_000;
    try err.print("thresh: {s}: column '{s}' is {t} because of {d} of {d} values (row {d} first); the rest are {t}: --threshold {d} infers {t} and rejects them\n", .{ path, c.name, infer.typeOf(c.*), misfits, rows, row, rest, fit, rest });
}

/// Names the typed columns read from too few values to trust, the first
/// five, so the schema is looked at before the next file is held to it.
fn warnThin(err: *Io.Writer, states: []const infer.ColumnState, cols: []const schema.Column) !void {
    var n: usize = 0;
    for (states, cols) |st, c| {
        if (!infer.thin(st, c)) continue;
        if (n < 5) try err.print("{s}{s}", .{ if (n == 0) "thresh: " else ", ", c.name });
        n += 1;
    }
    if (n == 0) return;
    if (n > 5) try err.print(" and {d} more", .{n - 5});
    try err.print(": typed from fewer than {d} values; check {s} before reusing the schema\n", .{ infer.few_values, if (n == 1) "it" else "them" });
}

fn outputOf(cfg: *const cli.Config) ?worker.OutputPlan {
    return switch (cfg.command) {
        .convert, .run => .{ .to = cfg.to.?, .dir = cfg.out.? },
        else => null,
    };
}

/// convert with no schema: each file's own, inferred from all of it
/// (pass 1), then the file read again and written through validation
/// (pass 2), the page cache making the second read cheap.
fn convertInferred(env: Env, cfg: *const cli.Config, out: *Io.Writer, err: *Io.Writer) !Exit {
    const no_schema: schema.Schema = .{ .columns = &.{} };
    const Ctx = struct {
        cfg: *const cli.Config,
        nulls: []const []const u8,
        names: []const []const u8,

        fn run(ctx: *anyopaque, w: *pool.Worker, i: usize) anyerror!report.Outcome {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            const a = w.scratch.allocator();
            const path = c.cfg.files[i];
            const inferred = try worker.inferFile(w.env, c.cfg, c.nulls, path, a);
            if (inferred.outcome.result == .@"error") return inferred.outcome;
            const columns = try a.dupe(infer.ColumnState, inferred.columns);
            if (c.cfg.threshold) |t| for (columns) |*col| {
                _ = infer.tolerate(col, t);
            };
            const s = try a.create(schema.Schema);
            s.* = .{
                .columns = try infer.columnsOf(a, columns),
                .nulls = c.nulls,
                .match = if (inferred.header) .name else .position,
            };
            const plan: worker.Plan = .{
                .cfg = c.cfg,
                .schema = s,
                .nulls = c.nulls,
                .threshold = c.cfg.threshold orelse 1.0,
                .output = outputOf(c.cfg),
            };
            return worker.validateNamed(w.env, plan, path, c.names[i], a);
        }
    };
    var ctx: Ctx = .{
        .cfg = cfg,
        .nulls = try worker.nullsOf(env.arena, &no_schema, cfg.nulls),
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
        plan: worker.Plan,
        names: []const []const u8,

        fn run(ctx: *anyopaque, w: *pool.Worker, i: usize) anyerror!report.Outcome {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            return worker.validateNamed(w.env, c.plan, c.plan.cfg.files[i], c.names[i], w.scratch.allocator());
        }
    };
    var ctx: Ctx = .{
        .plan = .{
            .cfg = cfg,
            .schema = s,
            .nulls = try worker.nullsOf(env.arena, s, cfg.nulls),
            .threshold = cfg.threshold orelse s.threshold orelse 1.0,
            .output = outputOf(cfg),
        },
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
    const cpus = std.Thread.getCpuCount() catch 1;
    try pool.run(env.io, env.gpa, task, outcomes, &lines, .{
        .jobs = cfg.jobs orelse cpus,
        .progress = progress,
        .keep = env.arena,
    });
    return outcomes;
}

/// summary.json with --report, and the run's exit status.
fn finishRun(env: Env, cfg: *const cli.Config, outcomes: []const report.Outcome, err: *Io.Writer) !Exit {
    if (interrupt.requested()) return interrupted(err);
    var code: Exit = .ok;
    for (outcomes) |o| code = code.worst(@fromBackingInt(o.result.exitCode()));
    if (cfg.report_dir) |dir| {
        var sink: worker.Sink = try .create(env.io, env.gpa, dir, "summary", ".json");
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
    for (cfg.files) |path| {
        const v = sniffFile(env, cfg, path) catch |e| {
            try err.print("thresh: {s}: {s}\n", .{ path, worker.describe(e) });
            code = code.worst(.unreadable);
            continue;
        };
        if (cfg.json) {
            try std.json.Stringify.value(.{ .file = path, .dialect = v, .warnings = v.warnings }, .{}, out);
            try out.writeByte('\n');
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
        if (v.confidence == .low and !cfg.pins.complete()) {
            try err.print("thresh: {s}: the dialect is not settled (confidence low, score {d:.2}); pin it with --delimiter, --quote, --escape, --newline and --header\n", .{ path, v.score });
            code = code.worst(.unreadable);
        }
    }
    return code;
}

/// The file's dialect, from as much of its start as the sniffer may want.
fn sniffFile(env: Env, cfg: cli.Config, path: []const u8) !dialect.Verdict {
    const max_sample = @max(cfg.sample_bytes, 16 << 20);
    var in: input.Input = try .open(env.io, env.gpa, path, .{ .no_mmap = cfg.no_mmap, .buffer = cfg.sample_bytes });
    defer in.close(env.io, env.gpa);
    while (!in.eof and in.data().len < max_sample) try in.refill(env.io, env.gpa, in.base);
    var v = try dialect.sniff(env.gpa, in.data(), in.eof, .{
        .pins = cfg.pins,
        .sample_bytes = cfg.sample_bytes,
        .max_sample = max_sample,
        .utf8 = cfg.encoding == .utf8 or in.utf16 != null,
    });
    v.warnings.utf16 = in.utf16 != null;
    return v;
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
    _ = @import("write/flatbuf.zig");
    _ = @import("builders.zig");
    _ = report;
    _ = worker;
    _ = infer;
    _ = pool;
    _ = interrupt;
    _ = @import("types/date.zig");
}

test "worst keeps the higher status" {
    try std.testing.expectEqual(Exit.unreadable, Exit.ok.worst(.unreadable));
    try std.testing.expectEqual(Exit.unreadable, Exit.unreadable.worst(.failed));
}
