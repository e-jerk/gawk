const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const is_macos = target.result.os.tag == .macos;
    const is_linux = target.result.os.tag == .linux;
    const is_native = target.result.os.tag == @import("builtin").os.tag;

    // GNU build option: enables all backends (GPL3 license)
    // Standard build (default): platform-specific backends only (Unlicense)
    // - macOS standard: Metal + CPU
    // - Linux standard: Vulkan + CPU
    // - GNU build: all available backends for the platform
    const gnu = b.option(bool, "gnu", "Enable GNU/GPL3 build with all backends") orelse false;

    // Determine which backends to enable
    const enable_metal = is_macos;
    const enable_vulkan = is_linux or (is_macos and gnu);

    // Build options to pass compile-time config to source
    const build_options = b.addOptions();
    build_options.addOption(bool, "is_macos", is_macos);
    build_options.addOption(bool, "enable_metal", enable_metal);
    build_options.addOption(bool, "enable_vulkan", enable_vulkan);
    build_options.addOption(bool, "gnu_build", gnu);
    const build_options_module = build_options.createModule();

    // e_jerk_gpu library for GPU detection and auto-selection (also provides zigtrait)
    const e_jerk_gpu_dep = b.dependency("e_jerk_gpu", .{});
    const e_jerk_gpu_module = e_jerk_gpu_dep.module("e_jerk_gpu");
    const zigtrait_module = e_jerk_gpu_dep.module("zigtrait");

    // e_jerk_regex library for regex support
    const e_jerk_regex_dep = b.dependency("e_jerk_regex", .{});
    const e_jerk_regex_module = e_jerk_regex_dep.module("regex");

    // zig-metal dependency
    const zig_metal_dep = b.dependency("zig_metal", .{});
    const zig_metal_module = b.addModule("zig-metal", .{
        .root_source_file = zig_metal_dep.path("src/main.zig"),
        .imports = &.{
            .{ .name = "zigtrait", .module = zigtrait_module },
        },
    });

    // Vulkan dependencies
    const vulkan_headers = b.dependency("vulkan_headers", .{});
    const vulkan_dep = b.dependency("vulkan_zig", .{
        .registry = vulkan_headers.path("registry/vk.xml"),
    });
    const vulkan_module = vulkan_dep.module("vulkan-zig");

    // Shared shader library
    const shaders_common = b.dependency("shaders_common", .{});

    // Compile SPIR-V shader from GLSL for Vulkan (main pattern matching)
    const spirv_compile = b.addSystemCommand(&.{
        "glslc",
        "--target-env=vulkan1.2",
        "-O",
    });
    // Add include path for shared GLSL headers
    spirv_compile.addArg("-I");
    spirv_compile.addDirectoryArg(shaders_common.path("glsl"));
    spirv_compile.addArg("-o");
    const spirv_output = spirv_compile.addOutputFileArg("awk.spv");
    spirv_compile.addFileArg(b.path("src/shaders/awk.comp"));

    // Compile SPIR-V shader for regex pattern matching
    const spirv_regex_compile = b.addSystemCommand(&.{
        "glslc",
        "--target-env=vulkan1.2",
        "-O",
    });
    spirv_regex_compile.addArg("-I");
    spirv_regex_compile.addDirectoryArg(shaders_common.path("glsl"));
    spirv_regex_compile.addArg("-o");
    const spirv_regex_output = spirv_regex_compile.addOutputFileArg("awk_regex.spv");
    spirv_regex_compile.addFileArg(b.path("src/shaders/awk_regex.comp"));

    // Create embedded SPIR-V module (includes both shaders)
    const spirv_module = b.addModule("spirv", .{
        .root_source_file = b.addWriteFiles().add("spirv.zig",
            \\pub const EMBEDDED_SPIRV = @embedFile("awk.spv");
            \\pub const EMBEDDED_SPIRV_REGEX = @embedFile("awk_regex.spv");
        ),
    });
    spirv_module.addAnonymousImport("awk.spv", .{ .root_source_file = spirv_output });
    spirv_module.addAnonymousImport("awk_regex.spv", .{ .root_source_file = spirv_regex_output });

    // Preprocess Metal shader to inline string_ops.h and regex_ops.h includes
    // Concatenates: string_ops.h + regex_ops.h + shader (with include lines removed)
    const metal_preprocess = b.addSystemCommand(&.{
        "/bin/sh", "-c",
        \\cat "$1" "$2" && grep -v '#include "string_ops.h"' "$3" | grep -v '#include "regex_ops.h"'
        , "--",
    });
    metal_preprocess.addFileArg(shaders_common.path("metal/string_ops.h"));
    metal_preprocess.addFileArg(shaders_common.path("metal/regex_ops.h"));
    metal_preprocess.addFileArg(b.path("src/shaders/awk.metal"));
    const preprocessed_metal = metal_preprocess.captureStdOut();

    // Create embedded Metal shader module
    const metal_module = b.addModule("metal_shader", .{
        .root_source_file = b.addWriteFiles().add("metal_shader.zig",
            \\pub const EMBEDDED_METAL_SHADER = @embedFile("awk.metal");
        ),
    });
    metal_module.addAnonymousImport("awk.metal", .{ .root_source_file = preprocessed_metal });

    // Create gpu module for reuse
    const gpu_module = b.addModule("gpu", .{
        .root_source_file = b.path("src/gpu/mod.zig"),
        .imports = &.{
            .{ .name = "zig-metal", .module = zig_metal_module },
            .{ .name = "build_options", .module = build_options_module },
            .{ .name = "vulkan", .module = vulkan_module },
            .{ .name = "spirv", .module = spirv_module },
            .{ .name = "metal_shader", .module = metal_module },
            .{ .name = "e_jerk_gpu", .module = e_jerk_gpu_module },
            .{ .name = "regex", .module = e_jerk_regex_module },
        },
    });

    // Create cpu module for reuse (optimized SIMD implementation)
    const cpu_module = b.addModule("cpu", .{
        .root_source_file = b.path("src/cpu_optimized.zig"),
        .imports = &.{
            .{ .name = "gpu", .module = gpu_module },
            .{ .name = "regex", .module = e_jerk_regex_module },
        },
    });

    // Create cpu_gnu module (GNU gawk reference implementation)
    // Note: Delegates to optimized backend since GNU gawk's interpreter is tightly integrated
    const cpu_gnu_module = b.addModule("cpu_gnu", .{
        .root_source_file = b.path("src/cpu_gnu.zig"),
        .imports = &.{
            .{ .name = "gpu", .module = gpu_module },
            .{ .name = "cpu_optimized", .module = cpu_module },
        },
    });

    // Main executable
    const exe = b.addExecutable(.{
        .name = "gawk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig-metal", .module = zig_metal_module },
                .{ .name = "build_options", .module = build_options_module },
                .{ .name = "vulkan", .module = vulkan_module },
                .{ .name = "spirv", .module = spirv_module },
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
                .{ .name = "cpu_gnu", .module = cpu_gnu_module },
                .{ .name = "regex", .module = e_jerk_regex_module },
            },
        }),
    });

    // Platform-specific linking based on enabled backends
    if (is_native) {
        if (enable_metal) {
            exe.linkFramework("Foundation");
            exe.linkFramework("Metal");
            exe.linkFramework("QuartzCore");
        }
        if (enable_vulkan) {
            if (is_macos) {
                // MoltenVK from Homebrew for Vulkan on macOS
                exe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
                exe.linkSystemLibrary("MoltenVK");
            } else {
                exe.linkSystemLibrary("vulkan");
            }
        }
    }

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run gawk");
    run_step.dependOn(&run_cmd.step);

    // Benchmark executable
    const bench_exe = b.addExecutable(.{
        .name = "gawk-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "zig-metal", .module = zig_metal_module },
                .{ .name = "build_options", .module = build_options_module },
                .{ .name = "vulkan", .module = vulkan_module },
                .{ .name = "spirv", .module = spirv_module },
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
                .{ .name = "cpu_gnu", .module = cpu_gnu_module },
            },
        }),
    });

    if (is_native) {
        if (enable_metal) {
            bench_exe.linkFramework("Foundation");
            bench_exe.linkFramework("Metal");
            bench_exe.linkFramework("QuartzCore");
        }
        if (enable_vulkan) {
            if (is_macos) {
                bench_exe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
                bench_exe.linkSystemLibrary("MoltenVK");
            } else {
                bench_exe.linkSystemLibrary("vulkan");
            }
        }
    }

    b.installArtifact(bench_exe);

    const bench_cmd = b.addRunArtifact(bench_exe);
    bench_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        bench_cmd.addArgs(args);
    }

    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench_cmd.step);

    // Smoke tests executable
    const smoke_exe = b.addExecutable(.{
        .name = "gawk-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/smoke_tests.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "zig-metal", .module = zig_metal_module },
                .{ .name = "build_options", .module = build_options_module },
                .{ .name = "vulkan", .module = vulkan_module },
                .{ .name = "spirv", .module = spirv_module },
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
                .{ .name = "cpu_gnu", .module = cpu_gnu_module },
            },
        }),
    });

    if (is_native) {
        if (enable_metal) {
            smoke_exe.linkFramework("Foundation");
            smoke_exe.linkFramework("Metal");
            smoke_exe.linkFramework("QuartzCore");
        }
        if (enable_vulkan) {
            if (is_macos) {
                smoke_exe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
                smoke_exe.linkSystemLibrary("MoltenVK");
            } else {
                smoke_exe.linkSystemLibrary("vulkan");
            }
        }
    }

    b.installArtifact(smoke_exe);

    const smoke_cmd = b.addRunArtifact(smoke_exe);
    smoke_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        smoke_cmd.addArgs(args);
    }

    const smoke_step = b.step("smoke", "Run smoke tests");
    smoke_step.dependOn(&smoke_cmd.step);

    // Tests
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig-metal", .module = zig_metal_module },
                .{ .name = "build_options", .module = build_options_module },
                .{ .name = "vulkan", .module = vulkan_module },
                .{ .name = "spirv", .module = spirv_module },
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
                .{ .name = "cpu_gnu", .module = cpu_gnu_module },
            },
        }),
    });

    if (is_native) {
        if (enable_metal) {
            unit_tests.linkFramework("Foundation");
            unit_tests.linkFramework("Metal");
            unit_tests.linkFramework("QuartzCore");
        }
        if (enable_vulkan) {
            if (is_macos) {
                unit_tests.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
                unit_tests.linkSystemLibrary("MoltenVK");
            } else {
                unit_tests.linkSystemLibrary("vulkan");
            }
        }
    }

    // Unit tests from tests/unit_tests.zig
    const extra_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig-metal", .module = zig_metal_module },
                .{ .name = "build_options", .module = build_options_module },
                .{ .name = "vulkan", .module = vulkan_module },
                .{ .name = "spirv", .module = spirv_module },
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
            },
        }),
    });

    if (is_native) {
        if (enable_metal) {
            extra_tests.linkFramework("Foundation");
            extra_tests.linkFramework("Metal");
            extra_tests.linkFramework("QuartzCore");
        }
        if (enable_vulkan) {
            if (is_macos) {
                extra_tests.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
                extra_tests.linkSystemLibrary("MoltenVK");
            } else {
                extra_tests.linkSystemLibrary("vulkan");
            }
        }
    }

    // Metal shader compilation check (only when Metal is enabled)
    if (enable_metal) {
        const write_shader = b.addWriteFiles();
        _ = write_shader.addCopyFile(preprocessed_metal, "awk_check.metal");

        const metal_compile_check = b.addSystemCommand(&.{
            "xcrun", "-sdk", "macosx", "metal",
            "-Werror",
            "-c",
        });
        metal_compile_check.addFileArg(write_shader.getDirectory().path(b, "awk_check.metal"));
        metal_compile_check.addArg("-o");
        _ = metal_compile_check.addOutputFileArg("awk.air");

        extra_tests.step.dependOn(&metal_compile_check.step);
    }

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const run_extra_tests = b.addRunArtifact(extra_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_extra_tests.step);
}
