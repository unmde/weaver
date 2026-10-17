//! The provider sources the Windows widget host compiles (ADR 0022 step 3):
//! runtime/build.zig builds this file as its `host_providers` module, with
//! windows_providers.cpp. They stay in host/src while macOS weaverd still
//! compiles audio, media_commands, art_cache and provider_protocol from here;
//! on Windows, weaverd no longer runs any of them.
pub const art_cache = @import("art_cache.zig");
pub const audio = @import("audio.zig");
pub const media = @import("media.zig");
pub const media_commands = @import("media_commands.zig");
pub const provider_protocol = @import("provider_protocol.zig");
pub const providers = @import("providers.zig");

test {
    _ = art_cache;
    _ = audio;
    _ = media;
    _ = media_commands;
    _ = provider_protocol;
    _ = providers;
}
