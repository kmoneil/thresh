//! thresh as a library: a delimited file's dialect (sniff), the schema its
//! values fit (infer), its rows checked against a schema (validate), or
//! handed out a batch at a time (read). Every call returns values, in the
//! caller's allocators, and prints nothing; nothing here is the process's:
//! no exit status, no signal handler, no global state. A caller that wants
//! Ctrl-C to stop a call passes its own flag in Options.cancel. The CLI
//! (main.zig) is built on it, so the CLI's tests hold it to what it says.
//!
//! Memory: env.gpa for what a call needs while it runs, freed before it
//! returns; arena for what it returns, which the caller frees by freeing
//! the arena. A Reader holds gpa memory until its deinit.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const arrow_c = @import("write/arrow_c.zig");
const arrow_stream = @import("arrow_stream.zig");
const builders = @import("builders.zig");
const dialect = @import("dialect.zig");
const infer_mod = @import("infer.zig");
const problem_mod = @import("problem.zig");
const report = @import("report.zig");
const schema_mod = @import("schema.zig");
const worker = @import("worker.zig");

/// What a call runs with: io, gpa, and optionally a scanner index buffer
/// to reuse from call to call (a caller reading many files keeps one;
/// without, each call allocates its own).
pub const Env = worker.Env;
pub const Options = worker.Options;
pub const Schema = schema_mod.Schema;
pub const Problem = problem_mod.Problem;
pub const Verdict = dialect.Verdict;
pub const Outcome = report.Outcome;
/// A file's report: what validate returns, and Reader.fileReport.
pub const File = report.File;
pub const Reader = worker.Reader;
/// A batch of typed rows, as read hands them out.
pub const Batch = builders.Batch;
/// One file's columns as inference left them: what merge takes.
pub const Columns = worker.Inferred;
/// Arrow's C Data Interface, as its C header lays the structs out.
pub const ArrowSchema = arrow_c.Schema;
pub const ArrowArray = arrow_c.Array;
pub const ArrowArrayStream = arrow_c.ArrayStream;
/// A file being read and handed out as Arrow C streams (readArrow).
pub const ArrowExport = arrow_stream.Export;
pub const ArrowWant = arrow_stream.Want;

/// A schema and the memory it lives in (deinit frees it), and why one was
/// refused.
pub const OwnedSchema = schema_mod.Owned;
pub const SchemaDiagnostic = schema_mod.Diagnostic;
/// A schema from its JSON (docs/REPORT.md, "The schema"): unknown fields
/// and versions newer than this thresh reads are refused, saying why.
pub const parseSchema = schema_mod.parseJson;
/// A schema file, read whole and parsed as parseSchema does.
pub const loadSchema = schema_mod.load;
/// The inline form, "id:int64,amount:decimal(18,2)": every column
/// nullable, the nulls "".
pub const parseColumns = schema_mod.parseInline;
/// The schema as JSON, as infer writes it and parseSchema reads it.
pub const writeSchema = schema_mod.writeJson;
/// A file's report as JSON, as docs/REPORT.md describes it.
pub const writeReport = report.writeFileReport;

/// What sniff found: how the file is written, or why it cannot be read.
pub const Sniffed = struct {
    /// result pass, or error with the problem that stops the file at its
    /// sniff (the file cannot be read, its dialect is not settled, its
    /// quotes look like data).
    outcome: Outcome,
    /// Null when the file could not be read or scored.
    verdict: ?Verdict = null,
};

/// The dialect of the file at path, from as much of its start as the
/// sniffer wants.
pub fn sniff(env: Env, path: []const u8, o: Options) !Sniffed {
    var out: Outcome = .{ .file = path, .result = .@"error" };
    var s = (try worker.openSniffed(env, o, path, null, &out)) orelse return .{ .outcome = out };
    s.in.close(env.io, env.gpa);
    out.problem = worker.verdictProblem(s.verdict, o);
    out.result = if (out.problem == null) .pass else .@"error";
    return .{ .outcome = out, .verdict = s.verdict };
}

