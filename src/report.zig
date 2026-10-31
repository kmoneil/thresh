//! What a run says about each file: the per-file JSON report, written by
//! the worker as it finishes so a crash elsewhere loses nothing already
//! done; summary.json over them all; and a line per file on stderr, or a
//! JSON object per file on stdout. docs/REPORT.md describes every field,
//! and src/format_test.zig holds the code to it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const dialect = @import("dialect.zig");
const Problem = @import("problem.zig").Problem;
const schema = @import("schema.zig");
const types = @import("types.zig");
const stats = @import("stats.zig");
const validate = @import("validate.zig");

/// The version of every JSON document this file writes (the report,
/// summary.json, the --json lines and sniff's): each starts with it. A
/// field added leaves it as it is; a field removed or renamed, or a value
/// that changes type or meaning, takes it to the next number, with a line
/// in docs/REPORT.md's changes. The schema has its own, schema.format_version.
pub const format_version: u32 = 1;

pub const Result = enum {
    pass,
    fail,
    /// The file could not be read, or its dialect could not be settled.
    @"error",

    pub fn exitCode(r: Result) u8 {
        return switch (r) {
            .pass => 0,
            .fail => 1,
            .@"error" => 2,
        };
    }
};

pub const Timing = struct {
    sniff_ns: u64 = 0,
    /// Reading, validating and building the typed columns.
    parse_ns: u64 = 0,
    /// convert and run: writing the output, apart from parse_ns.
    write_ns: u64 = 0,
};

/// One file's outcome, as the summary and the stderr line need it.
pub const Outcome = struct {
    file: []const u8,
    bytes: u64 = 0,
    rows: u64 = 0,
    rows_rejected: u64 = 0,
    result: Result,
    /// The first structural error, or why the file could not be read.
    problem: ?Problem = null,
    /// convert and run: the output file written.
    written: ?[]const u8 = null,
    timing: Timing = .{},

    pub fn throughput(o: Outcome) f64 {
        const ns = o.timing.parse_ns + o.timing.write_ns;
        if (ns == 0) return 0;
        return @as(f64, @floatFromInt(o.bytes)) / 1e6 / (@as(f64, @floatFromInt(ns)) / 1e9);
    }
};

/// What fileOf reads besides the outcome.
pub const Details = struct {
    verdict: ?dialect.Verdict = null,
    validator: ?*const validate.Validator = null,
    /// The file's, so sample values become UTF-8.
    encoding: types.Encoding = .utf8,
};

/// A file's report as data: built from the validator by fileOf, written as
/// JSON by writeFileReport, and what the library hands its caller. Its
/// strings are its own and UTF-8, whatever the file's encoding.
pub const File = struct {
    outcome: Outcome,
    /// How the file is written, when it was sniffed.
    verdict: ?dialect.Verdict = null,
    /// What reading it against its schema found, when it was.
    read: ?Read = null,
    /// What stopped or failed it.
    problems: []const Problem = &.{},
    warnings: Warnings = .{},
};

/// What reading a file against its schema found.
pub const Read = struct {
    /// One a schema column, in the schema's order.
    columns: []const Column,
    rows_rejected: u64,
    /// The source lines of the first rejected rows.
    rejected_sample: []const u64,
    /// The first rejected rows as the file has them, and why.
    rejected_lines: []const Line = &.{},
    /// Rows rejected whole, by why.
    row_errors: std.EnumArray(types.Reason, u64),
    /// The source lines of the first repeats of the header, skipped.
    repeated_header_rows: []const u64,
};

/// A schema column, as the file filled it.
pub const Column = struct {
    name: []const u8,
    type: schema.Type,
    nulls: u64,
    mismatches: u64,
    /// Of the rows read into columns, the fraction whose value fits.
    conformance: f64,
    format: ?[]const u8 = null,
    /// A date or timestamp column: values whose order of day, month and
    /// year is a guess; and, when there are any, the orders all still fit.
    ambiguous: ?u64 = null,
    fits: Fits = .{},
    /// The first values that do not fit.
    samples: []const Sample = &.{},
    /// What its values are like, when they were asked for (stats.zig).
    stats: ?stats.Summary = null,
};

pub const Fits = struct { month_first: bool = false, day_first: bool = false, year_first: bool = false };

/// A rejected row as the file has it.
pub const Line = struct {
    /// The source line its record starts on.
    row: u64,
    /// The record without its line break, in UTF-8: its first
    /// validate.max_line_len bytes.
    text: []const u8,
    /// When text is cut: the record's length in bytes.
    length: ?u64 = null,
    errors: []const LineError,
};

/// One thing wrong with a rejected row: the column it is in, or null for
/// the whole row, and why.
pub const LineError = struct { column: ?[]const u8 = null, code: types.Reason };

