//! docs/REPORT.md against the code. Each JSON document thresh writes is
//! written here with every field it can have, and held to the doc's table
//! for it: every field written has a row, of the type the row says, and
//! every row is a field thresh still writes. So a field renamed or removed
//! fails this until the doc drops its row, which docs/REPORT.md's
//! "Versions" says needs a new format_version. Only main.zig's tests
//! reference this file, as only its module embeds the doc.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;
const dialect = @import("dialect.zig");
const lib = @import("lib.zig");
const Problem = @import("problem.zig").Problem;
const Field = @import("records.zig").Field;
const reference = @import("reference.zig");
const report = @import("report.zig");
const schema = @import("schema.zig");
const stats = @import("stats.zig");
const validate = @import("validate.zig");

const doc_text = @embedFile("report_doc");

/// A field's JSON types, as a row's second cell names them. A problem is an
/// object PROBLEMS.md describes, held to it by problems_doc_test.zig; a
/// schema is one the schema's own table describes, held to it below.
const Kind = enum { string, integer, number, boolean, null, array, object, problem, schema };
const Kinds = std.EnumSet(Kind);

const Row = struct { kinds: Kinds, meaning: []const u8 };
const Rows = std.StringArrayHashMapUnmanaged(Row);

/// The table after `<!-- fields: name -->`: each row's field, the types
/// named in backticks in its second cell, and its third.
fn documented(a: Allocator, name: []const u8) !Rows {
    const marker = try std.fmt.allocPrint(a, "<!-- fields: {s} -->", .{name});
    const at = std.mem.find(u8, doc_text, marker) orelse {
        std.debug.print("docs/REPORT.md: no {s}\n", .{marker});
        return error.TestUnexpectedResult;
    };
    var rows: Rows = .empty;
    var lines = std.mem.splitScalar(u8, doc_text[at + marker.len ..], '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "|")) break;
        if (!std.mem.startsWith(u8, line, "| `")) continue;
        var cells = std.mem.splitScalar(u8, line, '|');
        _ = cells.next();
        const path = std.mem.trim(u8, cells.next().?, " `");
        var ticks = std.mem.splitScalar(u8, cells.next() orelse "", '`');
        var row: Row = .{ .kinds = .empty, .meaning = std.mem.trim(u8, cells.next() orelse "", " ") };
        var inside = false;
        while (ticks.next()) |t| : (inside = !inside) {
            if (!inside) continue;
            row.kinds.insert(std.meta.stringToEnum(Kind, t) orelse {
                std.debug.print("docs/REPORT.md: {s} `{s}`: no type '{s}'\n", .{ name, path, t });
                return error.TestUnexpectedResult;
            });
        }
        try rows.put(a, path, row);
    }
    return rows;
}

fn kindOf(v: std.json.Value) Kind {
    return switch (v) {
        .null => .null,
        .bool => .boolean,
        .integer => .integer,
        .float, .number_string => .number,
        .string => .string,
        .array => .array,
        .object => .object,
    };
}

/// Each field under v, at its path: `a.b` for a field of an object,
/// `a[]` for an array's items, `a{}` for a map's values (a row for
/// `a{}` says a is one), and no further into a problem or a schema. An
/// array's objects need no row of their own: their fields have them.
fn walk(a: Allocator, rows: *const Rows, seen: *std.StringArrayHashMapUnmanaged(Kinds), path: []const u8, v: std.json.Value) !void {
    const items_of_their_own = v == .object and std.mem.endsWith(u8, path, "[]") and !rows.contains(path);
    if (path.len > 0 and !items_of_their_own) {
        const kind: Kind = if (v == .object and rows.contains(path) and rows.get(path).?.kinds.contains(.problem)) kind: {
            const code = v.object.get("code");
            const message = v.object.get("message");
            if (code == null or code.? != .string or message == null or message.? != .string) {
                std.debug.print("`{s}`: a problem without its code and message\n", .{path});
                return error.TestUnexpectedResult;
            }
            break :kind .problem;
        } else if (v == .object and rows.contains(path) and rows.get(path).?.kinds.contains(.schema)) kind: {
            if (v.object.get("columns") == null) {
                std.debug.print("`{s}`: a schema without its columns\n", .{path});
                return error.TestUnexpectedResult;
            }
            break :kind .schema;
        } else kindOf(v);
        const kinds = try seen.getOrPut(a, path);
        if (!kinds.found_existing) kinds.value_ptr.* = .empty;
        kinds.value_ptr.insert(kind);
        if (kind == .problem or kind == .schema) return;
    }
    switch (v) {
        .array => |items| {
            const sub = try std.fmt.allocPrint(a, "{s}[]", .{path});
            for (items.items) |item| try walk(a, rows, seen, sub, item);
        },
        .object => |o| {
            const map = try std.fmt.allocPrint(a, "{s}{{}}", .{path});
            for (o.keys(), o.values()) |k, item| {
                const sub = if (rows.contains(map)) map else if (path.len == 0) k else try std.fmt.allocPrint(a, "{s}.{s}", .{ path, k });
                try walk(a, rows, seen, sub, item);
            }
        },
        else => {},
    }
}

