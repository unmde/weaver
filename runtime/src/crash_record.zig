//! The widget host's record of itself (ADR 0022): which generation of the
//! host is running, and, when it dies, whether a widget's code was running
//! on the thread that crashed, and which widget each of its slots holds. A
//! daemon host keeps it mapped from `%LOCALAPPDATA%\weaver\host.record`;
//! after the process is gone, the next host reads it to quarantine the
//! widget that crashed (runtime/src/daemon.zig), and `weaver status` reads
//! it, through `weaver-widget --status` (host_lifecycle.zig), to say why no
//! host runs. Mapped file pages outlive the process, so a crash needs no
//! flush, and the crash path only does plain stores into a slot that was
//! there from the start: the faulting thread's stack and heap may be broken.
//!
//! A crash is attributed to a widget only on evidence: the thread that
//! crashed was running that widget's JavaScript turn (`beginTurn`). Any
//! other crash, and a host that is gone with no crash written (killed, or a
//! fault no handler saw), names no widget.
//!
//! After a crash is recorded the host fails fast (`failFast`), so Windows
//! Error Reporting sees it and restarts the host if it asked to be
//! (RegisterApplicationRestart, main.zig `startDaemon`).
const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

const contract = @import("host_contract");

pub const magic = contract.record_magic;
pub const version = contract.record_version;
pub const State = contract.RecordState;
pub const CrashKind = contract.CrashKind;
pub const Turn = contract.Turn;
pub const Crash = contract.Crash;
/// The file's layout, shared with the CLI's client
/// (host/src/host_contract.zig).
pub const Record = contract.Record;

/// The exception code recorded for a Zig panic (`notePanic`).
pub const panic_code = contract.panic_code;

/// Mapped only on Windows: the functions that reach kernel32 return first
/// elsewhere, so other platforms neither compile nor link those calls.
var record: ?*volatile Record = null;
var ui_thread: u32 = 0;
/// When the running turn began (GetTickCount64), for `noteWedged`. Kept
/// out of the record: no reader after a crash needs it.
var turn_started_ms: std.atomic.Value(u64) = .init(0);

extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, disposition: u32, flags: u32, template: ?windows.HANDLE) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn CreateFileMappingW(file: windows.HANDLE, security: ?*anyopaque, protect: u32, size_high: u32, size_low: u32, name: ?[*:0]const u16) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn MapViewOfFile(mapping: windows.HANDLE, access: u32, offset_high: u32, offset_low: u32, bytes: usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn UnmapViewOfFile(base: *const anyopaque) callconv(.winapi) windows.BOOL;
extern "kernel32" fn CloseHandle(handle: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) u32;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) windows.HANDLE;
extern "kernel32" fn GetProcessTimes(process: windows.HANDLE, creation: *u64, exit: *u64, kernel: *u64, user: *u64) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetSystemTimeAsFileTime(time: *u64) callconv(.winapi) void;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

/// The Win32 error of the last failed `open`, for the host's log.
pub var open_error: u32 = 0;
extern "kernel32" fn SetUnhandledExceptionFilter(filter: ?*const fn (*windows.EXCEPTION_POINTERS) callconv(.winapi) c_long) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn RaiseFailFastException(record: ?*windows.EXCEPTION_RECORD, context: ?*windows.CONTEXT, flags: u32) callconv(.winapi) noreturn;
extern "kernel32" fn ReadFile(file: windows.HANDLE, buffer: [*]u8, bytes: u32, read: *u32, overlapped: ?*anyopaque) callconv(.winapi) windows.BOOL;
extern "kernel32" fn WriteFile(file: windows.HANDLE, buffer: [*]const u8, bytes: u32, written: ?*u32, overlapped: ?*anyopaque) callconv(.winapi) windows.BOOL;

/// A daemon host's crashes end in `failFast`, so Windows Error Reporting
/// sees them and restarts the host (`routeCrashesToWindows`). Dev, capture
/// and macOS keep Native's and Zig's own handling.
var fail_fast_crashes = false;
/// Where a daemon host writes a panic's message before it fails fast:
/// Native's `last-panic.txt`, which Native's panic capture writes before
/// Zig's abort, and which a daemon host now writes itself.
var panic_note_path: [1024:0]u16 = undefined;
var panic_note_length: usize = 0;

