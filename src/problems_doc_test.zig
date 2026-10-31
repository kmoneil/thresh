//! docs/PROBLEMS.md against the code: every problem, warning and reason
//! has a row, and every row is one thresh has. Only main.zig's tests
//! reference this file, as only its module embeds the doc.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const Problem = @import("problem.zig").Problem;
const dialect = @import("dialect.zig");
const Reason = @import("types.zig").Reason;

/// The codes in docs/PROBLEMS.md's tables under `## heading`: each row's
/// first cell, of a table whose header row starts "| Code |".
fn documented(gpa: Allocator, doc: []const u8, heading: []const u8) !std.StringHashMapUnmanaged([]const u8) {
    var codes: std.StringHashMapUnmanaged([]const u8) = .empty;
    errdefer codes.deinit(gpa);
    var in_section = false;
    var in_table = false;
    var lines = std.mem.splitScalar(u8, doc, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "## ")) in_section = std.mem.eql(u8, line[3..], heading);
        if (!in_section) continue;
        if (std.mem.startsWith(u8, line, "| Code |")) {
            in_table = true;
            continue;
        }
        if (!std.mem.startsWith(u8, line, "|")) in_table = false;
        if (!in_table or !std.mem.startsWith(u8, line, "| `")) continue;
        const end = std.mem.findScalarPos(u8, line, 3, '`') orelse return error.TestUnexpectedResult;
        // The row's second cell, for a check of what it says.
        const rest = line[end + 1 ..];
        const second = std.mem.trim(u8, rest[(std.mem.findScalar(u8, rest, '|') orelse 0) + 1 ..], " ");
        try codes.put(gpa, line[3..end], second);
    }
    return codes;
}

test "docs/PROBLEMS.md lists every code there is, and no other" {
    const gpa = testing.allocator;
    const doc = @embedFile("problems_doc");

    var problems = try documented(gpa, doc, "Problems");
    defer problems.deinit(gpa);
    for (std.enums.values(Problem.Code)) |c| if (!problems.contains(@tagName(c))) {
        std.debug.print("docs/PROBLEMS.md: no row for the problem {t}\n", .{c});
        return error.TestUnexpectedResult;
    };
    var it = problems.keyIterator();
    while (it.next()) |k| if (std.meta.stringToEnum(Problem.Code, k.*) == null) {
        std.debug.print("docs/PROBLEMS.md: {s} is not a problem\n", .{k.*});
        return error.TestUnexpectedResult;
    };

    // The sniffer's warnings, and the two the validator adds (report.zig).
    const warnings = dialect.Warnings.names ++ .{ "extra_columns", "header_repeated" };
    var listed = try documented(gpa, doc, "Warnings");
    defer listed.deinit(gpa);
    inline for (warnings) |w| if (!listed.contains(w)) {
        std.debug.print("docs/PROBLEMS.md: no row for the warning {s}\n", .{w});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(warnings.len, listed.count());

    var reasons = try documented(gpa, doc, "Reasons");
    defer reasons.deinit(gpa);
    for (std.enums.values(Reason)) |r| {
        const said = reasons.get(@tagName(r)) orelse {
            std.debug.print("docs/PROBLEMS.md: no row for the reason {t}\n", .{r});
            return error.TestUnexpectedResult;
        };
        // Its sentence, as the reject file and the report give it.
        if (!std.mem.startsWith(u8, said, r.text())) {
            std.debug.print("docs/PROBLEMS.md: {t} says '{s}', thresh '{s}'\n", .{ r, said, r.text() });
            return error.TestUnexpectedResult;
        }
    }
    try testing.expectEqual(std.enums.values(Reason).len, reasons.count());
}
