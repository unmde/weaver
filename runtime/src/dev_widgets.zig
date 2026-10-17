//! Dev widgets (`weaver dev`) in the daemon host (ADR 0022 steps 3, 4). Each
//! keeps a process of its own, so its hot swaps touch only it, but the host
//! launches it, inside a job object only the host holds: when the host dies,
//! for whatever reason, Windows ends its dev widgets too, and none runs on
//! without its providers. A dev widget gets its providers from the host over
//! a pipe only its own process may open, in the line protocol it spoke to
//! weaverd before (provider_windows.Client).
//!
//! The host's management thread (daemon.zig) decides when a dev widget runs
//! and watches its process. All of this runs on that thread and the dev
//! widget's own reader and writer threads; widgets in the host and the UI
//! thread are never involved. The shared renderer runs in the same job
//! (`startInJob`).
const std = @import("std");
const media_commands = @import("host_providers").media_commands;
const host_control = @import("host_control.zig");
const protocol = @import("provider_protocol.zig");
const provider_service = @import("provider_service.zig");
const widget_log = @import("widget_log.zig");

const win = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
});

/// Dev widget ids are the daemon's registry slots (host/src/supervisor.zig
/// max_widgets).
pub const max_dev_widgets: usize = 32;
/// How long a dev widget has to open its provider pipe: weaverd's wait for
/// the same pipe before the host served it, which dev loads have always met.
pub const connect_timeout_ms: u64 = 5_000;
/// The provider pipe's buffers and its writes' deadline, as weaverd had them.
const pipe_buffer_bytes: u32 = 8192;
const write_timeout_ms: u32 = 1000;
/// Initial stack commit of a dev widget's reader and writer: the writer's
/// one-frame buffer (12.5 KiB) is their largest local; the stack grows on
/// demand within the image's reservation.
const pipe_thread_stack_bytes: usize = 64 * 1024;
/// How long a graceful stop waits for the widget to close its window, then
/// for it to exit: weaverd's waits.
const close_wait_ms: u32 = 1500;
const exit_wait_ms: u32 = 1000;

const invalid_handle = win.INVALID_HANDLE_VALUE;

pub const Launch = struct {
    /// The daemon's registry slot for it.
    id: u16,
    /// Its bundle directory (`dist`).
    dir: []const u8,
    /// Where it reports its renderer (WEAVER_BACKEND_FILE).
    backend: ?[]const u8 = null,
    /// What its manifest declares; the daemon read it.
    wants: provider_service.Wants = .{},
    /// It draws through the shared renderer.
    gpu: bool = false,
};

