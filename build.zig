//! Build altaridsk for single or multiple targets
//! use -Dmulti-target=true to buld for all targets
//! Recommended build options are --release=safe --strip-exe
const std = @import("std");
pub fn build(b: *std.Build) void {
    // Build for all supported targets.
    const build_multi_target = b.option(bool, "multi-target", "Build for windows, linux and macos") orelse false;
    // Don't output a binary.
    const no_bin = b.option(bool, "no-bin", "skip emitting binary") orelse false;
    // Strip debug symbols
    const strip_debug_symbols = b.option(bool, "strip-exe", "Strip debugging information") orelse false;

    // Add other supported targets here as required.
    const all_targets = [_]std.Build.ResolvedTarget{
        b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows }),
        b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux }),
        b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .macos }),
        b.resolveTargetQuery(.{ .cpu_arch = .arm, .os_tag = .linux }),
        b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .windows }),
        b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .linux }),
        b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .macos }),
    };
    // If compiling for single target (default) single_exe will be set to the compile step for altairdsk.
    var single_exe: ?*std.Build.Step.Compile = null;
    const single_target = [_]std.Build.ResolvedTarget{b.standardTargetOptions(.{})};

    // Targets is list of targets we are building for.
    const targets = if (!build_multi_target)
        single_target[0..]
    else
        all_targets[0..];

    const optimize = b.standardOptimizeOption(.{});
    const run_step = b.step("run", "Run the app");
    const test_step = b.step("test", "Run unit tests");

    // For each target build the library and exe's
    for (targets) |target| {
        const lib_mod = b.addModule("altair_disk", .{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        });
        const lib = b.addStaticLibrary(.{
            .name = "altair_disk",
            .root_module = lib_mod,
        });
        if (targets.len > 1) {
            const install = b.addInstallArtifact(lib, .{
                .dest_dir = .{ .override = .{
                    .custom = std.fmt.allocPrint(b.allocator, "lib/{s}-{s}", .{
                        @tagName(target.result.cpu.arch),
                        @tagName(target.result.os.tag),
                    }) catch unreachable,
                } },
            });
            b.default_step.dependOn(&install.step);
        } else {
            b.installArtifact(lib);
        }
        const exe = b.addExecutable(.{
            .name = "altairdsk",
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip_debug_symbols,
        });
        const zigcli = b.dependency("cli", .{ .target = target, .optimize = optimize });
        exe.root_module.addImport("zig-cli", zigcli.module("zig-cli"));
        if (targets.len > 1) {
            const install = b.addInstallArtifact(exe, .{
                .dest_dir = .{ .override = .{
                    .custom = std.fmt.allocPrint(b.allocator, "bin/{s}-{s}", .{
                        @tagName(target.result.cpu.arch),
                        @tagName(target.result.os.tag),
                    }) catch unreachable,
                } },
            });
            b.default_step.dependOn(&install.step);
        } else {
            single_exe = exe;
            b.installArtifact(exe);
        }
    }
    if (single_exe) |exe| {
        // Add run and test commands, but only for sinlge arch builds.
        const target = single_target[0];
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        run_step.dependOn(&run_cmd.step);

        // Unit tests
        const lib_unit_tests = b.addTest(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        });
        const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

        const exe_unit_tests = b.addTest(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });

        const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

        test_step.dependOn(&run_lib_unit_tests.step);
        test_step.dependOn(&run_exe_unit_tests.step);

        // Don't output binary. Used for Zig "build on save" feature.
        // Which skips the LLVM emit so you can see buil errors more quickly.
        if (no_bin) {
            b.getInstallStep().dependOn(&exe.step);
        } else {
            b.installArtifact(exe);
        }
    }
}