/// The documents against the doc's table for name; each says it is
/// version.
fn expectDocumented(a: Allocator, name: []const u8, version: u32, texts: []const []const u8) !std.StringArrayHashMapUnmanaged(Kinds) {
    return expectRows(a, name, try documented(a, name), version, texts);
}

/// A description's rows: the report's, but its timing, and its own.
fn descriptionRows(a: Allocator) !Rows {
    var rows = try documented(a, "report");
    for ([_][]const u8{ "timing_ms", "timing_ms.sniff", "timing_ms.parse", "timing_ms.write", "throughput_mb_s" }) |p| {
        if (!rows.orderedRemove(p)) return error.TestUnexpectedResult;
    }
    const own = try documented(a, "describe");
    for (own.keys(), own.values()) |k, v| try rows.put(a, k, v);
    return rows;
}

fn expectRows(a: Allocator, name: []const u8, rows: Rows, version: u32, texts: []const []const u8) !std.StringArrayHashMapUnmanaged(Kinds) {
    var seen: std.StringArrayHashMapUnmanaged(Kinds) = .empty;
    for (texts) |text| {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
        const said = v.object.get("format_version") orelse .null;
        if (said != .integer or said.integer != version) {
            std.debug.print("a {s} says format_version {f}, not {d}\n", .{ name, std.json.fmt(said, .{}), version });
            return error.TestUnexpectedResult;
        }
        try walk(a, &rows, &seen, "", v);
    }
    var ok = true;
    for (seen.keys(), seen.values()) |path, kinds| {
        const row = rows.get(path) orelse {
            std.debug.print("docs/REPORT.md: the {s} writes `{s}`, which has no row: add one (a field added needs no new format_version)\n", .{ name, path });
            ok = false;
            continue;
        };
        var it = kinds.iterator();
        while (it.next()) |k| {
            if (row.kinds.contains(k) or (k == .integer and row.kinds.contains(.number))) continue;
            std.debug.print("docs/REPORT.md: the {s}'s `{s}` is {t} where its row says otherwise: a field's type changed needs a new format_version\n", .{ name, path, k });
            ok = false;
        }
    }
    for (rows.keys()) |path| if (!seen.contains(path)) {
        std.debug.print("docs/REPORT.md: the {s}'s `{s}` has a row and thresh did not write it: a field removed or renamed needs a new format_version (docs/REPORT.md, \"Versions\"); a field kept needs a value here that writes it\n", .{ name, path });
        ok = false;
    };
    if (!ok) return error.TestUnexpectedResult;
    return seen;
}

/// Each of E's values is named in backticks in the row for path.
fn expectValues(a: Allocator, name: []const u8, path: []const u8, comptime E: type) !void {
    const rows = try documented(a, name);
    const meaning = (rows.get(path) orelse return error.TestUnexpectedResult).meaning;
    for (std.enums.values(E)) |e| {
        const want = try std.fmt.allocPrint(a, "`{t}`", .{e});
        if (std.mem.find(u8, meaning, want) == null) {
            std.debug.print("docs/REPORT.md: the {s}'s `{s}` does not list {s}: a value added to a closed list needs a new format_version\n", .{ name, path, want });
            return error.TestUnexpectedResult;
        }
    }
}

