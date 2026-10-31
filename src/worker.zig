//! One file's pipeline, under lib.zig: open, sniff, scan a batch at a
//! time, and validate (Reader) or infer (inferFile). The only file of the
//! library that imports every stage, so each stage can be tested and
//! benchmarked alone. What the CLI writes of it is render.zig's.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const dialect = @import("dialect.zig");
const input = @import("input.zig");
const records = @import("records.zig");
const schema_mod = @import("schema.zig");
const Schema = schema_mod.Schema;
const validate = @import("validate.zig");
const report = @import("report.zig");
const Problem = @import("problem.zig").Problem;
const infer = @import("infer.zig");
const Encoding = @import("types.zig").Encoding;

pub const Env = struct {
    io: Io,
    gpa: Allocator,
    /// A worker's index buffer, reused from file to file.
    positions: ?[]u32 = null,
};

/// How a file is read, whoever asks: a library caller, or the CLI from its
/// flags. Nothing here is the process's: cancel is the caller's own flag.
pub const Options = struct {
    /// Dialect dimensions pinned; the sniffer settles the rest.
    pins: dialect.Pins = .{},
    /// The sniffer's first window; it grows to dialect.max_sample_bytes.
    sample_bytes: usize = 64 << 10,
    encoding: Encoding = .utf8,
    /// Map the file; false reads it through a buffer.
    mmap: bool = true,
    /// An empty line is a one-field record, not skipped.
    keep_empty: bool = false,
    /// Every date column reads ambiguous dates day first.
    day_first: bool = false,
    /// Extra columns, ragged rows and ambiguous dates fail the file.
    strict: bool = false,
    ragged: validate.Ragged = .reject,
    /// infer: only the first rows are read.
    sample_rows: ?u64 = null,
    /// lib.infer and lib.inferFiles: files read at once, on threads of the
    /// call's own; 0 for one a CPU core.
    jobs: usize = 1,
    /// Strings read as null in every column, besides the schema's (infer:
    /// besides "").
    nulls: []const []const u8 = &.{},
    /// The fraction of a column's values that must fit, and of rows read
    /// whole, for a file to pass; infer keeps a type that many fit. Null:
    /// the schema's, or 1.0; infer, every value.
    threshold: ?f64 = null,
    /// Set from another thread to stop: the call returns error.Interrupted
    /// at its next batch. Null: never.
    cancel: ?*const std.atomic.Value(bool) = null,

    pub fn canceled(o: Options) bool {
        const c = o.cancel orelse return false;
        return c.load(.acquire);
    }
};

fn now(io: Io) Io.Timestamp {
    return Io.Timestamp.now(io, .awake);
}

fn since(io: Io, t: Io.Timestamp) u64 {
    return @intCast(@max(0, t.durationTo(now(io)).nanoseconds));
}

