//! Files across workers. main pushes each file's index onto an Io.Queue,
//! and --jobs workers, started with Group.concurrent on one Io.Group, take
//! a file at a time and run its whole pipeline, writing its report as it
//! finishes. One file a worker, nothing finer: splitting a file means
//! settling quote parity at chunk boundaries, and thousands of files keep
//! every core busy anyway.
//!
//! Group.concurrent, not Group.async: an async task need not start until
//! the group is awaited, and main, blocked on a full queue, would wait for
//! workers that never ran (found checking the 0.17 API, card t2).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const worker = @import("worker.zig");
const report = @import("report.zig");
const interrupt = @import("interrupt.zig");

/// What a worker keeps from file to file.
pub const Worker = struct {
    id: usize,
    env: worker.Env,
    /// What outlives the run: outcomes' strings, a task's results. Shared
    /// by the workers; 0.17's ArenaAllocator is thread-safe over a
    /// thread-safe child.
    keep: Allocator,
    /// What does not outlive a file: reset before each.
    scratch: std.heap.ArenaAllocator,
    node: std.Progress.Node = .none,
};

/// A run's work: what to do with file index i, on a worker.
pub const Task = struct {
    ctx: *anyopaque,
    files: []const []const u8,
    run: *const fn (ctx: *anyopaque, w: *Worker, index: usize) anyerror!report.Outcome,
};

/// Each file's line, as it finishes: on stderr, or as JSON on stdout.
pub const Lines = struct {
    mutex: Io.Mutex = .init,
    err: *Io.Writer,
    out: *Io.Writer,
    json: bool = false,
    quiet: bool = false,

    fn put(l: *Lines, io: Io, o: report.Outcome) void {
        if (l.quiet and !l.json) return;
        l.mutex.lockUncancelable(io);
        defer l.mutex.unlock(io);
        if (l.json) report.writeJsonLine(l.out, o) catch {} else report.writeLine(l.err, o) catch {};
    }
};

pub const Options = struct {
    jobs: usize,
    /// --progress: a node per worker naming its file, under one for the run.
    progress: std.Progress.Node = .none,
    /// Each worker's index buffer, in u32s.
    positions: usize = 1 << 20,
    /// Where what outlives the run is allocated: thread-safe.
    keep: Allocator,
};

/// Runs task on every file, outcomes[i] for file i. A file the run never
/// got to (Ctrl-C) is an error outcome saying so.
pub fn run(io: Io, gpa: Allocator, task: Task, outcomes: []report.Outcome, lines: *Lines, options: Options) !void {
    const count = task.files.len;
    for (outcomes, task.files) |*o, f| o.* = .{ .file = f, .result = .@"error", .problem = "not reached: interrupted" };
    if (count == 0) return;
    const jobs = @max(1, @min(options.jobs, count));

    const workers = try gpa.alloc(Worker, jobs);
    defer gpa.free(workers);
    var made: usize = 0;
    defer for (workers[0..made]) |*w| {
        w.scratch.deinit();
        if (w.env.positions) |p| gpa.free(p);
        w.node.end();
    };
    for (workers, 0..) |*w, id| {
        w.* = .{
            .id = id,
            .env = .{ .io = io, .gpa = gpa, .positions = try gpa.alloc(u32, options.positions) },
            .keep = options.keep,
            .scratch = .init(gpa),
            .node = if (options.progress.index != .none) options.progress.start("", 0) else .none,
        };
        made += 1;
    }

    const buf = try gpa.alloc(usize, @min(count, 1024));
    defer gpa.free(buf);
    var queue: Io.Queue(usize) = .init(buf);
    var group: Io.Group = .init;
    var started: usize = 0;
    for (workers) |*w| {
        group.concurrent(io, work, .{ w, &queue, task, outcomes, lines, options.progress }) catch break;
        started += 1;
    }
    if (started == 0) {
        // No concurrency here (a single-threaded build): one worker, inline.
        for (0..count) |i| {
            if (interrupt.requested()) break;
            one(&workers[0], task, i, outcomes, lines, options.progress);
        }
        return;
    }
    for (0..count) |i| {
        if (interrupt.requested()) break;
        queue.putOne(io, i) catch break;
    }
    queue.close(io);
    group.await(io) catch {};
}