pub const DevWidgets = struct {
    /// Every dev widget's process, and the shared renderer, is in it. Only
    /// this process holds it, and it ends them all when that handle closes,
    /// as it does when the host exits.
    job: win.HANDLE,
    service: *provider_service.Service,
    /// The host's environment, which a dev widget inherits less the
    /// host's own channels.
    environment: *const std.process.Environ.Map,
    /// The renderer and art cache the host chose, for dev widgets whose
    /// manifests use them.
    channels: Channels,
    widgets: [max_dev_widgets]?*DevWidget = @splat(null),

    pub fn init(service: *provider_service.Service, environment: *const std.process.Environ.Map, channels: Channels) !DevWidgets {
        const job = win.CreateJobObjectW(null, null) orelse return error.CreateJobFailed;
        errdefer _ = win.CloseHandle(job);
        var limits = std.mem.zeroes(win.JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
        limits.BasicLimitInformation.LimitFlags = win.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (win.SetInformationJobObject(job, win.JobObjectExtendedLimitInformation, &limits, @sizeOf(@TypeOf(limits))) == 0) return error.SetJobLimitsFailed;
        return .{ .job = job, .service = service, .environment = environment, .channels = channels };
    }

    /// Launch dev widget `request.id`: its PID, once it has opened its
    /// provider pipe (when it subscribes to anything).
    pub fn launch(self: *DevWidgets, request: Launch) !u32 {
        if (request.id >= max_dev_widgets) return error.DevIdOutOfRange;
        if (self.widgets[request.id] != null) return error.DevWidgetRunning;
        const widget = try std.heap.page_allocator.create(DevWidget);
        widget.* = .{ .service = self.service };
        errdefer {
            widget.close(false);
            std.heap.page_allocator.destroy(widget);
        }
        try widget.start(self, request);
        self.widgets[request.id] = widget;
        return widget.pid;
    }

    /// Dev widget `id`'s process while it runs: the daemon watches it exit
    /// and samples its cost. The handle stays valid until `stop`.
    pub fn process(self: *const DevWidgets, id: u16) ?win.HANDLE {
        if (id >= max_dev_widgets) return null;
        const widget = self.widgets[id] orelse return null;
        return widget.process;
    }

    pub const Started = struct { process: win.HANDLE, pid: u32 };

    /// Start `command_line`, with `environment` when given, suspended; put it
    /// in the job, then let it run: from its first instruction it cannot
    /// outlive the host. The caller owns the process handle.
    pub fn startInJob(self: *DevWidgets, command_line: [:0]u16, environment: ?*const std.process.Environ.WindowsBlock) !Started {
        var startup = std.mem.zeroes(win.STARTUPINFOW);
        startup.cb = @sizeOf(win.STARTUPINFOW);
        var info = std.mem.zeroes(win.PROCESS_INFORMATION);
        const flags = win.CREATE_NO_WINDOW | win.CREATE_SUSPENDED | win.CREATE_UNICODE_ENVIRONMENT;
        const block: ?*anyopaque = if (environment) |value| @ptrCast(@constCast(value.slice.ptr)) else null;
        if (win.CreateProcessW(null, command_line.ptr, null, null, 0, flags, block, null, &startup, &info) == 0) return error.CreateProcessFailed;
        defer _ = win.CloseHandle(info.hThread);
        errdefer {
            _ = win.TerminateProcess(info.hProcess, 1);
            _ = win.CloseHandle(info.hProcess);
        }
        if (win.AssignProcessToJobObject(self.job, info.hProcess) == 0) return error.JobAssignFailed;
        if (win.ResumeThread(info.hThread) == std.math.maxInt(win.DWORD)) return error.ResumeFailed;
        return .{ .process = info.hProcess, .pid = info.dwProcessId };
    }

    /// Stop dev widget `id`: `graceful` lets it close its window first.
    pub fn stop(self: *DevWidgets, id: u16, graceful: bool) !void {
        if (id >= max_dev_widgets) return error.DevIdOutOfRange;
        const widget = self.widgets[id] orelse return error.NoDevWidget;
        self.widgets[id] = null;
        widget.close(graceful);
        std.heap.page_allocator.destroy(widget);
    }
};

const DevWidget = struct {
    service: *provider_service.Service,
    process: win.HANDLE = null,
    pid: u32 = 0,
    pipe: win.HANDLE = invalid_handle,
    /// Auto-reset: the writer has something to send.
    wake_event: win.HANDLE = null,
    /// Manual-reset: the reader and writer stop.
    shutdown_event: win.HANDLE = null,
    stopping: std.atomic.Value(bool) = .init(false),
    reader: ?std.Thread = null,
    writer: ?std.Thread = null,
    subscribed: bool = false,
    /// The frames the host has for the widget, until the writer sends them.
    queues: protocol.Queues = .{},
    /// Acknowledgements the writer has yet to send, under `ack_lock`.
    acks: [max_pending_acks]protocol.Ack = undefined,
    ack_head: usize = 0,
    ack_count: usize = 0,
    ack_lock: win.SRWLOCK = std.mem.zeroes(win.SRWLOCK),
    subscriber: provider_service.Subscriber = undefined,

    /// Acknowledgements owed at once: the commands the host has accepted and
    /// not yet run (a lane of media_commands.queue_capacity) and refusals
    /// not yet written (weaverd's lane, media_commands.nack_capacity). The
    /// widget's own four-pending limit does not bound this: a command it
    /// gave up on after its 3 s deadline is still owed an answer.
    const max_pending_acks = media_commands.queue_capacity + media_commands.nack_capacity;

    fn start(self: *DevWidget, owner: *DevWidgets, request: Launch) !void {
        const allocator = std.heap.page_allocator;
        var pipe_name_buffer: [96]u8 = undefined;
        const pipe_name: ?[]const u8 = if (request.wants.any()) name: {
            const name = try std.fmt.bufPrint(&pipe_name_buffer, "\\\\.\\pipe\\weaver-dev-{d}-{d}-{x}", .{ win.GetCurrentProcessId(), request.id, win.GetTickCount64() });
            const name_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, name);
            defer allocator.free(name_w);
            self.pipe = win.CreateNamedPipeW(
                name_w.ptr,
                win.PIPE_ACCESS_DUPLEX | win.FILE_FLAG_OVERLAPPED | win.FILE_FLAG_FIRST_PIPE_INSTANCE,
                win.PIPE_TYPE_BYTE | win.PIPE_READMODE_BYTE | win.PIPE_WAIT,
                1,
                pipe_buffer_bytes,
                pipe_buffer_bytes,
                0,
                null,
            );
            if (self.pipe == invalid_handle) return error.CreatePipeFailed;
            break :name name;
        } else null;

        const block = try environmentBlock(allocator, owner.environment, owner.channels, request, pipe_name);
        defer block.deinit(allocator);
        const command_line = try commandLine(allocator, request.dir);
        defer allocator.free(command_line);
        const started = try owner.startInJob(command_line, &block);
        self.process = started.process;
        self.pid = started.pid;
        if (pipe_name == null) return;

        if (!connectPipe(self.pipe, self.process, self.pid, connect_timeout_ms)) return error.ConnectPipeFailed;
        self.wake_event = win.CreateEventW(null, 0, 0, null) orelse return error.CreateEventFailed;
        self.shutdown_event = win.CreateEventW(null, 1, 0, null) orelse return error.CreateEventFailed;
        self.subscriber = .{
            .wants = request.wants,
            .owner = .{ .dev = request.id },
            .queues = &self.queues,
            .context = self,
            .store_ack = storeAck,
            .notify = notify,
        };
        try self.service.subscribe(&self.subscriber);
        self.subscribed = true;
        self.writer = try std.Thread.spawn(.{ .stack_size = pipe_thread_stack_bytes }, writerMain, .{self});
        self.reader = try std.Thread.spawn(.{ .stack_size = pipe_thread_stack_bytes }, readerMain, .{self});
    }

    fn close(self: *DevWidget, graceful: bool) void {
        if (self.subscribed) self.service.unsubscribe(&self.subscriber);
        self.subscribed = false;
        self.stopping.store(true, .release);
        if (self.shutdown_event) |event| _ = win.SetEvent(event);
        if (self.pipe != invalid_handle) _ = win.CancelIoEx(self.pipe, null);
        if (self.reader) |thread| thread.join();
        if (self.writer) |thread| thread.join();
        self.reader = null;
        self.writer = null;
        if (self.process) |process| {
            if (graceful) {
                closeWindowsForProcess(self.pid);
                if (win.WaitForSingleObject(process, close_wait_ms) != win.WAIT_OBJECT_0) _ = win.TerminateProcess(process, 0);
            } else _ = win.TerminateProcess(process, 0);
            _ = win.WaitForSingleObject(process, exit_wait_ms);
            _ = win.CloseHandle(process);
        }
        self.process = null;
        if (self.pipe != invalid_handle) {
            _ = win.DisconnectNamedPipe(self.pipe);
            _ = win.CloseHandle(self.pipe);
        }
        self.pipe = invalid_handle;
        if (self.wake_event) |event| _ = win.CloseHandle(event);
        if (self.shutdown_event) |event| _ = win.CloseHandle(event);
        self.wake_event = null;
        self.shutdown_event = null;
    }

    fn storeAck(context: *anyopaque, id: u64, ok: bool) provider_service.AckStore {
        const self: *DevWidget = @ptrCast(@alignCast(context));
        win.AcquireSRWLockExclusive(&self.ack_lock);
        defer win.ReleaseSRWLockExclusive(&self.ack_lock);
        if (self.ack_count == self.acks.len) return .full;
        self.acks[(self.ack_head + self.ack_count) % self.acks.len] = .{ .id = id, .ok = ok };
        self.ack_count += 1;
        return .stored;
    }

    fn takeAck(self: *DevWidget) ?protocol.Ack {
        win.AcquireSRWLockExclusive(&self.ack_lock);
        defer win.ReleaseSRWLockExclusive(&self.ack_lock);
        if (self.ack_count == 0) return null;
        const ack = self.acks[self.ack_head];
        self.ack_head = (self.ack_head + 1) % self.acks.len;
        self.ack_count -= 1;
        return ack;
    }

    fn notify(context: *anyopaque, _: provider_service.Delivery) void {
        const self: *DevWidget = @ptrCast(@alignCast(context));
        _ = win.SetEvent(self.wake_event);
    }

    /// Commands from the widget, one line each. A line that is not a
    /// command is dropped, as weaverd dropped it.
    fn readerMain(self: *DevWidget) void {
        widget_log.detachThread();
        const event = win.CreateEventW(null, 1, 0, null) orelse return self.service.fail(&self.subscriber);
        defer _ = win.CloseHandle(event);
        var storage: [media_commands.max_line_bytes * 2]u8 = undefined;
        var lines: host_control.LineReader = .{ .buffer = &storage };
        while (!self.stopping.load(.acquire)) {
            const room = lines.space();
            if (room.len == 0) return self.service.fail(&self.subscriber);
            const count = self.read(event, room) orelse return;
            lines.filled(count);
            while (lines.next()) |line| self.command(line);
        }
    }

    fn command(self: *DevWidget, line: []const u8) void {
        const value = media_commands.parse(line) catch return;
        self.service.submit(&self.subscriber, value);
    }

    /// One overlapped read; null when the widget closed its end or the
    /// widget is stopping.
    fn read(self: *DevWidget, event: win.HANDLE, buffer: []u8) ?usize {
        _ = win.ResetEvent(event);
        var overlapped = std.mem.zeroes(win.OVERLAPPED);
        overlapped.hEvent = event;
        var count: win.DWORD = 0;
        const length: win.DWORD = @intCast(@min(buffer.len, 512));
        if (win.ReadFile(self.pipe, buffer.ptr, length, &count, &overlapped) == 0) {
            if (win.GetLastError() != win.ERROR_IO_PENDING) return null;
            const handles = [_]win.HANDLE{ event, self.shutdown_event };
            const wait = win.WaitForMultipleObjects(handles.len, &handles, 0, win.INFINITE);
            if (wait != win.WAIT_OBJECT_0) {
                _ = win.CancelIoEx(self.pipe, &overlapped);
                _ = win.GetOverlappedResult(self.pipe, &overlapped, &count, 1);
                return null;
            }
            if (win.GetOverlappedResult(self.pipe, &overlapped, &count, 0) == 0) return null;
        }
        if (self.stopping.load(.acquire) or count == 0) return null;
        return count;
    }

    /// Send what the host has for the widget: acknowledgements first, then
    /// frames. A write that fails or stalls past its deadline fails the
    /// channel, as it did from weaverd.
    fn writerMain(self: *DevWidget) void {
        widget_log.detachThread();
        const event = win.CreateEventW(null, 1, 0, null) orelse return self.service.fail(&self.subscriber);
        defer _ = win.CloseHandle(event);
        var frame: [protocol.frame_line_capacity + 1]u8 = undefined;
        while (true) {
            const handles = [_]win.HANDLE{ self.wake_event, self.shutdown_event };
            if (win.WaitForMultipleObjects(handles.len, &handles, 0, win.INFINITE) != win.WAIT_OBJECT_0) return;
            if (self.stopping.load(.acquire)) return;
            while (self.takeAck()) |ack| {
                var buffer: [64]u8 = undefined;
                const line = media_commands.formatAck(ack.id, ack.ok, &buffer) catch unreachable;
                if (!writePipe(self.pipe, event, line)) return self.service.fail(&self.subscriber);
            }
            while (self.queues.takeFrame(frame[0 .. frame.len - 1])) |line| {
                frame[line.len] = '\n';
                if (!writePipe(self.pipe, event, frame[0 .. line.len + 1])) return self.service.fail(&self.subscriber);
            }
        }
    }
};