/// A file read against its schema a batch of records at a time: what
/// validate drains and read hands out. open sniffs it; each next reads a
/// batch into the validator, and the rows it accepts into v.batch when the
/// caller has set one; finish settles what came of it. The caller may set
/// v.reject and v.batch, which it owns, before the first next.
pub const Reader = struct {
    io: Io,
    gpa: Allocator,
    opts: Options,
    in: input.Input,
    verdict: dialect.Verdict,
    v: validate.Validator,
    s: records.Scanner,
    batch: records.Batch = .{},
    header_pending: bool,
    /// The last batch asked for more input: read before the next one, not
    /// after the last, since its rows may point into the bytes on hand.
    refill_pending: bool = false,
    ended: bool = false,
    started: Io.Timestamp,
    /// What has come of it so far; finish settles it. The caller adds to
    /// its write time.
    out: report.Outcome,

    pub const Opened = union(enum) {
        reader: Reader,
        stopped: Stopped,
    };

    /// The file stops before it is read: the outcome says why, and the
    /// verdict is there when it was sniffed.
    pub const Stopped = struct { outcome: report.Outcome, verdict: ?dialect.Verdict = null };

    /// open, with the nulls (the schema's and the options') and the
    /// threshold (the options', the schema's, or 1.0) they give, in arena.
    pub fn openFor(env: Env, arena: Allocator, path: []const u8, s: *const Schema, opts: Options) !Opened {
        const nulls = try std.mem.concat(arena, []const u8, &.{ s.nulls, opts.nulls });
        return open(env, arena, path, s, nulls, opts.threshold orelse s.threshold orelse 1.0, opts);
    }

    /// Opens path and sniffs it, ready to read against s. arena holds the
    /// schema's names for the sniffer, and what the reader keeps of nulls.
    pub fn open(env: Env, arena: Allocator, path: []const u8, s: *const Schema, nulls: []const []const u8, threshold: f64, opts: Options) !Opened {
        var out: report.Outcome = .{ .file = path, .result = .@"error" };
        const names = try arena.alloc([]const u8, s.columns.len);
        for (names, s.columns) |*n, c| n.* = c.name;
        var sniffed = (try openSniffed(env, opts, path, names, &out)) orelse return .{ .stopped = .{ .outcome = out } };
        errdefer sniffed.in.close(env.io, env.gpa);
        const verdict = sniffed.verdict;
        if (verdictProblem(verdict, opts)) |p| {
            sniffed.in.close(env.io, env.gpa);
            out.problem = p;
            return .{ .stopped = .{ .outcome = out, .verdict = verdict } };
        }
        const started = now(env.io);
        var v: validate.Validator = try .init(env.gpa, s, verdict.dialect, .{
            .nulls = nulls,
            .encoding = opts.encoding,
            .threshold = threshold,
            .strict = opts.strict,
            .day_first = opts.day_first,
            .ragged = opts.ragged,
        });
        errdefer v.deinit();
        var scanner: records.Scanner = try .init(env.gpa, verdict.dialect, .{
            .reference = .{ .start = verdict.start, .keep_empty = opts.keep_empty },
            .positions_buffer = env.positions,
        });
        errdefer scanner.deinit();
        const in = &sniffed.in;
        scanner.feed(in.data(), in.base, in.eof);
        const header_pending = verdict.dialect.header;
        if (!header_pending) try v.columns(null, verdict.fields, in.data(), in.base);
        return .{ .reader = .{
            .io = env.io,
            .gpa = env.gpa,
            .opts = opts,
            .in = sniffed.in,
            .verdict = verdict,
            .v = v,
            .s = scanner,
            .header_pending = header_pending,
            .started = started,
            .out = out,
        } };
    }

    pub fn deinit(r: *Reader) void {
        r.batch.deinit(r.gpa);
        r.s.deinit();
        r.v.deinit();
        r.in.close(r.io, r.gpa);
    }

    /// Reads the next batch of records; false when the file is done. A
    /// batch read leaves its accepted rows in v.batch, for the caller to
    /// take before the next call.
    pub fn next(r: *Reader) !bool {
        if (r.ended) return false;
        if (r.refill_pending) {
            r.refill_pending = false;
            try r.in.refill(r.io, r.gpa, r.s.keepFrom());
            r.s.feed(r.in.data(), r.in.base, r.in.eof);
        }
        r.batch.clear();
        const state = try r.batch.fill(r.gpa, &r.s, .{});
        const data = r.in.data();
        for (0..r.batch.len()) |i| {
            const fields = r.batch.recordFields(i);
            if (r.header_pending) {
                r.header_pending = false;
                try r.v.columns(fields, r.verdict.fields, data, r.in.base);
                continue;
            }
            try r.v.record(r.batch.records.items[i], fields, data, r.in.base);
        }
        if (r.opts.canceled()) return error.Interrupted;
        switch (state) {
            .full => {},
            .end => r.ended = true,
            .need_more => r.refill_pending = true,
        }
        return true;
    }

    /// What came of the file, read to its end: its rows, its result and
    /// its first problem (in arena). The verdict gains utf16_invalid when
    /// UTF-16 units were replaced.
    pub fn finish(r: *Reader, arena: Allocator) !report.Outcome {
        // An empty file with a header pending: no columns to match.
        if (r.header_pending) try r.v.columns(null, 0, r.in.data(), r.in.base);
        const v = &r.v;
        var out = r.out;
        out.timing.parse_ns = since(r.io, r.started) -| out.timing.write_ns;
        out.rows = v.rows;
        out.rows_rejected = v.rejected;
        // Quotes that are data folded lines into rows: what was read is not
        // the file's rows, so none of it is kept.
        const folded = if (r.opts.pins.quote == null) v.quotes.folding(v.stray_quotes) else null;
        if (folded) |f| try v.structural.insert(v.gpa, 0, .{ .quote_is_data = f });
        out.result = if (folded != null) .@"error" else if (v.passed()) .pass else .fail;
        if (v.structural.items.len > 0) {
            out.problem = try v.structural.items[0].dupe(arena);
        } else if (v.repeated_headers > 0) {
            out.problem = .{ .header_repeated = .{ .line = v.repeated_lines.items[0], .count = v.repeated_headers } };
        }
        if (r.in.utf16) |u| if (u.replaced > 0) {
            r.verdict.warnings.utf16_invalid = true;
        };
        r.out = out;
        return out;
    }

    /// The file's report, for out, finish's outcome, its strings in arena.
    pub fn fileReport(r: *const Reader, arena: Allocator, out: report.Outcome) !report.File {
        return report.fileOf(arena, out, .{ .verdict = r.verdict, .validator = &r.v, .encoding = r.opts.encoding });
    }
};

