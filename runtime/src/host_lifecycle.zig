//! Who starts and stops the Windows widget host (ADR 0022 step 5). There is
//! no supervisor process: the host asks Windows to restart it after a crash
//! (main.zig `startDaemon`), and the CLI starts, stops and asks after it
//! through the client verbs below, which run in a short-lived
//! `weaver-widget.exe` the CLI spawns (cli/src/index.ts):
//!
//! - `--up` takes the lifecycle lock, deletes the stop marker, and starts a
//!   host unless one runs and is not shutting down;
//! - `--down` takes the lock, writes the stop marker, signals the host and
//!   waits for it to exit, stopping it after `down_grace_ms`;
//! - `--status` asks a running host to write status.json, or, when none
//!   runs, prints what its record and the stop marker say (`describeDown`);
//! - `--reload` signals a registry reload and waits for the acknowledgement,
//!   or for the host to die before it answers;
//! - `--probe` says whether a host runs and can acknowledge reloads.
//!
//! The stop marker is what a pending restart meets after `weaver down`: a
//! starting host takes the same lock, and exits if the marker is there. So
//! nothing has to hold the host's named objects while no host runs.
const std = @import("std");
const contract = @import("host_contract");
const supervisor = @import("host_supervisor");
const crash_record = @import("crash_record.zig");

const win = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
    @cInclude("psapi.h");
    @cInclude("tlhelp32.h");
});

/// How a client verb ends. The CLI reads the code (cli/src/index.ts
/// `HostClientExit`, which must match), and a message on stderr for
/// `failed`.
pub const Exit = enum(u8) {
    ok = 0,
    failed = 1,
    /// `--up`: a host already runs.
    already_running = 2,
    /// No host runs. `--status` printed why on stdout.
    not_running = 3,
    /// `--reload`: the host could not read the registry; nothing changed.
    reload_failed = 4,
    /// The host did not answer in time.
    timed_out = 5,
    /// `--reload`: the host died before it answered. The registry change
    /// stands; the next host reads it.
    host_crashed = 6,
    /// Another `weaver up` or `weaver down` held the lifecycle lock past
    /// `client_lock_wait_ms`.
    busy = 7,
    /// A host runs that cannot acknowledge reloads (it predates them).
    legacy = 8,
};

pub const Verb = enum {
    up,
    down,
    status,
    reload,
    probe,

    pub fn parse(argument: []const u8) ?Verb {
        inline for (@typeInfo(Verb).@"enum".fields) |field| {
            if (std.mem.eql(u8, argument, "--" ++ field.name)) return @field(Verb, field.name);
        }
        return null;
    }
};

/// How long `--down` gives a signalled host to exit by itself before it
/// stops it: weaverd's grace, which a host stopping cleanly meets with room
/// (step 4 receipt: `weaver down` took about 490 ms end to end).
pub const down_grace_ms: u32 = 4_000;
/// How long `--down` waits for a host it stopped to be gone. Receipt
/// (2026-10-17, weaver-step5-scratch/gt-down*): stopping a crashed host
/// that Windows was still reporting, the whole `weaver down` took 4.42-4.52
/// s, 4 s of it the grace and most of the rest node starting.
const terminate_wait_ms: u32 = 1_000;
/// How long a client waits for the lifecycle lock. Its longest holder is
/// another `--down` (`down_grace_ms` plus `terminate_wait_ms`, 5 s); 10 s is
/// twice that.
const client_lock_wait_ms: u32 = 10_000;
/// How long `--up` waits for the host it started to publish control: what
/// the CLI waited for weaverd to bring the host up (5 s).
const up_wait_ms: u64 = 5_000;
/// How long a client waits, once the singleton exists, for the control
/// events. A starting host holds the singleton without them while it
/// retries its record (main.zig `openRecord`, up to `record_open_wait_ms`;
/// 203-250 ms after a crash), then creates them together (daemon.zig
/// `Objects.publish`): a second past the longest retry. Only a host that
/// predates them, or one that exits for want of its record, takes this
/// long.
const control_wait_ms: u64 = contract.record_open_wait_ms + 1_000;
/// `--reload`'s waits: weaverd's limits, which reloads have always met.
const reload_signal_wait_ms: u32 = 10_000;
const reload_answer_wait_ms: u32 = 10_000;
/// How long `--status` waits for the host to write status: what `--up`
/// waits for a host to come up, so a request sent as one starts is answered.
const status_answer_wait_ms: u32 = 5_000;
const poll_ms: u32 = 20;

/// Where the host keeps what the client reads: under
/// `%LOCALAPPDATA%\weaver`.
pub const Paths = struct {
    data_root: []const u8,
    record: []const u8,
    marker: []const u8,
    registry: []const u8,

    pub fn of(allocator: std.mem.Allocator, data_root: []const u8) !Paths {
        return .{
            .data_root = data_root,
            .record = try std.fs.path.join(allocator, &.{ data_root, "host.record" }),
            .marker = try std.fs.path.join(allocator, &.{ data_root, contract.stop_marker_name }),
            .registry = try std.fs.path.join(allocator, &.{ data_root, "registry.json" }),
        };
    }
};

// ---- The lock and the marker ------------------------------------------

/// `contract.lifecycle_mutex`, held.
pub const Lock = struct {
    handle: win.HANDLE,

    pub fn acquire(wait_ms: u32) !Lock {
        const handle = win.CreateMutexW(null, 0, contract.lifecycle_mutex) orelse return error.CreateMutexFailed;
        switch (win.WaitForSingleObject(handle, wait_ms)) {
            // An abandoned lock's holder died; what it guarded is files and
            // the host's own objects, which every holder re-reads.
            win.WAIT_OBJECT_0, win.WAIT_ABANDONED => return .{ .handle = handle },
            else => {
                _ = win.CloseHandle(handle);
                return error.LifecycleBusy;
            },
        }
    }

    pub fn release(self: Lock) void {
        _ = win.ReleaseMutex(self.handle);
        _ = win.CloseHandle(self.handle);
    }
};

