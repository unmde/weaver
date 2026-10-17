const std = @import("std");
const native_sdk = @import("native_sdk");

pub fn build(b: *std.Build) void {
    const automation_seam = b.option(bool, "automation-seam", "Compile deterministic runtime failure injection (automation builds only)") orelse false;
    // One process hosts every widget (`weaver-widget --host`), each in its
    // own Native window: the window capacity is src/main.zig's
    // max_host_widgets, which a comptime check there pins.
    const artifacts = native_sdk.addAppArtifacts(b, b.dependency("native_sdk", .{
        .@"widget-profile" = true,
        .@"widget-windows" = @as(usize, 32),
    }), .{
        .name = "weaver-widget",
        .widget_profile = true,
        .widget_windows = 32,
        // One runtime event per 30 Hz Canvas completion otherwise opens,
        // stats, appends, and closes native-sdk.jsonl on every frame. Widget
        // diagnostics live in the dedicated per-widget log; explicit
        // profiling builds can still opt back in with -Dtrace=events|all.
        .trace_default = .off,
    });
    // QuickJS measured 70 trivial recursive calls with its 4 MiB guard,
    // clearing the 32-level widget-tree contract by >2x. Reserve a 16 MiB
    // process stack so native dispatch retains 3x the JS guard; OS stack pages
    // commit only as used. Pinned to js_engine.max_stack_bytes.
    artifacts.exe.stack_size = 16 * 1024 * 1024;
    artifacts.tests.stack_size = 16 * 1024 * 1024;
    const weaver_options = b.addOptions();
    weaver_options.addOption(bool, "automation_seam", automation_seam);
    // The executable target and the selected Native SDK backend are separate
    // facts: a macOS-targeted `-Dplatform=null` build must not retain the
    // AppKit render-host symbol. Keep the gate structural so dead-code
    // elimination is not responsible for making the null build link.
    weaver_options.addOption(bool, "render_host_enabled", artifacts.backend == .macos);
    artifacts.exe.root_module.addOptions("weaver_build_options", weaver_options);
    if (artifacts.tests.root_module != artifacts.exe.root_module) {
        artifacts.tests.root_module.addOptions("weaver_build_options", weaver_options);
    }
    const target = artifacts.exe.root_module.resolved_target.?;
    const os_tag = target.result.os.tag;
    // Linux is a verification host only. Requiring the Native SDK's null
    // backend keeps this lane honest: it can execute the complete retained
    // tree/gradient suite without quietly presenting Linux as a shipped
    // Weaver runtime or pulling GTK into the portable contract.
    const portable_verification_host = os_tag == .linux and artifacts.backend == .null;
    if (os_tag != .windows and os_tag != .macos and !portable_verification_host) {
        @panic("weaver-widget ships only on Windows and macOS; use -Dplatform=null for portable Linux verification");
    }
    // The daemon host has no console window (ADR 0022 step 5): Windows
    // restarts a crashed console program in a new, visible console. Every
    // mode of the runtime shares this executable; a parent that wants its
    // output (capture, the CLI's client verbs) passes it handles.
    if (os_tag == .windows) artifacts.exe.subsystem = .Windows;
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
        .linux => &.{
            "-std=c11",
            "-funsigned-char",
            "-D_GNU_SOURCE",
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
    // Cross-target reviewers can compile the complete test artifact without
    // trying to execute a foreign binary. Native Linux CI uses the ordinary
    // `test` step; this step is the local proof that the same graph builds.
    if (os_tag == .windows) {
        // The providers' own tests (audio analysis, media frames, the art
        // cache, command parsing): weaverd's tests ran them until it
        // stopped running the providers.
        const provider_tests = b.addTest(.{ .root_module = hostProvidersModule(b, target, artifacts.tests.root_module.optimize) });
        b.top_level_steps.get("test").?.step.dependOn(&b.addRunArtifact(provider_tests).step);
    }
    const test_compile_step = b.step("test-compile", "Compile tests without running them");
    test_compile_step.dependOn(&artifacts.tests.step);

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
    const target = compile.root_module.resolved_target.?;
    const optimize = compile.root_module.optimize;
    // What the Windows widget host and the CLI's client verbs agree on: the
    // control objects' names, the lifecycle lock, the host's exit codes and
    // its record's layout.
    compile.root_module.addImport("host_contract", b.createModule(.{
        .root_source_file = b.path("../host/src/host_contract.zig"),
        .target = target,
        .optimize = optimize,
    }));
    switch (os_tag) {
        .windows => {
            addWindowsMonitor(b, compile);
            compile.root_module.addImport("host_providers", hostProvidersModule(b, target, optimize));
            // The daemon host's registry slots, backoff and status format
            // (runtime/src/daemon.zig): the same files macOS weaverd
            // compiles, so the two platforms keep one state machine.
            compile.root_module.addImport("host_supervisor", b.createModule(.{
                .root_source_file = b.path("../host/src/supervisor.zig"),
                .target = target,
                .optimize = optimize,
            }));
            // Process memory counters for the daemon's status rows.
            compile.root_module.linkSystemLibrary("psapi", .{});
            // No winhttp: network.zig loads WINHTTP.dll on the first fetch
            // (lazy_dll.zig), so a host whose widgets never fetch never
            // maps it.
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
        // The only admitted Linux configuration is the null-backend
        // verification lane above. QuickJS still links libc in addQuickJs;
        // there is deliberately no window-system or web-layer linkage.
        .linux => {},
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

/// The providers the anchored host runs on its own threads (ADR 0022 step
/// 3): system sampling, WASAPI audio, SMTC media and its art cache. Their
/// sources stay in host/src while macOS weaverd still compiles the shared
/// ones from there (host/src/windows_provider_sources.zig).
fn hostProvidersModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: ?std.builtin.OptimizeMode) *std.Build.Module {
    const windows_sdk = std.zig.WindowsSdk.find(b.allocator, b.graph.io, target.result.cpu.arch, &b.graph.environ_map) catch @panic("the Windows 10 SDK is required to build the host's providers (C++/WinRT)");
    defer windows_sdk.free(b.allocator);
    const windows_10 = windows_sdk.windows10sdk orelse @panic("the Windows 10 SDK is required to build the host's providers (C++/WinRT)");
    const windows_arch: []const u8 = switch (target.result.cpu.arch) {
        .x86_64 => "x64",
        .x86 => "x86",
        .aarch64 => "arm64",
        else => @panic("unsupported Windows architecture for the host's providers"),
    };
    const module = b.createModule(.{
        .root_source_file = b.path("../host/src/windows_provider_sources.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addCSourceFile(.{
        .file = b.path("../host/src/windows_providers.cpp"),
        .flags = &.{ "-std=c++20", "-fexceptions", "-frtti" },
    });
    module.addIncludePath(b.path("../host/src"));
    module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ windows_10.path, "Include", windows_10.version, "cppwinrt" }) });
    module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ windows_10.path, "Lib", windows_10.version, "um", windows_arch }) });
    for ([_][]const u8{ "c++", "ntdll", "ole32", "windowscodecs", "windowsapp" }) |library| {
        module.linkSystemLibrary(library, .{});
    }
    return module;
}

fn addQuickJs(b: *std.Build, compile: *std.Build.Step.Compile, sources: []const []const u8, c_flags: []const []const u8) void {
    compile.root_module.addIncludePath(b.path("vendor/quickjs-ng"));
    compile.root_module.addCSourceFiles(.{ .files = sources, .flags = c_flags });
    compile.root_module.linkSystemLibrary("c", .{});
}