/// The columns of the file at path, read whole (or its first
/// Options.sample_rows rows): the first pass of infer. Its outcome is an
/// error, with the problem, when the file cannot be read or stops at its
/// sniff.
pub fn inferFile(env: Env, arena: Allocator, path: []const u8, o: Options) !Columns {
    return worker.inferFile(env, o, try nullsOf(arena, &.{""}, o.nulls), path, arena);
}

/// Something infer has to say: about one file, or about the run.
pub const Note = struct {
    /// The file it follows, as an index into merge's files; null for the
    /// run's, which follow every file's.
    after: ?usize,
    /// The file it is about, when the problem does not name it itself.
    file: ?[]const u8 = null,
    problem: Problem,
};

/// What infer makes of its files.
pub const Merged = struct {
    /// Null when no file could be read; stop says so.
    schema: ?Schema = null,
    /// In order: each file's, then the run's.
    notes: []const Note = &.{},
    /// nothing_to_infer.
    stop: ?Problem = null,
    /// The files disagree, so the schema fails some of them (files_*).
    disagreement: ?Problem = null,
};

/// One schema from each file's columns, matched by name, each column the
/// lowest type any file took it to; a file whose outcome is an error is
/// left out. Under Options.threshold a column whose few misfits allow it
/// keeps the type the rest fit. Everything returned is in arena.
pub fn merge(arena: Allocator, files: []const Columns, o: Options) !Merged {
    const a = arena;
    var notes: std.ArrayList(Note) = .empty;
    var merged: std.ArrayList(infer_mod.ColumnState) = .empty;
    // Each merged column's index, by name, and how many files have it.
    var merged_at: schema_mod.NameMap(usize) = .empty;
    var present: std.ArrayList(u32) = .empty;
    var all_headers = true;
    // The files merged, those without a header and the first of them,
    // and the widths of those.
    var merged_files: u32 = 0;
    var headless: u32 = 0;
    var first_headless: []const u8 = "";
    var widths: [2]usize = .{ std.math.maxInt(usize), 0 };
    for (files, 0..) |r, i| {
        if (r.outcome.result == .@"error") continue;
        const path = r.outcome.file;
        if (!r.header) all_headers = false;
        merged_files += 1;
        if (!r.header) {
            if (headless == 0) first_headless = path;
            headless += 1;
            widths = .{ @min(widths[0], r.columns.len), @max(widths[1], r.columns.len) };
        }
        if (r.repeated_headers > 0) try notes.append(a, .{ .after = i, .file = path, .problem = .{ .header_repeated = .{ .line = r.repeated_line, .count = r.repeated_headers } } });
        if (r.wide_rows > 0) try notes.append(a, .{ .after = i, .file = path, .problem = .{ .rows_wider = .{ .rows = r.wide_rows, .line = r.wide_line } } });
        if (r.utf16_replaced > 0) try notes.append(a, .{ .after = i, .file = path, .problem = .{ .utf16_replaced = .{ .units = r.utf16_replaced } } });
        const columns = try a.dupe(infer_mod.ColumnState, r.columns);
        for (columns) |*c| if (restOf(c, o.threshold)) |p| try notes.append(a, .{ .after = i, .file = path, .problem = p });
        for (columns) |c| {
            const at = try merged_at.getOrPut(a, c.name);
            if (!at.found_existing) {
                at.value_ptr.* = merged.items.len;
                try merged.append(a, c);
                try present.append(a, 1);
                continue;
            }
            present.items[at.value_ptr.*] += 1;
            const m = &merged.items[at.value_ptr.*];
            const before = m.kind;
            infer_mod.merge(m, c, path);
            if (m.kind != before and before != .null)
                try notes.append(a, .{ .after = i, .problem = .{ .column_widened = .{ .column = m.name, .from = before, .to = m.kind, .file = path } } });
        }
    }
    if (merged.items.len == 0) return .{ .notes = notes.items, .stop = .nothing_to_infer };
    const s: Schema = .{
        .format_version = schema_mod.format_version,
        .columns = try infer_mod.columnsOf(a, merged.items),
        .nulls = try nullsOf(a, &.{""}, o.nulls),
        .match = if (all_headers) .name else .position,
        .sampled = if (o.sample_rows != null) true else null,
        // The threshold the types were inferred to: what validate needs
        // to pass these files again.
        .threshold = o.threshold,
    };
    if (try thinOf(a, merged.items, s.columns)) |p| try notes.append(a, .{ .after = null, .problem = p });
    return .{
        .schema = s,
        .notes = notes.items,
        .disagreement = try disagreement(a, merged.items, present.items, merged_files, headless, first_headless, widths),
    };
}