/// A path as Win32 takes it: the record's own limit (crash_record.open).
/// Small, because a starting host checks the marker on its UI thread,
/// whose stack stays as deep as it ever went.
const WidePath = struct {
    buffer: [1024:0]u16 = undefined,

    fn of(self: *WidePath, path: []const u8) ![*:0]const u16 {
        const length = try std.unicode.utf8ToUtf16Le(&self.buffer, path);
        if (length >= self.buffer.len) return error.NameTooLong;
        self.buffer[length] = 0;
        return &self.buffer;
    }
};

/// `weaver down` ran and `weaver up` has not since.
pub fn stopMarked(paths: Paths) bool {
    var wide: WidePath = .{};
    const path = wide.of(paths.marker) catch return false;
    return win.GetFileAttributesW(path) != win.INVALID_FILE_ATTRIBUTES;
}

fn writeMarker(paths: Paths) !void {
    var wide: WidePath = .{};
    // `weaver down` on a profile no host ever ran in still leaves a marker.
    _ = win.CreateDirectoryW(try wide.of(paths.data_root), null);
    const file = win.CreateFileW(try wide.of(paths.marker), win.GENERIC_WRITE, 0, null, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, null);
    if (file == win.INVALID_HANDLE_VALUE) return error.StopMarkerNotWritten;
    _ = win.CloseHandle(file);
}

fn clearMarker(paths: Paths) !void {
    var wide: WidePath = .{};
    if (win.DeleteFileW(try wide.of(paths.marker)) != 0) return;
    const err = win.GetLastError();
    if (err != win.ERROR_FILE_NOT_FOUND and err != win.ERROR_PATH_NOT_FOUND) return error.StopMarkerNotDeleted;
}

/// When the marker was written, as a FILETIME.
fn markerTime(paths: Paths) ?u64 {
    var wide: WidePath = .{};
    var data: win.WIN32_FILE_ATTRIBUTE_DATA = undefined;
    if (win.GetFileAttributesExW(wide.of(paths.marker) catch return null, win.GetFileExInfoStandard, &data) == 0) return null;
    return fileTime(data.ftLastWriteTime);
}

// ---- The running host ---------------------------------------------------

fn objectExists(comptime kind: enum { mutex, event }, name: [*:0]const u16) bool {
    const handle = switch (kind) {
        .mutex => win.OpenMutexW(win.SYNCHRONIZE, 0, name),
        .event => win.OpenEventW(win.SYNCHRONIZE, 0, name),
    } orelse return false;
    _ = win.CloseHandle(handle);
    return true;
}

/// A host owns the singleton. Nothing else holds it while no host runs, so
/// it exists exactly while a host does.
fn hostRunning() bool {
    return objectExists(.mutex, contract.singleton_mutex);
}

/// The running host's control objects are all up: the status events are
/// the last it creates. A host that predates them never has them.
fn controlReady() bool {
    const deadline = win.GetTickCount64() + control_wait_ms;
    while (true) {
        if (objectExists(.event, contract.status_written_event)) return true;
        if (!hostRunning() or win.GetTickCount64() >= deadline) return false;
        win.Sleep(poll_ms);
    }
}

fn shutdownSignalled() bool {
    const event = win.OpenEventW(win.SYNCHRONIZE, 0, contract.shutdown_event) orelse return false;
    defer _ = win.CloseHandle(event);
    return win.WaitForSingleObject(event, 0) == win.WAIT_OBJECT_0;
}

const Liveness = enum { gone, alive, unknown };

/// The process `record` names, opened with `access`, if it is still that
/// process: the same PID and creation time.
fn openRecorded(record: contract.Record, access: win.DWORD) union(enum) { open: win.HANDLE, gone, unknown } {
    const process = win.OpenProcess(access | win.PROCESS_QUERY_LIMITED_INFORMATION, 0, record.pid) orelse {
        // No process has that PID now (ERROR_INVALID_PARAMETER); anything
        // else (access denied) leaves us not knowing.
        return if (win.GetLastError() == win.ERROR_INVALID_PARAMETER) .gone else .unknown;
    };
    var created: win.FILETIME = undefined;
    var unused: win.FILETIME = undefined;
    if (win.GetProcessTimes(process, &created, &unused, &unused, &unused) == 0) {
        _ = win.CloseHandle(process);
        return .unknown;
    }
    if (fileTime(created) != record.start_time) {
        // A later process reused the PID: the recorded one is gone.
        _ = win.CloseHandle(process);
        return .gone;
    }
    return .{ .open = process };
}

fn liveness(record: contract.Record) Liveness {
    return switch (openRecorded(record, win.SYNCHRONIZE)) {
        .gone => .gone,
        .unknown => .unknown,
        .open => |process| live: {
            defer _ = win.CloseHandle(process);
            break :live if (win.WaitForSingleObject(process, 0) == win.WAIT_OBJECT_0) .gone else .alive;
        },
    };
}

/// Wait for the process `record` names to be gone, up to `timeout_ms`.
/// Returns whether it is. Windows can start a restart before the crashed
/// host has exited (host_contract.predecessor_wait_ms), and until it has,
/// it still owns the singleton.
pub fn waitForExit(record: contract.Record, timeout_ms: u32) bool {
    return switch (openRecorded(record, win.SYNCHRONIZE)) {
        .gone => true,
        .unknown => false,
        .open => |process| gone: {
            defer _ = win.CloseHandle(process);
            break :gone win.WaitForSingleObject(process, timeout_ms) == win.WAIT_OBJECT_0;
        },
    };
}

/// The running host's process, if its record names it.
fn hostProcess(paths: Paths, access: win.DWORD) ?win.HANDLE {
    return openLive(crash_record.read(paths.record) orelse return null, access);
}

