//! A Windows system DLL that only some widgets need, loaded the first time
//! one of them calls into it instead of at process start. A static import
//! makes Windows map the DLL and everything it imports into every host,
//! including a host running only clocks. Windows only.
//!
//! `Api` is a struct whose fields are named exactly like the DLL's exports
//! and typed as pointers to the SDK header's declarations, e.g.
//! `WinHttpOpen: *const @TypeOf(win.WinHttpOpen)`, so every call keeps the
//! old extern's signature.

const std = @import("std");

const load_library_search_system32: u32 = 0x00000800;
const format_message_from_system: u32 = 0x00001000;
const format_message_ignore_inserts: u32 = 0x00000200;

extern "kernel32" fn LoadLibraryExW(file: [*:0]const u16, reserved: ?*anyopaque, flags: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn FormatMessageA(flags: u32, source: ?*const anyopaque, message_id: u32, language_id: u32, buffer: [*]u8, size: u32, arguments: ?*anyopaque) callconv(.winapi) u32;

pub fn Library(comptime Api: type, comptime file: []const u8) type {
    return struct {
        const file_w = std.unicode.utf8ToUtf16LeStringLiteral(file);

        var mutex: std.atomic.Mutex = .unlocked;
        var state: enum { untried, ready, failed } = .untried;
        var api: Api = undefined;
        var reason_buffer: [512]u8 = undefined;
        var reason_len: usize = 0;

        /// Loads the DLL from System32 and resolves every field of `Api` on
        /// the first call; later calls return the same table, or the same
        /// failure (`reason` says why). Safe from any thread.
        pub fn load() error{LibraryUnavailable}!*const Api {
            while (!mutex.tryLock()) std.atomic.spinLoopHint();
            defer mutex.unlock();
            if (state == .untried) state = if (resolve()) .ready else .failed;
            return if (state == .ready) &api else error.LibraryUnavailable;
        }

        /// Why `load` failed, naming the DLL, the export and the Windows
        /// error. Empty until `load` has failed; it never changes after.
        pub fn reason() []const u8 {
            while (!mutex.tryLock()) std.atomic.spinLoopHint();
            defer mutex.unlock();
            return reason_buffer[0..reason_len];
        }

        fn resolve() bool {
            // System32 only: these are OS components, never something the
            // widget's or host's directory should be able to supply.
            const module = LoadLibraryExW(file_w, null, load_library_search_system32) orelse {
                const error_code = GetLastError();
                note("{s} could not be loaded from System32 (needed for {s})", .{ file, std.meta.fields(Api)[0].name }, error_code);
                return false;
            };
            inline for (std.meta.fields(Api)) |field| {
                const address = GetProcAddress(module, field.name) orelse {
                    const error_code = GetLastError();
                    note("{s} has no export {s}", .{ file, field.name }, error_code);
                    return false;
                };
                @field(api, field.name) = @ptrCast(address);
            }
            return true;
        }

        fn note(comptime format: []const u8, args: anytype, error_code: u32) void {
            var system_text: [256]u8 = undefined;
            var system_len: usize = FormatMessageA(format_message_from_system | format_message_ignore_inserts, null, error_code, 0, &system_text, system_text.len, null);
            while (system_len > 0 and std.mem.indexOfScalar(u8, "\r\n .", system_text[system_len - 1]) != null) system_len -= 1;
            const written = std.fmt.bufPrint(&reason_buffer, format ++ ": {s} (Windows error {d})", args ++ .{ system_text[0..system_len], error_code }) catch reason_buffer[0..];
            reason_len = written.len;
        }
    };
}

test "a missing DLL fails with a reason that names it and the export" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const Missing = Library(struct { WeaverNoSuchExport: *const fn () callconv(.winapi) void }, "weaver-no-such-library.dll");
    try std.testing.expectError(error.LibraryUnavailable, Missing.load());
    try std.testing.expectError(error.LibraryUnavailable, Missing.load());
    const text = Missing.reason();
    try std.testing.expect(std.mem.indexOf(u8, text, "weaver-no-such-library.dll could not be loaded from System32") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "WeaverNoSuchExport") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "(Windows error 126)") != null);
}

test "a present DLL without the export fails naming the export" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const NoExport = Library(struct { WeaverNoSuchExport: *const fn () callconv(.winapi) void }, "kernel32.dll");
    try std.testing.expectError(error.LibraryUnavailable, NoExport.load());
    try std.testing.expect(std.mem.indexOf(u8, NoExport.reason(), "kernel32.dll has no export WeaverNoSuchExport") != null);
}

test "a present export resolves with its declared type" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const Kernel = Library(struct { GetTickCount64: *const fn () callconv(.winapi) u64 }, "kernel32.dll");
    const kernel = try Kernel.load();
    try std.testing.expect(kernel.GetTickCount64() > 0);
    try std.testing.expectEqual(@as(usize, 0), Kernel.reason().len);
}
