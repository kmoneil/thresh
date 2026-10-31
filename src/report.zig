//! What a run says about each file: the per-file JSON report, written by
//! the worker as it finishes so a crash elsewhere loses nothing already
//! done; summary.json over them all; and a line per file on stderr, or a
//! JSON object per file on stdout. docs/REPORT.md describes every field,
//! and src/format_test.zig holds the code to it.

const std = @import("std");
const Io = std.Io;
const Stringify = std.json.Stringify;
const dialect = @import("dialect.zig");
const Problem = @import("problem.zig").Problem;
const schema = @import("schema.zig");
const types = @import("types.zig");
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

/// What goes into a file's report besides the outcome.
pub const Details = struct {
    verdict: ?dialect.Verdict = null,
    schema: ?*const schema.Schema = null,
    validator: ?*const validate.Validator = null,
    encoding: types.Encoding = .utf8,
    /// Leave out timing_ms and throughput, so a report is the same from
    /// run to run (the golden-file tests).
    timing: bool = true,
};

pub fn writeFileReport(w: *Io.Writer, o: Outcome, d: Details) Stringify.Error!void {
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
    if (d.verdict) |v| {
        try s.objectField("dialect");
        try s.write(v);
    }
    var warnings: dialect.Warnings = if (d.verdict) |v| v.warnings else .{};
    if (d.validator) |v| {
        if (v.stray_quotes > 0) warnings.quote_in_unquoted = true;
        if (v.foreign_newlines > 0) warnings.mixed_newlines = true;
        try s.objectField("columns");
        try s.beginArray();
        for (v.schema.columns, v.stats, 0..) |c, st, i| {
            try s.beginObject();
            try s.objectField("name");
            try s.write(c.name);
            try s.objectField("type");
            try s.write(@tagName(c.type));
            try s.objectField("nulls");
            try s.write(st.nulls);
            try s.objectField("mismatches");
            try s.write(st.mismatches);
            try s.objectField("conformance");
            try writeFraction(&s, validate.conformance(st, v.columnRows()));
            if (c.format) |f| {
                try s.objectField("format");
                try s.write(f);
            }
            if (v.dates[i]) |dc| {
                try s.objectField("ambiguous");
                try s.write(dc.ambiguous);
                if (dc.ambiguous > 0) {
                    // The orders every value whose order is a guess still fits.
                    const fits = dc.fits();
                    try s.objectField("fits");
                    try s.beginArray();
                    inline for (.{ "month_first", "day_first", "year_first" }) |order| {
                        if (@field(fits, order)) try s.write(order);
                    }
                    try s.endArray();
                }
            }
            if (st.samples.items.len > 0) {
                try s.objectField("samples");
                try s.beginArray();
                for (st.samples.items) |sample| {
                    try s.beginObject();
                    try s.objectField("row");
                    try s.write(sample.row);
                    try s.objectField("value");
                    try writeText(&s, sample.value, d.encoding);
                    try s.objectField("code");
                    try s.write(sample.reason);
                    try s.endObject();
                }
                try s.endArray();
            }
            try s.endObject();
        }
        try s.endArray();
        try writeProblems(&s, v.structural.items);
        try s.objectField("rows_rejected");
        try s.write(v.rejected);
        try s.objectField("rejected_sample");
        try s.write(v.rejected_sample.items);
        try s.objectField("row_errors");
        try s.beginObject();
        for (std.enums.values(types.Reason)) |r| {
            const n = v.row_errors.get(r);
            if (n == 0) continue;
            try s.objectField(@tagName(r));
            try s.write(n);
        }
        try s.endObject();
    } else {
        try writeProblems(&s, if (o.problem) |*p| p[0..1] else &.{});
    }
    try s.objectField("warnings");
    try s.beginArray();
    inline for (dialect.Warnings.names) |name| {
        if (@field(warnings, name)) try s.write(name);
    }
    if (d.validator) |v| {
        if (v.extra_columns) try s.write("extra_columns");
        if (v.repeated_headers > 0) try s.write("header_repeated");
    }
    try s.endArray();
    if (d.validator) |v| if (v.repeated_headers > 0) {
        try s.objectField("repeated_header_rows");
        try s.write(v.repeated_lines.items);
    };
    if (d.timing) {
        try s.objectField("timing_ms");
        try s.beginObject();
        inline for (.{ .{ "sniff", "sniff_ns" }, .{ "parse", "parse_ns" }, .{ "write", "write_ns" } }) |f| {
            try s.objectField(f[0]);
            try s.write(@field(o.timing, f[1]) / std.time.ns_per_ms);
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

/// A value as a JSON string: Latin-1 or Windows-1252 transcoded, and under
/// UTF-8 any byte that is not part of a character replaced with U+FFFD, so
/// the report is valid JSON whatever the cell held.
fn writeText(s: *Stringify, bytes: []const u8, encoding: types.Encoding) Stringify.Error!void {
    var buf: [validate.max_sample_len * 3]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const c = bytes[i];
        if (encoding != .utf8) {
            n += std.unicode.utf8Encode(types.codepoint(encoding, c), buf[n..]) catch unreachable;
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(c) catch 0;
        if (len > 0 and i + len <= bytes.len) {
            if (std.unicode.utf8Decode(bytes[i..][0..len])) |_| {
                @memcpy(buf[n..][0..len], bytes[i..][0..len]);
                n += len;
                i += len;
                continue;
            } else |_| {}
        }
        @memcpy(buf[n..][0..3], "\xef\xbf\xbd");
        n += 3;
        i += 1;
    }
    try s.write(buf[0..n]);
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
/// it (worker.verdictProblem), as one compact JSON object.
pub fn writeSniffLine(w: *Io.Writer, file: []const u8, v: dialect.Verdict, problems: []const Problem) Stringify.Error!void {
    var s: Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("format_version");
    try s.write(format_version);
    try s.objectField("file");
    try s.write(file);
    try s.objectField("dialect");
    try s.write(v);
    try s.objectField("warnings");
    try s.write(v.warnings);
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

test writeText {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var s: Stringify = .{ .writer = &w };
    try writeText(&s, "caf\xe9 ok", .utf8);
    try std.testing.expectEqualStrings("\"caf\u{fffd} ok\"", w.buffered());
    w = .fixed(&buf);
    s = .{ .writer = &w };
    try writeText(&s, "caf\xe9", .latin1);
    try std.testing.expectEqualStrings("\"café\"", w.buffered());
}