/// `"<this executable>" --dev "<dir>"`, as weaverd launched dev widgets.
fn commandLine(allocator: std.mem.Allocator, dir: []const u8) ![:0]u16 {
    // Windows' longest path, on the heap: a thread's stack stays as deep as
    // it ever went.
    const exe_w = try allocator.alloc(u16, 32768);
    defer allocator.free(exe_w);
    const length = win.GetModuleFileNameW(null, exe_w.ptr, @intCast(exe_w.len));
    if (length == 0 or length == exe_w.len) return error.ExecutablePathFailed;
    const exe = try std.unicode.utf16LeToUtf8Alloc(allocator, exe_w[0..length]);
    defer allocator.free(exe);
    const line = try std.fmt.allocPrint(allocator, "\"{s}\" --dev \"{s}\"", .{ exe, dir });
    defer allocator.free(line);
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, line);
}

/// The host's own channels, which a dev widget must not inherit; it gets
/// its own where it needs them.
const host_channels = [_][]const u8{
    "WEAVER_HOST_CRASHES",
    "WEAVER_HOST_EXIT_CODE",
    "WEAVER_HOST_PIPE",
    "WEAVER_HOST_ENDPOINT",
    "WEAVER_BACKEND_FILE",
    "WEAVER_RENDERER_PIPE",
    "WEAVER_ART_CACHE",
};