/// How a host opens its record. Readers (`read`) and deletion may share it;
/// another writer may not: two hosts on one record would mix one's identity
/// with the other's crash.
const record_access: u32 = 0x8000_0000 | 0x4000_0000; // GENERIC_READ | GENERIC_WRITE
const record_share: u32 = 0x1 | 0x4; // FILE_SHARE_READ | FILE_SHARE_DELETE

/// Map the record at `path` (creating it), start a new generation marked
/// running, and route unhandled exceptions through `noteCrash`. Called on
/// the UI thread, before any widget loads. A host that can't open it does
/// not run (main.zig `openRecord`). Returns the previous host's record,
/// when the file held one this version wrote: the host consumes it exactly
/// once, because this start overwrites it.
pub fn open(path: []const u8) !?Record {
    if (builtin.os.tag != .windows) return null;
    var wide: [1024:0]u16 = undefined;
    const length = try std.unicode.utf8ToUtf16Le(&wide, path);
    if (length >= wide.len) return error.NameTooLong;
    wide[length] = 0;
    const open_always: u32 = 4;
    const file = CreateFileW(&wide, record_access, record_share, null, open_always, 0, null);
    if (file == windows.INVALID_HANDLE_VALUE) {
        open_error = GetLastError();
        // ERROR_SHARING_VIOLATION: another host has it open for writing.
        return if (open_error == 32) error.RecordInUse else error.RecordOpenFailed;
    }
    defer _ = CloseHandle(file);
    // A mapping larger than the file extends it.
    const page_readwrite: u32 = 0x04;
    const mapping = CreateFileMappingW(file, null, page_readwrite, 0, @sizeOf(Record), null) orelse return error.MapFailed;
    defer _ = CloseHandle(mapping);
    const file_map_write: u32 = 0x0002;
    const view = MapViewOfFile(mapping, file_map_write, 0, 0, @sizeOf(Record)) orelse return error.MapFailed;
    const mapped: *volatile Record = @ptrCast(@alignCast(view));
    const previous: ?Record = if (mapped.magic == magic and mapped.version == version) mapped.* else null;
    var created: u64 = 0;
    var unused: u64 = 0;
    _ = GetProcessTimes(GetCurrentProcess(), &created, &unused, &unused, &unused);
    // Running is written last: a reader never sees a running record with
    // another start's fields.
    mapped.state = .none;
    mapped.magic = magic;
    mapped.version = version;
    mapped.generation = if (previous) |last| last.generation + 1 else 1;
    mapped.pid = GetCurrentProcessId();
    mapped.start_time = created;
    mapped.turn = .{};
    mapped.crash = .{};
    mapped.slots = @splat(.{});
    mapped.restarts = @splat(0);
    mapped.restart_count = 0;
    mapped.restart = .none;
    mapped.restart_error = 0;
    mapped.restart_line_len = 0;
    mapped.stop_reason_len = 0;
    mapped.state = .running;
    ui_thread = GetCurrentThreadId();
    record = mapped;
    _ = SetUnhandledExceptionFilter(onUnhandledException);
    return previous;
}

/// The generation this start's record holds, once `open` succeeded.
pub fn generation() ?u64 {
    const mapped = record orelse return null;
    return mapped.generation;
}

/// From here on a panic, a fault Zig's handler sees, and a stuck UI thread
/// fail fast (main.zig `recordPanic`, `debug.handleSegfault`, daemon.zig
/// `apply`), writing a panic's message to `panic_note` first.
pub fn routeCrashesToWindows(panic_note: []const u8) void {
    fail_fast_crashes = true;
    const length = std.unicode.utf8ToUtf16Le(&panic_note_path, panic_note) catch return;
    if (length >= panic_note_path.len) return;
    panic_note_path[length] = 0;
    panic_note_length = length;
}

pub fn failsFast() bool {
    return fail_fast_crashes;
}