/// A file with a value that does not fit, ambiguous dates, a column the
/// schema does not have, a repeated header, a ragged row, and a bad row
/// longer than the report keeps of it.
const sample_input =
    "lug_id,picked_on,picked,remark\n" ++
    "1,2024-01-02,03/04/2024,a\n" ++
    "x,2024-01-03,05/06/2024,b\n" ++
    "lug_id,picked_on,picked,remark\n" ++
    "4,2024-01-04,07/08/2024,c,d\n" ++
    "5,2024-01-05,09/10/2024,e\n" ++
    "y,2024-01-06,11/12/2024," ++ long_remark ++ "\n";

const long_remark: [320]u8 = @splat('z');

const sample_schema: schema.Schema = .{ .columns = &.{
    .{ .name = "lug_id", .type = .int64 },
    .{ .name = "picked_on", .type = .date, .format = "%Y-%m-%d" },
    .{ .name = "picked", .type = .date },
} };

fn verdict(quote: ?u8) dialect.Verdict {
    return .{
        .dialect = .{ .delimiter = ',', .quote = quote, .escape = .doubled, .newline = .lf, .header = true, .comment = '#' },
        .confidence = .high,
        .score = 1.5,
        .consistency = 1,
        .fields = 4,
        .records = 6,
        .sample_len = sample_input.len,
        .start = 0,
        .warnings = .{ .utf8_bom = true },
        .runners_up = .{ .{ .delimiter = ';', .score = 0.25 }, .{ .delimiter = '\t', .score = 0.125 } },
    };
}

fn written(a: Allocator, comptime f: anytype, args: anytype) ![]const u8 {
    var w: Io.Writer.Allocating = .init(a);
    try @call(.auto, f, .{&w.writer} ++ args);
    return w.written();
}

const ok_outcome: report.Outcome = .{ .file = "a.csv", .bytes = 120, .rows = 5, .result = .pass, .written = "out/a.csv" };

/// Column statistics with every field set: past every cap, and sampled.
const full_stats: stats.Summary = .{
    .values = 70_000,
    .empty = 12,
    .length = .{ .min = 4, .max = 5 },
    .min = "14.30",
    .max = "22.90",
    .distinct = 1000,
    .distinct_at_least = true,
    .top = &.{ .{ .value = "18.10", .count = 840 }, .{ .value = "14.70", .count = 610 } },
    .top_estimated = true,
    .shapes = &.{.{ .shape = "9.9", .count = 65_536 }},
    .shapes_estimated = true,
    .sampled = 65_536,
};
const error_outcome: report.Outcome = .{ .file = "b.csv", .result = .@"error", .problem = .{ .header_width = .{ .header_fields = 3, .fields = 4 } } };

