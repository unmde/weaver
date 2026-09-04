//! A widget diagnostic is a failure the widget author must fix: a render or
//! callback that threw, an unhandled promise rejection, or a script exception.
//! Every one is an error line in the per-widget log. Under `weaver capture`
//! that log lives in the temporary state root and dies with it, so the same
//! text is also appended to `<WEAVER_CAPTURE_STATE_ROOT>/diagnostic.txt`; the
//! CLI copies that file into the receipt's `error.diagnostic` and prints it,
//! so an agent holding only the capture output sees the message and stack.
const std = @import("std");

var io: ?std.Io = null;
var capture_path: []const u8 = &.{};

/// Capture-only. Ordinary widgets never call this, so a report costs them
/// exactly the log line it always cost.
pub fn initCaptureSink(runtime_io: std.Io, path: []const u8) void {
    io = runtime_io;
    capture_path = path;
}

pub fn report(comptime format: []const u8, args: anytype) void {
    std.log.err(format, args);
    const runtime_io = io orelse return;
    // Same 8 KiB bound as widget_log's line buffer: every caller slices its
    // detail to at most 6,000 bytes, so a diagnostic always fits. The stack
    // cost exists only during the report.
    var buffer: [8192]u8 = undefined;
    appendLine(runtime_io, capture_path, formatLine(&buffer, format, args)) catch |err| {
        std.log.warn("capture diagnostic file unavailable: {s}; path={s}", .{ @errorName(err), capture_path });
    };
}

fn formatLine(buffer: []u8, comptime format: []const u8, args: anytype) []const u8 {
    const suffix = "...\n";
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - suffix.len]);
    writer.print(format ++ "\n", args) catch {
        var length = writer.buffered().len;
        while (length > 0 and !std.unicode.utf8ValidateSlice(buffer[0..length])) length -= 1;
        @memcpy(buffer[length .. length + suffix.len], suffix);
        return buffer[0 .. length + suffix.len];
    };
    return writer.buffered();
}

fn appendLine(runtime_io: std.Io, path: []const u8, line: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(runtime_io, path, .{ .read = true, .truncate = false });
    defer file.close(runtime_io);
    const stat = try file.stat(runtime_io);
    try file.writePositionalAll(runtime_io, line, stat.size);
}

test "a diagnostic line keeps the heading, detail, and stack verbatim" {
    var buffer: [256]u8 = undefined;
    const line = formatLine(&buffer, "widget {s} failed:\n{s}", .{ "render", "Error: boom\n    at render (bundle.js:3:9)" });
    try std.testing.expectEqualStrings("widget render failed:\nError: boom\n    at render (bundle.js:3:9)\n", line);
}

test "an oversized diagnostic is truncated on a UTF-8 boundary instead of dropped" {
    var buffer: [64]u8 = undefined;
    const line = formatLine(&buffer, "{s}", .{"💥" ** 32});
    try std.testing.expect(std.mem.endsWith(u8, line, "...\n"));
    try std.testing.expect(std.unicode.utf8ValidateSlice(line));
    try std.testing.expect(line.len <= buffer.len);
}
