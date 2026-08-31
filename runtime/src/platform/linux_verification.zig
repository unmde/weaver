//! Minimal process, clock, and path services for the Linux null-backend test
//! lane. This module is not a Linux desktop host; runtime/build.zig refuses it
//! unless the Native SDK backend is explicitly `null`.

const std = @import("std");
const posix = std.posix;

pub fn currentProcessId() u32 {
    return @intCast(@max(0, posix.system.getpid()));
}

pub fn monotonicMilliseconds() u64 {
    return readClock(.MONOTONIC) / std.time.ns_per_ms;
}

pub fn wallClockMilliseconds() i64 {
    return @intCast(readClock(.REALTIME) / std.time.ns_per_ms);
}

fn readClock(clock: posix.clockid_t) u64 {
    var timestamp: posix.timespec = undefined;
    switch (posix.errno(posix.system.clock_gettime(clock, &timestamp))) {
        .SUCCESS => {
            const nanoseconds = @as(i128, timestamp.sec) * std.time.ns_per_s + timestamp.nsec;
            return @intCast(@max(0, nanoseconds));
        },
        else => return 0,
    }
}

pub fn dataRoot(allocator: std.mem.Allocator, _: ?[]const u8, home: ?[]const u8) ![]u8 {
    const root = home orelse return error.MissingHome;
    return std.fs.path.join(allocator, &.{ root, ".local", "share", "weaver" });
}

pub fn logsRoot(allocator: std.mem.Allocator, _: ?[]const u8, home: ?[]const u8) ![]u8 {
    const root = home orelse return error.MissingHome;
    return std.fs.path.join(allocator, &.{ root, ".local", "state", "weaver", "logs" });
}

pub fn providerEndpoint(legacy_endpoint: ?[]const u8, generic_endpoint: ?[]const u8) ?[]const u8 {
    return generic_endpoint orelse legacy_endpoint;
}