/// The process `record` names, opened with `access`, if it still runs. One
/// that has exited is not the running host, though it can still be opened
/// while anything holds a handle to it, and its creation time still
/// matches: the crashed host a record names in the moment after Windows
/// restarted the next one, before that one opens the record.
fn openLive(record: contract.Record, access: win.DWORD) ?win.HANDLE {
    return switch (openRecorded(record, access | win.SYNCHRONIZE)) {
        .open => |process| if (win.WaitForSingleObject(process, 0) == win.WAIT_OBJECT_0) gone: {
            _ = win.CloseHandle(process);
            break :gone null;
        } else process,
        else => null,
    };
}

// ---- The verbs ------------------------------------------------------------

pub fn run(verb: Verb, io: std.Io, allocator: std.mem.Allocator, paths: Paths) Exit {
    return switch (verb) {
        .up => up(paths),
        .down => down(paths),
        .status => status(io, allocator, paths),
        .reload => reload(paths),
        .probe => probe(),
    } catch |err| fail("weaver-widget --{s}: {s}", .{ @tagName(verb), @errorName(err) });
}

fn fail(comptime format: []const u8, args: anytype) Exit {
    std.debug.print(format ++ "\n", args);
    return .failed;
}

fn probe() !Exit {
    if (!hostRunning()) return .not_running;
    if (controlReady()) return .ok;
    return if (hostRunning()) .legacy else .not_running;
}

/// The host it starts inherits this process's environment, so `paths` are
/// the host's too.
fn up(paths: Paths) !Exit {
    const lock = Lock.acquire(client_lock_wait_ms) catch return .busy;
    var locked = true;
    defer if (locked) lock.release();
    try clearMarker(paths);
    if (hostRunning()) {
        if (!shutdownSignalled()) return if (controlReady()) .already_running else .legacy;
        // It is on its way out (a `weaver down` that gave up waiting, or
        // its own stop): wait for it, then start the next.
        const deadline = win.GetTickCount64() + down_grace_ms + terminate_wait_ms;
        while (hostRunning() and win.GetTickCount64() < deadline) win.Sleep(poll_ms);
        if (hostRunning()) return fail("the widget host is shutting down and did not exit within {d} ms; run 'weaver down', then 'weaver up'", .{down_grace_ms + terminate_wait_ms});
    }
    const process = try startHost();
    defer _ = win.CloseHandle(process);
    // The host takes the lock itself before it publishes control.
    lock.release();
    locked = false;
    const deadline = win.GetTickCount64() + up_wait_ms;
    while (win.GetTickCount64() < deadline) {
        if (hostRunning() and objectExists(.event, contract.status_written_event)) return .ok;
        if (win.WaitForSingleObject(process, poll_ms) == win.WAIT_OBJECT_0) {
            var code: win.DWORD = 0;
            _ = win.GetExitCodeProcess(process, &code);
            return switch (code) {
                contract.exit_stopped => fail("the widget host exited as it started: 'weaver down' ran meanwhile", .{}),
                contract.exit_already_running => .already_running,
                contract.exit_record_unavailable => recordUnavailable(paths),
                else => fail("the widget host exited as it started, with code 0x{X:0>8}; 'weaver status' says what its record holds", .{code}),
            };
        }
    }
    return .timed_out;
}

/// A host exited for want of its record (main.zig `openRecord`): name the
/// file and what Windows answers for it now.
fn recordUnavailable(paths: Paths) Exit {
    const err = crash_record.openFailure(paths.record) orelse
        return fail("the widget host could not open its record at {s} within record_open_wait_ms={d}, and exited; nothing holds it now, so run 'weaver up' again", .{ paths.record, contract.record_open_wait_ms });
    return fail("the widget host could not open its record at {s} (Win32 error {d}{s}), and exited: without it, it cannot quarantine the widget a crash blames. Close whatever holds that file, then run 'weaver up'", .{ paths.record, err, sharingWords(err) });
}

fn sharingWords(win32_error: u32) []const u8 {
    return if (win32_error == win.ERROR_SHARING_VIOLATION) ": another program holds it open" else "";
}

/// `"<this executable>" --host`, with this process's environment.
fn startHost() !win.HANDLE {
    var exe: [32768:0]u16 = undefined;
    const length = win.GetModuleFileNameW(null, &exe, exe.len);
    if (length == 0 or length >= exe.len) return error.ExecutablePathFailed;
    exe[length] = 0;
    var line: [32768 + 16:0]u16 = undefined;
    var at: usize = 0;
    for ([_][]const u16{ std.unicode.utf8ToUtf16LeStringLiteral("\""), exe[0..length], std.unicode.utf8ToUtf16LeStringLiteral("\" --host") }) |part| {
        @memcpy(line[at .. at + part.len], part);
        at += part.len;
    }
    line[at] = 0;
    var startup = std.mem.zeroes(win.STARTUPINFOW);
    startup.cb = @sizeOf(win.STARTUPINFOW);
    // No busy cursor while it starts: it is a background process.
    startup.dwFlags = win.STARTF_FORCEOFFFEEDBACK;
    var info = std.mem.zeroes(win.PROCESS_INFORMATION);
    if (win.CreateProcessW(&exe, &line, null, null, 0, win.CREATE_NEW_PROCESS_GROUP, null, null, &startup, &info) == 0) return error.CreateProcessFailed;
    _ = win.CloseHandle(info.hThread);
    return info.hProcess;
}

