const std = @import("std");
const platform = @import("platform/root.zig");

// Log receipt (2026-07-29): one runtime diagnostic is capped at 6,000 detail
// bytes and formats inside the 8 KiB line buffer below. 1 MiB retains at least
// 128 maximum-size diagnostics; current + rotated files cost at most 2 MiB on
// disk, while resident memory holds only the line being written.
const rotate_bytes: u64 = 1024 * 1024;
var io: ?std.Io = null;
var log_path: []u8 = &.{};
var old_log_path: []u8 = &.{};
var mutex: std.atomic.Mutex = .unlocked;
var write_failed = std.atomic.Value(bool).init(false);
var fallback_reported = std.atomic.Value(bool).init(false);

pub fn init(runtime_io: std.Io, path: []const u8) !void {
    const allocator = std.heap.page_allocator;
    const next_path = try allocator.dupe(u8, path);
    errdefer allocator.free(next_path);
    const next_old_path = try std.fmt.allocPrint(allocator, "{s}.old", .{path});
    if (log_path.len > 0) allocator.free(log_path);
    if (old_log_path.len > 0) allocator.free(old_log_path);
    log_path = next_path;
    old_log_path = next_old_path;
    io = runtime_io;
    write_failed.store(false, .release);
    fallback_reported.store(false, .release);
    var file = std.Io.Dir.cwd().createFile(runtime_io, path, .{ .read = true, .truncate = false }) catch |err| {
        noteFailure(err);
        return;
    };
    file.close(runtime_io);
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    // reportError forwards at most 6,000 detail bytes; 8 KiB leaves >2 KiB
    // for timestamp/level/scope and formatting. The stack cost exists only
    // during one log call.
    var buffer: [8192]u8 = undefined;
    const line = formatLogLine(level, scope, format, args, &buffer) catch |err| return noteFailure(err);
    writeLine(line);
}

fn formatLogLine(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
    buffer: []u8,
) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writeTimestamp(&writer);
    try writer.print(" {s}", .{level.asText()});
    if (scope != .default) try writer.print("({t})", .{scope});
    try writer.writeAll(": ");

    const prefix_len = writer.buffered().len;
    const suffix = "...\n";
    if (buffer.len -| prefix_len < suffix.len) return error.LogLineBufferTooSmall;
    const message_capacity = buffer.len - prefix_len - suffix.len;
    var message_writer = std.Io.Writer.fixed(buffer[prefix_len .. prefix_len + message_capacity]);
    var truncated = false;
    message_writer.print(format, args) catch {
        truncated = true;
    };
    var message_len = message_writer.buffered().len;
    if (truncated) {
        while (message_len > 0 and !std.unicode.utf8ValidateSlice(buffer[prefix_len .. prefix_len + message_len])) {
            message_len -= 1;
        }
        @memcpy(buffer[prefix_len + message_len .. prefix_len + message_len + suffix.len], suffix);
        return buffer[0 .. prefix_len + message_len + suffix.len];
    }
    buffer[prefix_len + message_len] = '\n';
    return buffer[0 .. prefix_len + message_len + 1];
}

pub fn failed() bool {
    return write_failed.load(.acquire);
}

fn writeTimestamp(writer: *std.Io.Writer) !void {
    const milliseconds: u64 = @intCast(@max(0, platform.wallClockMilliseconds()));
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = milliseconds / std.time.ms_per_s };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    try writer.print("[{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z]", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
        milliseconds % std.time.ms_per_s,
    });
}

fn writeLine(line: []const u8) void {
    writeLineFallible(line) catch |err| return noteFailure(err);
    if (write_failed.swap(false, .acq_rel)) {
        fallback_reported.store(false, .release);
        std.debug.print("weaver widget log recovered; path={s}\n", .{log_path});
    }
}

fn writeLineFallible(line: []const u8) !void {
    const runtime_io = io orelse return;
    if (log_path.len == 0) return;
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
    defer mutex.unlock();

    var cwd = std.Io.Dir.cwd();
    const path = log_path;
    const old_path = old_log_path;
    const size = if (cwd.statFile(runtime_io, path, .{})) |stat| stat.size else |_| 0;
    if (shouldRotate(size, line.len)) {
        cwd.deleteFile(runtime_io, old_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        try cwd.rename(path, cwd, old_path, runtime_io);
    }
    var file = try cwd.createFile(runtime_io, path, .{ .read = true, .truncate = false });
    defer file.close(runtime_io);
    const stat = try file.stat(runtime_io);
    try file.writePositionalAll(runtime_io, line, stat.size);
}

fn noteFailure(err: anyerror) void {
    write_failed.store(true, .release);
    if (!fallback_reported.swap(true, .acq_rel)) {
        std.debug.print(
            "weaver widget log unavailable: {s}; path={s}; the widget window will show an error surface\n",
            .{ @errorName(err), log_path },
        );
    }
}

fn shouldRotate(size: u64, incoming: usize) bool {
    return size > 0 and size + incoming > rotate_bytes;
}

test "rotation threshold is one MiB and never rotates an empty file" {
    try std.testing.expectEqual(@as(u64, 1_048_576), rotate_bytes);
    try std.testing.expect(!shouldRotate(0, rotate_bytes + 1));
    try std.testing.expect(!shouldRotate(rotate_bytes - 1, 1));
    try std.testing.expect(shouldRotate(rotate_bytes, 1));
}

test "oversized log messages are truncated without becoming log failures" {
    var buffer: [128]u8 = undefined;
    const message = "💥" ** 64;
    const line = try formatLogLine(.err, .default, "{s}", .{message}, &buffer);
    try std.testing.expect(std.mem.endsWith(u8, line, "...\n"));
    try std.testing.expect(std.unicode.utf8ValidateSlice(line));
}
