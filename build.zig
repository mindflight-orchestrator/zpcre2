const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zpcre2 = b.addModule("zpcre2", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "zpcre2",
        .root_module = zpcre2,
    });
    b.installArtifact(lib);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    run_unit_tests.has_side_effects = true;

    const test_step = b.step("test", "Run unit tests and PCRE2 oracle");
    test_step.dependOn(&run_unit_tests.step);

    const pcre2 = addBundledPcre2(b, target, optimize);
    const pcre2_c = translatePcre2(b, target, optimize, pcre2.header_dir);

    const oracle_mod = b.createModule(.{
        .root_source_file = b.path("tests/oracle.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zpcre2", .module = zpcre2 },
            .{ .name = "c", .module = pcre2_c },
        },
        .link_libc = true,
    });
    oracle_mod.linkLibrary(pcre2.lib);

    const oracle_tests = b.addTest(.{ .root_module = oracle_mod });
    const run_oracle = b.addRunArtifact(oracle_tests);
    run_oracle.has_side_effects = true;

    const oracle_step = b.step("test-oracle", "Differential tests against bundled PCRE2 10.47");
    oracle_step.dependOn(&run_oracle.step);
    test_step.dependOn(&run_oracle.step);

    const bench_optimize: std.builtin.OptimizeMode = .ReleaseFast;
    const zpcre2_fast = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = bench_optimize,
    });
    const pcre2_fast = addBundledPcre2(b, target, bench_optimize);
    const pcre2_c_fast = translatePcre2(b, target, bench_optimize, pcre2_fast.header_dir);

    const corpus_fast = b.createModule(.{
        .root_source_file = b.path("tests/corpus.zig"),
        .target = target,
        .optimize = bench_optimize,
        .imports = &.{.{ .name = "zpcre2", .module = zpcre2_fast }},
    });
    const bind_fast = b.createModule(.{
        .root_source_file = b.path("tests/pcre2_bind.zig"),
        .target = target,
        .optimize = bench_optimize,
        .imports = &.{
            .{ .name = "zpcre2", .module = zpcre2_fast },
            .{ .name = "c", .module = pcre2_c_fast },
        },
        .link_libc = true,
    });
    bind_fast.linkLibrary(pcre2_fast.lib);

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        .optimize = bench_optimize,
        .imports = &.{
            .{ .name = "zpcre2", .module = zpcre2_fast },
            .{ .name = "corpus", .module = corpus_fast },
            .{ .name = "pcre2_bind", .module = bind_fast },
        },
        .link_libc = true,
    });
    bench_mod.linkLibrary(pcre2_fast.lib);

    const bench_exe = b.addExecutable(.{
        .name = "zpcre2-bench",
        .root_module = bench_mod,
    });

    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Match throughput: zpcre2 vs PCRE2 10.47");
    bench_step.dependOn(&run_bench.step);
}

const Pcre2Lib = struct {
    lib: *std.Build.Step.Compile,
    header_dir: std.Build.LazyPath,
};

fn addBundledPcre2(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) Pcre2Lib {
    const root = b.path("ext/pcre2");
    const header_files = b.addWriteFiles();
    const header_dir = header_files.getDirectory();
    _ = header_files.addCopyFile(root.path(b, "src/pcre2.h.generic"), "pcre2.h");

    const config_header = b.addConfigHeader(
        .{
            .style = .{ .cmake = root.path(b, "src/config-cmake.h.in") },
            .include_path = "config.h",
        },
        .{
            .HAVE_ASSERT_H = true,
            .HAVE_UNISTD_H = (target.result.os.tag != .windows),
            .HAVE_WINDOWS_H = (target.result.os.tag == .windows),
            .HAVE_ATTRIBUTE_UNINITIALIZED = true,
            .HAVE_BUILTIN_MUL_OVERFLOW = true,
            .HAVE_BUILTIN_UNREACHABLE = true,
            .SUPPORT_PCRE2_8 = true,
            .SUPPORT_PCRE2_16 = false,
            .SUPPORT_PCRE2_32 = false,
            .SUPPORT_UNICODE = true,
            .SUPPORT_JIT = false,
            .PCRE2_EXPORT = null,
            .PCRE2_LINK_SIZE = 2,
            .PCRE2_HEAP_LIMIT = 20000000,
            .PCRE2_MATCH_LIMIT = 10000000,
            .PCRE2_MATCH_LIMIT_DEPTH = "MATCH_LIMIT",
            .PCRE2_MAX_VARLOOKBEHIND = 255,
            .NEWLINE_DEFAULT = 2,
            .PCRE2_PARENS_NEST_LIMIT = 250,
            .PCRE2GREP_BUFSIZE = 20480,
            .PCRE2GREP_MAX_BUFSIZE = 1048576,
        },
    );

    const lib_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib_mod.addCMacro("HAVE_CONFIG_H", "");
    lib_mod.addCMacro("PCRE2_CODE_UNIT_WIDTH", "8");
    lib_mod.addCMacro("PCRE2_STATIC", "");

    const lib = b.addLibrary(.{
        .name = "pcre2-8",
        .root_module = lib_mod,
        .linkage = .static,
    });
    lib_mod.addConfigHeader(config_header);
    lib_mod.addIncludePath(header_dir);
    lib_mod.addIncludePath(root.path(b, "src"));
    lib_mod.addCSourceFile(.{
        .file = b.addWriteFiles().addCopyFile(
            root.path(b, "src/pcre2_chartables.c.dist"),
            "pcre2_chartables.c",
        ),
    });
    lib_mod.addCSourceFiles(.{
        .root = root,
        .files = &.{
            "src/pcre2_auto_possess.c",
            "src/pcre2_chkdint.c",
            "src/pcre2_compile.c",
            "src/pcre2_compile_cgroup.c",
            "src/pcre2_compile_class.c",
            "src/pcre2_config.c",
            "src/pcre2_context.c",
            "src/pcre2_convert.c",
            "src/pcre2_dfa_match.c",
            "src/pcre2_error.c",
            "src/pcre2_extuni.c",
            "src/pcre2_find_bracket.c",
            "src/pcre2_jit_compile.c",
            "src/pcre2_maketables.c",
            "src/pcre2_match.c",
            "src/pcre2_match_data.c",
            "src/pcre2_match_next.c",
            "src/pcre2_newline.c",
            "src/pcre2_ord2utf.c",
            "src/pcre2_pattern_info.c",
            "src/pcre2_script_run.c",
            "src/pcre2_serialize.c",
            "src/pcre2_string_utils.c",
            "src/pcre2_study.c",
            "src/pcre2_substitute.c",
            "src/pcre2_substring.c",
            "src/pcre2_tables.c",
            "src/pcre2_ucd.c",
            "src/pcre2_valid_utf.c",
            "src/pcre2_xclass.c",
        },
    });

    return .{ .lib = lib, .header_dir = header_dir };
}

fn translatePcre2(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    header_dir: std.Build.LazyPath,
) *std.Build.Module {
    const tc = b.addTranslateC(.{
        .root_source_file = b.path("tests/pcre2_oracle.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    tc.addIncludePath(header_dir);
    tc.defineCMacro("PCRE2_STATIC", null);
    return tc.createModule();
}