/// Best effort, before `failFast`: the panic's message where Native keeps
/// it. Formats into the stack and writes with one call, as Native's own
/// capture does.
pub fn writePanicNote(msg: []const u8, return_address: ?usize) void {
    if (builtin.os.tag != .windows or panic_note_length == 0) return;
    var buffer: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "panic: {s}\nreturn_address: 0x{x}\n", .{ msg[0..@min(msg.len, 900)], return_address orelse 0 }) catch return;
    const generic_write: u32 = 0x4000_0000;
    const create_always: u32 = 2;
    const file = CreateFileW(&panic_note_path, generic_write, 0, null, create_always, 0, null);
    if (file == windows.INVALID_HANDLE_VALUE) return;
    defer _ = CloseHandle(file);
    _ = WriteFile(file, text.ptr, @intCast(text.len), null, null);
}

/// Stop recording and unmap the record (tests; a host keeps it to the end).
pub fn close() void {
    const mapped = record orelse return;
    record = null;
    _ = SetUnhandledExceptionFilter(null);
    _ = UnmapViewOfFile(@volatileCast(mapped));
}

/// The host is exiting on purpose.
pub fn markStopped() void {
    const mapped = record orelse return;
    mapped.state = .stopped;
}

/// The host is exiting because its startup failed with `reason` (an error
/// name): a clean stop, which Windows does not restart, and `weaver status`
/// says why.
pub fn markStoppedWith(reason: []const u8) void {
    const mapped = record orelse return;
    const length = @min(reason.len, mapped.stop_reason.len);
    for (reason[0..length], 0..) |byte, index| mapped.stop_reason[index] = byte;
    mapped.stop_reason_len = @intCast(length);
    mapped.state = .stopped;
}

/// The automatic restarts this start counts toward the cap, and what it
/// asked of Windows (main.zig `startDaemon`).
pub fn noteRestart(plan: contract.RestartPlan, request: contract.RestartRequest, hresult: u32, line_len: u32) void {
    const mapped = record orelse return;
    mapped.restarts = plan.restarts;
    mapped.restart_count = plan.count;
    mapped.restart_error = hresult;
    mapped.restart_line_len = line_len;
    mapped.restart = request;
}

/// The Win32 error a host opening the record at `path` would get now, or
/// null if it would open it (or create it: there is none yet). What `weaver
/// up` and `weaver status` name when a host exited for want of its record.
/// It opens the record as a host does and closes it at once; a host
/// starting meanwhile retries (main.zig `openRecord`).
pub fn openFailure(path: []const u8) ?u32 {
    if (builtin.os.tag != .windows) return null;
    var wide: [1024:0]u16 = undefined;
    const length = std.unicode.utf8ToUtf16Le(&wide, path) catch return null;
    if (length >= wide.len) return null;
    wide[length] = 0;
    const open_existing: u32 = 3;
    const file = CreateFileW(&wide, record_access, record_share, null, open_existing, 0, null);
    if (file == windows.INVALID_HANDLE_VALUE) {
        const err = GetLastError();
        // ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND: a host creates it.
        return if (err == 2 or err == 3) null else err;
    }
    _ = CloseHandle(file);
    return null;
}

/// The record at `path` as it is now, if it is one this version wrote: what
/// a host Windows restarted checks its generation against before it opens
/// (and so consumes) it, and what `weaver status` reads while no host runs.
/// Opened for reading only, sharing with the host that may hold it.
pub fn read(path: []const u8) ?Record {
    if (builtin.os.tag != .windows) return null;
    var wide: [1024:0]u16 = undefined;
    const length = std.unicode.utf8ToUtf16Le(&wide, path) catch return null;
    if (length >= wide.len) return null;
    wide[length] = 0;
    const generic_read: u32 = 0x8000_0000;
    const share_all: u32 = 0x1 | 0x2 | 0x4;
    const open_existing: u32 = 3;
    const file = CreateFileW(&wide, generic_read, share_all, null, open_existing, 0, null);
    if (file == windows.INVALID_HANDLE_VALUE) return null;
    defer _ = CloseHandle(file);
    var bytes: [@sizeOf(Record)]u8 = undefined;
    var count: u32 = 0;
    if (ReadFile(file, &bytes, bytes.len, &count, null) == .FALSE) return null;
    return contract.parseRecord(bytes[0..count]);
}

/// Host slot `slot` now holds the widget named by `name_hash`, launched
/// from the bundle modified at `artifact`: what the next host quarantines
/// if this one crashes in its turn. Plain stores, before the widget loads.
pub fn noteSlot(slot: u16, name_hash: u64, artifact: i64) void {
    const mapped = record orelse return;
    if (slot >= mapped.slots.len) return;
    mapped.slots[slot] = .{ .name_hash = name_hash, .artifact = artifact };
}

