//! A capture warning is a condition the PNG shows but cannot explain: the
//! render succeeded, yet something an author would call broken is visible,
//! and the receipt should say why. Under `weaver capture` each warning is
//! appended to `<WEAVER_CAPTURE_STATE_ROOT>/warnings.txt`; the CLI merges the
//! lines into the receipt's `warnings`. Ordinary widgets never call this.
const std = @import("std");

var io: ?std.Io = null;
var capture_path: []const u8 = &.{};

pub fn initCaptureSink(runtime_io: std.Io, path: []const u8) void {
    io = runtime_io;
    capture_path = path;
}

pub fn report(comptime format: []const u8, args: anytype) void {
    std.log.warn(format, args);
    const runtime_io = io orelse return;
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    writer.print(format ++ "\n", args) catch return;
    appendLine(runtime_io, capture_path, writer.buffered()) catch |err| {
        std.log.warn("capture warnings file unavailable: {s}; path={s}", .{ @errorName(err), capture_path });
    };
}

fn appendLine(runtime_io: std.Io, path: []const u8, line: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(runtime_io, path, .{ .read = true, .truncate = false });
    defer file.close(runtime_io);
    const stat = try file.stat(runtime_io);
    try file.writePositionalAll(runtime_io, line, stat.size);
}
