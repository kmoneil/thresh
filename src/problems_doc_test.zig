//! docs/PROBLEMS.md against the code: every problem, warning and reason
//! has a row, and every row is one thresh has; each problem's parameters
//! and the fixes it suggests are the ones its JSON object has. Only
//! main.zig's tests reference this file, as only its module embeds the doc.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const Problem = @import("problem.zig").Problem;
const dialect = @import("dialect.zig");
const Reason = @import("types.zig").Reason;

/// The codes in docs/PROBLEMS.md's tables under `## heading`: each row's
/// first cell, of a table whose header row starts "| Code |".
fn documented(gpa: Allocator, doc: []const u8, heading: []const u8) !std.StringHashMapUnmanaged([]const u8) {
    return documentedIn(gpa, doc, heading, "| Code |");
}

/// The same for the tables whose header row starts with header.
fn documentedIn(gpa: Allocator, doc: []const u8, heading: []const u8, header: []const u8) !std.StringHashMapUnmanaged([]const u8) {
    var codes: std.StringHashMapUnmanaged([]const u8) = .empty;
    errdefer codes.deinit(gpa);
    var in_section = false;
    var in_table = false;
    var lines = std.mem.splitScalar(u8, doc, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "## ")) in_section = std.mem.eql(u8, line[3..], heading);
        if (!in_section) continue;
        if (std.mem.startsWith(u8, line, header)) {
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
    // Each code's parameters, its second cell, are its object's fields.
    const info = @typeInfo(Problem).@"union";
    inline for (info.field_names, info.field_types) |code, T| {
        const names: []const []const u8 = if (T == void) &.{} else @typeInfo(T).@"struct".field_names;
        // The cells after it run on: the Parameters cell is up to the next.
        const rest = problems.get(code).?;
        try expectNames("the problem " ++ code, names, rest[0 .. std.mem.findScalar(u8, rest, '|') orelse rest.len]);
    }
    // And the fixes it suggests are the Suggest object's.
    var keys = try documentedIn(gpa, doc, "Problems", "| Key |");
    defer keys.deinit(gpa);
    inline for (@typeInfo(Problem.Suggest).@"struct".field_names) |k| if (!keys.contains(k)) {
        std.debug.print("docs/PROBLEMS.md: no row for suggest's {s}\n", .{k});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(@typeInfo(Problem.Suggest).@"struct".field_names.len, keys.count());

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

/// The names in backticks in cell that are names (not `{column, files}`,
/// which shows an item's shape) are names, and no others.
fn expectNames(what: []const u8, names: []const []const u8, cell: []const u8) !void {
    var count: usize = 0;
    var ticks = std.mem.splitScalar(u8, cell, '`');
    var inside = false;
    while (ticks.next()) |t| : (inside = !inside) {
        if (!inside) continue;
        const name = for (t) |c| {
            if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_')) break false;
        } else true;
        if (!name) continue;
        for (names) |n| {
            if (std.mem.eql(u8, n, t)) break;
        } else {
            std.debug.print("docs/PROBLEMS.md: {s} has no parameter '{s}'\n", .{ what, t });
            return error.TestUnexpectedResult;
        }
        count += 1;
    }
    if (count != names.len) {
        std.debug.print("docs/PROBLEMS.md: {s}'s parameters are {d}: ", .{ what, names.len });
        for (names) |n| std.debug.print("{s} ", .{n});
        std.debug.print("; its row names {d}\n", .{count});
        return error.TestUnexpectedResult;
    }
}