fn down(paths: Paths) !Exit {
    const lock = Lock.acquire(client_lock_wait_ms) catch return .busy;
    defer lock.release();
    // Written before anything else: a host Windows is about to restart, or
    // one starting now, finds it and exits.
    try writeMarker(paths);
    if (!hostRunning()) return .not_running;
    const process = hostProcess(paths, win.SYNCHRONIZE | win.PROCESS_TERMINATE);
    defer if (process) |handle| {
        _ = win.CloseHandle(handle);
    };
    if (win.OpenEventW(win.EVENT_MODIFY_STATE, 0, contract.shutdown_event)) |event| {
        _ = win.SetEvent(event);
        _ = win.CloseHandle(event);
    }
    if (process) |handle| {
        if (win.WaitForSingleObject(handle, down_grace_ms) != win.WAIT_OBJECT_0) {
            // Its management is stuck: stop it. Its record stays `running`,
            // but the marker says it was stopped.
            _ = win.TerminateProcess(handle, contract.exit_stopped_by_down);
            _ = win.WaitForSingleObject(handle, terminate_wait_ms);
        }
    }
    // Without a process to wait on (a host whose record is not this
    // version's), wait for its singleton to go.
    const deadline = win.GetTickCount64() + (if (process == null) down_grace_ms else 0) + terminate_wait_ms;
    while (hostRunning() and win.GetTickCount64() < deadline) win.Sleep(poll_ms);
    if (hostRunning()) return fail("the widget host did not stop within {d} ms of 'weaver down'", .{down_grace_ms + terminate_wait_ms});
    return .ok;
}

fn status(io: std.Io, allocator: std.mem.Allocator, paths: Paths) !Exit {
    // A host whose record holds a crash is dying: it keeps the singleton
    // while Windows reports the crash, seconds after its last status.
    if (!hostRunning() or hostCrashed(paths)) return printDown(io, allocator, paths);
    // A host that exits before publishing control (main.zig `openRecord`)
    // is down, not one that predates control.
    if (!controlReady()) return if (hostRunning()) .legacy else printDown(io, allocator, paths);
    const access = win.SYNCHRONIZE | win.EVENT_MODIFY_STATE;
    const written = win.OpenEventW(access, 0, contract.status_written_event) orelse return printDown(io, allocator, paths);
    defer _ = win.CloseHandle(written);
    const request = win.OpenEventW(win.EVENT_MODIFY_STATE, 0, contract.status_request_event) orelse return printDown(io, allocator, paths);
    defer _ = win.CloseHandle(request);
    const process = hostProcess(paths, win.SYNCHRONIZE);
    defer if (process) |handle| {
        _ = win.CloseHandle(handle);
    };
    if (win.ResetEvent(written) == 0 or win.SetEvent(request) == 0) return error.SignalFailed;
    var handles = [_]win.HANDLE{ written, process orelse null };
    const count: win.DWORD = if (process != null) 2 else 1;
    return switch (win.WaitForMultipleObjects(count, &handles, 0, status_answer_wait_ms)) {
        win.WAIT_OBJECT_0 => .ok,
        // It died, or crashed while it was asked: its last status is stale.
        win.WAIT_OBJECT_0 + 1 => printDown(io, allocator, paths),
        else => if (hostCrashed(paths)) printDown(io, allocator, paths) else .timed_out,
    };
}

/// The running host's own record holds a crash: the process the record
/// names is alive (Windows is reporting the crash) and has one.
fn hostCrashed(paths: Paths) bool {
    const record = crash_record.read(paths.record) orelse return false;
    if (record.crash.kind == .none or record.state != .running) return false;
    return liveness(record) == .alive;
}

fn printDown(io: std.Io, allocator: std.mem.Allocator, paths: Paths) !Exit {
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    try describeDown(io, allocator, paths, &stdout.interface);
    try stdout.interface.flush();
    return .not_running;
}

fn reload(paths: Paths) !Exit {
    const signal_mutex = win.CreateMutexW(null, 0, contract.reload_signal_mutex) orelse return error.CreateMutexFailed;
    defer _ = win.CloseHandle(signal_mutex);
    const mutex_wait = win.WaitForSingleObject(signal_mutex, reload_signal_wait_ms);
    if (mutex_wait != win.WAIT_OBJECT_0 and mutex_wait != win.WAIT_ABANDONED) return .busy;
    defer _ = win.ReleaseMutex(signal_mutex);

    if (!hostRunning()) return .not_running;
    // A host still starting (retrying its record) has no events yet.
    if (!controlReady()) return if (hostRunning()) .legacy else .not_running;
    const access = win.SYNCHRONIZE | win.EVENT_MODIFY_STATE;
    const success = win.OpenEventW(access, 0, contract.reload_success_event) orelse return .legacy;
    defer _ = win.CloseHandle(success);
    const failure = win.OpenEventW(access, 0, contract.reload_failure_event) orelse return .legacy;
    defer _ = win.CloseHandle(failure);
    const event = win.OpenEventW(win.EVENT_MODIFY_STATE, 0, contract.reload_event) orelse return .not_running;
    defer _ = win.CloseHandle(event);
    // A host that dies before it answers would leave this waiting out its
    // whole budget, and Windows restarts it 5-37 s later at best: its exit
    // answers instead.
    const process = hostProcess(paths, win.SYNCHRONIZE);
    defer if (process) |handle| {
        _ = win.CloseHandle(handle);
    };
    if (win.ResetEvent(success) == 0 or win.ResetEvent(failure) == 0) return error.SignalFailed;
    if (win.SetEvent(event) == 0) return error.SignalFailed;
    var handles = [_]win.HANDLE{ success, failure, process orelse null };
    const count: win.DWORD = if (process != null) 3 else 2;
    return switch (win.WaitForMultipleObjects(count, &handles, 0, reload_answer_wait_ms)) {
        win.WAIT_OBJECT_0 => .ok,
        win.WAIT_OBJECT_0 + 1 => .reload_failed,
        win.WAIT_OBJECT_0 + 2 => .host_crashed,
        else => .timed_out,
    };
}

// ---- The host's own log ------------------------------------------------------