/// inferFile on each of paths in turn, then merge: infer from start to
/// finish, for a caller that does not run files in parallel.
pub fn infer(env: Env, arena: Allocator, paths: []const []const u8, o: Options) !Merged {
    const files = try arena.alloc(Columns, paths.len);
    for (files, paths) |*f, p| f.* = try inferFile(env, arena, p, o);
    return merge(arena, files, o);
}

/// The file at path read against s: its report. Rejected rows go to
/// rejects as CSV when it is given (docs/REPORT.md, "Reject files"); the
/// caller flushes it.
pub fn validate(env: Env, arena: Allocator, path: []const u8, s: *const Schema, o: Options, rejects: ?*Io.Writer) !File {
    var opened = try read(env, arena, path, s, o, null);
    switch (opened) {
        .stopped => |st| return report.fileOf(arena, st.outcome, .{ .verdict = st.verdict, .encoding = o.encoding }),
        .reader => |*r| {
            defer r.deinit();
            r.v.reject = rejects;
            while (try r.next()) {}
            return r.fileReport(arena, try r.finish(arena));
        },
    }
}

/// The file at path, opened to read against s a batch at a time: each
/// Reader.next leaves the rows it accepted in rows (when given), which the
/// caller owns and empties (Batch.reset) before the next call. When the
/// file stops before it is read, the result says why. Reader.finish
/// settles the outcome, Reader.fileReport makes it a report, and deinit
/// releases the reader.
pub fn read(env: Env, arena: Allocator, path: []const u8, s: *const Schema, o: Options, rows: ?*Batch) !Reader.Opened {
    var opened = try Reader.openFor(env, arena, path, s, o);
    switch (opened) {
        .reader => |*r| r.v.batch = rows,
        .stopped => {},
    }
    return opened;
}

/// The file at path, opened to hand its accepted rows (and, when want
/// says, its rejected rows) out as Arrow C streams, for a library such as
/// pyarrow, polars or DuckDB to take in the same process with no copy. When
/// the file stops before it is read, the result says why, in arena.
/// Otherwise the export holds its own copies of path and s, and lives until
/// it and every stream it hands out are released: rowsStream and
/// rejectsStream hand them out, fileReport reads what is left and reports,
/// release drops the caller's hold. env.io, and o.cancel when set, must
/// outlive it. One thread at a time; a batch handed out is the consumer's.
pub fn readArrow(env: Env, arena: Allocator, path: []const u8, s: *const Schema, o: Options, want: ArrowWant) !arrow_stream.Opened {
    return arrow_stream.Export.open(env, arena, path, s, o, want);
}

/// first, then extra: the strings read as null in every column.
fn nullsOf(a: Allocator, first: []const []const u8, extra: []const []const u8) Allocator.Error![]const []const u8 {
    return std.mem.concat(a, []const u8, &.{ first, extra });
}

