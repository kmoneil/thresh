const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dateparsa = b.dependency("dateparsa", .{ .target = target, .optimize = optimize });
    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);
    // How many random inputs the scanner and the reference parser are
    // compared on; the milestone's bar is 1000000.
    options.addOption(u32, "differential_cases", b.option(u32, "differential", "Random inputs the scanner is checked against the reference parser on (default 20000)") orelse 20_000);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "dateparsa", .module = dateparsa.module("dateparsa") }},
    });
    mod.addOptions("build_options", options);

    // `zig build` installs thresh into zig-out/bin, and
    // `zig build run -- sniff a.csv` runs it.
    const exe = b.addExecutable(.{ .name = "thresh", .root_module = mod });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run thresh (-- sniff FILE)").dependOn(&run.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);

    // The program itself on a few inputs, for what its tests cannot see from
    // inside: arguments, files, the output streams and the exit status.
    for (cli_checks) |check| {
        const r = b.addRunArtifact(exe);
        r.setCwd(b.path("."));
        r.addArgs(check.args);
        r.addFileInput(b.path("test/cli/orders.csv"));
        if (check.stdout) |s| r.expectStdOutEqual(s);
        if (check.stderr) |s| r.expectStdErrEqual(s);
        r.expectExitCode(check.code);
        test_step.dependOn(&r.step);
    }

    // The fixture corpus, test/gen/corpus.py, written into the cache and
    // checked against test/gen/MANIFEST, so a change to what it writes shows
    // up as a diff of that file. Needs python3 on PATH. `zig build corpus`
    // also installs it into zig-out/corpus to look at.
    const corpus = b.addSystemCommand(&.{ "python3", "-I" });
    corpus.addFileArg(b.path("test/gen/corpus.py"));
    const corpus_dir = corpus.addOutputDirectoryArg("corpus");
    corpus.addArg("--check");
    corpus.addFileArg(b.path("test/gen/MANIFEST"));
    const corpus_step = b.step("corpus", "Generate the fixture corpus into zig-out/corpus, checked against test/gen/MANIFEST");
    corpus_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = corpus_dir,
        .install_dir = .prefix,
        .install_subdir = "corpus",
    }).step);

    // The tests over the corpus: a module of their own, given the corpus's
    // index (an option path must be a file), so -Dcorpus=false leaves a
    // test run that needs no Python.
    if (b.option(bool, "corpus", "Run the tests over the fixture corpus (needs python3; default true)") orelse true) {
        const corpus_options = b.addOptions();
        corpus_options.addOptionPath("corpus_index", corpus_dir.path(b, "index.txt"));
        // The module compiles the tests of every file it imports; the
        // random inputs are the main module's to run.
        corpus_options.addOption(u32, "differential_cases", 0);
        // The dirty files' reports, checked in; -Dupdate-golden rewrites them.
        const update_golden = b.option(bool, "update-golden", "Rewrite test/golden from what validate reports now") orelse false;
        corpus_options.addOption(bool, "update_golden", update_golden);
        // Relative to the build root, where the test runs.
        corpus_options.addOption([]const u8, "golden_dir", "test/golden");
        const corpus_mod = b.createModule(.{
            .root_source_file = b.path("src/corpus_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "dateparsa", .module = dateparsa.module("dateparsa") }},
        });
        corpus_mod.addOptions("build_options", corpus_options);
        const corpus_run = b.addRunArtifact(b.addTest(.{ .root_module = corpus_mod }));
        corpus_run.setCwd(b.path("."));
        if (update_golden) corpus_run.has_side_effects = true else for (dirty_files) |name| {
            corpus_run.addFileInput(b.path(b.fmt("test/golden/{s}.csv.report.json", .{name})));
        }
        test_step.dependOn(&corpus_run.step);
    }

    // The stages' throughput, always ReleaseFast: `zig build bench --
    // --size BYTES --runs N --profile narrow|wide|text`.
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "thresh", .module = b.createModule(.{
                .root_source_file = b.path("src/root.zig"),
                .target = target,
                .optimize = .ReleaseFast,
            }) }},
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.addPassthruArgs();
    // A measurement, not a build product: never served from the cache.
    run_bench.has_side_effects = true;
    b.step("bench", "Measure each stage's throughput (-- --size BYTES --runs N --profile P)").dependOn(&run_bench.step);
    b.step("bench-install", "Install the benchmark binary").dependOn(&b.addInstallArtifact(bench_exe, .{}).step);

    // The Arrow writer read back by pyarrow (and DuckDB when installed),
    // value for value against the CSV path. Needs python3 with pyarrow:
    // `uv run --with pyarrow --with duckdb zig build arrow-check`.
    const arrow_check = b.addSystemCommand(&.{ "python3", "-I" });
    arrow_check.addFileArg(b.path("test/arrow/check.py"));
    arrow_check.addArtifactArg(exe);
    arrow_check.addDirectoryArg(corpus_dir);
    arrow_check.has_side_effects = true;
    b.step("arrow-check", "Read thresh's Arrow output back with pyarrow (needs python3 with pyarrow)").dependOn(&arrow_check.step);

    // The parallel driver at scale: 10,000 files in one run, throughput by
    // --jobs, and a Ctrl-C mid-run. Run it optimized:
    // `zig build scale -Doptimize=ReleaseFast`.
    const scale = b.addSystemCommand(&.{ "python3", "-I" });
    scale.addFileArg(b.path("test/scale/run.py"));
    scale.addArtifactArg(exe);
    scale.has_side_effects = true;
    b.step("scale", "10,000 files, throughput by --jobs, and Ctrl-C (python3; use -Doptimize=ReleaseFast)").dependOn(&scale.step);

    // The fuzz targets, src/fuzz_test.zig. `zig build fuzz` replays their
    // seeds, as `zig build test` does; tools/fuzz.sh runs them under the
    // fuzzer. Always the LLVM backend: the self-hosted x86_64 one, the
    // Debug default there, emits no coverage for the fuzzer to steer by.
    const fuzz_options = b.addOptions();
    fuzz_options.addOption(u32, "differential_cases", 0);
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("src/fuzz_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_mod.addOptions("build_options", fuzz_options);
    const fuzz_tests = b.addTest(.{ .root_module = fuzz_mod, .filters = &.{"fuzz:"}, .use_llvm = true });
    const run_fuzz = b.addRunArtifact(fuzz_tests);
    b.step("fuzz", "Replay the fuzz seeds (tools/fuzz.sh to fuzz)").dependOn(&run_fuzz.step);
    test_step.dependOn(&run_fuzz.step);

    const lint_paths = [_][]const u8{ "build.zig", "src", "bench" };
    var fmt_paths: [lint_paths.len]std.Build.LazyPath = undefined;
    for (lint_paths, &fmt_paths) |p, *lp| lp.* = b.path(p);
    const fmt = b.addFmt(.{ .paths = &fmt_paths, .check = true });
    b.step("fmt-check", "Check source formatting").dependOn(&fmt.step);

    // zigvet (github.com/kmoneil/zigvet), built from the pinned dependency:
    // code Zig compiles that is almost certainly wrong. Run from the build
    // root with relative paths, so findings print as src/x.zig:line:col.
    const zigvet = b.dependency("zigvet", .{ .target = b.graph.host, .optimize = .ReleaseSafe });
    const vet = b.addRunArtifact(zigvet.artifact("zigvet"));
    vet.setCwd(b.path("."));
    vet.addArgs(&lint_paths);
    b.step("vet", "Check sources with zigvet").dependOn(&vet.step);
}