/// `host.log` past this size moves to `host.log.old`: when a host starts,
/// and before each note a running host writes (`note`). A host writes a
/// line or two per start, crash or failed reload (about 150 bytes each), so
/// 1 MiB is thousands of them: only a host that logs in a loop reaches it,
/// and then the two files hold at most 2 MiB.
const host_log_max_bytes: u64 = 1024 * 1024;

/// The open host.log, append-only, that stderr points at; null outside a
/// daemon host. Zig keeps the stderr handle it first saw, so a running
/// host rotates the file under this handle rather than swapping handles.
var log_file: ?win.HANDLE = null;
var log_path: [1024]u8 = undefined;
var log_path_len: usize = 0;
/// Serializes `note`, so a rotation never cuts a line in half.
var log_lock: win.SRWLOCK = std.mem.zeroes(win.SRWLOCK);

/// Send this host's stderr (daemon.zig `note`, startup errors) to
/// `<logs>\host.log`, appended: a GUI-subsystem host has no console, and a
/// host Windows restarted has no parent to read it.
pub fn logToFile(log_directory: []const u8) void {
    var wide: WidePath = .{};
    _ = win.CreateDirectoryW(wide.of(log_directory) catch return, null);
    var path_buffer: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "{s}\\host.log", .{log_directory}) catch return;
    var data: win.WIN32_FILE_ATTRIBUTE_DATA = undefined;
    if (win.GetFileAttributesExW(wide.of(path) catch return, win.GetFileExInfoStandard, &data) != 0) {
        const size = (@as(u64, data.nFileSizeHigh) << 32) | data.nFileSizeLow;
        if (size > host_log_max_bytes) {
            var old_buffer: [1024]u8 = undefined;
            const old = std.fmt.bufPrint(&old_buffer, "{s}.old", .{path}) catch return;
            var old_wide: WidePath = .{};
            _ = win.MoveFileExW(wide.of(path) catch return, old_wide.of(old) catch return, win.MOVEFILE_REPLACE_EXISTING);
        }
    }
    const file = win.CreateFileW(wide.of(path) catch return, win.FILE_APPEND_DATA, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE, null, win.OPEN_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, null);
    if (file == win.INVALID_HANDLE_VALUE) return;
    _ = win.SetStdHandle(win.STD_ERROR_HANDLE, file);
    @memcpy(log_path[0..path.len], path);
    log_path_len = path.len;
    log_file = file;
}

/// A host note on stderr (host.log in a daemon host), after rotating the
/// log if it has passed `host_log_max_bytes`. Everything a running host
/// writes more than once per start goes through here (daemon.zig `note`,
/// dev_widgets.zig).
pub fn note(comptime format: []const u8, args: anytype) void {
    win.AcquireSRWLockExclusive(&log_lock);
    defer win.ReleaseSRWLockExclusive(&log_lock);
    rotateIfFull();
    std.debug.print(format, args);
}

fn rotateIfFull() void {
    rotate(log_file orelse return, log_path[0..log_path_len], host_log_max_bytes);
}

/// The log at `path`, open as `file`, past `max_bytes`: copy it to
/// `<path>.old`, then empty it through a second handle. `file` appends, so
/// it writes on at the new end of the file. While the copy fails (something
/// holds the archive open) the log is kept whole, and the next note tries
/// again.
fn rotate(file: win.HANDLE, path: []const u8, max_bytes: u64) void {
    var size: win.LARGE_INTEGER = std.mem.zeroes(win.LARGE_INTEGER);
    if (win.GetFileSizeEx(file, &size) == 0 or @as(u64, @intCast(size.QuadPart)) <= max_bytes) return;
    var wide: WidePath = .{};
    var old_buffer: [1024]u8 = undefined;
    const old = std.fmt.bufPrint(&old_buffer, "{s}.old", .{path}) catch return;
    var old_wide: WidePath = .{};
    if (win.CopyFileW(wide.of(path) catch return, old_wide.of(old) catch return, 0) == 0) return;
    const truncate = win.CreateFileW(wide.of(path) catch return, win.GENERIC_WRITE, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE, null, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, null);
    if (truncate == win.INVALID_HANDLE_VALUE) return;
    defer _ = win.CloseHandle(truncate);
    _ = win.SetEndOfFile(truncate);
}

/// The first line a host writes: who it is, and how it was started.
pub fn logStart(restart_of: ?u64) void {
    var clock: [8]u8 = undefined;
    const now = nowFileTime();
    if (restart_of) |generation| {
        std.debug.print("{s} host {d}: restarted by Windows after the crash of generation {d}\n", .{ localClock(now, &clock), win.GetCurrentProcessId(), generation });
    } else {
        std.debug.print("{s} host {d}: started\n", .{ localClock(now, &clock), win.GetCurrentProcessId() });
    }
}

// ---- Windows' restart -------------------------------------------------------

extern "kernel32" fn RegisterApplicationRestart(command_line: [*:0]const u16, flags: u32) callconv(.winapi) i32;

pub const Registration = struct {
    request: contract.RestartRequest,
    /// RegisterApplicationRestart's HRESULT when it refused.
    hresult: u32 = 0,
    /// The restart command line's length in UTF-16 units.
    line_len: u32 = 0,
};

/// E_INVALIDARG, what RegisterApplicationRestart answers a command line
/// past its limit; reported the same way when this host does not try.
const e_invalidarg: u32 = 0x8007_0057;

/// Ask Windows to restart this host after a crash, with the profile it runs
/// against (`contract.local_app_data_flag`) and `generation`, the one this
/// start's record holds; unless the cap says not to (`plan.register`).
pub fn registerRestart(plan: contract.RestartPlan, generation: u64, local_app_data: []const u8) Registration {
    if (!plan.register) return .{ .request = .capped };
    var line: RestartLine = undefined;
    const length = restartLine(&line, generation, local_app_data) catch return .{ .request = .failed, .hresult = e_invalidarg };
    if (length >= line.len) return .{ .request = .failed, .hresult = e_invalidarg, .line_len = length };
    const result = RegisterApplicationRestart(&line, contract.restart_flags);
    if (result == 0) return .{ .request = .registered, .line_len = length };
    return .{ .request = .failed, .hresult = @bitCast(result), .line_len = length };
}