/// What a column's rest says: under threshold, that it took the rest's
/// type, those values its rejected ones; without, when few values moved
/// it, which type the rest fit and the threshold that would take it.
fn restOf(c: *infer_mod.ColumnState, threshold: ?f64) ?Problem {
    const rest = infer_mod.restType(c.*) orelse return null;
    const rows = c.values + c.nulls;
    const misfits = c.misfits;
    const row = c.misfit_row;
    if (threshold) |t| if (infer_mod.tolerate(c, t))
        return .{ .column_tolerated = .{ .column = c.name, .type = rest, .misfits = misfits, .values = rows, .row = row } };
    if (!infer_mod.fewMisfits(c.*)) return null;
    // The threshold that takes the rest's type, to four places.
    const fit = @floor((1.0 - @as(f64, @floatFromInt(misfits)) / @as(f64, @floatFromInt(rows))) * 10_000) / 10_000;
    return .{ .column_misfits = .{ .column = c.name, .type = infer_mod.typeOf(c.*), .misfits = misfits, .values = rows, .row = row, .rest = rest, .threshold = fit } };
}

/// The typed columns read from too few values to trust, the first five
/// named, so the schema is looked at before the next file is held to it.
fn thinOf(a: Allocator, states: []const infer_mod.ColumnState, cols: []const schema_mod.Column) Allocator.Error!?Problem {
    var first: std.ArrayList([]const u8) = .empty;
    var n: usize = 0;
    for (states, cols) |st, c| {
        if (!infer_mod.thin(st, c)) continue;
        if (n < 5) try first.append(a, c.name);
        n += 1;
    }
    if (n == 0) return null;
    return .{ .columns_thin = .{ .columns = first.items, .count = n, .few_values = infer_mod.few_values } };
}

/// How the files of one infer run disagree, if they do: a schema merged
/// from them then fails some of them, or matches by position where a
/// header named the columns. present: how many files have each column.
fn disagreement(a: Allocator, columns: []const infer_mod.ColumnState, present: []const u32, files: u32, headless: u32, first_headless: []const u8, widths: [2]usize) Allocator.Error!?Problem {
    if (headless > 0 and headless < files)
        return .{ .files_mixed_headers = .{ .headless = headless, .files = files, .first = first_headless } };
    if (headless > 0) {
        if (widths[0] == widths[1]) return null;
        return .{ .files_widths = .{ .min = widths[0], .max = widths[1] } };
    }
    var missing: usize = 0;
    var first: std.ArrayList(problem_mod.Presence) = .empty;
    for (columns, present) |c, n| {
        if (n == files) continue;
        missing += 1;
        if (missing <= 3) try first.append(a, .{ .column = c.name, .files = n });
    }
    if (missing == 0) return null;
    return .{ .files_columns = .{ .missing = missing, .columns = columns.len, .files = files, .first = first.items } };
}

const testing = std.testing;

/// name in tmp, as a path from the build root, where tests run.
fn pathIn(a: Allocator, tmp: testing.TmpDir, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
}

test "sniff: a file's dialect, or why there is none" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env: Env = .{ .io = testing.io, .gpa = testing.allocator };
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "lugs.csv", .data = "lug_id;cultivar\n1;Starfall\n2;Quillon\n3;Brookwood\n" });
    const s = try sniff(env, try pathIn(a, tmp, "lugs.csv"), .{});
    try testing.expectEqual(report.Result.pass, s.outcome.result);
    try testing.expectEqual(@as(u8, ';'), s.verdict.?.dialect.delimiter);
    try testing.expect(s.verdict.?.dialect.header);

    const missing = try sniff(env, try pathIn(a, tmp, "none.csv"), .{});
    try testing.expectEqual(report.Result.@"error", missing.outcome.result);
    try testing.expectEqual(Problem.Code.no_such_file, std.meta.activeTag(missing.outcome.problem.?));
    try testing.expectEqual(@as(?Verdict, null), missing.verdict);
}

