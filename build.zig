const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Releases are ReleaseSafe: thresh reads files nobody vouches for, and
    // a broken invariant must stop it with a panic, not run on undefined
    // (docs/PERF.md, "Shipped build"). A bare `zig build --release` builds
    // it; -Doptimize and --release=fast still choose any mode, as CI's
    // matrix and the scale test do. (standardOptimizeOption with a
    // preferred mode would drop -Doptimize and make every --release it.)
    const optimize: std.builtin.Optimize = b.option(
        std.builtin.Optimize,
        "optimize",
        "Prioritize performance, safety, or binary size (default Debug; --release: ReleaseSafe)",
    ) orelse switch (b.graph.release_mode) {
        .off => .debug,
        .any, .safe => .safe,
        .fast => .fast,
        .small => .small,
    };

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
    // Tests hold the codes' doc and the reports' doc to the code.
    mod.addAnonymousImport("problems_doc", .{ .root_source_file = b.path("docs/PROBLEMS.md") });
    mod.addAnonymousImport("report_doc", .{ .root_source_file = b.path("docs/REPORT.md") });

    // `zig build` installs thresh into zig-out/bin, and
    // `zig build run -- sniff a.csv` runs it.
    const exe = b.addExecutable(.{ .name = "thresh", .root_module = mod });
    b.installArtifact(exe);
    // Beside the binary, so an archive of zig-out carries what Apache-2.0
    // asks: the license, and the notices of what thresh compiles in.
    b.installFile("LICENSE", "share/doc/thresh/LICENSE");
    b.installFile("NOTICE", "share/doc/thresh/NOTICE");
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run thresh (-- sniff FILE)").dependOn(&run.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);

    // libthresh: include/thresh.h over src/capi.zig, static and shared,
    // into zig-out/lib and zig-out/include. On Windows the names keep the
    // DLL's import library and its .pdb from meeting the static library's
    // and the executable's.
    const capi_mod = b.createModule(.{
        .root_source_file = b.path("src/capi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "dateparsa", .module = dateparsa.module("dateparsa") }},
    });
    capi_mod.addOptions("build_options", options);
    const windows = target.result.os.tag == .windows;
    const static_lib = b.addLibrary(.{ .linkage = .static, .name = if (windows) "libthresh_static" else "thresh", .root_module = capi_mod });
    // A C toolchain other than Zig's may lack what 128-bit decimals call.
    static_lib.bundle_compiler_rt = true;
    const shared_lib = b.addLibrary(.{ .linkage = .dynamic, .name = if (windows) "libthresh" else "thresh", .root_module = capi_mod });
    b.installArtifact(static_lib);
    b.installArtifact(shared_lib);
    b.installFile("include/thresh.h", "include/thresh.h");

    // The C ABI's tests, with the header translated so they hold its
    // layout to the library's; and a C program through the header, linked
    // to each library.
    const capi_test_mod = b.createModule(.{
        .root_source_file = b.path("src/capi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "dateparsa", .module = dateparsa.module("dateparsa") },
            .{ .name = "thresh_h", .module = b.addTranslateC(.{ .root_source_file = b.path("include/thresh.h"), .target = target, .optimize = optimize }).createModule() },
        },
    });
    capi_test_mod.addOptions("build_options", options);
    // Its own tests: the library's run in the test above.
    const capi_test = b.addRunArtifact(b.addTest(.{ .name = "capi-test", .root_module = capi_test_mod, .filters = &.{"capi.test."} }));
    capi_test.setCwd(b.path("."));
    capi_test.addFileInput(b.path("test/c/lugs.csv"));
    test_step.dependOn(&capi_test.step);
    for ([_]*std.Build.Step.Compile{ static_lib, shared_lib }) |l| {
        const smoke = b.addExecutable(.{
            .name = b.fmt("c-smoke-{t}", .{l.linkage.?}),
            .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
        });
        smoke.root_module.addCSourceFile(.{ .file = b.path("test/c/smoke.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-pedantic" } });
        smoke.root_module.addIncludePath(b.path("include"));
        smoke.root_module.linkLibrary(l);
        const run_smoke = b.addRunArtifact(smoke);
        run_smoke.setCwd(b.path("."));
        run_smoke.addFileInput(b.path("test/c/lugs.csv"));
        run_smoke.expectExitCode(0);
        test_step.dependOn(&run_smoke.step);
    }

    // The program itself on a few inputs, for what its tests cannot see from
    // inside: arguments, files, the output streams and the exit status.
    for (cli_checks) |check| {
        const r = b.addRunArtifact(exe);
        r.setCwd(b.path("."));
        r.addArgs(check.args);
        r.addFileInput(b.path("test/cli/orders.csv"));
        r.addFileInput(b.path("test/cli/orders.txt"));
        r.addFileInput(b.path("test/cli/orders16.csv"));
        r.addFileInput(b.path("test/cli/wide.csv"));
        r.addFileInput(b.path("test/cli/noheader.csv"));
        r.addFileInput(b.path("test/cli/short.csv"));
        r.addFileInput(b.path("test/cli/trailing.csv"));
        r.addFileInput(b.path("test/cli/long.csv"));
        r.addFileInput(b.path("test/cli/inches.txt"));
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
    if (b.option(bool, "corpus", "Run the tests over the fixture corpus and examples/ (needs python3; default true)") orelse true) {
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

        // examples/README.md run: every command in it prints what it shows
        // (tools/examples_check.py; --update rewrites it).
        const examples = b.addSystemCommand(&.{ "python3", "-I" });
        examples.addFileArg(b.path("tools/examples_check.py"));
        examples.addArtifactArg(exe);
        examples.addFileArg(b.path("examples/README.md"));
        examples.has_side_effects = true;
        test_step.dependOn(&examples.step);
        // So is the top README's showcase, run in a copy of examples/.
        const readme = b.addSystemCommand(&.{ "python3", "-I" });
        readme.addFileArg(b.path("tools/examples_check.py"));
        readme.addArtifactArg(exe);
        readme.addFileArg(b.path("README.md"));
        readme.addArg("--dir");
        readme.addDirectoryArg(b.path("examples"));
        readme.has_side_effects = true;
        test_step.dependOn(&readme.step);
        // NOTICE carries dateparsa's NOTICE as the pinned version ships it.
        const notice = b.addSystemCommand(&.{ "python3", "-I" });
        notice.addFileArg(b.path("tools/notice_check.py"));
        notice.addFileArg(b.path("NOTICE"));
        notice.addFileArg(dateparsa.path("NOTICE"));
        test_step.dependOn(&notice.step);
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
                .imports = &.{.{ .name = "dateparsa", .module = b.dependency("dateparsa", .{
                    .target = target,
                    .optimize = .ReleaseFast,
                }).module("dateparsa") }},
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
    // value for value against the CSV path, and libthresh's Arrow C streams
    // imported by pyarrow through its C ABI, against both. Needs python3
    // with pyarrow: `uv run --with pyarrow --with duckdb zig build
    // arrow-check`.
    const arrow_check = b.addSystemCommand(&.{ "python3", "-I" });
    arrow_check.addFileArg(b.path("test/arrow/check.py"));
    arrow_check.addArtifactArg(exe);
    arrow_check.addDirectoryArg(corpus_dir);
    arrow_check.addArtifactArg(shared_lib);
    arrow_check.has_side_effects = true;
    b.step("arrow-check", "Read thresh's Arrow output and C streams back with pyarrow (needs python3 with pyarrow)").dependOn(&arrow_check.step);

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
    "dirty-comma-dq-crlf-h-quote-all",
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
        .stdout = "{\"format_version\":1,\"file\":\"test/cli/orders.csv\",\"dialect\":{\"delimiter\":\",\",\"quote\":\"\\\"\",\"escape\":\"doubled\",\"newline\":\"lf\",\"header\":true," ++
            "\"confidence\":\"high\",\"score\":1.39,\"runners_up\":[{\"delimiter\":\"\\t\",\"score\":0.19},{\"delimiter\":\"|\",\"score\":0.19}]},\"warnings\":[],\"problems\":[]}\n",
    },
    .{
        .args = &.{ "sniff", "test/cli/orders.csv", "--delimiter", ";", "--header", "no" },
        .stdout = "test/cli/orders.csv: delimiter=; quote=\" escape=doubled newline=lf header=no confidence=high warnings=quote_in_unquoted\n",
    },
    .{
        // A pinned quote the sniffer would not guess is the one scored.
        .args = &.{ "sniff", "test/cli/orders.csv", "--quote", "~" },
        .stdout = "test/cli/orders.csv: delimiter=, quote=~ escape=doubled newline=lf header=yes confidence=low\n",
        .stderr = "thresh: test/cli/orders.csv: the dialect is not settled (confidence low, score 0.92); pin it with --delimiter, --quote, --escape, --newline and --header\n",
        .code = 2,
    },
    .{
        // UTF-16 is transcoded as it is read: sniff refuses an --encoding
        // for it as validate does, and says what it read.
        .args = &.{ "sniff", "test/cli/orders16.csv", "--encoding", "latin1" },
        .stderr = "thresh: test/cli/orders16.csv: the file is UTF-16 (it starts with a byte order mark) and is read as such; leave out --encoding\n",
        .code = 2,
    },
    .{
        .args = &.{ "sniff", "test/cli/orders16.csv" },
        .stdout = "test/cli/orders16.csv: delimiter=, quote=\" escape=doubled newline=lf header=yes confidence=high warnings=utf16\n",
    },
    .{
        .args = &.{ "sniff", "test/cli/orders.csv", "--quote", "none", "--escape", "backslash" },
        .stderr = "thresh: --quote none and --escape backslash together\n(thresh --help lists the commands and options)\n",
        .code = 3,
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
        .stdout = "{\"format_version\":1,\"file\":\"test/cli/orders.csv\",\"result\":\"fail\",\"rows\":2,\"rows_rejected\":2,\"problems\":[]}\n",
        .code = 1,
    },
    .{
        // A problem as its code, its sentence and its parameters.
        .args = &.{ "validate", "test/cli/orders.csv", "--columns", "id:int64,name:string,qty:int64", "--json" },
        .stdout = "{\"format_version\":1,\"file\":\"test/cli/orders.csv\",\"result\":\"fail\",\"rows\":2,\"rows_rejected\":0," ++
            "\"problems\":[{\"code\":\"column_missing\",\"message\":\"the schema's column 'qty' is not in the header\",\"column\":\"qty\"}]}\n",
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
        \\  "format_version": 1,
        \\  "columns": [
        \\    {
        \\      "name": "id",
        \\      "type": "int64",
        \\      "conformance": 1,
        \\      "samples": [
        \\        "1",
        \\        "2"
        \\      ],
        \\      "inferred": true,
        \\      "stats": {
        \\        "values": 2,
        \\        "empty": 0,
        \\        "length": {
        \\          "min": 1,
        \\          "max": 1
        \\        },
        \\        "min": "1",
        \\        "max": "2",
        \\        "distinct": 2,
        \\        "top": [],
        \\        "shapes": [
        \\          {
        \\            "shape": "9",
        \\            "count": 2
        \\          }
        \\        ]
        \\      }
        \\    },
        \\    {
        \\      "name": "name",
        \\      "type": "string",
        \\      "conformance": 1,
        \\      "samples": [
        \\        "apple",
        \\        "pear, green"
        \\      ],
        \\      "inferred": true,
        \\      "stats": {
        \\        "values": 2,
        \\        "empty": 0,
        \\        "length": {
        \\          "min": 5,
        \\          "max": 11
        \\        },
        \\        "distinct": 2,
        \\        "top": [],
        \\        "shapes": [
        \\          {
        \\            "shape": "a",
        \\            "count": 1
        \\          },
        \\          {
        \\            "shape": "a, a",
        \\            "count": 1
        \\          }
        \\        ]
        \\      }
        \\    },
        \\    {
        \\      "name": "amount",
        \\      "type": "decimal",
        \\      "precision": 18,
        \\      "scale": 2,
        \\      "conformance": 1,
        \\      "samples": [
        \\        "1.50",
        \\        "2.25"
        \\      ],
        \\      "inferred": true,
        \\      "stats": {
        \\        "values": 2,
        \\        "empty": 0,
        \\        "length": {
        \\          "min": 4,
        \\          "max": 4
        \\        },
        \\        "min": "1.50",
        \\        "max": "2.25",
        \\        "distinct": 2,
        \\        "top": [],
        \\        "shapes": [
        \\          {
        \\            "shape": "9.9",
        \\            "count": 2
        \\          }
        \\        ]
        \\      }
        \\    }
        \\  ],
        \\  "nulls": [
        \\    ""
        \\  ],
        \\  "match": "name"
        \\}
        \\
        ,
        .stderr = "infer test/cli/orders.csv  2 rows  3 columns\n" ++
            "thresh: id, amount: typed from fewer than 10 values; check them before reusing the schema\n",
    },
    .{
        // A row wider than the header is a ragged row, not a column.
        .args = &.{ "infer", "test/cli/wide.csv" },
        .stdout = null,
        .stderr = "infer test/cli/wide.csv  39 rows  3 columns\n" ++
            "thresh: test/cli/wide.csv: 1 row wider than the header left out, the first on line 21: ragged rows, which validate rejects\n",
    },
    .{
        // Files that disagree on their columns: said, and exit 1.
        .args = &.{ "infer", "test/cli/orders.csv", "test/cli/wide.csv", "--jobs", "1" },
        .stdout = null,
        .stderr = "infer test/cli/orders.csv  2 rows  3 columns\n" ++
            "infer test/cli/wide.csv  39 rows  3 columns\n" ++
            "thresh: test/cli/wide.csv: 1 row wider than the header left out, the first on line 21: ragged rows, which validate rejects\n" ++
            "thresh: id, amount: typed from fewer than 10 values; check them before reusing the schema\n" ++
            "thresh: the files disagree: 6 of the schema's 6 columns are not in every file: 'id' (1 of 2), 'name' (1 of 2), 'amount' (1 of 2) and 3 more; validate fails a file without one\n",
        .code = 1,
    },
    .{
        .args = &.{ "infer", "test/cli/orders.csv", "test/cli/noheader.csv", "--jobs", "1" },
        .stdout = null,
        .stderr = "infer test/cli/orders.csv  2 rows  3 columns\n" ++
            "infer test/cli/noheader.csv  20 rows  3 columns\n" ++
            "thresh: id, amount: typed from fewer than 10 values; check them before reusing the schema\n" ++
            "thresh: the files disagree: 1 of 2 have no header (the first: test/cli/noheader.csv), so the schema matches columns by position; infer them apart, or pin --header\n",
        .code = 1,
    },
    .{
        // A header a name short of its rows: said, not guessed at.
        .args = &.{ "infer", "test/cli/short.csv" },
        .stderr = "error test/cli/short.csv  row 1 is a header of 3 names over rows of 4 fields, and which names go with which columns cannot be told; fix the header, or pin --header no to read row 1 as data\n" ++
            "thresh: no file to infer a schema from\n",
        .code = 2,
    },
    .{
        // A header line alone ending in a delimiter: its 3 columns.
        .args = &.{ "infer", "test/cli/trailing.csv" },
        .stdout = null,
        .stderr = "infer test/cli/trailing.csv  20 rows  3 columns\n",
    },
    .{
        .args = &.{ "sniff", "test/cli/long.csv" },
        .stderr = "thresh: test/cli/long.csv: row 1 is a header of 4 names over rows of 3 fields, and which names go with which columns cannot be told; fix the header, or pin --header no to read row 1 as data\n",
        .code = 2,
    },
    .{
        .args = &.{ "sniff", "test/cli/short.csv", "--header", "no" },
        .stdout = "test/cli/short.csv: delimiter=| quote=\" escape=doubled newline=lf header=no confidence=medium\n",
    },
    .{
        // '"' as an inch mark in a file that never quotes, past the sniff
        // window: three lines folded into one record are not rows.
        .args = &.{ "validate", "test/cli/inches.txt", "--columns", "lug_id:int64,bin:string,cultivar:string", "--sample-bytes", "512", "--json" },
        .stdout = "{\"format_version\":1,\"file\":\"test/cli/inches.txt\",\"result\":\"error\",\"rows\":68,\"rows_rejected\":0,\"problems\":[{\"code\":\"quote_is_data\"," ++
            "\"message\":\"the quotes look like data: 1 record holds 3 lines inside quotes, the first on line 62, and each of those lines is a whole row without them; pin --quote none to read quotes as data\"," ++
            "\"records\":1,\"lines\":3,\"line\":62,\"suggest\":{\"quote\":\"none\"}}]}\n",
        .code = 2,
    },
    .{
        // The fold inside the sniffer's sample: sniff says so, and the file
        // stops there, unread.
        .args = &.{ "sniff", "test/cli/inches.txt" },
        .stdout = "test/cli/inches.txt: delimiter=| quote=\" escape=doubled newline=lf header=yes confidence=high warnings=quote_in_unquoted\n",
        .stderr = "thresh: test/cli/inches.txt: the quotes look like data: 1 record holds 3 lines inside quotes, the first on line 62, and each of those lines is a whole row without them; pin --quote none to read quotes as data\n",
        .code = 2,
    },
    .{
        .args = &.{ "validate", "test/cli/inches.txt", "--columns", "lug_id:int64,bin:string,cultivar:string", "--json" },
        .stdout = "{\"format_version\":1,\"file\":\"test/cli/inches.txt\",\"result\":\"error\",\"rows\":0,\"rows_rejected\":0,\"problems\":[{\"code\":\"quote_is_data\"," ++
            "\"message\":\"the quotes look like data: 1 record holds 3 lines inside quotes, the first on line 62, and each of those lines is a whole row without them; pin --quote none to read quotes as data\"," ++
            "\"records\":1,\"lines\":3,\"line\":62,\"suggest\":{\"quote\":\"none\"}}]}\n",
        .code = 2,
    },
    .{
        .args = &.{ "sniff", "test/cli/inches.txt", "--quote", "\"" },
        .stdout = "test/cli/inches.txt: delimiter=| quote=\" escape=doubled newline=lf header=yes confidence=high warnings=quote_in_unquoted\n",
    },
    .{
        .args = &.{ "sniff", "test/cli/inches.txt", "--quote", "none" },
        .stdout = "test/cli/inches.txt: delimiter=| quote=none escape=doubled newline=lf header=yes confidence=high\n",
    },
    .{
        .args = &.{ "validate", "test/cli/inches.txt", "--columns", "lug_id:int64,bin:string,cultivar:string", "--sample-bytes", "512", "--quote", "none", "--json" },
        .stdout = "{\"format_version\":1,\"file\":\"test/cli/inches.txt\",\"result\":\"pass\",\"rows\":70,\"rows_rejected\":0,\"problems\":[]}\n",
    },
    .{
        // A quote pinned is the user's word that the file quotes.
        .args = &.{ "validate", "test/cli/inches.txt", "--columns", "lug_id:int64,bin:string,cultivar:string", "--sample-bytes", "512", "--quote", "\"", "--json" },
        .stdout = "{\"format_version\":1,\"file\":\"test/cli/inches.txt\",\"result\":\"pass\",\"rows\":68,\"rows_rejected\":0,\"problems\":[]}\n",
    },
    .{
        // Nor are they written out: no "written".
        .args = &.{ "run", "test/cli/inches.txt", "--columns", "lug_id:int64,bin:string,cultivar:string", "--sample-bytes", "512", "--to", "csv", "--out", ".zig-cache/cli-out/inches", "--json" },
        .stdout = "{\"format_version\":1,\"file\":\"test/cli/inches.txt\",\"result\":\"error\",\"rows\":68,\"rows_rejected\":0,\"problems\":[{\"code\":\"quote_is_data\"," ++
            "\"message\":\"the quotes look like data: 1 record holds 3 lines inside quotes, the first on line 62, and each of those lines is a whole row without them; pin --quote none to read quotes as data\"," ++
            "\"records\":1,\"lines\":3,\"line\":62,\"suggest\":{\"quote\":\"none\"}}]}\n",
        .code = 2,
    },
    .{
        // Nor does infer type columns from them.
        .args = &.{ "infer", "test/cli/inches.txt", "--sample-bytes", "512" },
        .stderr = "error test/cli/inches.txt  the quotes look like data: 1 record holds 3 lines inside quotes, the first on line 62, and each of those lines is a whole row without them; pin --quote none to read quotes as data\n" ++
            "thresh: no file to infer a schema from\n",
        .code = 2,
    },
    .{
        .args = &.{ "convert", "test/cli/orders.csv", "--to", "csv", "--out", ".zig-cache/cli-out/convert", "--json" },
        .stdout = "{\"format_version\":1,\"file\":\"test/cli/orders.csv\",\"result\":\"pass\",\"rows\":2,\"rows_rejected\":0,\"problems\":[],\"written\":\".zig-cache/cli-out/convert/orders.csv\"}\n",
    },
    .{
        // Names unique with their extensions, alike without: each output its own.
        .args = &.{ "convert", "test/cli/orders.csv", "test/cli/orders.txt", "--to", "csv", "--out", ".zig-cache/cli-out/stems", "--json", "--jobs", "1" },
        .stdout = "{\"format_version\":1,\"file\":\"test/cli/orders.csv\",\"result\":\"pass\",\"rows\":2,\"rows_rejected\":0,\"problems\":[],\"written\":\".zig-cache/cli-out/stems/orders.csv\"}\n" ++
            "{\"format_version\":1,\"file\":\"test/cli/orders.txt\",\"result\":\"pass\",\"rows\":1,\"rows_rejected\":0,\"problems\":[],\"written\":\".zig-cache/cli-out/stems/orders-2.csv\"}\n",
    },
    .{
        .args = &.{ "run", "test/cli/orders.csv", "--columns", "id:int64,amount:int64", "--to", "csv", "--out", ".zig-cache/cli-out/run", "--strict", "--quiet" },
        .code = 1,
    },
    .{ .args = &.{"--help"}, .stdout = null },
    .{ .args = &.{"--version"}, .stdout = "thresh " ++ zon.version ++ "\n" },
};