const RestartLine = [contract.restart_max_command_line:0]u16;

/// The restart command line in `line`, and its length in UTF-16 units. A
/// length of `line.len` or more did not fit, and left `line` unwritten.
fn restartLine(line: *RestartLine, generation: u64, local_app_data: []const u8) !u32 {
    // A trailing backslash would escape the closing quote. The path is not
    // escaped otherwise: Windows refuses `"` in file and directory names.
    const profile = std.mem.trimEnd(u8, local_app_data, "\\");
    var head_buffer: [64]u8 = undefined;
    const head = std.fmt.bufPrint(&head_buffer, "--host {s} {d} {s} \"", .{ contract.restart_of_flag, generation, contract.local_app_data_flag }) catch unreachable;
    const length: u32 = @intCast(head.len + try std.unicode.calcUtf16LeLen(profile) + 1);
    if (length >= line.len) return length;
    var at = std.unicode.utf8ToUtf16Le(line, head) catch unreachable;
    at += std.unicode.utf8ToUtf16Le(line[at..], profile) catch unreachable;
    line[at] = '"';
    line[length] = 0;
    return length;
}

/// What status's host row says about how this host runs, empty when there
/// is nothing to say: the crash Windows restarted it from and which restart
/// that is against the cap, and that Windows refused its restart request.
/// The last means a crash would leave Weaver down, so it also prints on
/// `weaver up` (cli/src/index.ts).
pub fn hostNote(allocator: std.mem.Allocator, previous: ?contract.Record, restarted: bool, plan: contract.RestartPlan, registration: Registration) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    const writer = &output.writer;
    if (restarted) {
        const crash = if (previous) |record| record.crash else contract.Crash{};
        if (crash.kind == .none) {
            try writer.writeAll("restarted by Windows after the last host ended without recording a crash");
        } else {
            var clock: [8]u8 = undefined;
            try writer.print("restarted by Windows after the last host crashed at {s} ({s})", .{ localClock(crash.time, &clock), crashWords(crash) });
        }
        try writer.print("; automatic restart {d} of restart_cap={d} within {d} minutes", .{ plan.count, contract.restart_cap, contract.restart_window_ms / 60_000 });
        if (registration.request == .capped) try writer.writeAll("; that is the cap, so if this host crashes it stays down until 'weaver up'");
    }
    if (registration.request == .failed) {
        if (output.written().len > 0) try writer.writeAll("; ");
        try writer.writeAll("Windows will not restart this host after a crash: ");
        if (registration.line_len >= contract.restart_max_command_line) {
            try writer.print("its restart command line carries the profile path and is {d} UTF-16 units, past RegisterApplicationRestart's limit of {d} with its terminator (restart_max_command_line). Set LOCALAPPDATA to a path at least {d} characters shorter, then run 'weaver down' and 'weaver up'", .{ registration.line_len, contract.restart_max_command_line, registration.line_len - contract.restart_max_command_line + 1 });
        } else {
            try writer.print("RegisterApplicationRestart refused with HRESULT 0x{X:0>8}. Run 'weaver down', then 'weaver up' to try again", .{registration.hresult});
        }
    }
    return output.toOwnedSlice();
}

fn crashWords(crash: contract.Crash) []const u8 {
    if (crash.code == contract.exit_wedged) return "its UI thread was stuck past the apply deadline";
    return switch (crash.kind) {
        .widget_turn => if (crash.code == contract.panic_code) "a panic in a widget's turn; that widget is quarantined" else "an exception in a widget's turn; that widget is quarantined",
        .ui => "on its UI thread, outside any widget's turn",
        else => "on a provider or management thread",
    };
}

/// A FILETIME as HH:MM:SS in this machine's time zone.
fn localClock(file_time: u64, buffer: *[8]u8) []const u8 {
    const utc: win.FILETIME = .{ .dwLowDateTime = @truncate(file_time), .dwHighDateTime = @truncate(file_time >> 32) };
    var system: win.SYSTEMTIME = undefined;
    var local: win.SYSTEMTIME = undefined;
    if (win.FileTimeToSystemTime(&utc, &system) == 0 or win.SystemTimeToTzSpecificLocalTime(null, &system, &local) == 0) return "??:??:??";
    return std.fmt.bufPrint(buffer, "{d:0>2}:{d:0>2}:{d:0>2}", .{ local.wHour, local.wMinute, local.wSecond }) catch unreachable;
}

// ---- Status while no host runs --------------------------------------------

