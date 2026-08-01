const std = @import("std");
const c = @cImport({
    @cInclude("poll.h");
    @cInclude("sys/socket.h");
});
const posix = std.posix;
const protocol = @import("provider_protocol.zig");

// Reader-stack receipt (2026-07-29): Framer is 25,016 bytes and the read chunk
// is 4,096, so the worker's dominant live locals total 29,112 bytes. 256 KiB
// leaves 9x headroom for its shallow syscall call graph. The OS reserves the
// stack and commits pages only as used; there is one reader per widget.
const reader_stack_bytes: usize = 256 * 1024;
// A legal command is at most 86 bytes and a healthy local socket write is
// immediate; one second is a supervision tripwire, not retained work, and
// costs no memory.
const command_write_deadline_ns: i128 = std.time.ns_per_s;

const SendAttempt = union(enum) {
    progress: usize,
    retry,
    failure,
};

const SendFn = *const fn (?*anyopaque, c_int, []const u8) SendAttempt;

fn systemSend(_: ?*anyopaque, socket: c_int, bytes: []const u8) SendAttempt {
    const sent = c.send(
        socket,
        bytes.ptr,
        bytes.len,
        c.MSG_DONTWAIT | c.MSG_NOSIGNAL,
    );
    if (sent > 0) return .{ .progress = @intCast(sent) };
    return switch (posix.errno(sent)) {
        .INTR, .AGAIN => .retry,
        else => .failure,
    };
}

const SpinMutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *SpinMutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *SpinMutex) void {
        self.inner.unlock();
    }
};

