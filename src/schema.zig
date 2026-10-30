//! The schema: each column's name, type, nulls and constraints. Read from
//! JSON (what catalogs emit and `infer` writes), or from the inline
//! `--columns "id:int64,amount:decimal(18,2)"` form.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Type = enum {
    bool,
    int64,
    float64,
    decimal,
    date,
    timestamp,
    time,
    string,
    @"enum",
    binary,
};

/// What a string column does with bytes that are not UTF-8.
pub const Utf8Policy = enum {
    /// A mismatch (the default).
    @"error",
    /// Valid; written with U+FFFD in their place.
    replace,
    /// Valid; the column is written as Arrow Binary.
    binary,
};

pub const Match = enum { name, position };

/// Column names as a header, a schema and infer's merge compare them:
/// ASCII case ignored. Callers trim them first.
pub const NameContext = struct {
    pub fn hash(_: NameContext, s: []const u8) u64 {
        var h: u64 = 0xcbf2_9ce4_8422_2325;
        for (s) |c| h = (h ^ std.ascii.toLower(c)) *% 0x100_0000_01b3;
        return h;
    }

    pub fn eql(_: NameContext, a: []const u8, b: []const u8) bool {
        return std.ascii.eqlIgnoreCase(a, b);
    }
};

/// The names a header gives its columns, read alike by infer and
/// validate: each trimmed, and a blank one, or one a name before it took
/// already (ASCII case aside), columnN by its place.
pub fn headerNames(arena: Allocator, raw: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, raw.len);
    var taken: NameMap(void) = .empty;
    defer taken.deinit(arena);
    try taken.ensureTotalCapacity(arena, @intCast(raw.len));
    for (out, raw, 0..) |*n, r, i| {
        const name = std.mem.trim(u8, r, " \t");
        n.* = if (name.len == 0 or taken.contains(name))
            try std.fmt.allocPrint(arena, "column{d}", .{i + 1})
        else
            try arena.dupe(u8, name);
        taken.putAssumeCapacity(n.*, {});
    }
    return out;
}

/// A map keyed by column name, compared as NameContext does: a file of
/// thousands of columns is matched in a pass, not a pass per column.
pub fn NameMap(comptime V: type) type {
    return std.HashMapUnmanaged([]const u8, V, NameContext, std.hash_map.default_max_load_percentage);
}

pub const Column = struct {
    name: []const u8,
    type: Type,
    nullable: bool = true,
    /// Strings read as null in this column, besides the schema's.
    nulls: []const []const u8 = &.{},
    /// decimal: digits in all, and after the point. At most 38.
    precision: u8 = 38,
    scale: u8 = 0,
    /// date, timestamp: a strftime layout; without one, dateparsa detects.
    format: ?[]const u8 = null,
    day_first: bool = false,
    /// enum: the values allowed.
    values: []const []const u8 = &.{},
    case_insensitive: bool = false,
    /// string: longest value in bytes.
    max_len: ?u64 = null,
    utf8: Utf8Policy = .@"error",
    /// bool: the spellings of each, compared ignoring case. Null for the
    /// defaults: true/false, t/f, yes/no, 1/0.
    true_values: ?[]const []const u8 = null,
    false_values: ?[]const []const u8 = null,

    // What infer adds; read back and written, never checked.
    inferred: ?bool = null,
    conformance: ?f64 = null,
    samples: ?[]const []const u8 = null,
    /// The file that took the column's type down the lattice, when infer
    /// merged several.
    widened_by: ?[]const u8 = null,

    /// The column as JSON: its name and type, and only the fields that
    /// say something, so a written schema reads like a hand-written one.
    pub fn jsonStringify(c: Column, s: *std.json.Stringify) std.json.Stringify.Error!void {
        try s.beginObject();
        try s.objectField("name");
        try s.write(c.name);
        try s.objectField("type");
        try s.write(@tagName(c.type));
        if (!c.nullable) {
            try s.objectField("nullable");
            try s.write(false);
        }
        if (c.nulls.len > 0) {
            try s.objectField("nulls");
            try s.write(c.nulls);
        }
        if (c.type == .decimal) {
            try s.objectField("precision");
            try s.write(c.precision);
            try s.objectField("scale");
            try s.write(c.scale);
        }
        inline for (.{ "format", "max_len", "true_values", "false_values", "conformance", "samples", "widened_by" }) |name| {
            if (@field(c, name)) |value| {
                try s.objectField(name);
                try s.write(value);
            }
        }
        if (c.day_first) {
            try s.objectField("day_first");
            try s.write(true);
        }
        if (c.values.len > 0) {
            try s.objectField("values");
            try s.write(c.values);
        }
        if (c.case_insensitive) {
            try s.objectField("case_insensitive");
            try s.write(true);
        }
        if (c.utf8 != .@"error") {
            try s.objectField("utf8");
            try s.write(@tagName(c.utf8));
        }
        if (c.inferred) |i| {
            try s.objectField("inferred");
            try s.write(i);
        }
        try s.endObject();
    }
};

