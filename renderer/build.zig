const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "weaver-renderer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.subsystem = .Windows;
    exe.root_module.addCSourceFiles(.{
        .files = &.{
            "src/renderer_server.cpp",
            "../runtime/native-sdk/src/platform/windows/d3d_presenter.cpp",
        },
        .flags = &.{"-std=c++17"},
    });
    exe.root_module.addIncludePath(b.path("../runtime/native-sdk/src/platform/windows"));
    exe.root_module.addIncludePath(b.path("src"));
    exe.root_module.linkSystemLibrary("c++", .{});
    exe.root_module.linkSystemLibrary("c", .{});
    exe.root_module.linkSystemLibrary("kernel32", .{});
    exe.root_module.linkSystemLibrary("ole32", .{});
    exe.root_module.linkSystemLibrary("d3d11", .{});
    exe.root_module.linkSystemLibrary("dxgi", .{});
    exe.root_module.linkSystemLibrary("dcomp", .{});
    b.installArtifact(exe);

    const test_step = b.step("test", "Test the Windows D3D packet presenter");
    if (target.result.os.tag == .windows) {
        const capture = b.addExecutable(.{
            .name = "weaver-window-capture",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/window_capture_main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        capture.root_module.addCSourceFile(.{
            .file = b.path("src/window_capture.cpp"),
            .flags = &.{"-std=c++17"},
        });
        capture.root_module.addIncludePath(b.path("../runtime/native-sdk/src/platform/windows"));
        capture.root_module.linkSystemLibrary("c++", .{});
        capture.root_module.linkSystemLibrary("c", .{});
        capture.root_module.linkSystemLibrary("d3d11", .{});
        capture.root_module.linkSystemLibrary("dxgi", .{});
        capture.root_module.linkSystemLibrary("dcomp", .{});
        capture.root_module.linkSystemLibrary("dwmapi", .{});
        capture.root_module.linkSystemLibrary("shell32", .{});
        capture.root_module.linkSystemLibrary("user32", .{});
        const capture_step = b.step("window-capture", "Build the composed-window capture helper");
        capture_step.dependOn(&b.addInstallArtifact(capture, .{}).step);

        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/d3d_presenter_test_runner.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        tests.root_module.addCSourceFile(.{
            .file = b.path("../runtime/native-sdk/src/platform/windows/d3d_presenter.cpp"),
            .flags = &.{ "-std=c++17", "-DWEAVER_D3D_PRESENTER_TESTS" },
        });
        tests.root_module.addIncludePath(b.path("../runtime/native-sdk/src/platform/windows"));
        tests.root_module.linkSystemLibrary("c++", .{});
        tests.root_module.linkSystemLibrary("c", .{});
        tests.root_module.linkSystemLibrary("kernel32", .{});
        tests.root_module.linkSystemLibrary("ole32", .{});
        tests.root_module.linkSystemLibrary("d3d11", .{});
        tests.root_module.linkSystemLibrary("dxgi", .{});
        tests.root_module.linkSystemLibrary("dcomp", .{});
        if (builtin.os.tag == .windows) {
            test_step.dependOn(&b.addRunArtifact(tests).step);
        } else {
            // Cross-host validation still compiles and links the exact Windows
            // test binary. A Windows host also runs it and compiles the HLSL.
            test_step.dependOn(&tests.step);
        }
    }
}
