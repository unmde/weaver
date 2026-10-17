//! File operations the host repeats on its UI thread (the per-widget log
//! appends every line, backend status publishes) and on its management
//! thread (status, source and bundle checks), with small stack frames.
//! Zig's std.Io Windows file calls convert every path into fixed
//! 32K-character wide buffers on the stack (256-512 KiB frames, and Windows
//! touches every page of a frame on entry), and a thread's stack never
//! shrinks, so one log line kept half a megabyte of the host resident. On
//! Windows these convert the path into a one-page buffer instead; elsewhere
//! they are std.Io, whose POSIX frames are small.
const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

/// Longest path these helpers take, in UTF-16 units. The longest the
/// daemon builds is a registered source (at most supervisor.max_path_bytes,
/// 2048 UTF-8 bytes, so at most 2048 units) plus `\dist\widget.json`;
/// 64 more covers that and the `\\?\` prefix. Widget data and log paths
/// are a few hundred characters.
const max_path_units: usize = 2048 + 64;
const WidePath = [max_path_units + 8:0]u16;

const DWORD = u32;
const invalid_handle: windows.HANDLE = @ptrFromInt(std.math.maxInt(usize));
const FileAttributeData = extern struct {
    attributes: DWORD,
    created: [2]DWORD,
    accessed: [2]DWORD,
    written: [2]DWORD,
    size_high: DWORD,
    size_low: DWORD,
};

extern "kernel32" fn GetFileAttributesExW(path: [*:0]const u16, level: c_int, data: *FileAttributeData) callconv(.winapi) windows.BOOL;
extern "kernel32" fn CreateFileW(path: [*:0]const u16, access: DWORD, share: DWORD, security: ?*anyopaque, disposition: DWORD, flags: DWORD, template: ?windows.HANDLE) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn ReadFile(file: windows.HANDLE, buffer: [*]u8, len: DWORD, read: *DWORD, overlapped: ?*anyopaque) callconv(.winapi) windows.BOOL;
extern "kernel32" fn WriteFile(file: windows.HANDLE, buffer: [*]const u8, len: DWORD, written: *DWORD, overlapped: ?*anyopaque) callconv(.winapi) windows.BOOL;
extern "kernel32" fn CloseHandle(handle: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn MoveFileExW(from: [*:0]const u16, to: [*:0]const u16, flags: DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn DeleteFileW(path: [*:0]const u16) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;

const file_append_data: DWORD = 0x0004;
const generic_read: DWORD = 0x8000_0000;
const open_existing: DWORD = 3;
const generic_write: DWORD = 0x4000_0000;
const share_all: DWORD = 0x1 | 0x2 | 0x4;
const create_always: DWORD = 2;
const open_always: DWORD = 4;
const file_attribute_normal: DWORD = 0x80;
const movefile_replace_existing: DWORD = 0x1;
const error_file_not_found: DWORD = 2;
const error_path_not_found: DWORD = 3;

fn wide(path: []const u8, buffer: *WidePath) ![*:0]const u16 {
    var offset: usize = 0;
    if (path.len >= 248 and std.fs.path.isAbsoluteWindows(path) and !std.mem.startsWith(u8, path, "\\\\")) {
        for ("\\\\?\\", 0..) |char, index| buffer[index] = char;
        offset = 4;
    }
    const length = std.unicode.utf8ToUtf16Le(buffer[offset..max_path_units], path) catch return error.InvalidPath;
    if (offset + length >= max_path_units) return error.NameTooLong;
    buffer[offset + length] = 0;
    return buffer[0 .. offset + length :0].ptr;
}

/// Size of `path` in bytes, or null when it does not exist.
pub fn size(io: std.Io, path: []const u8) ?u64 {
    if (builtin.os.tag != .windows) {
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
        return stat.size;
    }
    var buffer: WidePath = undefined;
    const path_w = wide(path, &buffer) catch return null;
    var data: FileAttributeData = undefined;
    if (GetFileAttributesExW(path_w, 0, &data) == .FALSE) return null;
    return (@as(u64, data.size_high) << 32) | data.size_low;
}

/// When `path` (a file or a directory) was last modified, in nanoseconds
/// since the Unix epoch, as `std.Io.Dir.statFile` reports it; null when it
/// does not exist.
pub fn modified(io: std.Io, path: []const u8) ?i128 {
    if (builtin.os.tag != .windows) {
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
        return stat.mtime.nanoseconds;
    }
    var buffer: WidePath = undefined;
    const path_w = wide(path, &buffer) catch return null;
    var data: FileAttributeData = undefined;
    if (GetFileAttributesExW(path_w, 0, &data) == .FALSE) return null;
    const file_time = (@as(i128, data.written[1]) << 32) | data.written[0];
    // FILETIME counts 100 ns ticks from 1601.
    const unix_epoch_ticks: i128 = 116_444_736_000_000_000;
    return (file_time - unix_epoch_ticks) * 100;
}

/// Read `path` into `buffer`: the bytes read, or null when it does not
/// exist or cannot be read. A longer file is cut at `buffer.len`.
pub fn readSmall(io: std.Io, path: []const u8, buffer: []u8) ?[]u8 {
    if (builtin.os.tag != .windows) {
        return std.Io.Dir.cwd().readFile(io, path, buffer) catch null;
    }
    var path_buffer: WidePath = undefined;
    const path_w = wide(path, &path_buffer) catch return null;
    const file = CreateFileW(path_w, generic_read, share_all, null, open_existing, file_attribute_normal, null);
    if (file == invalid_handle) return null;
    defer _ = CloseHandle(file);
    var filled: usize = 0;
    while (filled < buffer.len) {
        var read: DWORD = 0;
        const want: DWORD = @intCast(@min(buffer.len - filled, std.math.maxInt(DWORD)));
        if (ReadFile(file, buffer[filled..].ptr, want, &read, null) == .FALSE) return null;
        if (read == 0) break;
        filled += read;
    }
    return buffer[0..filled];
}

/// Append `bytes` to `path`, creating it when missing.
pub fn append(io: std.Io, path: []const u8, bytes: []const u8) !void {
    if (builtin.os.tag != .windows) {
        var file = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = false });
        defer file.close(io);
        const stat = try file.stat(io);
        return file.writePositionalAll(io, bytes, stat.size);
    }
    var buffer: WidePath = undefined;
    const path_w = try wide(path, &buffer);
    const file = CreateFileW(path_w, file_append_data, share_all, null, open_always, file_attribute_normal, null);
    if (file == invalid_handle) return error.CreateFailed;
    defer _ = CloseHandle(file);
    try writeAll(file, bytes);
}

