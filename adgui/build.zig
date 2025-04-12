const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Strip debug symbols
    const strip_debug_symbols = b.option(bool, "strip-exe", "Strip debugging information") orelse false;

    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip_debug_symbols,
    });

    const altair_disk_dep = b.dependency("altair_disk", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "adgui",
        .root_module = exe_mod,
        .use_llvm = true,
    });

    const dvui_dep = b.dependency("dvui", .{ .target = target, .optimize = optimize, .sdl3 = false, .linux_display_backend = .X11 });
    exe.root_module.addImport("dvui", dvui_dep.module("dvui_sdl"));

    exe.root_module.addImport("altair_disk", altair_disk_dep.module("altair_disk"));
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const button_handler_tests = b.addTest(.{
        .root_source_file = b.path("src/ButtonHandler.zig"),
    });
    button_handler_tests.root_module.addImport("altair_disk", altair_disk_dep.module("altair_disk"));
    const run_button_handler_tests = b.addRunArtifact(button_handler_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_button_handler_tests.step);

    const exe_check = b.addExecutable(.{
        .name = "adgui",
        .root_module = exe_mod,
    });

    const check = b.step("check", "Check if adgui compiles");
    check.dependOn(&exe_check.step);

    const no_bin = b.option(bool, "no-bin", "skip emitting binary") orelse false;
    if (no_bin) {
        b.getInstallStep().dependOn(&exe.step);
    } else {
        b.installArtifact(exe);
    }
}