test "docs/REPORT.md: the reports' fields, as thresh writes them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var v: validate.Validator = try .init(testing.allocator, &sample_schema, verdict('"').dialect, .{ .stats = true });
    defer v.deinit();
    var p: reference.Parser = .init(sample_input, .rfc4180, .{});
    var fields: std.ArrayList(Field) = .empty;
    defer fields.deinit(testing.allocator);
    var first = true;
    while (try p.next(testing.allocator, &fields)) |rec| {
        if (first) {
            first = false;
            try v.columns(fields.items, fields.items.len, sample_input, 0);
        } else try v.record(rec, fields.items, sample_input, 0);
    }
    try v.structural.append(testing.allocator, .{ .column_missing = .{ .column = "brix" } });
    const read: report.Outcome = .{
        .file = "a.csv",
        .bytes = sample_input.len,
        .rows = v.rows,
        .rows_rejected = v.rejected,
        .result = .fail,
        .timing = .{ .sniff_ns = 1_000_000, .parse_ns = 2_000_000, .write_ns = 3_000_000 },
    };
    const files = [_]report.File{
        try report.fileOf(a, read, .{ .verdict = verdict('"'), .validator = &v }),
        try report.fileOf(a, error_outcome, .{ .verdict = verdict(null) }),
        try report.fileOf(a, error_outcome, .{}),
        // A column's statistics, every field of them.
        .{ .outcome = ok_outcome, .read = .{
            .columns = &.{.{ .name = "lug_kg", .type = .decimal, .nulls = 0, .mismatches = 0, .conformance = 1, .stats = full_stats }},
            .rows_rejected = 0,
            .rejected_sample = &.{},
            .row_errors = .initFill(0),
            .repeated_header_rows = &.{},
        } },
    };
    var reports: [files.len][]const u8 = undefined;
    for (&reports, files) |*r, f| r.* = try written(a, report.writeFileReport, .{ f, true });
    _ = try expectDocumented(a, "report", report.format_version, &reports);
    // A description of each, inferred with a note, given, or of a file
    // that could not be read.
    var descriptions: [files.len][]const u8 = undefined;
    for (&descriptions, files, 0..) |*d, f, i| d.* = try written(a, lib.writeDescription, .{ lib.Description{
        .file = f,
        .schema = if (i == 2) null else sample_schema,
        .inferred = i != 1,
        .notes = if (i == 0) &.{.{ .rows_wider = .{ .rows = 1, .line = 5 } }} else &.{},
        .encoding = "utf8",
    }, i % 2 == 0 });
    _ = try expectRows(a, "describe", try descriptionRows(a), report.format_version, &descriptions);
    _ = try expectDocumented(a, "summary", report.format_version, &.{
        try written(a, report.writeSummary, .{ &[_]report.Outcome{ ok_outcome, error_outcome }, @as(u8, 2) }),
    });
    _ = try expectDocumented(a, "line", report.format_version, &.{
        try written(a, report.writeJsonLine, .{ok_outcome}),
        try written(a, report.writeJsonLine, .{error_outcome}),
    });
    _ = try expectDocumented(a, "sniff", report.format_version, &.{
        try written(a, report.writeSniffLine, .{ "a.csv", verdict('"'), &[_]Problem{.{ .quote_is_data = .{ .records = 1, .lines = 3, .line = 62 } }} }),
        try written(a, report.writeSniffLine, .{ "b.csv", verdict(null), &[_]Problem{} }),
        // The library's sniff of a file it cannot read.
        try written(a, report.writeSniffLine, .{ "c.csv", null, &[_]Problem{.no_such_file} }),
    });
    // Two files, one unreadable; a note on a file and one on the run; the
    // files disagree. And a run with nothing to infer from.
    const inferred = [_]lib.Columns{ .{ .outcome = ok_outcome }, .{ .outcome = error_outcome } };
    _ = try expectDocumented(a, "infer", report.format_version, &.{
        try written(a, lib.writeInferResult, .{ &inferred, lib.Merged{
            .schema = sample_schema,
            .notes = &.{
                .{ .after = 0, .problem = .{ .header_repeated = .{ .line = 4, .count = 1 } } },
                .{ .after = null, .problem = .{ .columns_thin = .{ .columns = &.{"lug_id"}, .count = 1, .few_values = 5 } } },
            },
            .disagreement = .{ .files_widths = .{ .min = 3, .max = 4 } },
        } }),
        try written(a, lib.writeInferResult, .{ inferred[1..], lib.Merged{ .stop = .nothing_to_infer } }),
    });
    try expectValues(a, "infer", "files[].result", enum { pass, @"error" });

    for ([_][]const u8{ "report", "sniff" }) |name| {
        try expectValues(a, name, "dialect.escape", dialect.Dialect.Escape);
        try expectValues(a, name, "dialect.newline", dialect.Dialect.Newline);
        try expectValues(a, name, "dialect.confidence", dialect.Confidence);
    }
    try expectValues(a, "report", "result", report.Result);
    // Each limit's row says the number thresh writes.
    const doc_rows = try documented(a, "report");
    const limits = (try std.json.parseFromSliceLeaky(std.json.Value, a, try written(a, report.writeFileReport, .{ try report.fileOf(a, read, .{ .validator = &v }), false }), .{})).object.get("limits").?.object;
    for (limits.keys(), limits.values()) |k, n| {
        const meaning = doc_rows.get(try std.fmt.allocPrint(a, "limits.{s}", .{k})).?.meaning;
        if (!std.mem.endsWith(u8, meaning, try std.fmt.allocPrint(a, "{d}", .{n.integer}))) {
            std.debug.print("docs/REPORT.md: `limits.{s}` says \"{s}\"; thresh writes {d}\n", .{ k, meaning, n.integer });
            return error.TestUnexpectedResult;
        }
    }
    try expectValues(a, "summary", "results[].result", report.Result);
    try expectValues(a, "line", "result", report.Result);
    try expectValues(a, "report", "columns[].type", schema.Type);
}