/// What the stop marker and the last host's record say, as one JSON object
/// on `writer`, for `weaver status` to word (cli/src/index.ts
/// `describeHostDown`). Facts only: times are Unix milliseconds, so the CLI
/// prints them in the reader's zone.
pub fn describeDown(io: std.Io, allocator: std.mem.Allocator, paths: Paths, writer: *std.Io.Writer) !void {
    try writer.writeAll("{\"stopped\":");
    if (markerTime(paths)) |time| try writer.print("{{\"at\":{d}}}", .{unixMs(time)}) else try writer.writeAll("null");
    try writer.print(",\"now\":{d},\"recordPath\":{f}", .{ unixMs(nowFileTime()), std.json.fmt(paths.record, .{}) });
    // The numbers the CLI words the restart with, from their one definition.
    try writer.print(",\"restartCap\":{d},\"restartWindowMs\":{d},\"minRunMs\":{d},\"restartWaitMs\":{d},\"restartMeasuredMs\":{d}", .{ contract.restart_cap, contract.restart_window_ms, contract.os_restart_min_run_ms, contract.os_restart_wait_ms, contract.os_restart_measured_max_ms });
    const last = crash_record.read(paths.record);
    // A record no live host holds that a host still could not open: the
    // next host would exit for it (main.zig `openRecord`).
    const live = if (last) |found| liveness(found) == .alive else false;
    try writer.writeAll(",\"recordHeld\":");
    if (if (live) null else crash_record.openFailure(paths.record)) |err| {
        try writer.print("{{\"error\":{d},\"sharing\":{}}}", .{ err, err == win.ERROR_SHARING_VIOLATION });
    } else try writer.writeAll("null");
    try writer.writeAll(",\"record\":");
    const record = last orelse {
        try writer.writeAll("null}\n");
        return;
    };
    const state = switch (record.state) {
        .running => "running",
        .stopped => "stopped",
        else => "none",
    };
    const process = switch (liveness(record)) {
        .gone => "gone",
        .alive => "alive",
        .unknown => "unknown",
    };
    const stop_reason = record.stop_reason[0..@min(record.stop_reason_len, record.stop_reason.len)];
    try writer.print("{{\"generation\":{d},\"pid\":{d},\"state\":\"{s}\",\"process\":\"{s}\",\"startedAt\":{d},\"stopReason\":{f},\"crash\":", .{
        record.generation, record.pid, state, process, unixMs(record.start_time), std.json.fmt(stop_reason, .{}),
    });
    if (record.crash.kind == .none) {
        try writer.writeAll("null");
    } else {
        const kind = switch (record.crash.kind) {
            .widget_turn => "widget",
            .ui => "ui",
            else => "other",
        };
        const cause = switch (record.crash.code) {
            contract.panic_code => "panic",
            contract.exit_wedged => "wedged",
            else => "exception",
        };
        try writer.print("{{\"kind\":\"{s}\",\"cause\":\"{s}\",\"code\":{d},\"at\":{d},\"widget\":", .{ kind, cause, record.crash.code, unixMs(record.crash.time) });
        var name_buffer: [supervisor.max_name_bytes]u8 = undefined;
        if (culprit(io, allocator, paths, record, &name_buffer)) |name| try writer.print("{f}", .{std.json.fmt(name, .{})}) else try writer.writeAll("null");
        try writer.writeAll("}");
    }
    const request = switch (record.restart) {
        .registered => "registered",
        .capped => "capped",
        .failed => "failed",
        else => "none",
    };
    try writer.print(",\"restart\":\"{s}\",\"restartError\":{d},\"restartLineLength\":{d},\"restartLineLimit\":{d},\"automaticRestarts\":[", .{ request, record.restart_error, record.restart_line_len, contract.restart_max_command_line });
    for (record.restarts[0..@min(record.restart_count, contract.restart_cap)], 0..) |time, index| {
        if (index > 0) try writer.writeAll(",");
        try writer.print("{d}", .{unixMs(time)});
    }
    try writer.writeAll("]}}\n");
}

/// The registered name of the widget whose turn crashed the host, matched
/// by the hash its slot recorded.
fn culprit(io: std.Io, allocator: std.mem.Allocator, paths: Paths, record: contract.Record, buffer: []u8) ?[]const u8 {
    if (record.crash.kind != .widget_turn or record.crash.slot == 0 or record.crash.slot > record.slots.len) return null;
    const hash = record.slots[record.crash.slot - 1].name_hash;
    if (hash == 0) return null;
    const max_registry_bytes = 256 * 1024;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, paths.registry, allocator, .limited(max_registry_bytes)) catch return null;
    defer allocator.free(bytes);
    const parsed = supervisor.registry.parse(allocator, bytes) catch return null;
    defer parsed.deinit();
    for (parsed.value.widgets) |widget| {
        if (contract.nameHash(widget.name) != hash or widget.name.len > buffer.len) continue;
        @memcpy(buffer[0..widget.name.len], widget.name);
        return buffer[0..widget.name.len];
    }
    return null;
}

fn fileTime(value: win.FILETIME) u64 {
    return (@as(u64, value.dwHighDateTime) << 32) | value.dwLowDateTime;
}

fn nowFileTime() u64 {
    var now: win.FILETIME = undefined;
    win.GetSystemTimeAsFileTime(&now);
    return fileTime(now);
}

/// A FILETIME (100 ns since 1601) as milliseconds since 1970.
pub fn unixMs(file_time: u64) i64 {
    const epoch_difference: i64 = 116_444_736_000_000_000;
    return @divFloor(@as(i64, @intCast(file_time)) - epoch_difference, 10_000);
}

test "client verbs parse by their flag only" {
    try std.testing.expectEqual(Verb.down, Verb.parse("--down").?);
    try std.testing.expectEqual(Verb.probe, Verb.parse("--probe").?);
    try std.testing.expect(Verb.parse("down") == null);
    try std.testing.expect(Verb.parse("--host") == null);
}

test "FILETIMEs read as Unix milliseconds" {
    try std.testing.expectEqual(@as(i64, 0), unixMs(116_444_736_000_000_000));
    try std.testing.expectEqual(@as(i64, 1_000), unixMs(116_444_736_010_000_000));
}

test "the host note names a restart request Windows refused" {
    const allocator = std.testing.allocator;
    const plan: contract.RestartPlan = .{};
    // Nothing to say about a fresh host Windows accepted.
    const quiet = try hostNote(allocator, null, false, plan, .{ .request = .registered, .line_len = 60 });
    defer allocator.free(quiet);
    try std.testing.expectEqualStrings("", quiet);
    const long = try hostNote(allocator, null, false, plan, .{ .request = .failed, .hresult = e_invalidarg, .line_len = 1028 });
    defer allocator.free(long);
    try std.testing.expect(std.mem.indexOf(u8, long, "is 1028 UTF-16 units, past RegisterApplicationRestart's limit of 1024") != null);
    try std.testing.expect(std.mem.indexOf(u8, long, "at least 5 characters shorter") != null);
}