pub const Schema = struct {
    columns: []const Column,
    /// Strings read as null in every column.
    nulls: []const []const u8 = &.{""},
    /// Null: by name when the file has a header, by position otherwise.
    match: ?Match = null,
    threshold: ?f64 = null,
    /// infer: only the first rows were read.
    sampled: ?bool = null,
};

/// A schema and the memory it lives in.
pub const Owned = struct {
    schema: Schema,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(o: *Owned) void {
        o.arena.deinit();
    }
};

/// Why a schema was refused, for the user.
pub const Diagnostic = struct {
    buf: [256]u8 = undefined,
    message: []const u8 = "",

    fn fail(d: *Diagnostic, comptime fmt: []const u8, args: anytype) error{InvalidSchema} {
        var w: Io.Writer = .fixed(&d.buf);
        w.print(fmt, args) catch {};
        d.message = w.buffered();
        return error.InvalidSchema;
    }
};

pub const Error = error{InvalidSchema} || Allocator.Error;

/// A schema from its JSON. Unknown fields are refused, so a misspelt
/// "nullable" says so instead of being ignored.
pub fn parseJson(gpa: Allocator, text: []const u8, diag: *Diagnostic) Error!Owned {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    var json_diag: std.json.Diagnostics = .{};
    var scanner: std.json.Scanner = .initCompleteInput(arena.allocator(), text);
    scanner.enableDiagnostics(&json_diag);
    const schema = std.json.parseFromTokenSourceLeaky(Schema, arena.allocator(), &scanner, .{
        .allocate = .alloc_always,
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return diag.fail("line {d}, column {d}: {s}", .{ json_diag.getLine(), json_diag.getColumn(), describeJson(e) }),
    };
    try check(schema, diag);
    return .{ .schema = schema, .arena = arena };
}

fn describeJson(e: anyerror) []const u8 {
    return switch (e) {
        error.UnknownField => "an unknown field",
        error.MissingField => "a required field is missing",
        error.InvalidEnumTag => "an unknown value (a type or policy?)",
        error.UnexpectedToken, error.SyntaxError => "not valid JSON here",
        error.InvalidNumber, error.Overflow, error.InvalidCharacter => "not a number thresh takes here",
        error.UnexpectedEndOfInput => "the JSON ends early",
        else => @errorName(e),
    };
}

/// The inline form: comma-separated name:type, the decimal's precision and
/// scale in parentheses. Every column is nullable; the nulls are "".
pub fn parseInline(gpa: Allocator, spec: []const u8, diag: *Diagnostic) Error!Owned {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var columns: std.ArrayList(Column) = .empty;
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |part0| {
        var part = std.mem.trim(u8, part0, " ");
        // A decimal's "(18,2)" holds a comma: take the scale back.
        if (std.mem.findScalar(u8, part, '(') != null and std.mem.findScalar(u8, part, ')') == null) {
            const rest = it.next() orelse return diag.fail("--columns: {s}: no closing parenthesis", .{part});
            part = try std.mem.concat(a, u8, &.{ part, ",", std.mem.trim(u8, rest, " ") });
        }
        const name, const ty = std.mem.cutScalar(u8, part, ':') orelse
            return diag.fail("--columns: {s}: write name:type", .{part});
        if (name.len == 0) return diag.fail("--columns: {s}: no name", .{part});
        var col: Column = .{ .name = try a.dupe(u8, name), .type = .string };
        if (std.mem.startsWith(u8, ty, "decimal(") and std.mem.endsWith(u8, ty, ")")) {
            const p, const s = std.mem.cutScalar(u8, ty["decimal(".len .. ty.len - 1], ',') orelse
                return diag.fail("--columns: {s}: decimal(precision,scale)", .{part});
            col.type = .decimal;
            col.precision = std.fmt.parseInt(u8, std.mem.trim(u8, p, " "), 10) catch
                return diag.fail("--columns: {s}: decimal(precision,scale)", .{part});
            col.scale = std.fmt.parseInt(u8, std.mem.trim(u8, s, " "), 10) catch
                return diag.fail("--columns: {s}: decimal(precision,scale)", .{part});
        } else {
            col.type = std.meta.stringToEnum(Type, ty) orelse
                return diag.fail("--columns: {s}: no type '{s}'", .{ part, ty });
            if (col.type == .@"enum") return diag.fail("--columns: {s}: an enum needs its values, in a --schema file", .{part});
        }
        try columns.append(a, col);
    }
    const schema: Schema = .{ .columns = try columns.toOwnedSlice(a) };
    try check(schema, diag);
    return .{ .schema = schema, .arena = arena };
}

/// What JSON's types cannot say: names unique, decimals that fit, an
/// enum with values, a threshold that is a fraction.
fn check(s: Schema, diag: *Diagnostic) error{InvalidSchema}!void {
    if (s.columns.len == 0) return diag.fail("no columns", .{});
    for (s.columns, 0..) |c, i| {
        if (std.mem.trim(u8, c.name, " \t").len == 0) return diag.fail("column {d} has no name", .{i + 1});
        for (s.columns[0..i]) |prev| {
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, prev.name, " \t"), std.mem.trim(u8, c.name, " \t")))
                return diag.fail("two columns named '{s}'", .{c.name});
        }
        switch (c.type) {
            .decimal => {
                if (c.precision == 0 or c.precision > 38) return diag.fail("{s}: precision {d}: from 1 to 38", .{ c.name, c.precision });
                if (c.scale > c.precision) return diag.fail("{s}: scale {d} is more than precision {d}", .{ c.name, c.scale, c.precision });
            },
            .@"enum" => if (c.values.len == 0) return diag.fail("{s}: an enum with no values", .{c.name}),
            else => {},
        }
    }
    if (s.threshold) |t| if (!(t >= 0 and t <= 1)) return diag.fail("threshold {d}: a fraction from 0 to 1", .{t});
}