/// The renderer pipe and art cache the host passes to the dev widgets that
/// use them.
pub const Channels = struct {
    renderer_pipe: ?[]const u8 = null,
    art_cache: ?[]const u8 = null,
};

/// A dev widget's environment: the host's, less the host's channels, plus
/// its provider pipe and backend file, and the renderer and art cache when
/// its manifest uses them (what weaverd set for it before the host
/// launched it). Built for each launch and freed after it.
fn environmentBlock(allocator: std.mem.Allocator, base: *const std.process.Environ.Map, channels: Channels, request: Launch, pipe_name: ?[]const u8) !std.process.Environ.WindowsBlock {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var map = try base.clone(arena_state.allocator());
    for (host_channels) |key| _ = map.orderedRemove(key);
    if (pipe_name) |name| try map.put("WEAVER_HOST_PIPE", name);
    if (request.backend) |path| try map.put("WEAVER_BACKEND_FILE", path);
    if (request.gpu) if (channels.renderer_pipe) |value| try map.put("WEAVER_RENDERER_PIPE", value);
    if (request.wants.media) if (channels.art_cache) |value| try map.put("WEAVER_ART_CACHE", value);
    return map.createWindowsBlock(allocator, .{});
}

/// Accept `pipe` from `process` only: a client with any other PID is
/// disconnected before it can send a byte.
fn connectPipe(pipe: win.HANDLE, process: win.HANDLE, expected_pid: u32, timeout_ms: u64) bool {
    const deadline = win.GetTickCount64() +| timeout_ms;
    while (true) {
        const now = win.GetTickCount64();
        if (now >= deadline or !connectPipeOnce(pipe, process, deadline - now)) return false;
        var pid: win.ULONG = 0;
        if (win.GetNamedPipeClientProcessId(pipe, &pid) == 0) {
            _ = win.DisconnectNamedPipe(pipe);
            return false;
        }
        if (pid == expected_pid) return true;
        @import("host_lifecycle.zig").note("weaver-widget: rejecting provider pipe client pid={d}; expected dev widget pid={d}\n", .{ pid, expected_pid });
        _ = win.DisconnectNamedPipe(pipe);
    }
}