test "the restart command line counts UTF-16 units, and the shortening status asks for fits" {
    var line: RestartLine = undefined;
    const short = try restartLine(&line, 7, "C:\\Users\\Zoë\\AppData\\Local\\");
    const expected = std.unicode.utf8ToUtf16LeStringLiteral("--host --restart-of 7 --localappdata \"C:\\Users\\Zoë\\AppData\\Local\"");
    try std.testing.expectEqualSlices(u16, expected, line[0..short]);
    try std.testing.expectEqual(@as(u16, 0), line[short]);
    // A profile path past the limit, with a character outside the BMP (two
    // UTF-16 units, four UTF-8 bytes).
    const allocator = std.testing.allocator;
    const head_len = "--host --restart-of 7 --localappdata \"".len;
    const long_profile = try allocator.alloc(u8, 1028 - head_len - 1 - 2 + 4);
    defer allocator.free(long_profile);
    @memset(long_profile, 'a');
    @memcpy(long_profile[0..4], "😀");
    const long = try restartLine(&line, 7, long_profile);
    try std.testing.expectEqual(@as(u32, 1028), long);
    // hostNote's advice: this many characters shorter.
    const shorter = long - contract.restart_max_command_line + 1;
    try std.testing.expect(try restartLine(&line, 7, long_profile[0 .. long_profile.len - shorter]) < line.len);
    try std.testing.expect(try restartLine(&line, 7, long_profile[0 .. long_profile.len - shorter + 1]) >= line.len);
}

test "a full host.log moves to host.log.old, and stays whole while the archive cannot be written" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "host.log" });
    defer std.testing.allocator.free(path);
    const old = try std.fmt.allocPrint(std.testing.allocator, "{s}.old", .{path});
    defer std.testing.allocator.free(old);
    var wide: WidePath = .{};
    const file = win.CreateFileW(try wide.of(path), win.FILE_APPEND_DATA, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE, null, win.OPEN_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, null);
    try std.testing.expect(file != win.INVALID_HANDLE_VALUE);
    defer _ = win.CloseHandle(file);
    const line = "a line of the host's log, 40 bytes long\n";
    const append = struct {
        fn lines(handle: win.HANDLE, count: usize) !void {
            for (0..count) |_| {
                var written: win.DWORD = 0;
                if (win.WriteFile(handle, line, line.len, &written, null) == 0) return error.WriteFailed;
            }
        }
    }.lines;
    const sizeOf = struct {
        fn of(file_path: []const u8) !u64 {
            var name: WidePath = .{};
            var data: win.WIN32_FILE_ATTRIBUTE_DATA = undefined;
            if (win.GetFileAttributesExW(try name.of(file_path), win.GetFileExInfoStandard, &data) == 0) return error.NoFile;
            return (@as(u64, data.nFileSizeHigh) << 32) | data.nFileSizeLow;
        }
    }.of;
    // Under the cap: untouched.
    try append(file, 2);
    rotate(file, path, 100);
    try std.testing.expectEqual(@as(u64, 80), try sizeOf(path));
    // Past it: archived whole, then emptied; the append handle writes on
    // from the start.
    try append(file, 1);
    rotate(file, path, 100);
    try std.testing.expectEqual(@as(u64, 120), try sizeOf(old));
    try std.testing.expectEqual(@as(u64, 0), try sizeOf(path));
    try append(file, 1);
    try std.testing.expectEqual(@as(u64, 40), try sizeOf(path));
    // The archive held open against writers: the log keeps every line.
    var old_wide: WidePath = .{};
    const holder = win.CreateFileW(try old_wide.of(old), win.GENERIC_READ, win.FILE_SHARE_READ, null, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, null);
    try std.testing.expect(holder != win.INVALID_HANDLE_VALUE);
    try append(file, 2);
    rotate(file, path, 100);
    try std.testing.expectEqual(@as(u64, 120), try sizeOf(path));
    try std.testing.expectEqual(@as(u64, 120), try sizeOf(old));
    // Released: the next note's rotation archives it.
    _ = win.CloseHandle(holder);
    rotate(file, path, 100);
    try std.testing.expectEqual(@as(u64, 120), try sizeOf(old));
    try std.testing.expectEqual(@as(u64, 0), try sizeOf(path));
}

test "a recorded process that has exited is not the running host" {
    // A suspended copy of this test binary: it never runs.
    var exe: [32768:0]u16 = undefined;
    const length = win.GetModuleFileNameW(null, &exe, exe.len);
    try std.testing.expect(length > 0 and length < exe.len);
    exe[length] = 0;
    var startup = std.mem.zeroes(win.STARTUPINFOW);
    startup.cb = @sizeOf(win.STARTUPINFOW);
    var info = std.mem.zeroes(win.PROCESS_INFORMATION);
    try std.testing.expect(win.CreateProcessW(&exe, null, null, null, 0, win.CREATE_SUSPENDED, null, null, &startup, &info) != 0);
    _ = win.CloseHandle(info.hThread);
    // This handle keeps the process openable after it exits.
    defer _ = win.CloseHandle(info.hProcess);
    var created: win.FILETIME = undefined;
    var unused: win.FILETIME = undefined;
    try std.testing.expect(win.GetProcessTimes(info.hProcess, &created, &unused, &unused, &unused) != 0);
    var record = std.mem.zeroes(contract.Record);
    record.pid = info.dwProcessId;
    record.start_time = fileTime(created);
    const alive = openLive(record, win.SYNCHRONIZE) orelse return error.NotOpened;
    _ = win.CloseHandle(alive);
    _ = win.TerminateProcess(info.hProcess, 1);
    try std.testing.expect(win.WaitForSingleObject(info.hProcess, 5_000) == win.WAIT_OBJECT_0);
    try std.testing.expect(openLive(record, win.SYNCHRONIZE) == null);
    try std.testing.expectEqual(Liveness.gone, liveness(record));
}
