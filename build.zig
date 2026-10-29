const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dateparsa = b.dependency("dateparsa", .{ .target = target, .optimize = optimize });
    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);

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

    const lint_paths = [_][]const u8{ "build.zig", "src" };
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
        .stdout = "test/cli/orders.csv: delimiter=, quote=\" escape=doubled newline=lf header=no\n",
    },
    .{
        .args = &.{ "sniff", "test/cli/orders.csv", "--json" },
        .stdout = "{\"file\":\"test/cli/orders.csv\",\"dialect\":{\"delimiter\":\",\",\"quote\":\"\\\"\",\"escape\":\"doubled\",\"newline\":\"lf\",\"header\":false}}\n",
    },
    .{
        .args = &.{ "sniff", "test/cli/missing.csv", "test/cli/orders.csv" },
        .stdout = "test/cli/orders.csv: delimiter=, quote=\" escape=doubled newline=lf header=no\n",
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
    .{ .args = &.{"--help"}, .stdout = null },
    .{ .args = &.{"--version"}, .stdout = "thresh " ++ zon.version ++ "\n" },
};
