//! The file operations weaverd's supervision loop repeats, with small stack
//! frames. Zig's std.Io Windows file calls convert every path into fixed
//! 32K-character wide buffers on the stack (256-512 KiB frames, and Windows
//! touches every page of a frame on entry), so one status rename every two
//! seconds kept ~1 MiB of the daemon's stack resident. These convert paths
//! on the heap instead.
const std = @import("std");
const windows = std.os.windows;

const BOOL = windows.BOOL;
const DWORD = u32;
const HANDLE = windows.HANDLE;
const invalid_handle: HANDLE = @ptrFromInt(std.math.maxInt(usize));
const invalid_attributes: DWORD = 0xFFFF_FFFF;

const FILETIME = extern struct { low: DWORD, high: DWORD };
const FileAttributeData = extern struct {
    attributes: DWORD,
    created: FILETIME,
    accessed: FILETIME,
    written: FILETIME,
    size_high: DWORD,
    size_low: DWORD,
};

extern "kernel32" fn GetFileAttributesW(path: [*:0]const u16) callconv(.winapi) DWORD;
extern "kernel32" fn GetFileAttributesExW(path: [*:0]const u16, level: c_int, data: *FileAttributeData) callconv(.winapi) BOOL;
extern "kernel32" fn CreateFileW(path: [*:0]const u16, access: DWORD, share: DWORD, security: ?*anyopaque, disposition: DWORD, flags: DWORD, template: ?HANDLE) callconv(.winapi) HANDLE;
extern "kernel32" fn ReadFile(file: HANDLE, buffer: [*]u8, len: DWORD, read: *DWORD, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn WriteFile(file: HANDLE, buffer: [*]const u8, len: DWORD, written: *DWORD, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn MoveFileExW(from: [*:0]const u16, to: [*:0]const u16, flags: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn DeleteFileW(path: [*:0]const u16) callconv(.winapi) BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;

const generic_read: DWORD = 0x8000_0000;
const generic_write: DWORD = 0x4000_0000;
const share_all: DWORD = 0x1 | 0x2 | 0x4;
const create_always: DWORD = 2;
const open_existing: DWORD = 3;
const file_attribute_normal: DWORD = 0x80;
const movefile_replace_existing: DWORD = 0x1;
const error_file_not_found: DWORD = 2;
const error_path_not_found: DWORD = 3;

/// `path` as a NUL-terminated wide string, with the `\\?\` prefix that lifts
/// MAX_PATH from long absolute paths.
fn wide(gpa: std.mem.Allocator, path: []const u8) ![:0]u16 {
    const long = path.len >= 248 and std.fs.path.isAbsoluteWindows(path) and !std.mem.startsWith(u8, path, "\\\\");
    const text = if (long) try std.fmt.allocPrint(gpa, "\\\\?\\{s}", .{path}) else path;
    defer if (long) gpa.free(text);
    return std.unicode.utf8ToUtf16LeAllocZ(gpa, text);
}

pub fn exists(gpa: std.mem.Allocator, path: []const u8) bool {
    const path_w = wide(gpa, path) catch return false;
    defer gpa.free(path_w);
    return GetFileAttributesW(path_w.ptr) != invalid_attributes;
}

/// Last-write time in nanoseconds since the Unix epoch, as std's stat
/// reports it, or null when the file is missing.
pub fn mtime(gpa: std.mem.Allocator, path: []const u8) ?i128 {
    const path_w = wide(gpa, path) catch return null;
    defer gpa.free(path_w);
    var data: FileAttributeData = undefined;
    if (GetFileAttributesExW(path_w.ptr, 0, &data) == .FALSE) return null;
    const ticks = (@as(i128, data.written.high) << 32) | data.written.low;
    const unix_epoch_ticks: i128 = 116_444_736_000_000_000;
    return (ticks - unix_epoch_ticks) * 100;
}

fn open(gpa: std.mem.Allocator, path: []const u8) !HANDLE {
    const path_w = try wide(gpa, path);
    defer gpa.free(path_w);
    const file = CreateFileW(path_w.ptr, generic_read, share_all, null, open_existing, file_attribute_normal, null);
    if (file == invalid_handle) {
        return switch (GetLastError()) {
            error_file_not_found, error_path_not_found => error.FileNotFound,
            else => error.OpenFailed,
        };
    }
    return file;
}

/// Read up to `buffer.len` bytes of `path`.
pub fn readInto(gpa: std.mem.Allocator, path: []const u8, buffer: []u8) ![]u8 {
    const file = try open(gpa, path);
    defer _ = CloseHandle(file);
    var total: usize = 0;
    while (total < buffer.len) {
        var read: DWORD = 0;
        const want: DWORD = @intCast(@min(buffer.len - total, std.math.maxInt(DWORD)));
        if (ReadFile(file, buffer[total..].ptr, want, &read, null) == .FALSE) return error.ReadFailed;
        if (read == 0) break;
        total += read;
    }
    return buffer[0..total];
}

/// The whole of `path`, refusing files longer than `limit`.
pub fn readAlloc(gpa: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    const file = try open(gpa, path);
    defer _ = CloseHandle(file);
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);
    var chunk: [4096]u8 = undefined;
    while (true) {
        var read: DWORD = 0;
        if (ReadFile(file, &chunk, chunk.len, &read, null) == .FALSE) return error.ReadFailed;
        if (read == 0) break;
        if (bytes.items.len + read > limit) return error.FileTooBig;
        try bytes.appendSlice(gpa, chunk[0..read]);
    }
    return bytes.toOwnedSlice(gpa);
}

/// Publish `data` at `final` atomically: write `temp`, then move it over.
pub fn writeReplace(gpa: std.mem.Allocator, temp: []const u8, final: []const u8, data: []const u8) !void {
    const temp_w = try wide(gpa, temp);
    defer gpa.free(temp_w);
    const final_w = try wide(gpa, final);
    defer gpa.free(final_w);
    const file = CreateFileW(temp_w.ptr, generic_write, 0, null, create_always, file_attribute_normal, null);
    if (file == invalid_handle) return error.CreateFailed;
    var offset: usize = 0;
    while (offset < data.len) {
        var written: DWORD = 0;
        const want: DWORD = @intCast(@min(data.len - offset, std.math.maxInt(DWORD)));
        if (WriteFile(file, data[offset..].ptr, want, &written, null) == .FALSE) {
            _ = CloseHandle(file);
            return error.WriteFailed;
        }
        offset += written;
    }
    _ = CloseHandle(file);
    if (MoveFileExW(temp_w.ptr, final_w.ptr, movefile_replace_existing) == .FALSE) return error.RenameFailed;
}

/// Remove `path`; a missing file is already removed.
pub fn delete(gpa: std.mem.Allocator, path: []const u8) !void {
    const path_w = try wide(gpa, path);
    defer gpa.free(path_w);
    if (DeleteFileW(path_w.ptr) == .FALSE) {
        switch (GetLastError()) {
            error_file_not_found, error_path_not_found => return,
            else => return error.DeleteFailed,
        }
    }
}

test "small_fs round-trips a file through write, read, mtime and delete" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(dir);
    const final = try std.fs.path.join(gpa, &.{ dir, "status.json" });
    defer gpa.free(final);
    const temp = try std.fs.path.join(gpa, &.{ dir, "status.json.tmp" });
    defer gpa.free(temp);

    try std.testing.expect(!exists(gpa, final));
    try std.testing.expect(mtime(gpa, final) == null);
    try std.testing.expectError(error.FileNotFound, readAlloc(gpa, final, 64));
    try writeReplace(gpa, temp, final, "{\"a\":1}");
    try writeReplace(gpa, temp, final, "{\"b\":2}");
    try std.testing.expect(exists(gpa, final));
    try std.testing.expect(!exists(gpa, temp));
    try std.testing.expect(mtime(gpa, final).? > 0);
    const bytes = try readAlloc(gpa, final, 64);
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings("{\"b\":2}", bytes);
    var buffer: [4]u8 = undefined;
    try std.testing.expectEqualStrings("{\"b\"", try readInto(gpa, final, &buffer));
    try std.testing.expectError(error.FileTooBig, readAlloc(gpa, final, 3));
    try delete(gpa, final);
    try delete(gpa, final);
    try std.testing.expect(!exists(gpa, final));
}
