const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = hostTarget(b);
    const optimize = b.standardOptimizeOption(.{});
    const automation_seam = b.option(bool, "automation-seam", "Compile the deterministic audio test-injection seam (automation builds only)") orelse false;
    const supervisor_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/supervisor.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const supervisor_test_step = b.step("test-supervisor", "Run platform-neutral supervisor tests");
    supervisor_test_step.dependOn(&b.addRunArtifact(supervisor_tests).step);
    if (target.result.os.tag == .macos) {
        const exe = b.addExecutable(.{
            .name = "weaverd",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        addMacosAudio(exe.root_module, b, automation_seam);
        const adapter_build_dir = b.pathFromRoot(".zig-cache/mediaremote-adapter");
        const adapter_source_dir = b.pathFromRoot("assets/mediaremote-adapter");
        const adapter_configure = b.addSystemCommand(&.{
            "cmake",
            "-S",
            adapter_source_dir,
            "-B",
            adapter_build_dir,
            "-DCMAKE_BUILD_TYPE=Release",
            "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.2",
        });
        const adapter_build = b.addSystemCommand(&.{
            "cmake",
            "--build",
            adapter_build_dir,
            "--target",
            "MediaRemoteAdapter",
            "MediaRemoteAdapterSeekTests",
            "--config",
            "Release",
        });
        adapter_build.step.dependOn(&adapter_configure.step);
        exe.root_module.linkSystemLibrary("c", .{});
        b.installArtifact(exe);
        const bundle_executable = b.addInstallFile(exe.getEmittedBin(), "Weaverd.app/Contents/MacOS/weaverd");
        const bundle_plist = b.addInstallFile(b.path("macos/Info.plist"), "Weaverd.app/Contents/Info.plist");
        const adapter_framework_source = b.pathJoin(&.{ adapter_build_dir, "MediaRemoteAdapter.framework" });
        const share_framework = b.addSystemCommand(&.{
            "/usr/bin/ditto",
            adapter_framework_source,
            b.getInstallPath(.prefix, "share/weaver/mediaremote-adapter/MediaRemoteAdapter.framework"),
        });
        share_framework.step.dependOn(&adapter_build.step);
        const app_framework = b.addSystemCommand(&.{
            "/usr/bin/ditto",
            adapter_framework_source,
            b.getInstallPath(.prefix, "Weaverd.app/Contents/Resources/mediaremote-adapter/MediaRemoteAdapter.framework"),
        });
        app_framework.step.dependOn(&adapter_build.step);
        const share_script = b.addInstallFile(
            b.path("assets/mediaremote-adapter/bin/mediaremote-adapter.pl"),
            "share/weaver/mediaremote-adapter/mediaremote-adapter.pl",
        );
        const app_script = b.addInstallFile(
            b.path("assets/mediaremote-adapter/bin/mediaremote-adapter.pl"),
            "Weaverd.app/Contents/Resources/mediaremote-adapter/mediaremote-adapter.pl",
        );
        const share_license = b.addInstallFile(
            b.path("assets/mediaremote-adapter/LICENSE"),
            "share/weaver/mediaremote-adapter/LICENSE",
        );
        const app_license = b.addInstallFile(
            b.path("assets/mediaremote-adapter/LICENSE"),
            "Weaverd.app/Contents/Resources/mediaremote-adapter/LICENSE",
        );
        share_framework.step.dependOn(&share_script.step);
        app_framework.step.dependOn(&app_script.step);
        b.getInstallStep().dependOn(&share_framework.step);
        b.getInstallStep().dependOn(&app_framework.step);
        b.getInstallStep().dependOn(&share_script.step);
        b.getInstallStep().dependOn(&app_script.step);
        b.getInstallStep().dependOn(&share_license.step);
        b.getInstallStep().dependOn(&app_license.step);
        const bundle_path = b.getInstallPath(.prefix, "Weaverd.app");
        const sign_bundle = b.addSystemCommand(&.{
            "codesign",                     "--force",   "--deep", "--sign", "-", "--identifier",
            "com.sunkenintime.weaver.host", bundle_path,
        });
        sign_bundle.step.dependOn(&bundle_executable.step);
        sign_bundle.step.dependOn(&bundle_plist.step);
        sign_bundle.step.dependOn(&app_framework.step);
        sign_bundle.step.dependOn(&app_script.step);
        sign_bundle.step.dependOn(&app_license.step);
        b.getInstallStep().dependOn(&sign_bundle.step);
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        addMacosAudio(tests.root_module, b, automation_seam);
        tests.root_module.addCSourceFile(.{
            .file = b.path("src/macos_renderer_test.c"),
            .flags = &.{ "-std=c11", "-mmacosx-version-min=14.2", "-isysroot", b.sysroot.?, b.fmt("-I{s}/usr/include", .{b.sysroot.?}) },
        });
        tests.root_module.linkSystemLibrary("c", .{});
        const test_step = b.step("test", "Run macOS host and portable supervisor tests");
        test_step.dependOn(&b.addRunArtifact(tests).step);
        test_step.dependOn(&adapter_build.step);
        return;
    }
    if (target.result.os.tag != .windows) @panic("weaverd supports only Windows and macOS");
    // Windows has no weaverd (ADR 0022): the widget host is the daemon and
    // asks Windows to restart it (runtime/src/daemon.zig), and the CLI's
    // client verbs live in the runtime too (runtime/src/host_lifecycle.zig).
    // What stays here on Windows is what the runtime compiles from this
    // package: the registry slots, backoff and status format, and the host
    // contract, tested on their own.
    const contract_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/host_contract.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_step = b.step("test", "Run the supervisor and host contract tests the Windows runtime compiles");
    test_step.dependOn(&b.addRunArtifact(supervisor_tests).step);
    test_step.dependOn(&b.addRunArtifact(contract_tests).step);
}

fn hostTarget(b: *std.Build) std.Build.ResolvedTarget {
    const target = b.standardTargetOptions(.{});
    if (target.result.os.tag != .macos) return target;
    if (b.sysroot == null) b.sysroot = macosSdkRoot(b);
    var query = target.query;
    query.os_tag = .macos;
    query.os_version_min = .{ .semver = .{ .major = 14, .minor = 2, .patch = 0 } };
    return b.resolveTargetQuery(query);
}

fn macosSdkRoot(b: *std.Build) []const u8 {
    if (b.graph.environ_map.get("SDKROOT")) |root| if (root.len > 0) return root;
    const result = std.process.run(b.allocator, b.graph.io, .{
        .argv = &.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" },
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    }) catch @panic("xcrun is required to locate the macOS SDK");
    b.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) @panic("xcrun could not locate the macOS SDK"),
        else => @panic("xcrun could not locate the macOS SDK"),
    }
    return std.mem.trim(u8, result.stdout, " \t\r\n");
}

