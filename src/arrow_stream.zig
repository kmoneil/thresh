//! A file read against its schema and handed out as Arrow C streams
//! (write/arrow_c.zig): one of its accepted rows, one of its rejected rows,
//! and its report once it is read. An Export owns everything it reads
//! with (its own copy of the schema and the path, the reader, the
//! builders) and lives while its caller holds it or a stream it handed
//! out is open: each is a reference, and the last released frees it.
//!
//! A stream's get_next reads the file on until it has a batch, and keeps
//! the batches the other stream will want until it asks for them, so the
//! two can be read in either order, or one alone. Only what a stream that
//! is still open will take is built: a stream not asked for at open, or
//! released, has no batches made.
//!
//! One thread at a time: the export and its streams share one reader. A
//! batch handed out is the consumer's, on any thread (arrow_c.zig says what
//! that asks of the allocator).

const std = @import("std");
const Allocator = std.mem.Allocator;
const arrow_c = @import("write/arrow_c.zig");
const builders = @import("builders.zig");
const report = @import("report.zig");
const schema_mod = @import("schema.zig");
const worker = @import("worker.zig");
const Problem = @import("problem.zig").Problem;

/// The streams the caller will take; the others' batches are not built. A
/// stream wanted and not yet taken keeps its batches until it is taken or
/// the export released: take it, or do not ask for it.
pub const Want = struct {
    rows: bool = true,
    rejects: bool = false,
};

pub const Opened = union(enum) {
    ready: *Export,
    /// The file stops before it is read, as Reader.open says.
    stopped: worker.Reader.Stopped,
};

// What a stream's calls return, as errno values: the same on Linux, macOS,
// the BSDs and Windows' C runtime.
const e_intr: c_int = 4;
const e_io: c_int = 5;
const e_nomem: c_int = 12;

/// Rejected rows a batch, at most: a file of them comes a batch at a time.
const reject_batch_rows = 65_536;