fn work(w: *Worker, queue: *Io.Queue(usize), task: Task, outcomes: []report.Outcome, lines: *Lines, root: std.Progress.Node) Io.Cancelable!void {
    while (true) {
        const i = queue.getOne(w.env.io) catch |e| switch (e) {
            error.Closed => return,
            error.Canceled => return error.Canceled,
        };
        if (interrupt.requested()) continue;
        one(w, task, i, outcomes, lines, root);
    }
}

fn one(w: *Worker, task: Task, i: usize, outcomes: []report.Outcome, lines: *Lines, root: std.Progress.Node) void {
    _ = w.scratch.reset(.retain_capacity);
    w.node.setName(std.fs.path.basename(task.files[i]));
    var o = task.run(task.ctx, w, i) catch |e| report.Outcome{
        .file = task.files[i],
        .result = .@"error",
        .problem = if (e == error.Interrupted) "interrupted" else worker.describe(e),
    };
    // The outcome's strings outlive the file's scratch.
    const a = w.keep;
    if (o.problem) |p| o.problem = a.dupe(u8, p) catch "out of memory";
    if (o.written) |p| o.written = a.dupe(u8, p) catch null;
    outcomes[i] = o;
    lines.put(w.env.io, o);
    root.completeOne();
}

/// Each file's base name for its report, reject and output files: the
/// base name of its path, or where two inputs share one, the path with
/// its separators as underscores, so neither overwrites the other's.
pub fn uniqueNames(arena: Allocator, files: []const []const u8) Allocator.Error![]const []const u8 {
    const names = try arena.alloc([]const u8, files.len);
    var seen: std.StringHashMapUnmanaged(u32) = .empty;
    defer seen.deinit(arena);
    for (files) |f| {
        const r = try seen.getOrPut(arena, std.fs.path.basename(f));
        r.value_ptr.* = if (r.found_existing) r.value_ptr.* + 1 else 1;
    }
    for (names, files) |*n, f| {
        const base = std.fs.path.basename(f);
        if (seen.get(base).? == 1) {
            n.* = base;
            continue;
        }
        var trimmed = f;
        while (std.mem.startsWith(u8, trimmed, "./")) trimmed = trimmed[2..];
        trimmed = std.mem.trimStart(u8, trimmed, "/");
        const copy = try arena.dupe(u8, trimmed);
        std.mem.replaceScalar(u8, copy, '/', '_');
        std.mem.replaceScalar(u8, copy, '\\', '_');
        n.* = copy;
    }
    return names;
}

test uniqueNames {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const names = try uniqueNames(arena.allocator(), &.{ "inbox/a/orders.csv", "./inbox/b/orders.csv", "x/other.csv" });
    try std.testing.expectEqualStrings("inbox_a_orders.csv", names[0]);
    try std.testing.expectEqualStrings("inbox_b_orders.csv", names[1]);
    try std.testing.expectEqualStrings("other.csv", names[2]);
}

test "a run reaches every file once, across workers" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const files = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j" };
    var seen: [files.len]std.atomic.Value(u32) = @splat(.init(0));
    const Ctx = struct {
        seen: *[files.len]std.atomic.Value(u32),
        fn run(ctx: *anyopaque, w: *Worker, i: usize) anyerror!report.Outcome {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            _ = c.seen[i].fetchAdd(1, .monotonic);
            return .{ .file = "x", .result = .pass, .rows = w.id };
        }
    };
    var ctx: Ctx = .{ .seen = &seen };
    var outcomes: [files.len]report.Outcome = undefined;
    var discard: Io.Writer.Discarding = .init(&.{});
    var lines: Lines = .{ .err = &discard.writer, .out = &discard.writer };
    interrupt.reset();
    var keep: std.heap.ArenaAllocator = .init(gpa);
    defer keep.deinit();
    try run(io, gpa, .{ .ctx = &ctx, .files = &files, .run = Ctx.run }, &outcomes, &lines, .{ .jobs = 4, .positions = 64, .keep = keep.allocator() });
    for (seen, outcomes) |s, o| {
        try std.testing.expectEqual(@as(u32, 1), s.load(.monotonic));
        try std.testing.expectEqual(report.Result.pass, o.result);
    }
}
