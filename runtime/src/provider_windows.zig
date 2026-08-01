const std = @import("std");
const win = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
});
const protocol = @import("provider_protocol.zig");

// Reader-stack receipt (2026-07-29): Framer is 25,016 bytes and the read chunk
// is 4,096, so the worker's dominant live locals total 29,112 bytes. 256 KiB
// leaves 9x headroom for its shallow overlapped-I/O call graph. Windows
// reserves the stack and commits pages only as used; there is one reader per
// widget.
const reader_stack_bytes: usize = 256 * 1024;

const SpinMutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *SpinMutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *SpinMutex) void {
        self.inner.unlock();
    }
};

/// The pipe reader owns no QuickJS state. It only copies complete JSON lines
/// into the provider/ack queues; the Native timer drain remains the sole place
/// where callbacks enter JavaScript on the app loop thread.
pub const Client = struct {
    io: std.Io = undefined,
    handle: win.HANDLE = win.INVALID_HANDLE_VALUE,
    write_event: win.HANDLE = null,
    shutdown_event: win.HANDLE = null,
    thread: ?std.Thread = null,
    send_mutex: SpinMutex = .{},
    queues: protocol.Queues = .{},
    connected: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    disconnected: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    stopping: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    next_command_id: u64 = 1,
    wake: ?*const fn () void = null,
    test_before_read: win.HANDLE = null,
    test_resume_read: win.HANDLE = null,

    pub fn init(self: *Client, io: std.Io, pipe_name: ?[]const u8) !void {
        self.io = io;
        const name = pipe_name orelse return;
        self.stopping.store(0, .release);
        const name_w = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, name);
        defer std.heap.page_allocator.free(name_w);
        self.handle = win.CreateFileW(
            name_w.ptr,
            win.GENERIC_READ | win.GENERIC_WRITE,
            0,
            null,
            win.OPEN_EXISTING,
            win.FILE_FLAG_OVERLAPPED,
            null,
        );
        if (self.handle == win.INVALID_HANDLE_VALUE) return error.HostPipeUnavailable;
        errdefer {
            _ = win.CloseHandle(self.handle);
            self.handle = win.INVALID_HANDLE_VALUE;
        }
        self.write_event = win.CreateEventW(null, 0, 0, null) orelse return error.CreateEventFailed;
        errdefer {
            _ = win.CloseHandle(self.write_event);
            self.write_event = null;
        }
        self.shutdown_event = win.CreateEventW(null, 1, 0, null) orelse return error.CreateEventFailed;
        errdefer {
            _ = win.CloseHandle(self.shutdown_event);
            self.shutdown_event = null;
        }
        self.connected.store(1, .release);
        // Avoid the platform's much larger default reservation; see the
        // measured fixed-local receipt at reader_stack_bytes.
        self.thread = try std.Thread.spawn(.{ .stack_size = reader_stack_bytes }, readerMain, .{self});
    }

    pub fn deinit(self: *Client) void {
        self.stopping.store(1, .release);
        if (self.shutdown_event) |event| _ = win.SetEvent(event);
        if (self.handle != win.INVALID_HANDLE_VALUE) {
            _ = win.CancelIoEx(self.handle, null);
        }
        if (self.thread) |thread| thread.join();
        self.thread = null;
        if (self.handle != win.INVALID_HANDLE_VALUE) {
            _ = win.CloseHandle(self.handle);
            self.handle = win.INVALID_HANDLE_VALUE;
        }
        if (self.write_event) |event| _ = win.CloseHandle(event);
        self.write_event = null;
        if (self.shutdown_event) |event| _ = win.CloseHandle(event);
        self.shutdown_event = null;
        self.connected.store(0, .release);
        self.disconnected.store(1, .release);
    }

    pub fn take(self: *Client, output: []u8) ?[]const u8 {
        return self.queues.takeFrame(output);
    }

    pub fn takeAck(self: *Client) ?protocol.Ack {
        return self.queues.takeAck();
    }

    pub fn registerAck(self: *Client, id: u64) bool {
        return self.queues.registerAck(id);
    }

    pub fn unregisterAck(self: *Client, id: u64) void {
        self.queues.unregisterAck(id);
    }

    pub fn setWake(self: *Client, wake: *const fn () void) void {
        self.wake = wake;
    }

    pub fn isAvailable(self: *const Client) bool {
        return self.connected.load(.acquire) != 0;
    }

    pub fn protocolFailed(self: *const Client) bool {
        return self.queues.ack_protocol_failed.load(.acquire) != 0;
    }

    pub fn isDisconnected(self: *const Client) bool {
        return self.disconnected.load(.acquire) != 0;
    }

    pub fn fatalChannelFailure(_: *const Client) bool {
        return false;
    }

    pub fn nowMilliseconds(self: *const Client) u64 {
        return @intCast(std.Io.Clock.now(.awake, self.io).toMilliseconds());
    }

    pub fn send(self: *Client, line: []const u8) !void {
        if (line.len == 0 or line.len > protocol.command_line_capacity or std.mem.indexOfScalar(u8, line, '\n') != null) return error.InvalidCommandFrame;
        self.send_mutex.lock();
        defer self.send_mutex.unlock();
        if (!self.isAvailable() or self.handle == win.INVALID_HANDLE_VALUE) return error.HostPipeUnavailable;
        const event = self.write_event orelse return error.HostPipeUnavailable;
        var framed: [protocol.command_line_capacity + 1]u8 = undefined;
        @memcpy(framed[0..line.len], line);
        framed[line.len] = '\n';
        _ = win.ResetEvent(event);
        var overlapped: win.OVERLAPPED = std.mem.zeroes(win.OVERLAPPED);
        overlapped.hEvent = event;
        var written: win.DWORD = 0;
        if (win.WriteFile(self.handle, &framed, @intCast(line.len + 1), &written, &overlapped) == 0) {
            if (win.GetLastError() != win.ERROR_IO_PENDING) {
                self.connected.store(0, .release);
                self.disconnected.store(1, .release);
                return error.HostPipeWriteFailed;
            }
            if (win.WaitForSingleObject(event, 1000) != win.WAIT_OBJECT_0) {
                _ = win.CancelIoEx(self.handle, &overlapped);
                var cancelled_bytes: win.DWORD = 0;
                _ = win.GetOverlappedResult(self.handle, &overlapped, &cancelled_bytes, 1);
                self.connected.store(0, .release);
                self.disconnected.store(1, .release);
                return error.HostPipeWriteFailed;
            }
            if (win.GetOverlappedResult(self.handle, &overlapped, &written, 0) == 0) {
                self.connected.store(0, .release);
                self.disconnected.store(1, .release);
                return error.HostPipeWriteFailed;
            }
        }
        if (written != line.len + 1) {
            self.connected.store(0, .release);
            self.disconnected.store(1, .release);
            return error.HostPipeWriteFailed;
        }
    }

    pub fn nextCommandId(self: *Client) !u64 {
        if (self.next_command_id > protocol.max_safe_id) return error.CommandIdExhausted;
        const result = self.next_command_id;
        self.next_command_id += 1;
        return result;
    }

    fn readerMain(self: *Client) void {
        defer {
            self.connected.store(0, .release);
            self.disconnected.store(1, .release);
            if (self.wake) |wake| wake();
        }
        const event = win.CreateEventW(null, 0, 0, null) orelse return;
        defer _ = win.CloseHandle(event);
        var framer: protocol.Framer = .{};
        var chunk: [4096]u8 = undefined;
        while (true) {
            if (self.stopping.load(.acquire) != 0) return;
            var read: win.DWORD = 0;
            _ = win.ResetEvent(event);
            var overlapped: win.OVERLAPPED = std.mem.zeroes(win.OVERLAPPED);
            overlapped.hEvent = event;
            if (self.test_before_read) |barrier| {
                _ = win.SetEvent(barrier);
                if (self.test_resume_read) |resume_event| _ = win.WaitForSingleObject(resume_event, win.INFINITE);
            }
            // This second check closes the cancel-before-read window: teardown
            // sets `stopping` and the persistent manual-reset event before it
            // cancels any in-flight operation.
            if (self.stopping.load(.acquire) != 0) return;
            if (win.ReadFile(self.handle, &chunk, chunk.len, &read, &overlapped) == 0) {
                if (win.GetLastError() != win.ERROR_IO_PENDING) {
                    framer.finish(&self.queues);
                    return;
                }
                const shutdown = self.shutdown_event orelse {
                    framer.finish(&self.queues);
                    return;
                };
                const handles = [_]win.HANDLE{ event, shutdown };
                const wait = win.WaitForMultipleObjects(handles.len, &handles, 0, win.INFINITE);
                if (wait == win.WAIT_OBJECT_0 + 1) {
                    _ = win.CancelIoEx(self.handle, &overlapped);
                    var cancelled: win.DWORD = 0;
                    _ = win.GetOverlappedResult(self.handle, &overlapped, &cancelled, 1);
                    return;
                }
                if (wait != win.WAIT_OBJECT_0 or win.GetOverlappedResult(self.handle, &overlapped, &read, 0) == 0) {
                    framer.finish(&self.queues);
                    return;
                }
            }
            if (self.stopping.load(.acquire) != 0) return;
            if (read == 0) {
                framer.finish(&self.queues);
                return;
            }
            const wake_before = self.queues.wakeGeneration();
            if (!framer.feed(&self.queues, chunk[0..read])) return;
            if (self.queues.wakeGeneration() != wake_before) {
                if (self.wake) |wake| wake();
            }
        }
    }
};

test "Windows runtime reader closes the cancel-before-read shutdown race" {
    var client: Client = .{};
    client.shutdown_event = win.CreateEventW(null, 1, 0, null) orelse return error.CreateEventFailed;
    defer _ = win.CloseHandle(client.shutdown_event);
    client.test_before_read = win.CreateEventW(null, 1, 0, null) orelse return error.CreateEventFailed;
    defer _ = win.CloseHandle(client.test_before_read);
    client.test_resume_read = win.CreateEventW(null, 1, 0, null) orelse return error.CreateEventFailed;
    defer _ = win.CloseHandle(client.test_resume_read);
    const thread = try std.Thread.spawn(.{}, Client.readerMain, .{&client});
    try std.testing.expectEqual(win.WAIT_OBJECT_0, win.WaitForSingleObject(client.test_before_read, 1000));

    // Teardown deliberately lands while no ReadFile exists to cancel.
    client.stopping.store(1, .release);
    _ = win.SetEvent(client.shutdown_event);
    _ = win.CancelIoEx(client.handle, null);
    _ = win.SetEvent(client.test_resume_read);
    thread.join();
    try std.testing.expect(client.isDisconnected());
}