test "infer, then validate: a schema from two files, a file held to it, its rejects" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env: Env = .{ .io = testing.io, .gpa = testing.allocator };
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "monday.csv", .data = "lug_id,lug_kg\n1,17.5\n2,18.25\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "tuesday.csv", .data = "lug_id,lug_kg,remark\n3,16.0,frost\n" });
    const both = try infer(env, a, &.{ try pathIn(a, tmp, "monday.csv"), try pathIn(a, tmp, "tuesday.csv") }, .{});
    const s = both.schema.?;
    try testing.expectEqual(@as(usize, 3), s.columns.len);
    try testing.expectEqual(schema_mod.Type.int64, s.columns[0].type);
    try testing.expectEqual(schema_mod.Type.decimal, s.columns[1].type);
    // remark is in one file of two: they disagree, and say so.
    try testing.expectEqual(Problem.Code.files_columns, std.meta.activeTag(both.disagreement.?));
    // Every note follows a file or the run, and names a problem.
    for (both.notes) |n| if (n.after) |i| try testing.expect(i < 2);

    const monday = (try infer(env, a, &.{try pathIn(a, tmp, "monday.csv")}, .{})).schema.?;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "wednesday.csv", .data = "lug_id,lug_kg\n4,15.5\nx,19.0\n" });
    var rejects: Io.Writer.Allocating = .init(testing.allocator);
    defer rejects.deinit();
    const f = try validate(env, a, try pathIn(a, tmp, "wednesday.csv"), &monday, .{}, &rejects.writer);
    try testing.expectEqual(report.Result.fail, f.outcome.result);
    try testing.expectEqual(@as(u64, 2), f.outcome.rows);
    try testing.expectEqual(@as(u64, 1), f.read.?.rows_rejected);
    try testing.expectEqual(@import("types.zig").Reason.not_int, f.read.?.columns[0].samples[0].code);
    try testing.expectEqualStrings("lug_id,lug_kg,_row,_errors,_extra\nx,19.0,3,lug_id:not an int64,\n", rejects.written());
}

test "read: the accepted rows a batch at a time, then the outcome" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env: Env = .{ .io = testing.io, .gpa = testing.allocator };
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "lugs.csv", .data = "lug_id,lug_kg\n1,17.5\nx,18.0\n3,16.25\n" });
    var diag: schema_mod.Diagnostic = .{};
    var owned = try schema_mod.parseInline(testing.allocator, "lug_id:int64,lug_kg:decimal(4,2)", &diag);
    defer owned.deinit();
    var rows: Batch = try .init(testing.allocator, &owned.schema, .utf8);
    defer rows.deinit();
    var opened = try read(env, a, try pathIn(a, tmp, "lugs.csv"), &owned.schema, .{}, &rows);
    const r = &opened.reader;
    defer r.deinit();
    var accepted: usize = 0;
    while (try r.next()) {
        accepted += rows.rows;
        rows.reset();
    }
    try testing.expectEqual(@as(usize, 2), accepted);
    const out = try r.finish(a);
    try testing.expectEqual(@as(u64, 3), out.rows);
    try testing.expectEqual(@as(u64, 1), out.rows_rejected);
    const f = try r.fileReport(a, out);
    try testing.expectEqual(@as(u64, 1), f.read.?.columns[0].mismatches);
}

test "cancel: the caller's own flag stops a call" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env: Env = .{ .io = testing.io, .gpa = testing.allocator };
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "lugs.csv", .data = "lug_id\n1\n2\n" });
    var diag: schema_mod.Diagnostic = .{};
    var owned = try schema_mod.parseInline(testing.allocator, "lug_id:int64", &diag);
    defer owned.deinit();
    const path = try pathIn(a, tmp, "lugs.csv");
    var stop: std.atomic.Value(bool) = .init(true);
    try testing.expectError(error.Interrupted, validate(env, a, path, &owned.schema, .{ .cancel = &stop }, null));
    try testing.expectError(error.Interrupted, inferFile(env, a, path, .{ .cancel = &stop }));
    stop.store(false, .release);
    const f = try validate(env, a, path, &owned.schema, .{ .cancel = &stop }, null);
    try testing.expectEqual(report.Result.pass, f.outcome.result);
}