fn addMacosAudio(module: *std.Build.Module, b: *std.Build, automation_seam: bool) void {
    const sdk_include = b.fmt("-I{s}/usr/include", .{b.sysroot.?});
    const audio_flags: []const []const u8 = if (automation_seam)
        &.{ "-fobjc-arc", "-fblocks", "-mmacosx-version-min=14.2", "-isysroot", b.sysroot.?, sdk_include, "-DWEAVER_AUTOMATION_SEAM=1" }
    else
        &.{ "-fobjc-arc", "-fblocks", "-mmacosx-version-min=14.2", "-isysroot", b.sysroot.?, sdk_include };
    module.addCSourceFile(.{
        .file = b.path("src/macos_audio.m"),
        .flags = audio_flags,
    });
    module.addCSourceFile(.{
        .file = b.path("src/macos_media.m"),
        .flags = audio_flags,
    });
    module.addCSourceFile(.{
        .file = b.path("src/macos_system.c"),
        .flags = &.{ "-std=c11", "-mmacosx-version-min=14.2", "-isysroot", b.sysroot.?, sdk_include },
    });
    module.addIncludePath(b.path("src"));
    module.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ b.sysroot.?, "System", "Library", "Frameworks" }) });
    module.linkFramework("CoreAudio", .{});
    module.linkFramework("CoreGraphics", .{});
    module.linkFramework("Foundation", .{});
    module.linkFramework("ImageIO", .{});
}
