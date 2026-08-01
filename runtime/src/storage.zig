const std = @import("std");

// Storage receipt (2026-07-29): no shipped example persists user data yet, so
// the previous 64 KiB had no real ruler. Serializing a realistic good notes
// fixture (100 records with 900-byte bodies and metadata) measured 103,291
// bytes; 256 KiB leaves 2.5x headroom.
// Reads/serialization allocate exact document length, so unused allowance
// costs no memory. Pinned by sdk/src/reconciler.ts STORAGE_QUOTA_BYTES.
pub const quota_bytes: usize = 256 * 1024;

pub const Error = error{
    StorageQuotaExceeded,
};

/// One widget owns one JSON document. The filename is a stable hash of the
/// declared widget name, so source-directory moves and `weaver dev` restarts
/// preserve state without making user-authored names filesystem syntax.
pub const Store = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    directory: []const u8,
    path: []const u8,
    temporary_path: []const u8,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, data_root: []const u8, widget_name: []const u8) !Store {
        const directory = try std.fs.path.join(allocator, &.{ data_root, "storage" });
        const hash = nameHash(widget_name);
        const filename = try std.fmt.allocPrint(allocator, "{x:0>16}.json", .{hash});
        const path = try std.fs.path.join(allocator, &.{ directory, filename });
        const temporary_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
        return .{ .io = io, .allocator = allocator, .directory = directory, .path = path, .temporary_path = temporary_path };
    }

    pub fn read(self: *const Store) !?[]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(self.io, self.path, self.allocator, .limited(quota_bytes)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
    }

    /// Write beside the destination, then rename over it. Readers either see
    /// the old complete JSON document or the new one, never a debounce-time
    /// prefix produced by a killed widget.
    pub fn write(self: *const Store, bytes: []const u8) !void {
        try validatePayload(bytes);
        var cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(self.io, self.directory);
        try cwd.writeFile(self.io, .{ .sub_path = self.temporary_path, .data = bytes });
        try cwd.rename(self.temporary_path, cwd, self.path, self.io);
    }
};

pub fn nameHash(widget_name: []const u8) u64 {
    return std.hash.Wyhash.hash(0x776561766572, widget_name);
}

pub fn validatePayload(bytes: []const u8) Error!void {
    if (bytes.len > quota_bytes) return error.StorageQuotaExceeded;
}

test "storage quota is an exact 256 KiB boundary" {
    try validatePayload(&([_]u8{0} ** quota_bytes));
    try std.testing.expectError(error.StorageQuotaExceeded, validatePayload(&([_]u8{0} ** (quota_bytes + 1))));
    try std.testing.expectEqual(nameHash("Pomodoro"), nameHash("Pomodoro"));
    try std.testing.expect(nameHash("Pomodoro") != nameHash("pomodoro"));
}