/// What a consumer such as pyarrow makes of an Arrow C stream: its schema,
/// then its batches to the end, each released as it is read.
const Drained = struct { batches: usize = 0, rows: i64 = 0 };

fn drain(stream: *ArrowArrayStream) !Drained {
    var d: Drained = .{};
    var s: ArrowSchema = undefined;
    if (stream.get_schema.?(stream, &s) != 0) return error.StreamFailed;
    s.release.?(&s);
    while (true) {
        var a: ArrowArray = undefined;
        if (stream.get_next.?(stream, &a) != 0) return error.StreamFailed;
        const release = a.release orelse return d;
        d.batches += 1;
        d.rows += a.length;
        release(&a);
    }
}

/// Row i of a utf8 array.
fn textOf(a: *const ArrowArray, i: usize) []const u8 {
    const offsets: [*]const i32 = @ptrCast(@alignCast(a.buffers.?[1].?));
    const data: [*]const u8 = @ptrCast(a.buffers.?[2].?);
    return data[@intCast(offsets[i])..@intCast(offsets[i + 1])];
}

test "readArrow: the rows and the rejected rows as Arrow C streams, in either order" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env: Env = .{ .io = testing.io, .gpa = testing.allocator };
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "lugs.csv", .data = "lug_id,lug_kg\n1,17.5\nx,18.0\n3,16.25\n4\n" });
    var diag: schema_mod.Diagnostic = .{};
    var owned = try schema_mod.parseInline(testing.allocator, "lug_id:int64,lug_kg:decimal(4,2)", &diag);
    const e = (try readArrow(env, a, try pathIn(a, tmp, "lugs.csv"), &owned.schema, .{}, .{ .rejects = true })).ready;
    var rows: ArrowArrayStream = undefined;
    var rejects: ArrowArrayStream = undefined;
    try e.rowsStream(&rows);
    try e.rejectsStream(&rejects);
    var again: ArrowArrayStream = undefined;
    try testing.expectError(error.AlreadyTaken, e.rowsStream(&again));
    // The export has its own schema, and the streams hold the export.
    owned.deinit();
    e.release();

    var s: ArrowSchema = undefined;
    try testing.expectEqual(@as(c_int, 0), rejects.get_schema.?(&rejects, &s));
    for ([_][]const u8{ "lug_id", "lug_kg", "_row", "_errors", "_extra" }, s.children.?[0..5]) |want, c|
        try testing.expectEqualStrings(want, std.mem.span(c.name.?));
    s.release.?(&s);
    var b: ArrowArray = undefined;
    try testing.expectEqual(@as(c_int, 0), rejects.get_next.?(&rejects, &b));
    try testing.expectEqual(@as(i64, 2), b.length);
    const lines: [*]const i64 = @ptrCast(@alignCast(b.children.?[2].buffers.?[1].?));
    try testing.expectEqualSlices(i64, &.{ 3, 5 }, lines[0..2]);
    const item = b.children.?[3].children.?[0];
    try testing.expectEqualStrings("lug_id", textOf(item.children.?[0], 0));
    try testing.expectEqualStrings("not_int", textOf(item.children.?[1], 0));
    try testing.expectEqualStrings("ragged", textOf(item.children.?[1], 1));
    // The short row's missing field is a null, not an empty string.
    try testing.expectEqual(@as(i64, 1), b.children.?[1].null_count);
    b.release.?(&b);
    try testing.expectEqual(@as(c_int, 0), rejects.get_next.?(&rejects, &b));
    try testing.expect(b.release == null);
    rejects.release.?(&rejects);

    // The rows waited for their stream.
    const d = try drain(&rows);
    try testing.expectEqual(@as(i64, 2), d.rows);
    rows.release.?(&rows);
}