/// The schema as JSON, in the shape parseJson reads: what infer writes.
pub fn writeJson(s: Schema, w: *Io.Writer) Io.Writer.Error!void {
    try std.json.Stringify.value(s, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }, w);
    try w.writeByte('\n');
}

/// A schema file's contents, read whole.
pub fn load(io: Io, gpa: Allocator, path: []const u8, diag: *Diagnostic) (Error || Io.Dir.ReadFileAllocError)!Owned {
    const text = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20));
    defer gpa.free(text);
    return parseJson(gpa, text, diag);
}

const testing = std.testing;

test "the spec's example schema reads" {
    const text =
        \\{
        \\  "columns": [
        \\    { "name": "id",      "type": "int64",   "nullable": false },
        \\    { "name": "amount",  "type": "decimal", "precision": 18, "scale": 2 },
        \\    { "name": "created", "type": "timestamp", "format": "%Y-%m-%d %H:%M:%S" },
        \\    { "name": "shipped", "type": "date", "day_first": true },
        \\    { "name": "status",  "type": "enum", "values": ["open", "closed"] },
        \\    { "name": "note",    "type": "string", "max_len": 65536, "utf8": "replace" }
        \\  ],
        \\  "nulls": ["", "NULL", "N/A"],
        \\  "match": "name",
        \\  "threshold": 1.0
        \\}
    ;
    var diag: Diagnostic = .{};
    var o = try parseJson(testing.allocator, text, &diag);
    defer o.deinit();
    const s = o.schema;
    try testing.expectEqual(@as(usize, 6), s.columns.len);
    try testing.expect(!s.columns[0].nullable);
    try testing.expectEqual(@as(u8, 18), s.columns[1].precision);
    try testing.expectEqualStrings("%Y-%m-%d %H:%M:%S", s.columns[2].format.?);
    try testing.expect(s.columns[3].day_first);
    try testing.expectEqualStrings("closed", s.columns[4].values[1]);
    try testing.expectEqual(Utf8Policy.replace, s.columns[5].utf8);
    try testing.expectEqual(@as(usize, 3), s.nulls.len);
    try testing.expectEqual(Match.name, s.match.?);
}