pub const Export = struct {
    gpa: Allocator,
    /// The schema's and the path's copies, the reader's names and nulls,
    /// the messages.
    arena: std.heap.ArenaAllocator,
    schema: schema_mod.Schema,
    reader: worker.Reader,
    rows: builders.Batch,
    rejects: builders.Rejects,
    /// The caller's and each open stream's.
    refs: std.atomic.Value(u32) = .init(1),
    sides: [2]Side,
    /// The reader has read the file to its end.
    ended: bool = false,
    /// What stopped the streams: an error, or the file's problem when its
    /// read ends in one.
    failure: ?Failure = null,
    /// What came of the file, once it is read.
    outcome: ?report.Outcome = null,

    const Failure = struct { code: c_int, err: anyerror, message: [:0]const u8 };

    const Which = enum(u1) { rows, rejects };

    /// A stream, from open to its release: whether it was asked for,
    /// handed out and released, and the batches it has not taken yet.
    const Side = struct {
        owner: *Export,
        which: Which,
        wanted: bool,
        taken: bool = false,
        released: bool = false,
        queue: std.ArrayList(arrow_c.Array) = .empty,
        head: usize = 0,

        fn live(s: *const Side) bool {
            return s.wanted and !s.released;
        }

        /// Releases the batches it has not taken.
        fn drop(s: *Side, gpa: Allocator) void {
            for (s.queue.items[s.head..]) |*a| if (a.release) |r| r(a);
            s.queue.deinit(gpa);
            s.queue = .empty;
            s.head = 0;
        }
    };

    /// Opens path to read against s, for the streams want names. A file
    /// that stops before it is read gives its outcome, in arena. The export
    /// keeps its own copies of s, path and o.nulls; env.io, and o.cancel
    /// when set, must outlive it. Release it with release.
    pub fn open(env: worker.Env, arena: Allocator, path: []const u8, s: *const schema_mod.Schema, o: worker.Options, want: Want) !Opened {
        const gpa = env.gpa;
        const e = try gpa.create(Export);
        e.* = .{
            .gpa = gpa,
            .arena = .init(gpa),
            .schema = undefined,
            .reader = undefined,
            .rows = undefined,
            .rejects = .init(gpa, o.encoding),
            .sides = .{
                .{ .owner = e, .which = .rows, .wanted = want.rows },
                .{ .owner = e, .which = .rejects, .wanted = want.rejects },
            },
        };
        var reading = false;
        errdefer {
            if (reading) e.reader.deinit();
            e.arena.deinit();
            gpa.destroy(e);
        }
        const a = e.arena.allocator();
        e.schema = try schema_mod.dupe(s.*, a);
        var opts = o;
        const nulls = try a.alloc([]const u8, o.nulls.len);
        for (nulls, o.nulls) |*n, x| n.* = try a.dupe(u8, x);
        opts.nulls = nulls;
        // The caller's index buffer is for its own calls: the reader
        // allocates its own.
        var own = env;
        own.positions = null;
        switch (try worker.Reader.openFor(own, a, try a.dupe(u8, path), &e.schema, opts)) {
            .stopped => |st| {
                var out = st;
                out.outcome.file = path;
                if (st.outcome.problem) |p| out.outcome.problem = try p.dupe(arena);
                e.arena.deinit();
                gpa.destroy(e);
                return .{ .stopped = out };
            },
            .reader => |r| e.reader = r,
        }
        reading = true;
        e.rows = try .init(gpa, &e.schema, o.encoding);
        return .{ .ready = e };
    }

    /// Drops the caller's reference: the export is freed now, or when the
    /// last stream it handed out is released.
    pub fn release(e: *Export) void {
        if (e.refs.fetchSub(1, .acq_rel) != 1) return;
        const gpa = e.gpa;
        for (&e.sides) |*s| s.drop(gpa);
        e.rows.deinit();
        e.rejects.deinit();
        e.reader.deinit();
        e.arena.deinit();
        gpa.destroy(e);
    }

    /// The accepted rows, as a stream of struct arrays of the schema's
    /// columns: once, and only when opened wanting them.
    pub fn rowsStream(e: *Export, out: *arrow_c.ArrayStream) error{ NotWanted, AlreadyTaken }!void {
        return e.take(.rows, out);
    }

    /// The rejected rows, as arrow_c.exportRejectsSchema has them: once,
    /// and only when opened wanting them.
    pub fn rejectsStream(e: *Export, out: *arrow_c.ArrayStream) error{ NotWanted, AlreadyTaken }!void {
        return e.take(.rejects, out);
    }

    fn take(e: *Export, which: Which, out: *arrow_c.ArrayStream) error{ NotWanted, AlreadyTaken }!void {
        const side = &e.sides[@backingInt(which)];
        if (!side.wanted) return error.NotWanted;
        if (side.taken) return error.AlreadyTaken;
        side.taken = true;
        _ = e.refs.fetchAdd(1, .monotonic);
        out.* = .{
            .get_schema = getSchema,
            .get_next = getNext,
            .get_last_error = getLastError,
            .release = releaseStream,
            .private_data = side,
        };
    }

    /// The file's report, its strings in arena: what is left of the file
    /// is read first, its batches kept for the streams still open. A file
    /// whose read ends in a problem has its report; an error that stopped
    /// the read is returned.
    pub fn fileReport(e: *Export, arena: Allocator) !report.File {
        while (!e.ended and e.failure == null) e.pump() catch |err| {
            _ = e.fail(err);
        };
        if (e.outcome == null) if (e.failure) |f| return f.err;
        try e.settle();
        return e.reader.fileReport(arena, e.outcome.?);
    }

    /// Reads one batch of the file, and queues what the open streams
    /// will take of it.
    fn pump(e: *Export) !void {
        const rows = &e.sides[@backingInt(Which.rows)];
        const rejects = &e.sides[@backingInt(Which.rejects)];
        e.reader.v.batch = if (rows.live()) &e.rows else null;
        e.reader.v.rejects = if (rejects.live()) &e.rejects else null;
        if (!try e.reader.next()) e.ended = true;
        if (rows.live() and e.rows.rows > 0) try e.queue(rows);
        if (rejects.live() and e.rejects.rows > 0 and (e.ended or e.rejects.rows >= reject_batch_rows)) try e.queue(rejects);
    }

    fn queue(e: *Export, side: *Side) !void {
        try side.queue.ensureUnusedCapacity(e.gpa, 1);
        var a: arrow_c.Array = undefined;
        switch (side.which) {
            .rows => try arrow_c.exportBatch(e.gpa, &e.schema, &e.rows, &a),
            .rejects => try arrow_c.exportRejects(e.gpa, &e.rejects, e.reader.v.names.len, &a),
        }
        side.queue.appendAssumeCapacity(a);
    }

    /// Settles what came of the file, once it is read. When that is an
    /// error (its quotes turn out to be data, so what was read is not its
    /// rows), the streams end in it, as the CLI writes nothing of it.
    fn settle(e: *Export) !void {
        if (e.outcome != null) return;
        const out = try e.reader.finish(e.arena.allocator());
        e.outcome = out;
        if (out.result == .@"error") e.failure = .{
            .code = e_io,
            .err = error.FileProblem,
            .message = e.messageOf(out.problem orelse .{ .io_error = .{ .@"error" = "FileProblem" } }),
        };
    }

    /// Records err as what stopped the streams, if nothing has yet, and
    /// gives its code.
    fn fail(e: *Export, err: anyerror) c_int {
        if (e.failure == null) e.failure = .{
            .code = switch (err) {
                error.Interrupted => e_intr,
                error.OutOfMemory => e_nomem,
                else => e_io,
            },
            .err = err,
            .message = e.messageOf(Problem.of(err)),
        };
        return e.failure.?.code;
    }

    /// "path: the problem's sentence", for get_last_error.
    fn messageOf(e: *Export, p: Problem) [:0]const u8 {
        return std.fmt.allocPrintSentinel(e.arena.allocator(), "{s}: {f}", .{ e.reader.out.file, p }, 0) catch "out of memory";
    }
};