/// lugs.csv in tmp, rows of it: more than one batch's worth.
fn manyRows(tmp: testing.TmpDir, rows: usize) !void {
    var text: Io.Writer.Allocating = .init(testing.allocator);
    defer text.deinit();
    try text.writer.writeAll("lug_id,remark\n");
    for (0..rows) |i| try text.writer.print("{d},row {d}\n", .{ i, i });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "lugs.csv", .data = text.written() });
}

test "readArrow: a consumer that stops early, in any order, leaks nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env: Env = .{ .io = testing.io, .gpa = testing.allocator };
    try manyRows(tmp, 70_000);
    const path = try pathIn(a, tmp, "lugs.csv");
    var diag: schema_mod.Diagnostic = .{};
    var owned = try schema_mod.parseInline(testing.allocator, "lug_id:int64,remark:string", &diag);
    defer owned.deinit();

    // One batch kept past the stream and the export.
    {
        const e = (try readArrow(env, a, path, &owned.schema, .{}, .{})).ready;
        var rows: ArrowArrayStream = undefined;
        try e.rowsStream(&rows);
        var b: ArrowArray = undefined;
        try testing.expectEqual(@as(c_int, 0), rows.get_next.?(&rows, &b));
        // A batch of records, the header one of the first.
        try testing.expectEqual(@as(i64, 65_535), b.length);
        rows.release.?(&rows);
        e.release();
        try testing.expectEqualStrings("row 7", textOf(b.children.?[1], 7));
        b.release.?(&b);
    }
    // Streams taken and never read, the export released last.
    {
        const e = (try readArrow(env, a, path, &owned.schema, .{}, .{ .rejects = true })).ready;
        var rows: ArrowArrayStream = undefined;
        var rejects: ArrowArrayStream = undefined;
        try e.rowsStream(&rows);
        try e.rejectsStream(&rejects);
        rejects.release.?(&rejects);
        rows.release.?(&rows);
        e.release();
    }
    // The report read with a stream still open: its batches wait for it,
    // and are released with it.
    {
        const e = (try readArrow(env, a, path, &owned.schema, .{}, .{})).ready;
        var rows: ArrowArrayStream = undefined;
        try e.rowsStream(&rows);
        const f = try e.fileReport(a);
        try testing.expectEqual(report.Result.pass, f.outcome.result);
        try testing.expectEqual(@as(u64, 70_000), f.outcome.rows);
        e.release();
        var b: ArrowArray = undefined;
        try testing.expectEqual(@as(c_int, 0), rows.get_next.?(&rows, &b));
        b.release.?(&b);
        rows.release.?(&rows);
    }
    // No stream asked for: the export only validates.
    {
        const e = (try readArrow(env, a, path, &owned.schema, .{}, .{ .rows = false })).ready;
        defer e.release();
        var rows: ArrowArrayStream = undefined;
        try testing.expectError(error.NotWanted, e.rowsStream(&rows));
        try testing.expectError(error.NotWanted, e.rejectsStream(&rows));
        try testing.expectEqual(@as(u64, 70_000), (try e.fileReport(a)).outcome.rows);
    }
}

