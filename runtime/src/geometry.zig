const std = @import("std");
const storage = @import("storage.zig");

/// A user-dragged window origin. This is user state, not widget source:
/// the manifest anchor stays the authoritative placement until the first
/// real drag writes a record here, and deleting the record restores the
/// anchor. Coordinates are the platform's logical (DIP) top-level window
/// space — exactly what the Native SDK's `window_frame_changed` reports
/// and what window creation consumes — plus the scale the window had
/// when it was dragged, so launch-time validation can reason in physical
/// pixels.
pub const Saved = struct {
    x: f32,
    y: f32,
    scale: f32,
};

// Geometry receipt (2026-07-29): the complete encoded record is bounded by
// the 128-byte formatter below (the round-trip fixture is 33 bytes). A 512-byte
// read cap leaves 4x format/whitespace headroom. Reads allocate actual length,
// so unused allowance costs no memory.
const max_file_bytes: usize = 512;

/// One widget owns one small JSON record beside (not inside) its
/// `useStorage` document: placement is user state the widget's own code
/// must not be able to read or clobber through the storage quota.
pub const Store = struct {
    io: std.Io,
    directory: []const u8,
    path: []const u8,
    temporary_path: []const u8,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, data_root: []const u8, widget_name: []const u8) !Store {
        const directory = try std.fs.path.join(allocator, &.{ data_root, "geometry" });
        const filename = try std.fmt.allocPrint(allocator, "{x:0>16}.json", .{storage.nameHash(widget_name)});
        const path = try std.fs.path.join(allocator, &.{ directory, filename });
        const temporary_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
        return .{ .io = io, .directory = directory, .path = path, .temporary_path = temporary_path };
    }

    pub fn load(self: *const Store, allocator: std.mem.Allocator) !?Saved {
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, self.path, allocator, .limited(max_file_bytes)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer allocator.free(bytes);
        return parse(bytes) orelse error.InvalidGeometryRecord;
    }

    /// Write beside the destination, then rename over it — a killed
    /// widget process never leaves a truncated record behind.
    pub fn save(self: *const Store, value: Saved) !void {
        // Three finite f32 values plus JSON punctuation fit in <128 bytes by
        // construction; the measured round-trip record is 33. Undefined stack
        // storage costs 128 bytes only while saving.
        var buffer: [128]u8 = undefined;
        const bytes = try format(&buffer, value);
        var cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(self.io, self.directory);
        try cwd.writeFile(self.io, .{ .sub_path = self.temporary_path, .data = bytes });
        try cwd.rename(self.temporary_path, cwd, self.path, self.io);
    }
};

pub fn format(buffer: []u8, value: Saved) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writer.print("{{\"x\":{d},\"y\":{d},\"scale\":{d}}}", .{ value.x, value.y, value.scale });
    return writer.buffered();
}

pub fn parse(bytes: []const u8) ?Saved {
    const Record = struct { x: f64, y: f64, scale: f64 };
    // The parser arena is 2x max_file_bytes, leaving one input-sized copy of
    // headroom for this flat three-number object. It costs 1 KiB on load only.
    var parse_buffer: [1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&parse_buffer);
    const record = std.json.parseFromSliceLeaky(Record, fixed.allocator(), bytes, .{}) catch return null;
    if (!std.math.isFinite(record.x) or !std.math.isFinite(record.y) or
        !std.math.isFinite(record.scale) or record.scale <= 0) return null;
    return .{
        .x = @floatCast(record.x),
        .y = @floatCast(record.y),
        .scale = @floatCast(record.scale),
    };
}

test "geometry record round-trips through its wire format" {
    var buffer: [128]u8 = undefined;
    const bytes = try format(&buffer, .{ .x = -1890.5, .y = 42, .scale = 1.25 });
    const parsed = parse(bytes).?;
    try std.testing.expectApproxEqAbs(@as(f32, -1890.5), parsed.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 42), parsed.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.25), parsed.scale, 0.001);
}

test "geometry parse rejects malformed and non-finite records" {
    try std.testing.expect(parse("") == null);
    try std.testing.expect(parse("{\"x\":1}") == null);
    try std.testing.expect(parse("{\"x\":1,\"y\":2,\"scale\":0}") == null);
    try std.testing.expect(parse("not json") == null);
}

test "geometry store surfaces a corrupt persisted record" {
    const path = ".zig-cache/weaver-invalid-geometry-test.json";
    const temporary_path = ".zig-cache/weaver-invalid-geometry-test.json.tmp";
    var cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(std.testing.io, ".zig-cache");
    cwd.deleteFile(std.testing.io, path) catch {};
    defer cwd.deleteFile(std.testing.io, path) catch {};
    try cwd.writeFile(std.testing.io, .{ .sub_path = path, .data = "not json" });

    const store: Store = .{
        .io = std.testing.io,
        .directory = ".zig-cache",
        .path = path,
        .temporary_path = temporary_path,
    };
    try std.testing.expectError(error.InvalidGeometryRecord, store.load(std.testing.allocator));
}
