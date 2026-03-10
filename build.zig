const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Main executable ---
    const exe = b.addExecutable(.{
        .name = "base24-gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    // stb_image: single vendored C translation unit
    exe.addIncludePath(b.path("vendor"));
    exe.addCSourceFile(.{
        .file = b.path("vendor/stb_image.c"),
        .flags = &.{"-std=c99"},
    });

    b.installArtifact(exe);

    // --- Dev TUI ---
    const devtui = b.addExecutable(.{
        .name = "devtui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/devtui.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    devtui.addIncludePath(b.path("vendor"));
    devtui.addCSourceFile(.{
        .file = b.path("vendor/stb_image.c"),
        .flags = &.{"-std=c99"},
    });
    b.installArtifact(devtui);

    // --- Run step ---
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run base24-gen");
    run_step.dependOn(&run_cmd.step);

    // --- Dev TUI run step ---
    const devtui_run = b.addRunArtifact(devtui);
    devtui_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| devtui_run.addArgs(args);
    const devtui_step = b.step("devtui", "Run palette devtool TUI");
    devtui_step.dependOn(&devtui_run.step);

    // --- Test step ---
    const test_step = b.step("test", "Run unit tests");
    for (&[_][]const u8{
        "src/color.zig",
        "src/analysis.zig",
        "src/peaks.zig",
        "src/palette.zig",
    }) |src| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(src),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        t.addIncludePath(b.path("vendor"));
        t.addCSourceFile(.{
            .file = b.path("vendor/stb_image.c"),
            .flags = &.{"-std=c99"},
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