fn sideOf(stream: *arrow_c.ArrayStream) *Export.Side {
    return @ptrCast(@alignCast(stream.private_data.?));
}

fn getSchema(stream: *arrow_c.ArrayStream, out: *arrow_c.Schema) callconv(.c) c_int {
    const side = sideOf(stream);
    const e = side.owner;
    switch (side.which) {
        .rows => arrow_c.exportSchema(e.gpa, &e.schema, out) catch |err| return e.fail(err),
        .rejects => {
            // Its names are the header's: read on until it is read.
            while (e.reader.header_pending and !e.ended) {
                if (e.failure) |f| return f.code;
                e.pump() catch |err| return e.fail(err);
            }
            arrow_c.exportRejectsSchema(e.gpa, e.reader.v.names, out) catch |err| return e.fail(err);
        },
    }
    return 0;
}

fn getNext(stream: *arrow_c.ArrayStream, out: *arrow_c.Array) callconv(.c) c_int {
    const side = sideOf(stream);
    const e = side.owner;
    while (true) {
        if (side.head < side.queue.items.len) {
            out.* = side.queue.items[side.head];
            side.head += 1;
            if (side.head == side.queue.items.len) {
                side.queue.clearRetainingCapacity();
                side.head = 0;
            }
            return 0;
        }
        if (e.failure) |f| return f.code;
        if (e.ended) {
            e.settle() catch |err| return e.fail(err);
            if (e.failure) |f| return f.code;
            // The end: an array already released.
            out.* = .{};
            return 0;
        }
        e.pump() catch |err| return e.fail(err);
    }
}

fn getLastError(stream: *arrow_c.ArrayStream) callconv(.c) ?[*:0]const u8 {
    const f = sideOf(stream).owner.failure orelse return null;
    return f.message.ptr;
}

fn releaseStream(stream: *arrow_c.ArrayStream) callconv(.c) void {
    const side = sideOf(stream);
    const e = side.owner;
    side.released = true;
    side.drop(e.gpa);
    // Nothing will take what its builder holds.
    switch (side.which) {
        .rows => e.rows.reset(),
        .rejects => e.rejects.reset(),
    }
    stream.release = null;
    e.release();
}
