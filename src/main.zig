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
        err.interface.print("thresh: {s}\n", .{describe(cause)}) catch {};
        break :blk .unreadable;
    };
    out.interface.flush() catch |e| {
        err.interface.print("thresh: cannot write the output: {s}\n", .{describe(out.err orelse e)}) catch {};
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

/// infer: each file's columns, merged by name into one schema (the lowest
/// type any file reached), written to --out or stdout. A line per file on
/// stderr, and one per column a later file widened.
fn inferFiles(env: Env, cfg: *const cli.Config, out: *Io.Writer, err: *Io.Writer) !Exit {
    const a = env.arena;
    const default_nulls: schema.Schema = .{ .columns = &.{} };
    const nulls = try worker.nullsOf(a, &default_nulls, cfg.nulls);
    var merged: std.ArrayList(infer.ColumnState) = .empty;
    var all_headers = true;
    var code: Exit = .ok;
    var rows: u64 = 0;
    for (cfg.files) |path| {
        const r = try worker.inferFile(.{ .io = env.io, .gpa = env.gpa }, cfg, nulls, path, a);
        if (r.outcome.result == .@"error") {
            code = code.worst(.unreadable);
            if (!cfg.quiet) try err.print("error {s}  {s}\n", .{ path, r.outcome.problem orelse "" });
            continue;
        }
        rows += r.outcome.rows;
        if (!r.header) all_headers = false;
        if (!cfg.quiet) try err.print("infer {s}  {d} rows  {d} columns\n", .{ path, r.outcome.rows, r.columns.len });
        for (r.columns) |c| {
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
        .nulls = nulls,
        .match = if (all_headers) .name else .position,
        .sampled = if (cfg.sample_rows != null) true else null,
    };
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
    const a = env.arena;
    const no_schema: schema.Schema = .{ .columns = &.{} };
    const nulls = try worker.nullsOf(a, &no_schema, cfg.nulls);
    var outcomes: std.ArrayList(report.Outcome) = .empty;
    var code: Exit = .ok;
    for (cfg.files) |path| {
        const inferred = try worker.inferFile(.{ .io = env.io, .gpa = env.gpa }, cfg, nulls, path, a);
        var o = inferred.outcome;
        if (o.result != .@"error") {
            const s = try a.create(schema.Schema);
            s.* = .{
                .columns = try infer.columnsOf(a, inferred.columns),
                .nulls = nulls,
                .match = if (inferred.header) .name else .position,
            };
            const plan: worker.Plan = .{
                .cfg = cfg,
                .schema = s,
                .nulls = nulls,
                .threshold = cfg.threshold orelse 1.0,
                .output = outputOf(cfg),
            };
            o = try worker.validateFile(.{ .io = env.io, .gpa = env.gpa }, plan, path, a);
        }
        try outcomes.append(a, o);
        code = code.worst(@fromBackingInt(o.result.exitCode()));
        if (cfg.json) {
            try report.writeJsonLine(out, o);
        } else if (!cfg.quiet) {
            try report.writeLine(err, o);
        }
    }
    if (cfg.report_dir) |dir| {
        var sink: worker.Sink = try .create(env.io, env.gpa, dir, "summary", ".json");
        defer sink.close(env.io, env.gpa);
        try report.writeSummary(&sink.writer.interface, outcomes.items, @backingInt(code));
        try sink.writer.interface.flush();
    }
    return code;
}

/// validate: each file against the schema, a line apiece on stderr (or a
/// JSON object on stdout under --json), reports and reject files as asked.
fn validateFiles(env: Env, cfg: *const cli.Config, out: *Io.Writer, err: *Io.Writer) !Exit {
    var owned = (try loadSchema(env, cfg, err)) orelse return .usage;
    defer owned.deinit();
    const s = &owned.schema;
    const plan: worker.Plan = .{
        .cfg = cfg,
        .schema = s,
        .nulls = try worker.nullsOf(env.arena, s, cfg.nulls),
        .threshold = cfg.threshold orelse s.threshold orelse 1.0,
        .output = outputOf(cfg),
    };
    var outcomes: std.ArrayList(report.Outcome) = .empty;
    var code: Exit = .ok;
    for (cfg.files) |path| {
        const o = try worker.validateFile(.{ .io = env.io, .gpa = env.gpa }, plan, path, env.arena);
        try outcomes.append(env.arena, o);
        code = code.worst(@fromBackingInt(o.result.exitCode()));
        if (cfg.json) {
            try report.writeJsonLine(out, o);
        } else if (!cfg.quiet) {
            try report.writeLine(err, o);
        }
    }
    if (cfg.report_dir) |dir| {
        var sink: worker.Sink = try .create(env.io, env.gpa, dir, "summary", ".json");
        defer sink.close(env.io, env.gpa);
        try report.writeSummary(&sink.writer.interface, outcomes.items, @backingInt(code));
        try sink.writer.interface.flush();
    }
    return code;
}

/// Each file's dialect, a line apiece: text, or JSON under --json.
fn sniff(env: Env, cfg: cli.Config, out: *Io.Writer, err: *Io.Writer) !Exit {
    var code: Exit = .ok;
    for (cfg.files) |path| {
        const v = sniffFile(env, cfg, path) catch |e| {
            try err.print("thresh: {s}: {s}\n", .{ path, describe(e) });
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
                inline for (.{ "utf8_bom", "mixed_newlines", "quote_in_unquoted" }) |name| {
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
    return dialect.sniff(env.gpa, in.data(), in.eof, .{
        .pins = cfg.pins,
        .sample_bytes = cfg.sample_bytes,
        .max_sample = max_sample,
    });
}

fn describe(e: anyerror) []const u8 {
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
    _ = @import("types/date.zig");
}

test "worst keeps the higher status" {
    try std.testing.expectEqual(Exit.unreadable, Exit.ok.worst(.unreadable));
    try std.testing.expectEqual(Exit.unreadable, Exit.unreadable.worst(.failed));
}
