const builtin = @import("builtin");
const media_protocol = @import("media_protocol.zig");
const provider_protocol = @import("provider_protocol.zig");

const implementation = switch (builtin.os.tag) {
    .windows => @import("provider_windows.zig"),
    .macos => @import("provider_macos.zig"),
    else => @compileError("Weaver providers support only Windows and macOS"),
};

pub const Client = implementation.Client;
pub const Ack = provider_protocol.Ack;
// Framing alias only: the 12,502-byte derived protocol receipt lives in
// media_protocol.zig, so the client cannot drift to a second line budget.
pub const max_line_bytes = media_protocol.max_media_frame_bytes;
// Command framing alias only; the measured 86-byte/256-byte receipt lives in
// provider_protocol.zig.
pub const max_command_line_bytes = provider_protocol.command_line_capacity;

test "provider client is inert only without an endpoint" {
    const std = @import("std");
    var client: Client = .{};
    try client.init(std.testing.io, null);
    defer client.deinit();
    try std.testing.expect(!client.isAvailable());
}

test {
    _ = provider_protocol;
}
