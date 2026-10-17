const std = @import("std");
const small_fs = @import("small_fs.zig");
const platform = @import("platform/root.zig");

// Log receipt (2026-07-29): one runtime diagnostic is capped at 6,000 detail
// bytes and formats inside the 8 KiB line buffer below. 1 MiB retains at least
// 128 maximum-size diagnostics; current + rotated files cost at most 2 MiB on
// disk, while resident memory holds only the line being written.
const rotate_bytes: u64 = 1024 * 1024;
var mutex: std.atomic.Mutex = .unlocked;

/// One widget's log file. A host process keeps one per widget and points
/// `current` at the widget whose code is running, so every `std.log` line
/// lands in the log of the widget that wrote it.
pub const Sink = struct {
    io: ?std.Io = null,
    path: []u8 = &.{},
    old_path: []u8 = &.{},
    write_failed: std.atomic.Value(bool) = .init(false),
    fallback_reported: std.atomic.Value(bool) = .init(false),
};

/// The log `std.log` writes to. Lines logged before any widget is current
/// (or after the last one is gone) are dropped, as before `init`.
var current: ?*Sink = null;

/// Set on a thread that runs no widget's code (the host's provider
/// threads): `current` belongs to the UI thread, which may switch or free
/// it at any moment, so this thread's lines are dropped instead.
threadlocal var detached = false;

/// The calling thread runs no widget's code; see `detached`.
pub fn detachThread() void {
    detached = true;
}

pub fn init(sink: *Sink, runtime_io: std.Io, path: []const u8) !void {
    // Two short paths: the C heap packs them; `page_allocator` rounded each
    // to its own 4 KiB page.
    const allocator = std.heap.c_allocator;
    const next_path = try allocator.dupe(u8, path);
    errdefer allocator.free(next_path);
    const next_old_path = try std.fmt.allocPrint(allocator, "{s}.old", .{path});
    if (sink.path.len > 0) allocator.free(sink.path);
    if (sink.old_path.len > 0) allocator.free(sink.old_path);
    sink.path = next_path;
    sink.old_path = next_old_path;
    sink.io = runtime_io;
    sink.write_failed.store(false, .release);
    sink.fallback_reported.store(false, .release);
    small_fs.append(runtime_io, path, "") catch |err| noteFailure(sink, err);
}

/// Route `std.log` to `sink` until the next call.
pub fn use(sink: *Sink) void {
    current = sink;
}

/// Release a widget's sink when it unloads; logging goes nowhere until the
/// next `use` if it was current.
pub fn deinit(sink: *Sink) void {
    if (current == sink) current = null;
    if (sink.path.len > 0) std.heap.c_allocator.free(sink.path);
    if (sink.old_path.len > 0) std.heap.c_allocator.free(sink.old_path);
    sink.path = &.{};
    sink.old_path = &.{};
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    // Never inlined, so the 8 KiB line buffer lives only while a line is
    // written. Inlined, it sat in the frames of every function that logs,
    // the host's per-tick ones included (Native's frame and rebuild
    // handlers, `view`, `update`), and the Windows stack probe touches every
    // page of a frame on entry whether or not the log line runs. (Marking
    // `logFn` itself `noinline` did not stop the inlining in a ReleaseFast
    // build; this call does.)
    @call(.never_inline, writeLogLine, .{ level, scope, format, args });
}

fn writeLogLine(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    // reportError forwards at most 6,000 detail bytes; 8 KiB leaves >2 KiB
    // for timestamp/level/scope and formatting.
    if (detached) return;
    const sink = current orelse return;
    var buffer: [8192]u8 = undefined;
    const line = formatLogLine(level, scope, format, args, &buffer) catch |err| return noteFailure(sink, err);
    writeLine(sink, line);
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

/// Whether `sink`'s log is failing to write (its widget shows an error
/// surface instead of a silent blank).
pub fn failed(sink: *const Sink) bool {
    return sink.write_failed.load(.acquire);
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

fn writeLine(sink: *Sink, line: []const u8) void {
    writeLineFallible(sink, line) catch |err| return noteFailure(sink, err);
    if (sink.write_failed.swap(false, .acq_rel)) {
        sink.fallback_reported.store(false, .release);
        std.debug.print("weaver widget log recovered; path={s}\n", .{sink.path});
    }
}

fn writeLineFallible(sink: *Sink, line: []const u8) !void {
    const runtime_io = sink.io orelse return;
    if (sink.path.len == 0) return;
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
    defer mutex.unlock();

    // Every log line runs this on the UI thread: small_fs keeps it to small
    // stack frames.
    const path = sink.path;
    const old_path = sink.old_path;
    if (shouldRotate(small_fs.size(runtime_io, path) orelse 0, line.len)) {
        try small_fs.delete(runtime_io, old_path);
        try small_fs.rename(runtime_io, path, old_path);
    }
    try small_fs.append(runtime_io, path, line);
}

fn noteFailure(sink: *Sink, err: anyerror) void {
    sink.write_failed.store(true, .release);
    if (!sink.fallback_reported.swap(true, .acq_rel)) {
        std.debug.print(
            "weaver widget log unavailable: {s}; path={s}; the widget window will show an error surface\n",
            .{ @errorName(err), sink.path },
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