/// Replace `path`'s contents with `bytes`.
pub fn write(io: std.Io, path: []const u8, bytes: []const u8) !void {
    if (builtin.os.tag != .windows) return std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
    var buffer: WidePath = undefined;
    const path_w = try wide(path, &buffer);
    const file = CreateFileW(path_w, generic_write, share_all, null, create_always, file_attribute_normal, null);
    if (file == invalid_handle) return error.CreateFailed;
    defer _ = CloseHandle(file);
    try writeAll(file, bytes);
}

fn writeAll(file: windows.HANDLE, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        var written: DWORD = 0;
        const want: DWORD = @intCast(@min(bytes.len - offset, std.math.maxInt(DWORD)));
        if (WriteFile(file, bytes[offset..].ptr, want, &written, null) == .FALSE) return error.WriteFailed;
        offset += written;
    }
}

/// Move `from` over `to`.
pub fn rename(io: std.Io, from: []const u8, to: []const u8) !void {
    if (builtin.os.tag != .windows) {
        const cwd = std.Io.Dir.cwd();
        return cwd.rename(from, cwd, to, io);
    }
    var from_buffer: WidePath = undefined;
    var to_buffer: WidePath = undefined;
    const from_w = try wide(from, &from_buffer);
    const to_w = try wide(to, &to_buffer);
    if (MoveFileExW(from_w, to_w, movefile_replace_existing) == .FALSE) return error.RenameFailed;
}

/// Remove `path`; a missing file is already removed.
pub fn delete(io: std.Io, path: []const u8) !void {
    if (builtin.os.tag != .windows) {
        return std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => err,
        };
    }
    var buffer: WidePath = undefined;
    const path_w = try wide(path, &buffer);
    if (DeleteFileW(path_w) == .FALSE) {
        switch (GetLastError()) {
            error_file_not_found, error_path_not_found => return,
            else => return error.DeleteFailed,
        }
    }
}

test "small_fs appends, sizes, writes, renames and deletes" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    const path = try std.fs.path.join(gpa, &.{ dir, "widget.log" });
    defer gpa.free(path);
    const old = try std.fs.path.join(gpa, &.{ dir, "widget.log.old" });
    defer gpa.free(old);

    try std.testing.expect(size(io, path) == null);
    try append(io, path, "one\n");
    try append(io, path, "two\n");
    try std.testing.expectEqual(@as(?u64, 8), size(io, path));
    try rename(io, path, old);
    try std.testing.expect(size(io, path) == null);
    try std.testing.expectEqual(@as(?u64, 8), size(io, old));
    try write(io, path, "gpu");
    try write(io, path, "software");
    try std.testing.expectEqual(@as(?u64, 8), size(io, path));
    var small: [4]u8 = undefined;
    try std.testing.expectEqualStrings("soft", readSmall(io, path, &small).?);
    try std.testing.expect(readSmall(io, old, &small) != null);
    try delete(io, old);
    try delete(io, old);
    try std.testing.expect(size(io, old) == null);
    try std.testing.expect(readSmall(io, old, &small) == null);
    try std.testing.expect(modified(io, old) == null);
    // The same clock as std.Io's stat, for a file and a directory.
    try std.testing.expectEqual((try std.Io.Dir.cwd().statFile(io, path, .{})).mtime.nanoseconds, modified(io, path).?);
    try std.testing.expectEqual((try std.Io.Dir.cwd().statFile(io, dir, .{})).mtime.nanoseconds, modified(io, dir).?);
}