fn connectPipeOnce(pipe: win.HANDLE, process: win.HANDLE, timeout_ms: u64) bool {
    const event = win.CreateEventW(null, 0, 0, null) orelse return false;
    defer _ = win.CloseHandle(event);
    var overlapped = std.mem.zeroes(win.OVERLAPPED);
    overlapped.hEvent = event;
    if (win.ConnectNamedPipe(pipe, &overlapped) != 0) return true;
    switch (win.GetLastError()) {
        win.ERROR_PIPE_CONNECTED => return true,
        win.ERROR_IO_PENDING => {},
        else => return false,
    }
    const handles = [_]win.HANDLE{ event, process };
    if (win.WaitForMultipleObjects(handles.len, &handles, 0, @intCast(timeout_ms)) != win.WAIT_OBJECT_0) {
        _ = win.CancelIoEx(pipe, &overlapped);
        var cancelled: win.DWORD = 0;
        _ = win.GetOverlappedResult(pipe, &overlapped, &cancelled, 1);
        return false;
    }
    var transferred: win.DWORD = 0;
    return win.GetOverlappedResult(pipe, &overlapped, &transferred, 0) != 0;
}

fn writePipe(pipe: win.HANDLE, event: win.HANDLE, bytes: []const u8) bool {
    _ = win.ResetEvent(event);
    var overlapped = std.mem.zeroes(win.OVERLAPPED);
    overlapped.hEvent = event;
    var written: win.DWORD = 0;
    if (win.WriteFile(pipe, bytes.ptr, @intCast(bytes.len), &written, &overlapped) == 0) {
        if (win.GetLastError() != win.ERROR_IO_PENDING) return false;
        if (win.WaitForSingleObject(event, write_timeout_ms) != win.WAIT_OBJECT_0) {
            _ = win.CancelIoEx(pipe, &overlapped);
            var cancelled: win.DWORD = 0;
            _ = win.GetOverlappedResult(pipe, &overlapped, &cancelled, 1);
            return false;
        }
        if (win.GetOverlappedResult(pipe, &overlapped, &written, 0) == 0) return false;
    }
    return written == bytes.len;
}