pub const Sample = struct {
    /// The source line its record starts on.
    row: u64,
    /// Its first validate.max_sample_len bytes, as UTF-8.
    value: []const u8,
    code: types.Reason,
};

/// What is unusual about a file: the sniffer's warnings and what reading
/// it added to them, and two of the read's own.
pub const Warnings = struct {
    dialect: dialect.Warnings = .{},
    /// The header has columns the schema does not.
    extra_columns: bool = false,
    /// Records that were the header again were skipped.
    header_repeated: bool = false,
};

/// The report of the file o is the outcome of, its strings in a.
pub fn fileOf(a: Allocator, o: Outcome, d: Details) Allocator.Error!File {
    var f: File = .{ .outcome = o, .verdict = d.verdict };
    f.outcome.file = try a.dupe(u8, o.file);
    if (o.problem) |p| f.outcome.problem = try p.dupe(a);
    if (o.written) |p| f.outcome.written = try a.dupe(u8, p);
    if (d.verdict) |v| f.warnings.dialect = v.warnings;
    const v = d.validator orelse {
        if (f.outcome.problem) |p| f.problems = try a.dupe(Problem, &.{p});
        return f;
    };
    if (v.stray_quotes > 0) f.warnings.dialect.quote_in_unquoted = true;
    if (v.foreign_newlines > 0) f.warnings.dialect.mixed_newlines = true;
    f.warnings.extra_columns = v.extra_columns;
    f.warnings.header_repeated = v.repeated_headers > 0;
    const columns = try a.alloc(Column, v.schema.columns.len);
    for (columns, v.schema.columns, v.stats, v.dates, 0..) |*col, c, st, dc, col_index| {
        col.* = .{
            .name = try a.dupe(u8, c.name),
            .type = c.type,
            .nulls = st.nulls,
            .mismatches = st.mismatches,
            .conformance = validate.conformance(st, v.columnRows()),
            .format = if (c.format) |x| try a.dupe(u8, x) else null,
        };
        if (v.profiles.len > 0) col.stats = try v.profiles[col_index].summary(a, c.statsFormat());
        if (dc) |date| {
            col.ambiguous = date.ambiguous;
            if (date.ambiguous > 0) {
                const fits = date.fits();
                inline for (@typeInfo(Fits).@"struct".field_names) |n| @field(col.fits, n) = @field(fits, n);
            }
        }
        const samples = try a.alloc(Sample, st.samples.items.len);
        for (samples, st.samples.items) |*s, x| s.* = .{ .row = x.row, .value = try types.utf8Of(a, x.value, d.encoding), .code = x.reason };
        col.samples = samples;
    }
    const problems = try a.alloc(Problem, v.structural.items.len);
    for (problems, v.structural.items) |*p, x| p.* = try x.dupe(a);
    f.problems = problems;
    const lines = try a.alloc(Line, v.rejected_lines.items.len);
    for (lines, v.rejected_lines.items) |*l, x| {
        const errors = try a.alloc(LineError, x.errors.len);
        for (errors, x.errors) |*e, xe| e.* = .{ .column = if (xe.column) |c| try a.dupe(u8, c) else null, .code = xe.reason };
        l.* = .{
            .row = x.row,
            .text = try types.utf8Of(a, x.text, d.encoding),
            .length = if (x.text.len < x.len) x.len else null,
            .errors = errors,
        };
    }
    f.read = .{
        .columns = columns,
        .rows_rejected = v.rejected,
        .rejected_sample = try a.dupe(u64, v.rejected_sample.items),
        .rejected_lines = lines,
        .row_errors = v.row_errors,
        .repeated_header_rows = try a.dupe(u64, v.repeated_lines.items),
    };
    return f;
}