test "docs/REPORT.md: the schema's fields, as infer writes and --schema reads them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Every field set, so each is written.
    const full: schema.Schema = .{
        .format_version = schema.format_version,
        .columns = &.{
            .{ .name = "lug_id", .type = .int64, .nullable = false, .inferred = true, .conformance = 0.5, .samples = &.{"1"}, .widened_by = "b.csv" },
            .{ .name = "lug_kg", .type = .decimal, .precision = 18, .scale = 2, .stats = full_stats },
            .{ .name = "picked_on", .type = .date, .format = "%d/%m/%Y", .day_first = true, .nulls = &.{"-"} },
            .{ .name = "cultivar", .type = .@"enum", .values = &.{ "Starfall", "Quillon" }, .case_insensitive = true },
            .{ .name = "remark", .type = .string, .max_len = 200, .utf8 = .replace },
            .{ .name = "bruised", .type = .bool, .true_values = &.{"Y"}, .false_values = &.{"N"} },
        },
        .nulls = &.{ "", "NULL" },
        .match = .name,
        .threshold = 0.99,
        .sampled = true,
    };
    var w: Io.Writer.Allocating = .init(a);
    try schema.writeJson(full, &w.writer);
    const text = w.written();
    const seen = try expectDocumented(a, "schema", schema.format_version, &.{text});
    // A field of the structs that the schema above leaves out would be
    // one the doc is never held to.
    // The schema an infer result holds is written the same way.
    var nested: Io.Writer.Allocating = .init(a);
    try lib.writeInferResult(&nested.writer, &.{}, .{ .schema = full });
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, nested.written(), .{});
    var alone: Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(parsed.object.get("schema").?, .{}, &alone.writer);
    _ = try expectDocumented(a, "schema", schema.format_version, &.{alone.written()});
    inline for (@typeInfo(schema.Schema).@"struct".field_names) |f| try testing.expect(seen.contains(f));
    inline for (@typeInfo(schema.Column).@"struct".field_names) |f| try testing.expect(seen.contains("columns[]." ++ f));
    // What infer writes, --schema reads.
    var diag: schema.Diagnostic = .{};
    var back = try schema.parseJson(testing.allocator, text, &diag);
    back.deinit();

    try expectValues(a, "schema", "columns[].type", schema.Type);
    try expectValues(a, "schema", "columns[].utf8", schema.Utf8Policy);
    try expectValues(a, "schema", "match", schema.Match);
}

test "docs/REPORT.md: its changes reach each version thresh writes" {
    const changes = doc_text[std.mem.find(u8, doc_text, "\n## Changes\n").?..];
    for ([_]struct { []const u8, u32 }{ .{ "reports", report.format_version }, .{ "schema", schema.format_version } }) |c| {
        var last: u32 = 0;
        var lines = std.mem.splitScalar(u8, changes, '\n');
        _ = lines.next();
        _ = lines.next();
        while (lines.next()) |line| {
            if (line.len > 0 and !std.mem.startsWith(u8, line, "|")) break;
            var cells = std.mem.splitScalar(u8, line, '|');
            _ = cells.next();
            if (!std.mem.eql(u8, std.mem.trim(u8, cells.next() orelse "", " "), c[0])) continue;
            last = @max(last, std.fmt.parseInt(u32, std.mem.trim(u8, cells.next().?, " "), 10) catch continue);
        }
        if (last != c[1]) {
            std.debug.print("docs/REPORT.md: the changes reach {s} version {d}; thresh writes {d}\n", .{ c[0], last, c[1] });
            return error.TestUnexpectedResult;
        }
    }
}
