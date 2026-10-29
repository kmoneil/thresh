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
        else => {
            try err.print("thresh: {t} is not built yet\n", .{cfg.command});
            return .usage;
        },
    };
}

/// Each file's dialect, a line apiece: text, or JSON under --json.
fn sniff(env: Env, cfg: cli.Config, out: *Io.Writer, err: *Io.Writer) !Exit {
    const sample = try env.gpa.alloc(u8, cfg.sample_bytes);
    defer env.gpa.free(sample);
    var code: Exit = .ok;
    for (cfg.files) |path| {
        const n = readSample(env.io, path, sample) catch |e| {
            try err.print("thresh: {s}: {s}\n", .{ path, describe(e) });
            code = code.worst(.unreadable);
            continue;
        };
        const d = dialect.sniff(sample[0..n]);
        if (cfg.json) {
            try std.json.Stringify.value(.{ .file = path, .dialect = d }, .{}, out);
            try out.writeByte('\n');
        } else {
            try out.print("{s}: {f}\n", .{ path, d });
        }
    }
    return code;
}

/// Reads up to buf.len bytes from the start of the file at path.
fn readSample(io: Io, path: []const u8, buf: []u8) !usize {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var r = file.reader(io, &.{});
    return r.interface.readSliceShort(buf) catch |e| switch (e) {
        error.ReadFailed => return r.err.?,
    };
}

fn describe(e: anyerror) []const u8 {
    return switch (e) {
        error.FileNotFound => "no such file",
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.IsDir => "is a directory",
        error.OutOfMemory => "out of memory",
        error.BrokenPipe => "the output was closed",
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
}

test "worst keeps the higher status" {
    try std.testing.expectEqual(Exit.unreadable, Exit.ok.worst(.unreadable));
    try std.testing.expectEqual(Exit.unreadable, Exit.unreadable.worst(.failed));
}