/// The corpus's dirty files (test/gen/corpus.py's DIRTY), whose reports are
/// checked in under test/golden.
const dirty_files = [_][]const u8{
    "dirty-comma-dq-lf-h-utf8",
    "dirty-tab-sq-crlf-h-latin1",
    "dirty-pipe-noquote-lf-nh-utf8",
    "dirty-semicolon-dq-cr-h-utf8-bom",
    "dirty-comma-dq-lf-h-missing-column",
};

/// What `zig build test` runs thresh with, and what it must write and exit
/// with. Null leaves a stream unchecked.
const cli_checks = [_]struct {
    args: []const []const u8,
    stdout: ?[]const u8 = "",
    stderr: ?[]const u8 = "",
    code: u8 = 0,
}{
    .{
        .args = &.{ "sniff", "test/cli/orders.csv" },
        .stdout = "test/cli/orders.csv: delimiter=, quote=\" escape=doubled newline=lf header=yes confidence=high\n",
    },
    .{
        .args = &.{ "sniff", "test/cli/orders.csv", "--no-mmap", "--sample-bytes", "8" },
        .stdout = "test/cli/orders.csv: delimiter=, quote=\" escape=doubled newline=lf header=yes confidence=high\n",
    },
    .{
        .args = &.{ "sniff", "test/cli/orders.csv", "--json" },
        .stdout = "{\"file\":\"test/cli/orders.csv\",\"dialect\":{\"delimiter\":\",\",\"quote\":\"\\\"\",\"escape\":\"doubled\",\"newline\":\"lf\",\"header\":true," ++
            "\"confidence\":\"high\",\"score\":1.39,\"runners_up\":[{\"delimiter\":\"\\t\",\"score\":0.19},{\"delimiter\":\"|\",\"score\":0.19}]},\"warnings\":[]}\n",
    },
    .{
        .args = &.{ "sniff", "test/cli/orders.csv", "--delimiter", ";", "--header", "no" },
        .stdout = "test/cli/orders.csv: delimiter=; quote=\" escape=doubled newline=lf header=no confidence=high warnings=quote_in_unquoted\n",
    },
    .{
        .args = &.{ "sniff", "test/cli/missing.csv", "test/cli/orders.csv" },
        .stdout = "test/cli/orders.csv: delimiter=, quote=\" escape=doubled newline=lf header=yes confidence=high\n",
        .stderr = "thresh: test/cli/missing.csv: no such file\n",
        .code = 2,
    },
    .{
        .args = &.{"sniff"},
        .stderr = "thresh: sniff: no input files\n(thresh --help lists the commands and options)\n",
        .code = 3,
    },
    .{
        .args = &.{ "validate", "test/cli/orders.csv" },
        .stderr = "thresh: validate needs --schema or --columns\n(thresh --help lists the commands and options)\n",
        .code = 3,
    },
    .{ .args = &.{ "validate", "test/cli/orders.csv", "--columns", "id:int64,name:string,amount:decimal(6,2)", "--quiet" } },
    .{
        .args = &.{ "validate", "test/cli/orders.csv", "--columns", "id:int64,name:string,amount:int64", "--quiet" },
        .code = 1,
    },
    .{
        .args = &.{ "validate", "test/cli/orders.csv", "--columns", "id:int64,amount:int64", "--json" },
        .stdout = "{\"file\":\"test/cli/orders.csv\",\"result\":\"fail\",\"rows\":2,\"rows_rejected\":2,\"problem\":null}\n",
        .code = 1,
    },
    .{
        .args = &.{ "validate", "test/cli/orders.csv", "--schema", "test/cli/missing.json" },
        .stderr = "thresh: test/cli/missing.json: no such file\n",
        .code = 3,
    },
    .{
        .args = &.{ "infer", "test/cli/orders.csv" },
        .stdout =
        \\{
        \\  "columns": [
        \\    {
        \\      "name": "id",
        \\      "type": "int64",
        \\      "conformance": 1,
        \\      "samples": [
        \\        "1",
        \\        "2"
        \\      ],
        \\      "inferred": true
        \\    },
        \\    {
        \\      "name": "name",
        \\      "type": "string",
        \\      "conformance": 1,
        \\      "samples": [
        \\        "apple",
        \\        "pear, green"
        \\      ],
        \\      "inferred": true
        \\    },
        \\    {
        \\      "name": "amount",
        \\      "type": "decimal",
        \\      "precision": 3,
        \\      "scale": 2,
        \\      "conformance": 1,
        \\      "samples": [
        \\        "1.50",
        \\        "2.25"
        \\      ],
        \\      "inferred": true
        \\    }
        \\  ],
        \\  "nulls": [
        \\    ""
        \\  ],
        \\  "match": "name"
        \\}
        \\
        ,
        .stderr = "infer test/cli/orders.csv  2 rows  3 columns\n",
    },
    .{
        .args = &.{ "convert", "test/cli/orders.csv", "--to", "csv", "--out", ".zig-cache/cli-out/convert", "--json" },
        .stdout = "{\"file\":\"test/cli/orders.csv\",\"result\":\"pass\",\"rows\":2,\"rows_rejected\":0,\"problem\":null}\n",
    },
    .{
        .args = &.{ "run", "test/cli/orders.csv", "--columns", "id:int64,amount:int64", "--to", "csv", "--out", ".zig-cache/cli-out/run", "--strict", "--quiet" },
        .code = 1,
    },
    .{ .args = &.{"--help"}, .stdout = null },
    .{ .args = &.{"--version"}, .stdout = "thresh " ++ zon.version ++ "\n" },
};
