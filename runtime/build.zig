const std = @import("std");
const native_sdk = @import("native_sdk");

pub fn build(b: *std.Build) void {
    const automation_seam = b.option(bool, "automation-seam", "Compile deterministic runtime failure injection (automation builds only)") orelse false;
    const artifacts = native_sdk.addAppArtifacts(b, b.dependency("native_sdk", .{
        .@"widget-profile" = true,
    }), .{
        .name = "weaver-widget",
        .widget_profile = true,
    });
    // QuickJS measured 70 trivial recursive calls with its 4 MiB guard,
    // clearing the 32-level widget-tree contract by >2x. Reserve a 16 MiB
    // process stack so native dispatch retains 3x the JS guard; OS stack pages
    // commit only as used. Pinned to js_engine.max_stack_bytes.
    artifacts.exe.stack_size = 16 * 1024 * 1024;
    artifacts.tests.stack_size = 16 * 1024 * 1024;
    const weaver_options = b.addOptions();
    weaver_options.addOption(bool, "automation_seam", automation_seam);
    artifacts.exe.root_module.addOptions("weaver_build_options", weaver_options);
    if (artifacts.tests.root_module != artifacts.exe.root_module) {
        artifacts.tests.root_module.addOptions("weaver_build_options", weaver_options);
    }
    const target = artifacts.exe.root_module.resolved_target.?;
    const os_tag = target.result.os.tag;
    if (os_tag != .windows and os_tag != .macos) {
        @panic("weaver-widget currently supports only Windows and macOS targets");
    }
    const c_flags: []const []const u8 = switch (os_tag) {
        .windows => &.{
            "-std=c11",
            "-funsigned-char",
            "-D_GNU_SOURCE",
            "-DWIN32_LEAN_AND_MEAN",
            "-D_WIN32_WINNT=0x0601",
            "-D_CRT_SECURE_NO_WARNINGS",
        },
        .macos => &.{
            "-std=c11",
            "-funsigned-char",
        },
        else => unreachable,
    };
    const sources = &.{
        "vendor/quickjs-ng/dtoa.c",
        "vendor/quickjs-ng/libregexp.c",
        "vendor/quickjs-ng/libunicode.c",
        "vendor/quickjs-ng/quickjs.c",
    };
    addQuickJs(b, artifacts.exe, sources, c_flags);
    addPlatformLinkage(b, artifacts.exe, os_tag, false);
    if (artifacts.tests.root_module != artifacts.exe.root_module) {
        addQuickJs(b, artifacts.tests, sources, c_flags);
        addPlatformLinkage(b, artifacts.tests, os_tag, true);
    }

    const platform_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/platform/root.zig"),
            .target = target,
            .optimize = artifacts.tests.root_module.optimize,
        }),
    });
    const platform_test_step = b.step("test-platform-services", "Run portable platform-service seam tests");
    platform_test_step.dependOn(&b.addRunArtifact(platform_tests).step);
}

fn addPlatformLinkage(b: *std.Build, compile: *std.Build.Step.Compile, os_tag: std.Target.Os.Tag, is_test: bool) void {
    switch (os_tag) {
        .windows => {
            addWindowsMonitor(b, compile);
            compile.root_module.linkSystemLibrary("winhttp", .{});
            // windows_monitor.cpp: virtual-screen metrics (user32) and
            // the DPI fallback (gdi32). The exe gets both transitively
            // through the Native SDK host; the test binary links the
            // monitor shim without the host.
            compile.root_module.linkSystemLibrary("user32", .{});
            compile.root_module.linkSystemLibrary("gdi32", .{});
        },
        .macos => {
            const sdk_include = if (b.sysroot) |sysroot| b.fmt("-I{s}/usr/include", .{sysroot}) else "";
            const flags: []const []const u8 = if (b.sysroot) |sysroot|
                if (is_test)
                    &.{ "-fobjc-arc", "-DWEAVER_NETWORK_TESTING=1", "-mmacosx-version-min=11.0", "-isysroot", sysroot, sdk_include }
                else
                    &.{ "-fobjc-arc", "-mmacosx-version-min=11.0", "-isysroot", sysroot, sdk_include }
            else if (is_test)
                &.{ "-fobjc-arc", "-DWEAVER_NETWORK_TESTING=1", "-mmacosx-version-min=11.0" }
            else
                &.{ "-fobjc-arc", "-mmacosx-version-min=11.0" };
            compile.root_module.addCSourceFile(.{
                .file = b.path("src/network_macos.m"),
                .flags = flags,
            });
            if (b.sysroot) |sysroot| {
                compile.root_module.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" }) });
            }
            compile.root_module.linkFramework("Foundation", .{});
            compile.root_module.linkFramework("Security", .{});
        },
        else => unreachable,
    }
}

fn addWindowsMonitor(b: *std.Build, compile: *std.Build.Step.Compile) void {
    compile.root_module.addCSourceFile(.{
        .file = b.path("src/windows_monitor.cpp"),
        .flags = &.{"-std=c++17"},
    });
    compile.root_module.addIncludePath(b.path("src"));
}

fn addQuickJs(b: *std.Build, compile: *std.Build.Step.Compile, sources: []const []const u8, c_flags: []const []const u8) void {
    compile.root_module.addIncludePath(b.path("vendor/quickjs-ng"));
    compile.root_module.addCSourceFiles(.{ .files = sources, .flags = c_flags });
    compile.root_module.linkSystemLibrary("c", .{});
}