/// Why a file stops at its sniff, before it is read, if it does: its
/// dialect is not settled, or the sample's quotes look like data.
pub fn verdictProblem(v: dialect.Verdict, o: Options) ?Problem {
    if (v.confidence == .low and !o.pins.complete()) return .{ .dialect_unsettled = .{ .score = v.score } };
    if (v.folded) |f| return .{ .quote_is_data = f };
    return null;
}

/// A UTF-16 file is transcoded to UTF-8 as it is read, so an --encoding
/// for its bytes would read the UTF-8 as something else.
fn utf16Conflict(in: *const input.Input, o: Options) ?Problem {
    if (in.utf16 == null or o.encoding == .utf8) return null;
    return .utf16_with_encoding;
}

/// A file open, and its dialect.
pub const Sniffed = struct {
    in: input.Input,
    verdict: dialect.Verdict,
};

/// Opens path and sniffs as much of its start as the sniffer may want:
/// the one way sniff, infer and validate read a file's dialect. A problem
/// with the file (it cannot be opened, is UTF-16 under --encoding, gives
/// the sniffer nothing to score, or has a header a name short of its
/// rows) goes in out.problem and gives null.
/// out.bytes and out.timing.sniff_ns are set as far as it gets. Low
/// confidence is the caller's to judge. The caller closes the Input.
pub fn openSniffed(env: Env, o: Options, path: []const u8, schema_names: ?[]const []const u8, out: *report.Outcome) !?Sniffed {
    const t0 = now(env.io);
    defer out.timing.sniff_ns = since(env.io, t0);
    var in = input.Input.open(env.io, env.gpa, path, .{ .no_mmap = !o.mmap }) catch |e| {
        out.problem = Problem.of(e);
        return null;
    };
    var kept = false;
    defer if (!kept) in.close(env.io, env.gpa);
    out.bytes = in.size;
    if (utf16Conflict(&in, o)) |p| {
        out.problem = p;
        return null;
    }
    const max_sample = @max(o.sample_bytes, dialect.max_sample_bytes);
    while (!in.eof and in.data().len < max_sample) try in.refill(env.io, env.gpa, in.base);
    var verdict = dialect.sniff(env.gpa, in.data(), in.eof, .{
        .pins = o.pins,
        .sample_bytes = o.sample_bytes,
        .max_sample = max_sample,
        .utf8 = o.encoding == .utf8,
        .schema = schema_names,
    }) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => {
            out.problem = Problem.of(e);
            return null;
        },
    };
    verdict.warnings.utf16 = in.utf16 != null;
    // Its names cannot be matched to its columns, and guessing where one
    // is missing or extra would name the columns after it wrongly.
    if (verdict.warnings.header_width) {
        out.problem = .{ .header_width = .{ .header_fields = verdict.header_fields, .fields = verdict.fields } };
        return null;
    }
    kept = true;
    return .{ .in = in, .verdict = verdict };
}