/// The report as JSON. timing false leaves out timing_ms and
/// throughput_mb_s, so a report is the same from run to run (the
/// golden-file tests).
pub fn writeFileReport(w: *Io.Writer, f: File, timing: bool) Stringify.Error!void {
    const o = f.outcome;
    var s: Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();
    try s.objectField("format_version");
    try s.write(format_version);
    try s.objectField("file");
    try s.write(o.file);
    try s.objectField("bytes");
    try s.write(o.bytes);
    try s.objectField("rows");
    try s.write(o.rows);
    try s.objectField("result");
    try s.write(@tagName(o.result));
    if (f.verdict) |v| {
        try s.objectField("dialect");
        try s.write(v);
    }
    if (f.read) |r| {
        try s.objectField("columns");
        try s.beginArray();
        for (r.columns) |c| {
            try s.beginObject();
            try s.objectField("name");
            try s.write(c.name);
            try s.objectField("type");
            try s.write(@tagName(c.type));
            try s.objectField("nulls");
            try s.write(c.nulls);
            try s.objectField("mismatches");
            try s.write(c.mismatches);
            try s.objectField("conformance");
            try writeFraction(&s, c.conformance);
            if (c.format) |x| {
                try s.objectField("format");
                try s.write(x);
            }
            if (c.ambiguous) |n| {
                try s.objectField("ambiguous");
                try s.write(n);
                if (n > 0) {
                    try s.objectField("fits");
                    try s.beginArray();
                    inline for (@typeInfo(Fits).@"struct".field_names) |order| {
                        if (@field(c.fits, order)) try s.write(order);
                    }
                    try s.endArray();
                }
            }
            if (c.samples.len > 0) {
                try s.objectField("samples");
                try s.beginArray();
                for (c.samples) |x| {
                    try s.beginObject();
                    try s.objectField("row");
                    try s.write(x.row);
                    try s.objectField("value");
                    try s.write(x.value);
                    try s.objectField("code");
                    try s.write(x.code);
                    try s.endObject();
                }
                try s.endArray();
            }
            if (c.stats) |st| {
                try s.objectField("stats");
                s.options.emit_null_optional_fields = false;
                defer s.options.emit_null_optional_fields = true;
                try s.write(st);
            }
            try s.endObject();
        }
        try s.endArray();
        try writeProblems(&s, f.problems);
        try s.objectField("rows_rejected");
        try s.write(r.rows_rejected);
        try s.objectField("rejected_sample");
        try s.write(r.rejected_sample);
        try s.objectField("rejected_lines");
        try s.beginArray();
        for (r.rejected_lines) |l| {
            try s.beginObject();
            try s.objectField("row");
            try s.write(l.row);
            try s.objectField("text");
            try s.write(l.text);
            if (l.length) |n| {
                try s.objectField("length");
                try s.write(n);
            }
            try s.objectField("errors");
            try s.beginArray();
            for (l.errors) |e| {
                try s.beginObject();
                if (e.column) |c| {
                    try s.objectField("column");
                    try s.write(c);
                }
                try s.objectField("code");
                try s.write(e.code);
                try s.endObject();
            }
            try s.endArray();
            try s.endObject();
        }
        try s.endArray();
        // What the lists above keep, so one that is full says there may
        // be more.
        try s.objectField("limits");
        try s.beginObject();
        inline for (.{
            .{ "samples", validate.max_samples },
            .{ "sample_bytes", validate.max_sample_len },
            .{ "rejected_sample", validate.max_samples },
            .{ "rejected_lines", validate.max_lines },
            .{ "line_bytes", validate.max_line_len },
            .{ "repeated_header_rows", validate.max_samples },
        }) |limit| {
            try s.objectField(limit[0]);
            try s.write(limit[1]);
        }
        try s.endObject();
        try s.objectField("row_errors");
        try s.beginObject();
        for (std.enums.values(types.Reason)) |reason| {
            const n = r.row_errors.get(reason);
            if (n == 0) continue;
            try s.objectField(@tagName(reason));
            try s.write(n);
        }
        try s.endObject();
    } else {
        try writeProblems(&s, f.problems);
    }
    try s.objectField("warnings");
    try s.beginArray();
    inline for (dialect.Warnings.names) |name| {
        if (@field(f.warnings.dialect, name)) try s.write(name);
    }
    if (f.warnings.extra_columns) try s.write("extra_columns");
    if (f.warnings.header_repeated) try s.write("header_repeated");
    try s.endArray();
    if (f.read) |r| if (f.warnings.header_repeated) {
        try s.objectField("repeated_header_rows");
        try s.write(r.repeated_header_rows);
    };
    if (timing) {
        try s.objectField("timing_ms");
        try s.beginObject();
        inline for (.{ .{ "sniff", "sniff_ns" }, .{ "parse", "parse_ns" }, .{ "write", "write_ns" } }) |t| {
            try s.objectField(t[0]);
            try s.write(@field(o.timing, t[1]) / std.time.ns_per_ms);
        }
        try s.endObject();
        try s.objectField("throughput_mb_s");
        try s.write(@as(u64, @intFromFloat(@round(o.throughput()))));
    }
    try s.endObject();
    try w.writeByte('\n');
}

/// "problems": each as its code, sentence, parameters and fix.
fn writeProblems(s: *Stringify, problems: []const Problem) Stringify.Error!void {
    try s.objectField("problems");
    try s.write(problems);
}