test "readArrow: a stream stops where the read does, and says why" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env: Env = .{ .io = testing.io, .gpa = testing.allocator };
    var diag: schema_mod.Diagnostic = .{};
    var owned = try schema_mod.parseInline(testing.allocator, "lug_id:int64,bin:string,cultivar:string", &diag);
    defer owned.deinit();

    // Stopped before it is read: no export.
    const missing = try readArrow(env, a, try pathIn(a, tmp, "none.csv"), &owned.schema, .{}, .{});
    try testing.expectEqual(Problem.Code.no_such_file, std.meta.activeTag(missing.stopped.outcome.problem.?));
    const sniffed = try readArrow(env, a, "test/cli/inches.txt", &owned.schema, .{}, .{});
    try testing.expectEqual(Problem.Code.quote_is_data, std.meta.activeTag(sniffed.stopped.outcome.problem.?));

    // The quotes are data past the sniff's sample: the rows handed out are
    // not the file's, so the stream ends in the problem, not at an end.
    {
        const e = (try readArrow(env, a, "test/cli/inches.txt", &owned.schema, .{ .sample_bytes = 512 }, .{})).ready;
        defer e.release();
        var rows: ArrowArrayStream = undefined;
        try e.rowsStream(&rows);
        defer rows.release.?(&rows);
        try testing.expectError(error.StreamFailed, drain(&rows));
        const message = std.mem.span(rows.get_last_error.?(&rows).?);
        try testing.expect(std.mem.endsWith(u8, message, "pin --quote none to read quotes as data"));
        try testing.expect(std.mem.startsWith(u8, message, "test/cli/inches.txt: the quotes look like data"));
        const f = try e.fileReport(a);
        try testing.expectEqual(report.Result.@"error", f.outcome.result);
        try testing.expectEqual(Problem.Code.quote_is_data, std.meta.activeTag(f.outcome.problem.?));
    }

    // The caller's cancel: EINTR, and the report is that error.
    try manyRows(tmp, 10);
    var stop: std.atomic.Value(bool) = .init(true);
    var lugs = try schema_mod.parseInline(testing.allocator, "lug_id:int64,remark:string", &diag);
    defer lugs.deinit();
    const e = (try readArrow(env, a, try pathIn(a, tmp, "lugs.csv"), &lugs.schema, .{ .cancel = &stop }, .{})).ready;
    defer e.release();
    var rows: ArrowArrayStream = undefined;
    try e.rowsStream(&rows);
    defer rows.release.?(&rows);
    var b: ArrowArray = undefined;
    try testing.expectEqual(@as(c_int, 4), rows.get_next.?(&rows, &b));
    try testing.expect(std.mem.endsWith(u8, std.mem.span(rows.get_last_error.?(&rows).?), "lugs.csv: interrupted"));
    try testing.expectError(error.Interrupted, e.fileReport(a));
}

test "the library imports nothing of the CLI's" {
    // Every file lib.zig reaches; main, cli, pool and interrupt are the
    // CLI's: its arguments, its parallel runs, its Ctrl-C.
    const sources = [_][]const u8{
        @embedFile("lib.zig"),           @embedFile("worker.zig"),        @embedFile("report.zig"),
        @embedFile("problem.zig"),       @embedFile("dialect.zig"),       @embedFile("records.zig"),
        @embedFile("reference.zig"),     @embedFile("scan.zig"),          @embedFile("input.zig"),
        @embedFile("schema.zig"),        @embedFile("validate.zig"),      @embedFile("infer.zig"),
        @embedFile("builders.zig"),      @embedFile("types.zig"),         @embedFile("types/bool.zig"),
        @embedFile("types/date.zig"),    @embedFile("types/decimal.zig"), @embedFile("types/enum.zig"),
        @embedFile("types/float.zig"),   @embedFile("types/int.zig"),     @embedFile("types/time.zig"),
        @embedFile("types/utf8.zig"),    @embedFile("write/arrow.zig"),   @embedFile("write/csv.zig"),
        @embedFile("write/flatbuf.zig"), @embedFile("write/arrow_c.zig"), @embedFile("arrow_stream.zig"),
    };
    // Spelled in two pieces, so this file does not hold them whole.
    const cli_files = [_][]const u8{ "@import(\"" ++ "cli.zig\")", "@import(\"" ++ "pool.zig\")", "@import(\"" ++ "interrupt.zig\")", "@import(\"" ++ "main.zig\")" };
    for (sources) |src| for (cli_files) |f| try testing.expect(std.mem.find(u8, src, f) == null);
}