/// A widget's turn starts on this thread: `slot` is its slot in the host.
pub fn beginTurn(slot: u16, bundle: u64) void {
    if (builtin.os.tag != .windows) return;
    const mapped = record orelse return;
    turn_started_ms.store(GetTickCount64(), .release);
    mapped.turn.thread = GetCurrentThreadId();
    mapped.turn.bundle = bundle;
    mapped.turn.slot = @as(u32, slot) + 1;
}

pub fn endTurn() void {
    const mapped = record orelse return;
    mapped.turn.slot = 0;
}

/// Fill the crash slot for a crash on the calling thread: plain stores, no
/// allocation, no locks. The first crash wins.
pub fn noteCrash(code: u32) void {
    if (builtin.os.tag != .windows) return;
    const mapped = record orelse return;
    if (mapped.crash.kind != .none) return;
    const thread = GetCurrentThreadId();
    const turn_slot = mapped.turn.slot;
    const in_turn = turn_slot != 0 and mapped.turn.thread == thread;
    var now: u64 = 0;
    GetSystemTimeAsFileTime(&now);
    mapped.crash.code = code;
    mapped.crash.thread = thread;
    mapped.crash.slot = if (in_turn) turn_slot else 0;
    mapped.crash.bundle = if (in_turn) mapped.turn.bundle else 0;
    mapped.crash.time = now;
    mapped.crash.kind = if (in_turn) .widget_turn else if (thread == ui_thread) .ui else .other;
}

/// The management thread found the UI thread still busy past its deadline
/// (daemon.zig `apply`), and the host is about to stop itself with `code`.
/// The widget whose turn is running, on whichever thread, held it up if
/// that turn has run at least `min_turn_ms`: that is the evidence, as for a
/// crash in its turn. Otherwise the crash names no one.
pub fn noteWedged(code: u32, min_turn_ms: u64) void {
    if (builtin.os.tag != .windows) return;
    const mapped = record orelse return;
    if (mapped.crash.kind != .none) return;
    const open_slot = mapped.turn.slot;
    const turn_slot = if (open_slot != 0 and GetTickCount64() -| turn_started_ms.load(.acquire) >= min_turn_ms) open_slot else 0;
    var now: u64 = 0;
    GetSystemTimeAsFileTime(&now);
    mapped.crash.code = code;
    mapped.crash.thread = mapped.turn.thread;
    mapped.crash.slot = turn_slot;
    mapped.crash.bundle = if (turn_slot != 0) mapped.turn.bundle else 0;
    mapped.crash.time = now;
    mapped.crash.kind = if (turn_slot != 0) .widget_turn else .other;
}

/// A Zig panic, before its diagnostics run.
pub fn notePanic() void {
    noteCrash(panic_code);
}

fn onUnhandledException(info: *windows.EXCEPTION_POINTERS) callconv(.winapi) c_long {
    noteCrash(info.ExceptionRecord.ExceptionCode);
    // Fail fast whether or not the store landed: nothing else may run on a
    // broken thread, and Windows Error Reporting still sees the crash.
    RaiseFailFastException(info.ExceptionRecord, info.ContextRecord, 0);
}

/// End the process as a crash with `code`, which Windows Error Reporting
/// sees (and restarts, when the host asked it to). A Zig panic and a stuck
/// UI thread end this way in a daemon host: Zig's own abort exits with 3,
/// which Windows treats as an ordinary exit.
pub fn failFast(code: u32) noreturn {
    var exception = std.mem.zeroes(windows.EXCEPTION_RECORD);
    exception.ExceptionCode = code;
    // EXCEPTION_NONCONTINUABLE
    exception.ExceptionFlags = 0x1;
    RaiseFailFastException(&exception, null, 0);
}