/// A fraction as the report writes it: 1.0, or up to eight places.
fn writeFraction(s: *Stringify, f: f64) Stringify.Error!void {
    if (f == 1.0) return s.print("1.0", .{});
    var buf: [32]u8 = undefined;
    // A fraction prints in 10 bytes; anything else as it comes.
    const text = std.fmt.bufPrint(&buf, "{d:.8}", .{f}) catch return s.print("{d}", .{f});
    var end = text.len;
    while (end > 0 and text[end - 1] == '0') end -= 1;
    if (text[end - 1] == '.') end += 1;
    try s.print("{s}", .{text[0..end]});
}

/// summary.json: every file's outcome, and the counts over them.
pub fn writeSummary(w: *Io.Writer, outcomes: []const Outcome, exit: u8) Stringify.Error!void {
    var s: Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
    var counts: std.EnumArray(Result, u64) = .initFill(0);
    var rows: u64 = 0;
    var rejected: u64 = 0;
    for (outcomes) |o| {
        counts.getPtr(o.result).* += 1;
        rows += o.rows;
        rejected += o.rows_rejected;
    }
    try s.beginObject();
    try s.objectField("format_version");
    try s.write(format_version);
    try s.objectField("files");
    try s.write(outcomes.len);
    inline for (.{ .{ "passed", .pass }, .{ "failed", .fail }, .{ "errors", .@"error" } }) |f| {
        try s.objectField(f[0]);
        try s.write(counts.get(f[1]));
    }
    try s.objectField("rows");
    try s.write(rows);
    try s.objectField("rows_rejected");
    try s.write(rejected);
    try s.objectField("exit");
    try s.write(exit);
    try s.objectField("results");
    try s.beginArray();
    for (outcomes) |o| try writeOutcome(&s, o, false);
    try s.endArray();
    try s.endObject();
    try w.writeByte('\n');
}

/// A file's outcome: on its own a document (a --json line), so versioned;
/// in summary.json's results, not.
fn writeOutcome(s: *Stringify, o: Outcome, versioned: bool) Stringify.Error!void {
    try s.beginObject();
    if (versioned) {
        try s.objectField("format_version");
        try s.write(format_version);
    }
    try s.objectField("file");
    try s.write(o.file);
    try s.objectField("result");
    try s.write(@tagName(o.result));
    try s.objectField("rows");
    try s.write(o.rows);
    try s.objectField("rows_rejected");
    try s.write(o.rows_rejected);
    try s.objectField("problems");
    try s.write(if (o.problem) |*p| p[0..1] else &[_]Problem{});
    // Its name may not be the input's: pool.uniqueNames.
    if (o.written) |p| {
        try s.objectField("written");
        try s.write(p);
    }
    try s.endObject();
}

/// The file's line on stderr: the result, rows, rejected rows, MB/s, and
/// the first structural error.
pub fn writeLine(w: *Io.Writer, o: Outcome) Io.Writer.Error!void {
    try w.print("{s:<5} {s}  {d} rows  {d} rejected  {d:.0} MB/s", .{
        @tagName(o.result), o.file, o.rows, o.rows_rejected, o.throughput(),
    });
    if (o.problem) |p| try w.print("  {f}", .{p});
    try w.writeByte('\n');
}

/// The same as one compact JSON object, for --json.
pub fn writeJsonLine(w: *Io.Writer, o: Outcome) Stringify.Error!void {
    var s: Stringify = .{ .writer = w };
    try writeOutcome(&s, o, true);
    try w.writeByte('\n');
}

/// sniff --json: a file's dialect, how sure, its warnings, and what stops
/// it (worker.verdictProblem), as one compact JSON object. With no verdict
/// (the library's sniff of a file it could not read), no dialect, and the
/// problem why.
pub fn writeSniffLine(w: *Io.Writer, file: []const u8, verdict: ?dialect.Verdict, problems: []const Problem) Stringify.Error!void {
    var s: Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("format_version");
    try s.write(format_version);
    try s.objectField("file");
    try s.write(file);
    if (verdict) |v| {
        try s.objectField("dialect");
        try s.write(v);
    }
    try s.objectField("warnings");
    try s.write(if (verdict) |v| v.warnings else dialect.Warnings{});
    try s.objectField("problems");
    try s.write(problems);
    try s.endObject();
    try w.writeByte('\n');
}

test writeFraction {
    var buf: [64]u8 = undefined;
    for ([_]struct { f64, []const u8 }{ .{ 1.0, "1.0" }, .{ 0.5, "0.5" }, .{ 0.99999973, "0.99999973" }, .{ 2.0 / 3.0, "0.66666667" }, .{ 0, "0.0" } }) |c| {
        var w: Io.Writer = .fixed(&buf);
        var s: Stringify = .{ .writer = &w };
        try writeFraction(&s, c[0]);
        try std.testing.expectEqualStrings(c[1], w.buffered());
    }
}