/// The Unix-socket reader owns no QuickJS state. It only copies complete JSON
/// lines into separate provider/ack queues; the app-loop timer remains the
/// sole place callbacks enter JavaScript.
pub const Client = struct {
    io: std.Io = undefined,
    stream: ?std.Io.net.Stream = null,
    thread: ?std.Thread = null,
    send_mutex: SpinMutex = .{},
    queues: protocol.Queues = .{},
    connected: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    disconnected: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    fatal_channel_failure: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    next_command_id: u64 = 1,
    wake: ?*const fn () void = null,
    send_fn: SendFn = systemSend,
    send_context: ?*anyopaque = null,
    send_deadline_ns: i128 = command_write_deadline_ns,
    automation_send_failure_path: ?[]const u8 = null,

    pub fn init(self: *Client, io: std.Io, endpoint: ?[]const u8) !void {
        // Inert clients still provide the monotonic clock used by transport
        // deadline bookkeeping; endpoint absence must not leave `io`
        // undefined.
        self.io = io;
        const path = endpoint orelse return;
        const address = try std.Io.net.UnixAddress.init(path);
        self.stream = address.connect(io) catch return error.HostEndpointUnavailable;
        errdefer {
            self.stream.?.close(io);
            self.stream = null;
        }
        self.connected.store(1, .release);
        // See reader_stack_bytes: measured live fixed locals are 29,112 bytes.
        self.thread = try std.Thread.spawn(.{ .stack_size = reader_stack_bytes }, readerMain, .{self});
    }

    pub fn deinit(self: *Client) void {
        if (self.stream) |stream| _ = c.shutdown(stream.socket.handle, c.SHUT_RDWR);
        if (self.thread) |thread| thread.join();
        self.thread = null;
        if (self.stream) |stream| stream.close(self.io);
        self.stream = null;
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

    pub fn fatalChannelFailure(self: *const Client) bool {
        return self.fatal_channel_failure.load(.acquire) != 0;
    }

    /// Installed only by the automation build after WEAVER_AUTOMATION=1 has
    /// been checked in main. Deleting the marker makes the failure one-shot
    /// across the replacement process spawned by host supervision.
    pub fn setAutomationSendFailurePath(self: *Client, path: []const u8) void {
        self.automation_send_failure_path = path;
    }

    pub fn nowMilliseconds(self: *const Client) u64 {
        return @intCast(std.Io.Clock.now(.awake, self.io).toMilliseconds());
    }

    pub fn send(self: *Client, line: []const u8) !void {
        if (line.len == 0 or line.len > protocol.command_line_capacity or std.mem.indexOfScalar(u8, line, '\n') != null) return error.InvalidCommandFrame;
        self.send_mutex.lock();
        defer self.send_mutex.unlock();
        const stream = self.stream orelse return error.HostEndpointUnavailable;
        if (!self.isAvailable()) return error.HostEndpointUnavailable;
        if (self.consumeAutomationSendFailure()) {
            std.log.warn("automation injected provider command send failure", .{});
            return self.failWrite();
        }
        var framed: [protocol.command_line_capacity + 1]u8 = undefined;
        @memcpy(framed[0..line.len], line);
        framed[line.len] = '\n';
        const started_ns = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
        var offset: usize = 0;
        while (offset < line.len + 1) {
            switch (self.send_fn(self.send_context, stream.socket.handle, framed[offset .. line.len + 1])) {
                .progress => |sent| {
                    offset += sent;
                    continue;
                },
                .retry => {},
                .failure => {
                    std.log.warn("provider command socket write failed", .{});
                    return self.failWrite();
                },
            }
            if (std.Io.Timestamp.now(self.io, .awake).nanoseconds - started_ns >= self.send_deadline_ns) {
                std.log.warn("provider command socket write reached its deadline", .{});
                return self.failWrite();
            }
            std.Io.sleep(self.io, .fromMilliseconds(1), .awake) catch {
                std.log.warn("provider command socket retry sleep failed", .{});
                return self.failWrite();
            };
        }
    }

    fn failWrite(self: *Client) error{HostEndpointWriteFailed} {
        self.connected.store(0, .release);
        self.disconnected.store(1, .release);
        self.fatal_channel_failure.store(1, .release);
        if (self.wake) |wake| wake();
        return error.HostEndpointWriteFailed;
    }

    fn consumeAutomationSendFailure(self: *Client) bool {
        const path = self.automation_send_failure_path orelse return false;
        std.Io.Dir.cwd().deleteFile(self.io, path) catch return false;
        return true;
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
        const stream = self.stream orelse return;
        var framer: protocol.Framer = .{};
        var chunk: [4096]u8 = undefined;
        while (true) {
            var descriptor: c.struct_pollfd = .{
                .fd = stream.socket.handle,
                .events = c.POLLIN | c.POLLHUP,
                .revents = 0,
            };
            const ready = c.poll(&descriptor, 1, -1);
            if (ready < 0) {
                if (posix.errno(ready) == .INTR) continue;
                framer.finish(&self.queues);
                return;
            }
            if (ready == 0) continue;
            // The duplex provider socket remains open for the widget
            // lifetime. poll(2) blocks without idle work and proves that a
            // short read or EOF is ready. Reading again without poll would
            // turn the socket's ordinary EAGAIN between acks into a false
            // channel failure.
            const read = posix.read(stream.socket.handle, &chunk) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => {
                    framer.finish(&self.queues);
                    return;
                },
            };
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

const TestEndpoint = struct {
    io: std.Io,
    listener: std.Io.net.Server,

    fn run(self: *TestEndpoint) void {
        const stream = self.listener.accept(self.io) catch return;
        defer stream.close(self.io);
        var buffer: [256]u8 = undefined;
        var writer = stream.writer(self.io, &buffer);
        writer.interface.writeAll("one\ntwo\nthree\nfour\nfive\n") catch return;
        // The client-side queue assertion reports a fixture disconnect.
        writer.interface.flush() catch {};
    }
};

test "inert Unix provider client retains a valid monotonic clock" {
    var client: Client = .{};
    try client.init(std.testing.io, null);
    defer client.deinit();
    try std.testing.expect(client.nowMilliseconds() > 0);
    try std.testing.expect(!client.isAvailable());
}

test "Unix provider transport frames lines and bounds its queue" {
    var path_buffer: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/tmp/weaver-provider-test-{d}.sock", .{std.posix.system.getpid()});
    // Test socket cleanup must not hide the transport assertion.
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const address = try std.Io.net.UnixAddress.init(path);
    var endpoint: TestEndpoint = .{ .io = std.testing.io, .listener = try address.listen(std.testing.io, .{}) };
    defer endpoint.listener.deinit(std.testing.io);
    const server_thread = try std.Thread.spawn(.{}, TestEndpoint.run, .{&endpoint});
    defer server_thread.join();

    var client: Client = .{};
    try client.init(std.testing.io, path);
    defer client.deinit();
    var ready = false;
    for (0..100) |_| {
        client.queues.mutex.lock();
        ready = client.queues.frame_count == protocol.frame_queue_capacity;
        client.queues.mutex.unlock();
        if (ready) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
    }
    try std.testing.expect(ready);
    var output: [protocol.frame_line_capacity]u8 = undefined;
    for ([_][]const u8{ "two", "three", "four", "five" }) |expected| {
        try std.testing.expectEqualStrings(expected, client.take(&output).?);
    }
    try std.testing.expect(client.take(&output) == null);
}

test "Unix provider transport routes a short ack while the host stays connected" {
    const Endpoint = struct {
        io: std.Io,
        listener: std.Io.net.Server,
        send_ack: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        send_second_ack: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(self: *@This()) void {
            const stream = self.listener.accept(self.io) catch return;
            defer stream.close(self.io);
            while (!self.send_ack.load(.acquire) and !self.stopping.load(.acquire)) {
                std.Io.sleep(self.io, .fromMilliseconds(1), .awake) catch return;
            }
            if (self.stopping.load(.acquire)) return;
            var buffer: [64]u8 = undefined;
            var writer = stream.writer(self.io, &buffer);
            writer.interface.writeAll("{\"ack\":7,\"ok\":true}\n") catch return;
            writer.interface.flush() catch return;
            while (!self.send_second_ack.load(.acquire) and !self.stopping.load(.acquire)) {
                std.Io.sleep(self.io, .fromMilliseconds(1), .awake) catch return;
            }
            if (self.stopping.load(.acquire)) return;
            writer.interface.writeAll("{\"ack\":8,\"ok\":false}\n") catch return;
            writer.interface.flush() catch return;
            while (!self.stopping.load(.acquire)) {
                std.Io.sleep(self.io, .fromMilliseconds(1), .awake) catch return;
            }
        }
    };
    var path_buffer: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/tmp/weaver-provider-live-ack-test-{d}.sock", .{std.posix.system.getpid()});
    // Test socket cleanup must not hide the ack assertion.
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const address = try std.Io.net.UnixAddress.init(path);
    var endpoint: Endpoint = .{ .io = std.testing.io, .listener = try address.listen(std.testing.io, .{}) };
    defer endpoint.listener.deinit(std.testing.io);
    const server_thread = try std.Thread.spawn(.{}, Endpoint.run, .{&endpoint});
    defer server_thread.join();
    defer endpoint.stopping.store(true, .release);

    var client: Client = .{};
    try client.init(std.testing.io, path);
    defer client.deinit();
    try std.testing.expect(client.registerAck(7));
    try std.testing.expect(client.registerAck(8));
    endpoint.send_ack.store(true, .release);

    var ack: ?protocol.Ack = null;
    for (0..100) |_| {
        ack = client.takeAck();
        if (ack != null) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
    }
    try std.testing.expect(ack != null);
    try std.testing.expectEqual(@as(u64, 7), ack.?.id);
    try std.testing.expect(ack.?.ok);
    try std.Io.sleep(std.testing.io, .fromMilliseconds(25), .awake);
    try std.testing.expect(client.isAvailable());
    endpoint.send_second_ack.store(true, .release);
    ack = null;
    for (0..100) |_| {
        ack = client.takeAck();
        if (ack != null) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
    }
    try std.testing.expect(ack != null);
    try std.testing.expectEqual(@as(u64, 8), ack.?.id);
    try std.testing.expect(!ack.?.ok);
    try std.testing.expect(client.isAvailable());
}

test "Unix provider transport rejects an unterminated ack at EOF" {
    const Endpoint = struct {
        io: std.Io,
        listener: std.Io.net.Server,

        fn run(self: *@This()) void {
            const stream = self.listener.accept(self.io) catch return;
            defer stream.close(self.io);
            var buffer: [64]u8 = undefined;
            var writer = stream.writer(self.io, &buffer);
            writer.interface.writeAll("{\"ack\":7,\"ok\":true}") catch return;
            // EOF is the fixture behavior; the client assertion owns failure.
            writer.interface.flush() catch {};
        }
    };
    var path_buffer: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/tmp/weaver-provider-eof-test-{d}.sock", .{std.posix.system.getpid()});
    // Test socket cleanup must not hide the protocol assertion.
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const address = try std.Io.net.UnixAddress.init(path);
    var endpoint: Endpoint = .{ .io = std.testing.io, .listener = try address.listen(std.testing.io, .{}) };
    defer endpoint.listener.deinit(std.testing.io);
    const server_thread = try std.Thread.spawn(.{}, Endpoint.run, .{&endpoint});
    defer server_thread.join();
    var client: Client = .{};
    try client.init(std.testing.io, path);
    defer client.deinit();
    try std.testing.expect(client.registerAck(7));
    for (0..100) |_| {
        if (client.isDisconnected()) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
    }
    try std.testing.expect(client.protocolFailed());
    try std.testing.expect(client.takeAck() == null);
}

test "Unix provider command send has a deadline when the connected host stalls" {
    const Endpoint = struct {
        io: std.Io,
        listener: std.Io.net.Server,
        stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(self: *@This()) void {
            const stream = self.listener.accept(self.io) catch return;
            defer stream.close(self.io);
            while (!self.stopping.load(.acquire)) {
                std.Io.sleep(self.io, .fromMilliseconds(10), .awake) catch return;
            }
        }
    };
    var path_buffer: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/tmp/weaver-provider-stall-test-{d}.sock", .{std.posix.system.getpid()});
    // Test socket cleanup must not hide the deadline assertion.
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const address = try std.Io.net.UnixAddress.init(path);
    var endpoint: Endpoint = .{ .io = std.testing.io, .listener = try address.listen(std.testing.io, .{}) };
    defer endpoint.listener.deinit(std.testing.io);
    const server_thread = try std.Thread.spawn(.{}, Endpoint.run, .{&endpoint});
    defer server_thread.join();

    var client: Client = .{};
    client.io = std.testing.io;
    client.stream = try address.connect(std.testing.io);
    client.connected.store(1, .release);
    defer client.deinit();
    defer endpoint.stopping.store(true, .release);

    const StalledSend = struct {
        attempts: usize = 0,

        fn send(context: ?*anyopaque, _: c_int, _: []const u8) SendAttempt {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.attempts += 1;
            return .retry;
        }
    };
    var stalled_send: StalledSend = .{};
    client.send_fn = StalledSend.send;
    client.send_context = &stalled_send;
    client.send_deadline_ns = 20 * std.time.ns_per_ms;

    const started = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds;
    try std.testing.expectError(error.HostEndpointWriteFailed, client.send("{\"command\":\"media\",\"verb\":\"pause\",\"id\":1}"));
    const elapsed = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds - started;
    try std.testing.expect(elapsed >= client.send_deadline_ns);
    try std.testing.expect(elapsed < 500 * std.time.ns_per_ms);
    try std.testing.expect(stalled_send.attempts > 1);
    try std.testing.expect(client.isDisconnected());
    try std.testing.expect(client.fatalChannelFailure());
    // The caller is back on the app loop after the finite send deadline, so
    // pending-slot cleanup can run before the app-loop wake exits the process
    // through host crash supervision.
    try std.testing.expect(client.nowMilliseconds() > 0);
}