pub const Inferred = struct {
    outcome: report.Outcome,
    columns: []const infer.ColumnState = &.{},
    header: bool = false,
    /// Records that were the header again, skipped, and the first's line.
    repeated_headers: u64 = 0,
    repeated_line: u64 = 0,
    /// UTF-16 code units that made no character, read as U+FFFD.
    utf16_replaced: u64 = 0,
    /// Rows wider than the header, left out, and the first one's line.
    wide_rows: u64 = 0,
    wide_line: u64 = 0,
};

/// Infers the file at path's columns, reading all of it, or the first
/// --sample rows. arena holds the result.
pub fn inferFile(env: Env, opts: Options, nulls: []const []const u8, path: []const u8, arena: Allocator) !Inferred {
    const io = env.io;
    const gpa = env.gpa;
    var out: report.Outcome = .{ .file = path, .result = .@"error" };
    var sniffed = (try openSniffed(env, opts, path, null, &out)) orelse return .{ .outcome = out };
    defer sniffed.in.close(io, gpa);
    const in = &sniffed.in;
    const verdict = sniffed.verdict;
    if (verdictProblem(verdict, opts)) |p| {
        out.problem = p;
        return .{ .outcome = out };
    }

    const t1 = now(io);
    var f: infer.Inferrer = .init(arena, .{
        .nulls = nulls,
        .encoding = opts.encoding,
        .day_first = opts.day_first,
    });
    var s: records.Scanner = try .init(gpa, verdict.dialect, .{
        .reference = .{ .start = verdict.start, .keep_empty = opts.keep_empty },
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
    var quotes: records.QuoteCheck = .{};
    var stray: u64 = 0;
    const limit = opts.sample_rows orelse std.math.maxInt(u64);
    read: while (f.rows < limit) {
        batch.clear();
        const state = try batch.fill(gpa, &s, .{});
        for (0..batch.len()) |i| {
            if (f.rows >= limit) break :read;
            quotes.record(batch.records.items[i], verdict.fields, verdict.dialect, in.data(), in.base);
            stray += batch.records.items[i].stray_quotes;
            if (batch.records.items[i].problem != null) continue;
            try records.values(gpa, batch.recordFields(i), in.data(), in.base, verdict.dialect, &scratch, &values);
            if (header_pending) {
                header_pending = false;
                const kept = values.items[0..schema_mod.headerWidth(values.items, verdict.fields)];
                try f.header(kept, kept.len);
                const names = try arena.alloc([]const u8, kept.len);
                for (names, kept) |*n, h| n.* = try arena.dupe(u8, std.mem.trim(u8, h, " \t"));
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
        if (opts.canceled()) return error.Interrupted;
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
    // Rows folded together by quotes that are data: no schema from them.
    if (opts.pins.quote == null) if (quotes.folding(stray)) |folded| {
        out.problem = .{ .quote_is_data = folded };
        return .{ .outcome = out };
    };
    // Read as UTF-8 and not UTF-8: a guess of replace would turn every
    // accented letter of a Windows export into U+FFFD, so say what to do.
    for (f.columns.items) |c| if (c.invalid_utf8) {
        out.problem = .{ .column_not_utf8 = .{ .column = c.name, .row = c.invalid_row } };
        return .{ .outcome = out };
    };
    out.result = .pass;
    return .{
        .outcome = out,
        .columns = f.columns.items,
        .header = verdict.dialect.header,
        .repeated_headers = repeated,
        .repeated_line = repeated_line,
        .utf16_replaced = if (in.utf16) |u| u.replaced else 0,
        .wide_rows = f.wide_rows,
        .wide_line = f.wide_line,
    };
}

/// Whether a record's values are the header's names, trimmed and in any case.
fn sameNames(values: []const []const u8, names: []const []const u8) bool {
    if (values.len != names.len) return false;
    for (values, names) |v, n| if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, v, " \t"), n)) return false;
    return true;
}