test "a crash in a widget's turn names it; one outside a turn names no one" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var storage: Record = std.mem.zeroes(Record);
    record = &storage;
    defer record = null;
    ui_thread = GetCurrentThreadId();
    beginTurn(4, 0xabcd);
    noteCrash(0xC000_0005);
    try std.testing.expectEqual(CrashKind.widget_turn, storage.crash.kind);
    try std.testing.expectEqual(@as(u32, 5), storage.crash.slot);
    try std.testing.expectEqual(@as(u64, 0xabcd), storage.crash.bundle);
    // The first crash wins.
    noteCrash(panic_code);
    try std.testing.expectEqual(@as(u32, 0xC000_0005), storage.crash.code);

    storage.crash = .{};
    endTurn();
    notePanic();
    try std.testing.expectEqual(CrashKind.ui, storage.crash.kind);
    try std.testing.expectEqual(@as(u32, 0), storage.crash.slot);

    // A turn running on another thread doesn't make this thread's crash its.
    storage.crash = .{};
    beginTurn(2, 1);
    storage.turn.thread +%= 1;
    const Other = struct {
        fn crash() void {
            noteCrash(0xC000_0005);
        }
    };
    const thread = try std.Thread.spawn(.{}, Other.crash, .{});
    thread.join();
    try std.testing.expectEqual(CrashKind.other, storage.crash.kind);

    // A stuck UI thread names the widget whose turn holds it, from the
    // management thread, once that turn has lasted long enough; a turn that
    // just began, or none, names no one.
    storage.crash = .{};
    beginTurn(6, 9);
    const Management = struct {
        fn wedge(min_turn_ms: u64) void {
            noteWedged(contract.exit_wedged, min_turn_ms);
        }
    };
    var management = try std.Thread.spawn(.{}, Management.wedge, .{@as(u64, 60_000)});
    management.join();
    try std.testing.expectEqual(CrashKind.other, storage.crash.kind);
    storage.crash = .{};
    management = try std.Thread.spawn(.{}, Management.wedge, .{@as(u64, 0)});
    management.join();
    try std.testing.expectEqual(CrashKind.widget_turn, storage.crash.kind);
    try std.testing.expectEqual(@as(u32, 7), storage.crash.slot);
    try std.testing.expectEqual(contract.exit_wedged, storage.crash.code);
    storage.crash = .{};
    endTurn();
    noteWedged(contract.exit_wedged, 0);
    try std.testing.expectEqual(CrashKind.other, storage.crash.kind);
}

test "a record another program holds open names the error a host would get" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "host.record" });
    defer std.testing.allocator.free(path);
    // None yet: a host creates it.
    try std.testing.expectEqual(@as(?u32, null), openFailure(path));
    _ = try open(path);
    close();
    try std.testing.expectEqual(@as(?u32, null), openFailure(path));
    // Held with no sharing, as a backup or scanning tool might.
    var wide: [1024:0]u16 = undefined;
    const length = try std.unicode.utf8ToUtf16Le(&wide, path);
    wide[length] = 0;
    const file = CreateFileW(&wide, 0x8000_0000, 0, null, 3, 0, null);
    try std.testing.expect(file != windows.INVALID_HANDLE_VALUE);
    defer _ = CloseHandle(file);
    try std.testing.expectEqual(@as(?u32, 32), openFailure(path));
    try std.testing.expectError(error.RecordInUse, open(path));
}

test "a new start takes the next generation and clears the last crash" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "host.record" });
    defer std.testing.allocator.free(path);
    _ = try open(path);
    const first = record.?.generation;
    beginTurn(3, 7);
    noteSlot(3, 0x1234, 99);
    noteCrash(0xC000_0005);
    close();
    // The next start hands back the crashed one's record, then clears it.
    const previous = (try open(path)).?;
    defer close();
    try std.testing.expectEqual(first, previous.generation);
    try std.testing.expectEqual(CrashKind.widget_turn, previous.crash.kind);
    try std.testing.expectEqual(@as(u32, 4), previous.crash.slot);
    try std.testing.expectEqual(@as(u64, 0x1234), previous.slots[3].name_hash);
    try std.testing.expectEqual(@as(i64, 99), previous.slots[3].artifact);
    try std.testing.expectEqual(first + 1, record.?.generation);
    try std.testing.expectEqual(State.running, record.?.state);
    try std.testing.expectEqual(CrashKind.none, record.?.crash.kind);
    try std.testing.expectEqual(@as(u64, 0), record.?.slots[3].name_hash);
    try std.testing.expectEqual(GetCurrentProcessId(), record.?.pid);
}