/// Ask a dev widget to close: WM_CLOSE to each of its windows.
fn closeWindowsForProcess(pid: u32) void {
    const Callback = struct {
        fn call(window: win.HWND, process_id: win.LPARAM) callconv(.c) win.BOOL {
            var owner: win.DWORD = 0;
            _ = win.GetWindowThreadProcessId(window, &owner);
            if (owner == @as(u32, @intCast(process_id))) _ = win.PostMessageW(window, win.WM_CLOSE, 0, 0);
            return 1;
        }
    };
    _ = win.EnumWindows(Callback.call, @intCast(pid));
}

test "a dev widget's environment holds its channels and none of the host's" {
    var base = std.process.Environ.Map.init(std.testing.allocator);
    defer base.deinit();
    try base.put("PATH", "C:\\Windows");
    try base.put("WEAVER_HOST_CRASHES", "2");
    // The host's own, inherited from weaverd or a shell: never passed on.
    try base.put("WEAVER_RENDERER_PIPE", "\\\\.\\pipe\\inherited");
    try base.put("WEAVER_ART_CACHE", "C:\\inherited");
    try base.put("WEAVER_BACKEND_FILE", "C:\\host-backend");
    const Case = struct { request: Launch, pipe: ?[]const u8, expected: []const []const u8, absent: []const []const u8 };
    const cases = [_]Case{
        .{
            .request = .{ .id = 1, .dir = "d", .backend = "C:\\b", .gpu = true, .wants = .{ .media = true } },
            .pipe = "\\\\.\\pipe\\dev",
            .expected = &.{ "PATH=C:\\Windows", "WEAVER_HOST_PIPE=\\\\.\\pipe\\dev", "WEAVER_BACKEND_FILE=C:\\b", "WEAVER_RENDERER_PIPE=\\\\.\\pipe\\renderer", "WEAVER_ART_CACHE=C:\\art" },
            .absent = &.{"WEAVER_HOST_CRASHES"},
        },
        .{
            .request = .{ .id = 2, .dir = "d" },
            .pipe = null,
            .expected = &.{"PATH=C:\\Windows"},
            .absent = &.{ "WEAVER_HOST_CRASHES", "WEAVER_HOST_PIPE", "WEAVER_RENDERER_PIPE", "WEAVER_ART_CACHE", "WEAVER_BACKEND_FILE" },
        },
    };
    for (cases) |case| {
        const block = try environmentBlock(std.testing.allocator, &base, .{ .renderer_pipe = "\\\\.\\pipe\\renderer", .art_cache = "C:\\art" }, case.request, case.pipe);
        defer block.deinit(std.testing.allocator);
        const text = try std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, block.slice);
        defer std.testing.allocator.free(text);
        var entries = std.mem.splitScalar(u8, text, 0);
        var found: usize = 0;
        while (entries.next()) |entry| {
            if (entry.len == 0) continue;
            for (case.absent) |key| try std.testing.expect(!std.mem.startsWith(u8, entry, key));
            for (case.expected) |wanted| found += @intFromBool(std.mem.eql(u8, entry, wanted));
        }
        try std.testing.expectEqual(case.expected.len, found);
    }
}

