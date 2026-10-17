const builtin = @import("builtin");
const supervisor = @import("supervisor.zig");
// weaverd runs only on macOS: on Windows the widget host is the daemon
// (ADR 0022, runtime/src/daemon.zig), and host/build.zig builds no weaverd.
const platform_host = switch (builtin.os.tag) {
    .macos => @import("macos_host.zig"),
    else => @compileError("weaverd runs only on macOS; on Windows the widget host is the daemon (runtime/src/daemon.zig)"),
};

pub fn main(init: @import("std").process.Init) void {
    platform_host.main(init);
}

// Referencing the platform host is not enough to reach the tests in the files
// it imports: unreferenced decls are never analyzed, so those imports are never
// evaluated and their tests are silently dropped from the binary. Every host
// source file with tests must be listed here by hand.
test {
    _ = supervisor;
    _ = platform_host;
    _ = @import("backoff.zig");
    _ = @import("registry.zig");
    _ = @import("host_contract.zig");
    // The providers run in weaverd on macOS. On Windows the widget host runs
    // them, and runtime/build.zig tests them there
    // (windows_provider_sources.zig).
    if (builtin.os.tag == .macos) {
        _ = @import("art_cache.zig");
        _ = @import("audio.zig");
        _ = @import("media.zig");
        _ = @import("media_commands.zig");
        _ = @import("provider_protocol.zig");
        _ = @import("providers_macos.zig");
    }
}