test "a column writes only what it says" {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try std.json.Stringify.value(Column{ .name = "amount", .type = .decimal, .precision = 18, .scale = 2, .nullable = false }, .{}, &w);
    try testing.expectEqualStrings(
        \\{"name":"amount","type":"decimal","nullable":false,"precision":18,"scale":2}
    , w.buffered());
}

test "a schema written back reads the same" {
    var diag: Diagnostic = .{};
    var o = try parseInline(testing.allocator, "id:int64, amount:decimal(18, 2),created:timestamp,ok:bool", &diag);
    defer o.deinit();
    var buf: [2048]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeJson(o.schema, &w);
    var back = try parseJson(testing.allocator, w.buffered(), &diag);
    defer back.deinit();
    try testing.expectEqual(@as(usize, 4), back.schema.columns.len);
    try testing.expectEqual(Type.decimal, back.schema.columns[1].type);
    try testing.expectEqual(@as(u8, 2), back.schema.columns[1].scale);
    try testing.expectEqualStrings("ok", back.schema.columns[3].name);
}

fn expectRefused(text: []const u8, message: []const u8) !void {
    var diag: Diagnostic = .{};
    if (parseJson(testing.allocator, text, &diag)) |o| {
        var owned = o;
        owned.deinit();
        return error.TestExpectedError;
    } else |e| {
        try testing.expectEqual(error.InvalidSchema, e);
        try testing.expectEqualStrings(message, diag.message);
    }
}

test "bad schemas say why" {
    try expectRefused("{\"columns\":[{\"name\":\"a\",\"type\":\"int64\",\"nulable\":false}]}", "line 1, column 49: an unknown field");
    try expectRefused("{\"columns\":[{\"name\":\"a\",\"type\":\"integer\"}]}", "line 1, column 41: an unknown value (a type or policy?)");
    try expectRefused("{\"columns\":[]}", "no columns");
    try expectRefused("{\"columns\":[{\"name\":\"a\",\"type\":\"int64\"},{\"name\":\" A \",\"type\":\"bool\"}]}", "two columns named ' A '");
    try expectRefused("{\"columns\":[{\"name\":\"a\",\"type\":\"decimal\",\"precision\":40}]}", "a: precision 40: from 1 to 38");
    try expectRefused("{\"columns\":[{\"name\":\"a\",\"type\":\"enum\"}]}", "a: an enum with no values");
    try expectRefused("{\"columns\":[{\"name\":\"a\",\"type\":\"bool\"}],\"threshold\":2}", "threshold 2: a fraction from 0 to 1");
}

test "inline errors" {
    var diag: Diagnostic = .{};
    try testing.expectError(error.InvalidSchema, parseInline(testing.allocator, "id", &diag));
    try testing.expectEqualStrings("--columns: id: write name:type", diag.message);
    try testing.expectError(error.InvalidSchema, parseInline(testing.allocator, "id:integer", &diag));
    try testing.expectEqualStrings("--columns: id:integer: no type 'integer'", diag.message);
    try testing.expectError(error.InvalidSchema, parseInline(testing.allocator, "a:decimal(18", &diag));
}

test headerNames {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try headerNames(arena.allocator(), &.{ " zv_id ", "", "ZV_ID", "column2", "zv_vol" });
    const want = [_][]const u8{ "zv_id", "column2", "column3", "column4", "zv_vol" };
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

fn parseAndFree(gpa: Allocator, json: bool, text: []const u8) !void {
    var diag: Diagnostic = .{};
    var o = if (json) try parseJson(gpa, text, &diag) else try parseInline(gpa, text, &diag);
    o.deinit();
}

test "the parsers free what they hold when an allocation fails" {
    const json =
        \\{"columns": [{"name": "id", "type": "int64", "nullable": false},
        \\  {"name": "status", "type": "enum", "values": ["open", "closed"]}], "nulls": ["", "N/A"]}
    ;
    try testing.checkAllAllocationFailures(testing.allocator, parseAndFree, .{ true, json });
    try testing.checkAllAllocationFailures(testing.allocator, parseAndFree, .{ false, "id:int64, amount:decimal(8,2), name:string" });
}