test "a dev widget's job ends its process when the job's last handle closes" {
    var service = provider_service.Service.init(.{ .io = std.testing.io, .art_cache_root = null });
    defer service.deinit();
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    const devs = try DevWidgets.init(&service, &environment, .{});
    // A process that would wait a minute, in the job.
    var startup = std.mem.zeroes(win.STARTUPINFOW);
    startup.cb = @sizeOf(win.STARTUPINFOW);
    var info = std.mem.zeroes(win.PROCESS_INFORMATION);
    var command = std.unicode.utf8ToUtf16LeStringLiteral("cmd.exe /c ping -n 60 127.0.0.1 >nul").*;
    try std.testing.expect(win.CreateProcessW(null, &command, null, null, 0, win.CREATE_NO_WINDOW | win.CREATE_SUSPENDED, null, null, &startup, &info) != 0);
    defer _ = win.CloseHandle(info.hProcess);
    try std.testing.expect(win.AssignProcessToJobObject(devs.job, info.hProcess) != 0);
    _ = win.ResumeThread(info.hThread);
    _ = win.CloseHandle(info.hThread);
    try std.testing.expectEqual(@as(win.DWORD, win.WAIT_TIMEOUT), win.WaitForSingleObject(info.hProcess, 100));
    _ = win.CloseHandle(devs.job);
    try std.testing.expectEqual(@as(win.DWORD, win.WAIT_OBJECT_0), win.WaitForSingleObject(info.hProcess, 5000));
}

test "the provider pipe refuses a client whose pid is not the dev widget's" {
    var name_buffer: [160]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "\\\\.\\pipe\\weaver-dev-hijack-test-{d}-{d}", .{ win.GetCurrentProcessId(), win.GetTickCount64() });
    const name_w = try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, name);
    defer std.testing.allocator.free(name_w);
    const pipe = win.CreateNamedPipeW(name_w.ptr, win.PIPE_ACCESS_DUPLEX | win.FILE_FLAG_OVERLAPPED, win.PIPE_TYPE_BYTE | win.PIPE_READMODE_BYTE | win.PIPE_WAIT, 1, 512, 512, 0, null);
    try std.testing.expect(pipe != invalid_handle);
    defer _ = win.CloseHandle(pipe);
    const Connector = struct {
        fn run(path: [*:0]const u16) void {
            const client = win.CreateFileW(path, win.GENERIC_READ | win.GENERIC_WRITE, 0, null, win.OPEN_EXISTING, 0, null);
            if (client != invalid_handle) {
                win.Sleep(500);
                _ = win.CloseHandle(client);
            }
        }
    };
    const connector = try std.Thread.spawn(.{}, Connector.run, .{name_w.ptr});
    defer connector.join();
    try std.testing.expect(!connectPipe(pipe, win.GetCurrentProcess(), win.GetCurrentProcessId() + 1, 200));
}
