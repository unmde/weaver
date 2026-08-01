const std = @import("std");
const art_cache = @import("art_cache.zig");
const audio = @import("audio.zig");
const media = @import("media.zig");
const media_commands = @import("media_commands.zig");
const supervisor = @import("supervisor.zig");
const registry = @import("registry.zig");
const provider_protocol = @import("provider_protocol.zig");
const system_providers = @import("providers_macos.zig");

const posix = std.posix;
const c = @cImport({
    @cInclude("macos_system.h");
    @cInclude("poll.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
});

const max_widgets = supervisor.max_widgets;
const max_path_bytes = supervisor.max_path_bytes;
const provider_environment = "WEAVER_HOST_ENDPOINT";
const shared_renderer_environment = "NATIVE_SDK_GPU_SHARED_RENDERER";
const render_host_name_environment = "WEAVER_RENDER_HOST_NAME";
const render_host_default_name = "com.weaver.render-host";
/// Restart backoff for a crashed render host. Widgets reconnect lazily on
/// their existing 1/5/30 s retry cadence, so one second of host absence
/// costs at most one retained-frame beat.
const render_host_restart_backoff_ms = 1000;
const art_cache_environment = "WEAVER_ART_CACHE";
const backend_environment = "WEAVER_BACKEND_FILE";

const ControlCommand = enum { reload, down };
const ControlResponse = enum { none, ok, failed };

const ControlServer = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []u8,
    listener: std.Io.net.Server,
    thread: std.Thread,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    pending: ?ControlCommand = null,
    claimed: bool = false,
    response: ControlResponse = .none,
    stopping: bool = false,

    fn start(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !*ControlServer {
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        const address = try std.Io.net.UnixAddress.init(owned_path);
        var listener = try address.listen(io, .{});
        errdefer listener.deinit(io);
        const self = try allocator.create(ControlServer);
        errdefer allocator.destroy(self);
        self.* = .{
            .io = io,
            .allocator = allocator,
            .path = owned_path,
            .listener = listener,
            .thread = undefined,
        };
        self.thread = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, threadMain, .{self});
        return self;
    }

    fn deinit(self: *ControlServer) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
        self.listener.deinit(self.io);
        self.thread.join();
        std.Io.Dir.cwd().deleteFile(self.io, self.path) catch {};
        const allocator = self.allocator;
        allocator.free(self.path);
        allocator.destroy(self);
    }

    fn take(self: *ControlServer) ?ControlCommand {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.pending == null or self.claimed) return null;
        self.claimed = true;
        return self.pending;
    }

    fn complete(self: *ControlServer, response: ControlResponse) void {
        self.mutex.lockUncancelable(self.io);
        self.response = response;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
    }

    fn threadMain(self: *ControlServer) void {
        var consecutive_accept_failures: u64 = 0;
        while (true) {
            self.mutex.lockUncancelable(self.io);
            const stopping = self.stopping;
            self.mutex.unlock(self.io);
            if (stopping) return;
            const stream = self.listener.accept(self.io) catch |err| {
                self.mutex.lockUncancelable(self.io);
                const now_stopping = self.stopping;
                self.mutex.unlock(self.io);
                if (now_stopping) return;
                consecutive_accept_failures += 1;
                if (consecutive_accept_failures == 1) {
                    std.log.err("host control listener accept failed: {s}; retrying and suppressing repeats until recovery", .{@errorName(err)});
                }
                std.Io.sleep(self.io, .fromMilliseconds(100), .awake) catch |sleep_err| {
                    std.log.err("host control listener retry wait failed: {s}; control listener is stopping", .{@errorName(sleep_err)});
                    return;
                };
                continue;
            };
            if (consecutive_accept_failures != 0) {
                std.log.info("host control listener recovered after {d} accept failures", .{consecutive_accept_failures});
                consecutive_accept_failures = 0;
            }
            self.handle(stream);
            stream.close(self.io);
        }
    }

    fn handle(self: *ControlServer, stream: std.Io.net.Stream) void {
        var read_buffer: [64]u8 = undefined;
        var stream_reader = stream.reader(self.io, &read_buffer);
        const command_text = stream_reader.interface.takeDelimiterExclusive('\n') catch return;
        if (std.mem.eql(u8, command_text, "probe")) return writeControlResponse(self.io, stream, "ok\n");
        const command: ControlCommand = if (std.mem.eql(u8, command_text, "reload"))
            .reload
        else if (std.mem.eql(u8, command_text, "down"))
            .down
        else
            return writeControlResponse(self.io, stream, "unknown\n");

        self.mutex.lockUncancelable(self.io);
        while (self.pending != null and !self.stopping) self.condition.waitUncancelable(self.io, &self.mutex);
        if (self.stopping) {
            self.mutex.unlock(self.io);
            return;
        }
        self.pending = command;
        self.claimed = false;
        self.response = .none;
        self.condition.broadcast(self.io);
        while (self.response == .none and !self.stopping) self.condition.waitUncancelable(self.io, &self.mutex);
        const response = self.response;
        self.pending = null;
        self.claimed = false;
        self.response = .none;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
        writeControlResponse(self.io, stream, if (response == .ok) "ok\n" else "failed\n");
    }
};

fn writeControlResponse(io: std.Io, stream: std.Io.net.Stream, response: []const u8) void {
    var write_buffer: [64]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buffer);
    stream_writer.interface.writeAll(response) catch return;
    stream_writer.interface.flush() catch {};
}

const ProviderEndpoint = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []u8,
    listener: std.Io.net.Server,
    thread: ?std.Thread = null,
    expected_pid: posix.pid_t = 0,
    mutex: std.Io.Mutex = .init,
    stream: ?std.Io.net.Stream = null,
    command_queue: media_commands.Queue = .{},
    stopping: bool = false,

    fn start(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !*ProviderEndpoint {
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        const address = try std.Io.net.UnixAddress.init(owned_path);
        var listener = try address.listen(io, .{});
        errdefer listener.deinit(io);
        const self = try allocator.create(ProviderEndpoint);
        errdefer allocator.destroy(self);
        self.* = .{ .io = io, .allocator = allocator, .path = owned_path, .listener = listener };
        return self;
    }

    fn bind(self: *ProviderEndpoint, expected_pid: posix.pid_t) !void {
        self.expected_pid = expected_pid;
        self.thread = try std.Thread.spawn(.{ .stack_size = 128 * 1024 }, acceptMain, .{self});
    }

    fn deinit(self: *ProviderEndpoint) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.command_queue.stop();
        if (self.stream) |stream| _ = c.shutdown(stream.socket.handle, c.SHUT_RDWR);
        self.stream = null;
        self.mutex.unlock(self.io);
        self.listener.deinit(self.io);
        if (self.thread) |thread| thread.join();
        std.Io.Dir.cwd().deleteFile(self.io, self.path) catch {};
        const allocator = self.allocator;
        allocator.free(self.path);
        allocator.destroy(self);
    }

    fn acceptMain(self: *ProviderEndpoint) void {
        var consecutive_accept_failures: u64 = 0;
        while (true) {
            self.mutex.lockUncancelable(self.io);
            const stopping = self.stopping;
            self.mutex.unlock(self.io);
            if (stopping) return;
            const stream = self.listener.accept(self.io) catch |err| {
                self.mutex.lockUncancelable(self.io);
                const now_stopping = self.stopping;
                self.mutex.unlock(self.io);
                if (now_stopping) return;
                consecutive_accept_failures += 1;
                if (consecutive_accept_failures == 1) {
                    std.log.err(
                        "widget provider listener accept failed for pid={d}: {s}; retrying and suppressing repeats until recovery",
                        .{ self.expected_pid, @errorName(err) },
                    );
                }
                std.Io.sleep(self.io, .fromMilliseconds(100), .awake) catch |sleep_err| {
                    std.log.err("widget provider listener retry wait failed: {s}; provider listener is stopping", .{@errorName(sleep_err)});
                    return;
                };
                continue;
            };
            if (consecutive_accept_failures != 0) {
                std.log.info("widget provider listener recovered after {d} accept failures", .{consecutive_accept_failures});
                consecutive_accept_failures = 0;
            }
            const actual_pid = peerPid(stream);
            if (actual_pid != self.expected_pid) {
                std.log.warn(
                    "rejecting provider socket client pid={?}; expected widget pid={d}",
                    .{ actual_pid, self.expected_pid },
                );
                stream.close(self.io);
                continue;
            }
            self.mutex.lockUncancelable(self.io);
            if (self.stopping) {
                self.mutex.unlock(self.io);
                stream.close(self.io);
                return;
            }
            self.stream = stream;
            self.mutex.unlock(self.io);

            var framer: media_commands.Framer = .{};
            var chunk: [512]u8 = undefined;
            while (true) {
                var descriptor: c.struct_pollfd = .{
                    .fd = stream.socket.handle,
                    .events = c.POLLIN | c.POLLHUP,
                    .revents = 0,
                };
                const ready = c.poll(&descriptor, 1, -1);
                if (ready < 0) {
                    if (posix.errno(ready) == .INTR) continue;
                    framer.finish(&self.command_queue);
                    break;
                }
                if (ready == 0) continue;
                // The provider socket stays open for the widget lifetime.
                // poll(2) blocks without idle work and proves that a short
                // command or EOF is ready. A bare nonblocking read after a
                // command can otherwise report EAGAIN and falsely sever the
                // healthy per-widget channel.
                const read = posix.read(stream.socket.handle, &chunk) catch |err| switch (err) {
                    error.WouldBlock => continue,
                    else => {
                        framer.finish(&self.command_queue);
                        break;
                    },
                };
                if (read == 0) {
                    framer.finish(&self.command_queue);
                    break;
                }
                if (!framer.feed(&self.command_queue, chunk[0..read])) break;
            }
            self.mutex.lockUncancelable(self.io);
            if (self.stream) |active| {
                if (active.socket.handle == stream.socket.handle) self.stream = null;
            }
            const should_stop = self.stopping;
            self.mutex.unlock(self.io);
            // The reader thread owns the accepted descriptor. Writers only
            // shut it down to wake this loop, avoiding close-vs-read races.
            stream.close(self.io);
            if (should_stop) return;
        }
    }

    fn failStreamLocked(self: *ProviderEndpoint, stream: std.Io.net.Stream) void {
        // A failed write is fatal for this per-widget channel. Mark stopping
        // before shutdown so the reader cannot race back into accept() after
        // observing the HUP while slot teardown is starting.
        self.stopping = true;
        _ = c.shutdown(stream.socket.handle, c.SHUT_RDWR);
        self.stream = null;
    }

    fn sendCompleteNonblockingImpl(comptime force_backpressure: bool, handle: posix.fd_t, bytes: []const u8) bool {
        if (force_backpressure) return false;
        const sent = c.send(
            handle,
            bytes.ptr,
            bytes.len,
            c.MSG_DONTWAIT | c.MSG_NOSIGNAL,
        );
        return sent > 0 and @as(usize, @intCast(sent)) == bytes.len;
    }

    fn sendCompleteNonblocking(handle: posix.fd_t, bytes: []const u8) bool {
        return sendCompleteNonblockingImpl(false, handle, bytes);
    }

    pub fn write(self: *ProviderEndpoint, bytes: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const stream = self.stream orelse return false;
        if (sendCompleteNonblocking(stream.socket.handle, bytes)) return true;

        // This method runs on the shared supervision loop. A partial write,
        // EAGAIN, or any other error is therefore a channel failure, never an
        // invitation to retry here. Shutting the stream down makes a partial
        // newline frame an EOF protocol failure and lets the existing
        // channel-failure path crash-restart only this widget.
        self.failStreamLocked(stream);
        return false;
    }

    pub fn disconnect(self: *ProviderEndpoint) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stream) |stream| self.failStreamLocked(stream);
    }

    pub fn takeCommand(self: *ProviderEndpoint) ?media_commands.Command {
        return self.command_queue.take();
    }

    pub fn takeNack(self: *ProviderEndpoint) ?u64 {
        return self.command_queue.takeNack();
    }
};

const CostSamples = struct {
    previous_ticks_ns: u64 = 0,
    previous_sample_ms: u64 = 0,
    private_samples: [15]u64 = [_]u64{0} ** 15,
    cpu_samples: [15]f64 = [_]f64{0} ** 15,
    sample_count: usize = 0,
    sample_cursor: usize = 0,

    fn add(self: *CostSamples, footprint: u64, ticks_ns: u64, now_ms: u64) void {
        const elapsed_ms = now_ms -| self.previous_sample_ms;
        const tick_delta = ticks_ns -| self.previous_ticks_ns;
        const cpu = if (elapsed_ms == 0) 0 else 100.0 * @as(f64, @floatFromInt(tick_delta)) / (@as(f64, @floatFromInt(elapsed_ms)) * std.time.ns_per_ms);
        self.private_samples[self.sample_cursor] = footprint;
        self.cpu_samples[self.sample_cursor] = @round(cpu * 10.0) / 10.0;
        self.sample_cursor = (self.sample_cursor + 1) % self.private_samples.len;
        self.sample_count = @min(self.sample_count + 1, self.private_samples.len);
        self.previous_ticks_ns = ticks_ns;
        self.previous_sample_ms = now_ms;
    }

    fn averages(self: *const CostSamples) struct { private_mb: f64, cpu: f64 } {
        if (self.sample_count == 0) return .{ .private_mb = 0, .cpu = 0 };
        var private_total: u64 = 0;
        var cpu_total: f64 = 0;
        for (self.private_samples[0..self.sample_count]) |value| private_total += value;
        for (self.cpu_samples[0..self.sample_count]) |value| cpu_total += value;
        return .{
            .private_mb = @as(f64, @floatFromInt(private_total)) / @as(f64, @floatFromInt(self.sample_count)) / (1024.0 * 1024.0),
            .cpu = cpu_total / @as(f64, @floatFromInt(self.sample_count)),
        };
    }
};

const MacSlotState = struct {
    process: ?posix.pid_t = null,
    exit_code: ?u32 = null,
    endpoint: ?*ProviderEndpoint = null,
    media_command_executor: ?*system_providers.MediaCommandExecutor = null,
    command_rate: media_commands.RateLimiter = .{},
    costs: CostSamples = .{},
    threads: u32 = 0,
    backend_path_buffer: [max_path_bytes]u8 = undefined,
    backend_path_len: usize = 0,

    fn backendPath(self: *const MacSlotState) []const u8 {
        return self.backend_path_buffer[0..self.backend_path_len];
    }
};

const Slot = supervisor.Slot(MacSlotState);

const Host = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    registry_path: []const u8,
    status_path: []const u8,
    status_temp_path: []const u8,
    runtime_exe: []const u8,
    cli_script: []const u8,
    runtime_root: []const u8,
    slots: [max_widgets]Slot = [_]Slot{.{}} ** max_widgets,
    sampler: system_providers.Sampler = .{},
    previous_cpu: [8192]u8 = undefined,
    previous_cpu_len: usize = 0,
    previous_memory: [512]u8 = undefined,
    previous_memory_len: usize = 0,
    previous_media: [media.max_media_frame_bytes]u8 = undefined,
    previous_media_len: usize = 0,
    system_frames: u64 = 0,
    audio_provider: audio.Provider = .{},
    audio_authorization_marker: []const u8,
    audio_authorization_mtime: i128 = 0,
    audio_pipe_frames: u64 = 0,
    media_provider: *system_providers.MediaProvider,
    media_pipe_frames: u64 = 0,
    art_cache_root: []const u8,
    /// Compile-time-only hosted seam. It exercises the authenticated UDS,
    /// command framer, and ack writer without invoking a private-framework
    /// helper on a player-less CI runner.
    automation_seam: bool = false,
    status_write_failures: u64 = 0,
    /// The shared render host: one Metal-owning process every widget's
    /// frames route through (docs/macos-memory-handoff.md carries the
    /// receipts — widgets drop from ~125 MB to ~30 MB because only this
    /// process pays the GPU driver's per-process submission arena).
    /// Supervised here like a widget: crash -> respawn with backoff;
    /// widgets reconnect on their own.
    render_host_name: []const u8 = render_host_default_name,
    render_host_process: ?posix.pid_t = null,
    render_host_restart_at_ms: u64 = 0,

    fn loadRegistry(self: *Host) !void {
        const owned_bytes = std.Io.Dir.cwd().readFileAlloc(self.io, self.registry_path, self.allocator, .limited(256 * 1024)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (owned_bytes) |bytes| self.allocator.free(bytes);
        const parsed = try registry.parse(self.allocator, owned_bytes orelse "{\"widgets\":[]}");
        defer parsed.deinit();
        try supervisor.reconcile(&self.slots, parsed.value.widgets, self);
        if (authorizationMtime(self.io, self.audio_authorization_marker)) |mtime| {
            if (mtime != self.audio_authorization_mtime) {
                self.audio_authorization_mtime = mtime;
                self.audio_provider.setAuthorized(false);
                self.audio_provider.setAuthorized(true);
            }
        } else {
            self.audio_authorization_mtime = 0;
            self.audio_provider.setAuthorized(false);
        }
    }

    pub fn running(self: *const Host, index: usize) bool {
        return self.slots[index].platform.process != null;
    }
    pub fn stop(self: *Host, index: usize, graceful: bool) void {
        self.stopSlot(&self.slots[index], graceful);
    }
    pub fn artifactMtime(self: *Host, source: []const u8) i128 {
        const path = std.fs.path.join(self.allocator, &.{ source, "dist", "bundle.js" }) catch return 0;
        defer self.allocator.free(path);
        const stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch return 0;
        return stat.mtime.nanoseconds;
    }

    fn sourceExists(self: *Host, source: []const u8) bool {
        _ = std.Io.Dir.cwd().statFile(self.io, source, .{}) catch return false;
        return true;
    }

    fn supervise(self: *Host, now_ms: u64) void {
        for (&self.slots) |*slot| {
            if (!slot.used or !slot.enabled) continue;
            const process_running = slot.platform.process != null;
            const exited = if (process_running) self.processExited(slot) else false;
            switch (supervisor.nextSlotAction(slot, self.sourceExists(slot.source()), process_running, exited, now_ms)) {
                .none => {},
                .stop_missing => self.stopSlot(slot, true),
                .handle_exit => self.handleExit(slot, now_ms),
                .launch => self.launch(slot, now_ms) catch |err| {
                    supervisor.recordLaunchFailure(slot, now_ms, err);
                },
            }
        }
    }

    fn drainMediaCommands(self: *Host, now_ms: u64) void {
        var ack_buffer: [64]u8 = undefined;
        for (&self.slots) |*slot| {
            const endpoint = slot.platform.endpoint orelse continue;
            var channel_failed = false;
            if (slot.platform.media_command_executor) |executor| {
                while (executor.takeResult()) |result| {
                    switch (result.outcome) {
                        .accepted, .declined => {
                            const ack = media_commands.formatAck(
                                result.id,
                                result.outcome == .accepted,
                                &ack_buffer,
                            ) catch continue;
                            if (!endpoint.write(ack)) {
                                channel_failed = true;
                                break;
                            }
                        },
                        .channel_failure => {
                            channel_failed = true;
                            break;
                        },
                    }
                }
            }
            if (channel_failed) {
                self.restartAfterMediaChannelFailure(slot, now_ms);
                continue;
            }
            while (endpoint.takeNack()) |id| {
                const ack = media_commands.formatAck(id, false, &ack_buffer) catch continue;
                if (!endpoint.write(ack)) {
                    channel_failed = true;
                    break;
                }
            }
            if (channel_failed) {
                self.restartAfterMediaChannelFailure(slot, now_ms);
                continue;
            }
            while (endpoint.takeCommand()) |command| {
                const allowed = media_commands.authorize(slot.wants_media_transport, &slot.platform.command_rate, now_ms);
                if (self.automation_seam) {
                    if (!writeAutomationMediaAck(endpoint, command.id, &ack_buffer)) {
                        channel_failed = true;
                        break;
                    }
                    continue;
                }
                const queued = allowed and if (slot.platform.media_command_executor) |executor|
                    executor.submit(command)
                else
                    false;
                if (!queued) {
                    const ack = media_commands.formatAck(command.id, false, &ack_buffer) catch continue;
                    if (!endpoint.write(ack)) {
                        channel_failed = true;
                        break;
                    }
                }
            }
            if (channel_failed) {
                self.restartAfterMediaChannelFailure(slot, now_ms);
                continue;
            }
            if (endpoint.command_queue.malformed.swap(false, .acq_rel)) {
                std.log.warn("dropping malformed media command frame from widget {s}", .{slot.name()});
            }
        }
    }

    /// Keep exactly one render host alive. The automation seam keeps the
    /// legacy in-process renderer (its verdicts sample the widget's own
    /// drawable), so it neither spawns a host nor points widgets at one.
    fn superviseRenderHost(self: *Host, now_ms: u64) void {
        if (self.automation_seam) return;
        if (self.render_host_process) |pid| {
            var status: c_int = 0;
            const result = posix.system.waitpid(pid, &status, posix.W.NOHANG);
            if (posix.errno(result) != .SUCCESS or result == 0) return;
            std.log.warn("render host pid={d} exited; restarting in {d} ms (widgets keep retained frames and reconnect)", .{ pid, render_host_restart_backoff_ms });
            self.removeChildMarker(pid);
            self.render_host_process = null;
            self.render_host_restart_at_ms = now_ms + render_host_restart_backoff_ms;
        }
        if (self.render_host_process != null or now_ms < self.render_host_restart_at_ms) return;
        const argv = [_][]const u8{ self.runtime_exe, "--render-host", self.render_host_name };
        var environment = self.environ_map.clone(self.allocator) catch return;
        defer environment.deinit();
        const child = std.process.spawn(self.io, .{
            .argv = &argv,
            .environ_map = &environment,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .pgid = 0,
        }) catch |err| {
            std.log.err("render host spawn failed: {s}; retrying in {d} ms", .{ @errorName(err), render_host_restart_backoff_ms });
            self.render_host_restart_at_ms = now_ms + render_host_restart_backoff_ms;
            return;
        };
        self.render_host_process = child.id.?;
        self.writeChildMarker(child.id.?) catch {};
        std.log.info("render host started pid={d} name={s}", .{ child.id.?, self.render_host_name });
    }

    fn stopRenderHost(self: *Host) void {
        const pid = self.render_host_process orelse return;
        // Same escalation as widget teardown: the marker is removed only
        // after the process is actually dead and reaped — a TERM-ignoring
        // host must never outlive its recovery marker, or the next weaverd
        // cannot find the orphan.
        posix.kill(pid, .TERM) catch {};
        var status: c_int = 0;
        const deadline = monotonicMilliseconds() + 1500;
        var dead = false;
        while (monotonicMilliseconds() < deadline) {
            const result = posix.system.waitpid(pid, &status, posix.W.NOHANG);
            if (posix.errno(result) == .CHILD or (posix.errno(result) == .SUCCESS and result != 0)) {
                dead = true;
                break;
            }
            std.Io.sleep(self.io, .fromMilliseconds(20), .awake) catch break;
        }
        if (!dead) {
            posix.kill(pid, .KILL) catch {};
            while (true) {
                const result = posix.system.waitpid(pid, &status, 0);
                if (posix.errno(result) != .INTR) break;
            }
        }
        self.removeChildMarker(pid);
        self.render_host_process = null;
    }

    fn restartAfterMediaChannelFailure(self: *Host, slot: *Slot, now_ms: u64) void {
        std.log.warn("restarting widget {s} after fatal provider channel failure", .{slot.name()});
        self.stopSlot(slot, false);
        supervisor.recordChannelFailure(slot, now_ms);
    }

    fn launch(self: *Host, slot: *Slot, now_ms: u64) !void {
        try self.ensureBundle(slot.source());
        const dist = try std.fs.path.join(self.allocator, &.{ slot.source(), "dist" });
        defer self.allocator.free(dist);
        const manifest_path = try std.fs.path.join(self.allocator, &.{ dist, "widget.json" });
        defer self.allocator.free(manifest_path);
        const manifest_bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, manifest_path, self.allocator, .limited(64 * 1024));
        defer self.allocator.free(manifest_bytes);
        const Manifest = struct {
            subscribe: []const []const u8 = &.{},
            capabilities: []const []const u8 = &.{},
            renderBackend: []const u8 = "software",
        };
        const manifest = try std.json.parseFromSlice(Manifest, self.allocator, manifest_bytes, .{ .ignore_unknown_fields = true });
        defer manifest.deinit();
        supervisor.selectManifest(slot, manifest.value.subscribe, manifest.value.capabilities, manifest.value.renderBackend, false);

        const needs_endpoint = slot.wants_cpu or slot.wants_memory or slot.wants_audio or slot.wants_media or slot.wants_media_transport;
        var endpoint_path: ?[]u8 = null;
        defer if (endpoint_path) |path| self.allocator.free(path);
        if (needs_endpoint) {
            var endpoint_token: [16]u8 = undefined;
            try self.io.randomSecure(&endpoint_token);
            const endpoint_token_hex = std.fmt.bytesToHex(endpoint_token, .lower);
            endpoint_path = try std.fmt.allocPrint(self.allocator, "{s}/widget-{s}.sock", .{ self.runtime_root, endpoint_token_hex });
            slot.platform.endpoint = try ProviderEndpoint.start(self.io, self.allocator, endpoint_path.?);
        }
        errdefer if (slot.platform.endpoint) |endpoint| {
            endpoint.deinit();
            slot.platform.endpoint = null;
        };
        if (slot.wants_media_transport and !self.automation_seam) {
            slot.platform.media_command_executor = try system_providers.MediaCommandExecutor.start(
                self.io,
                self.allocator,
                self.media_provider,
            );
        }
        errdefer if (slot.platform.media_command_executor) |executor| {
            executor.deinit();
            slot.platform.media_command_executor = null;
        };

        const backend_hash = std.hash.Wyhash.hash(0, slot.name());
        const backend_path = try std.fmt.bufPrint(&slot.platform.backend_path_buffer, "{s}.backend-{x}", .{ self.status_path, backend_hash });
        slot.platform.backend_path_len = backend_path.len;
        std.Io.Dir.cwd().deleteFile(self.io, backend_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        var environment = try self.environ_map.clone(self.allocator);
        defer environment.deinit();
        try environment.put(backend_environment, backend_path);
        if (endpoint_path) |path| try environment.put(provider_environment, path);
        if (slot.wants_media) try environment.put(art_cache_environment, self.art_cache_root);
        if (!self.automation_seam) {
            // The macOS cutover: weaverd-owned widgets render through the
            // shared host and never create a Metal device in-process.
            try environment.put(shared_renderer_environment, "1");
            try environment.put(render_host_name_environment, self.render_host_name);
        }
        const dev_argv = [_][]const u8{ self.runtime_exe, "--dev", dist };
        const run_argv = [_][]const u8{ self.runtime_exe, dist };
        const argv: []const []const u8 = if (slot.dev) &dev_argv else &run_argv;
        const child = try std.process.spawn(self.io, .{
            .argv = argv,
            .environ_map = &environment,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .pgid = 0,
        });
        slot.platform.process = child.id.?;
        if (slot.platform.endpoint) |endpoint| try endpoint.bind(slot.platform.process.?);
        errdefer self.stopSlot(slot, false);
        try self.writeChildMarker(slot.platform.process.?);
        slot.platform.exit_code = null;
        slot.platform.costs = .{};
        slot.platform.command_rate = .{};
        supervisor.markRunning(slot, now_ms, self.artifactMtime(slot.source()));
    }

    fn processExited(_: *Host, slot: *Slot) bool {
        const pid = slot.platform.process orelse return false;
        var status: c_int = 0;
        while (true) {
            const result = posix.system.waitpid(pid, &status, posix.W.NOHANG);
            switch (posix.errno(result)) {
                .SUCCESS => {
                    if (result == 0) return false;
                    slot.platform.exit_code = if (posix.W.IFEXITED(@bitCast(status))) posix.W.EXITSTATUS(@bitCast(status)) else 1;
                    return true;
                },
                .INTR => continue,
                .CHILD => return true,
                else => return false,
            }
        }
    }

    fn handleExit(self: *Host, slot: *Slot, now_ms: u64) void {
        const exit_code = slot.platform.exit_code;
        self.closeProcess(slot);
        if (!self.sourceExists(slot.source())) {
            _ = supervisor.nextSlotAction(slot, false, false, false, now_ms);
            return;
        }
        supervisor.recordCrash(slot, now_ms, exit_code);
    }

    fn stopSlot(self: *Host, slot: *Slot, graceful: bool) void {
        const pid = slot.platform.process orelse {
            self.closeProcess(slot);
            return;
        };
        if (!self.processExited(slot)) {
            posix.kill(pid, if (graceful) .TERM else .KILL) catch {};
            const deadline = monotonicMilliseconds() + @as(u64, if (graceful) 1500 else 250);
            while (!self.processExited(slot) and monotonicMilliseconds() < deadline) std.Io.sleep(self.io, .fromMilliseconds(20), .awake) catch break;
            if (slot.platform.process != null and !self.processExited(slot)) {
                posix.kill(-pid, .KILL) catch posix.kill(pid, .KILL) catch {};
                while (!self.processExited(slot)) std.Io.sleep(self.io, .fromMilliseconds(10), .awake) catch break;
            }
        }
        self.closeProcess(slot);
    }

    fn closeProcess(self: *Host, slot: *Slot) void {
        if (slot.platform.process) |pid| self.removeChildMarker(pid);
        // Reload, crash, and uninstall all run on the supervision loop. An
        // in-flight adapter helper retains its own bounded 2.5 s timeout, so
        // transfer executor ownership to its detached worker instead of
        // joining here and pausing every Widget.
        if (slot.platform.media_command_executor) |executor| executor.stopDetached();
        slot.platform.media_command_executor = null;
        if (slot.platform.endpoint) |endpoint| endpoint.deinit();
        slot.platform.endpoint = null;
        slot.platform.process = null;
        slot.platform.exit_code = null;
        slot.platform.costs = .{};
        if (slot.platform.backend_path_len > 0) std.Io.Dir.cwd().deleteFile(self.io, slot.platform.backendPath()) catch {};
        slot.platform.backend_path_len = 0;
    }

    fn writeChildMarker(self: *Host, pid: posix.pid_t) !void {
        const path = try std.fmt.allocPrint(self.allocator, "{s}/child-{d}.pid", .{ self.runtime_root, pid });
        defer self.allocator.free(path);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = self.runtime_exe });
    }

    fn removeChildMarker(self: *Host, pid: posix.pid_t) void {
        const path = std.fmt.allocPrint(self.allocator, "{s}/child-{d}.pid", .{ self.runtime_root, pid }) catch return;
        defer self.allocator.free(path);
        std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
    }

    fn ensureBundle(self: *Host, source: []const u8) !void {
        const source_path = try std.fs.path.join(self.allocator, &.{ source, "widget.tsx" });
        defer self.allocator.free(source_path);
        const bundle_path = try std.fs.path.join(self.allocator, &.{ source, "dist", "bundle.js" });
        defer self.allocator.free(bundle_path);
        const manifest_path = try std.fs.path.join(self.allocator, &.{ source, "dist", "widget.json" });
        defer self.allocator.free(manifest_path);
        const source_stat = try std.Io.Dir.cwd().statFile(self.io, source_path, .{});
        const bundle_stat = std.Io.Dir.cwd().statFile(self.io, bundle_path, .{}) catch null;
        const manifest_stat = std.Io.Dir.cwd().statFile(self.io, manifest_path, .{}) catch null;
        if (bundle_stat != null and manifest_stat != null and bundle_stat.?.mtime.nanoseconds >= source_stat.mtime.nanoseconds) return;
        const result = try std.process.run(self.allocator, self.io, .{
            .argv = &.{ "node", self.cli_script, "bundle", source },
            .stdout_limit = .limited(64 * 1024),
            .stderr_limit = .limited(64 * 1024),
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.BundleFailed,
            else => return error.BundleFailed,
        }
    }

    fn sampleCosts(self: *Host, now_ms: u64) void {
        for (&self.slots) |*slot| {
            const pid = slot.platform.process orelse continue;
            var footprint: u64 = 0;
            var cpu_time_ns: u64 = 0;
            var threads: u32 = 0;
            if (c.weaver_process_sample(pid, &footprint, &cpu_time_ns, &threads) != 0) continue;
            slot.platform.threads = threads;
            slot.platform.costs.add(footprint, cpu_time_ns, now_ms);
        }
    }

    fn sampleProviders(self: *Host) void {
        if (!supervisor.hasSubscription(&self.slots, .cpu, self) and !supervisor.hasSubscription(&self.slots, .memory, self)) return;
        const sample = self.sampler.sample() catch return orelse return;
        var cpu_buffer: [8192]u8 = undefined;
        const cpu = provider_protocol.formatCpu(sample.cpu, &cpu_buffer) catch return;
        var memory_buffer: [512]u8 = undefined;
        const memory = provider_protocol.formatMemory(sample.memory, &memory_buffer) catch return;
        const cpu_changed = !std.mem.eql(u8, cpu, self.previous_cpu[0..self.previous_cpu_len]);
        const memory_changed = !std.mem.eql(u8, memory, self.previous_memory[0..self.previous_memory_len]);
        for (&self.slots) |*slot| {
            const endpoint = slot.platform.endpoint orelse continue;
            const send_cpu = provider_protocol.deliveryNeeded(slot.wants_cpu, slot.cpu_sent, cpu_changed);
            const send_memory = provider_protocol.deliveryNeeded(slot.wants_memory, slot.memory_sent, memory_changed);
            if (send_cpu and send_memory) {
                // One system sample is one socket publication. Keeping the two
                // newline-delimited frames in a single bounded write prevents
                // the runtime's 1 Hz drain from phase-splitting CPU and memory
                // indefinitely while preserving the frozen per-frame wire
                // format and all-or-nothing delivery accounting.
                var batch: [cpu_buffer.len + memory_buffer.len]u8 = undefined;
                @memcpy(batch[0..cpu.len], cpu);
                @memcpy(batch[cpu.len..][0..memory.len], memory);
                if (endpoint.write(batch[0 .. cpu.len + memory.len])) {
                    slot.cpu_sent = true;
                    slot.memory_sent = true;
                    self.system_frames += 2;
                }
                continue;
            }
            if (send_cpu and endpoint.write(cpu)) {
                slot.cpu_sent = true;
                self.system_frames += 1;
            }
            if (send_memory and endpoint.write(memory)) {
                slot.memory_sent = true;
                self.system_frames += 1;
            }
        }
        @memcpy(self.previous_cpu[0..cpu.len], cpu);
        self.previous_cpu_len = cpu.len;
        @memcpy(self.previous_memory[0..memory.len], memory);
        self.previous_memory_len = memory.len;
    }

    fn hasAudioSubscribers(self: *const Host) bool {
        return supervisor.hasSubscription(&self.slots, .audio, self);
    }

    fn hasMediaSubscribers(self: *const Host) bool {
        return supervisor.hasSubscription(&self.slots, .media, self);
    }

    fn sampleAudio(self: *Host, now_ms: u64) void {
        const active = self.hasAudioSubscribers();
        self.audio_provider.setActive(active, now_ms);
        if (!active) return;
        const frame = self.audio_provider.poll(now_ms) orelse return;
        var buffer: [512]u8 = undefined;
        const encoded = audio.formatFrame(frame, &buffer) catch return;
        var delivered = false;
        for (&self.slots) |*slot| {
            const endpoint = slot.platform.endpoint orelse continue;
            if (slot.wants_audio and endpoint.write(encoded)) delivered = true;
        }
        if (delivered) self.audio_pipe_frames += 1;
    }

    fn sampleMedia(self: *Host, now_ms: u64) void {
        const active = self.hasMediaSubscribers();
        self.media_provider.setActive(active);
        if (!active) {
            self.previous_media_len = 0;
            return;
        }
        const queued = self.media_provider.takeFrame(now_ms);
        var encoded: []const u8 = self.previous_media[0..self.previous_media_len];
        var changed = false;
        var force = false;
        var frame_buffer: [media.max_media_frame_bytes]u8 = undefined;
        if (queued) |item| {
            encoded = media.formatFrame(&item.frame, &frame_buffer) catch |err| {
                std.log.err("macOS media frame exceeded protocol bound or failed to encode: {s}", .{@errorName(err)});
                return;
            };
            changed = !std.mem.eql(u8, encoded, self.previous_media[0..self.previous_media_len]);
            force = item.force;
        } else if (encoded.len == 0) {
            return;
        }

        var delivered = false;
        for (&self.slots) |*slot| {
            const endpoint = slot.platform.endpoint orelse continue;
            if (!slot.wants_media) continue;
            if ((!slot.media_sent or changed or force) and endpoint.write(encoded)) {
                slot.media_sent = true;
                delivered = true;
            }
        }
        if (delivered) self.media_pipe_frames += 1;
        if (queued != null) {
            @memcpy(self.previous_media[0..encoded.len], encoded);
            self.previous_media_len = encoded.len;
        }
    }

    fn writeStatus(self: *Host, now_ms: u64) void {
        var entries: [max_widgets]supervisor.StatusEntry = undefined;
        var entry_count: usize = 0;
        var backend_allocations = [_]?[]u8{null} ** max_widgets;
        defer for (backend_allocations) |value| if (value) |bytes| self.allocator.free(bytes);
        for (&self.slots, 0..) |*slot, index| {
            if (!slot.used) continue;
            const average = slot.platform.costs.averages();
            var backend: []const u8 = "-";
            if (slot.platform.process != null and slot.platform.backend_path_len > 0) {
                backend_allocations[index] = std.Io.Dir.cwd().readFileAlloc(self.io, slot.platform.backendPath(), self.allocator, .limited(32)) catch null;
                if (backend_allocations[index]) |value| backend = value;
            }
            entries[entry_count] = .{
                .name = slot.name(),
                .pid = if (slot.platform.process) |pid| @intCast(pid) else 0,
                .private_mb = average.private_mb,
                .cpu_percent = average.cpu,
                .threads = slot.platform.threads,
                .backend = backend,
                .uptime_seconds = if (slot.platform.process != null) (now_ms -| slot.started_ms) / 1000 else 0,
                .state = slot.state,
                .reason = slot.reason(),
            };
            entry_count += 1;
        }
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        supervisor.writeStatus(&output.writer, @intCast(posix.system.getpid()), .{
            .system_subscribers = supervisor.systemSubscriberCount(&self.slots, self),
            .system_sample_count = self.sampler.sample_calls,
            .system_frames = self.system_frames,
            .audio_capture_active = self.audio_provider.availability == .live,
            .audio_silent = self.audio_provider.silent,
            .audio_pipe_frames = self.audio_pipe_frames,
            .media_pipe_frames = self.media_pipe_frames,
            .media_availability = self.media_provider.availabilityLabel(),
            .media_subscribers = supervisor.subscriptionCount(&self.slots, .media, self),
            .audio_availability = self.audio_provider.availability.label(),
            .audio_subscribers = supervisor.subscriptionCount(&self.slots, .audio, self),
            .audio_capture_starts = self.audio_provider.capture_starts,
            .audio_provider_frames = self.audio_provider.frame_count,
            .audio_last_error = self.audio_provider.last_error,
        }, entries[0..entry_count]) catch |err| return self.noteStatusWriteFailure("encode", err);
        var cwd = std.Io.Dir.cwd();
        cwd.writeFile(self.io, .{ .sub_path = self.status_temp_path, .data = output.written() }) catch |err| return self.noteStatusWriteFailure("write temporary file", err);
        cwd.rename(self.status_temp_path, cwd, self.status_path, self.io) catch |err| return self.noteStatusWriteFailure("publish", err);
        self.noteStatusWriteRecovery();
    }

    fn noteStatusWriteFailure(self: *Host, operation: []const u8, err: anyerror) void {
        self.status_write_failures += 1;
        if (self.status_write_failures == 1) {
            std.log.err(
                "host status publication degraded while attempting to {s}: {s}; path={s}; repeated failures are suppressed until recovery",
                .{ operation, @errorName(err), self.status_path },
            );
        }
    }

    fn noteStatusWriteRecovery(self: *Host) void {
        if (self.status_write_failures == 0) return;
        std.log.info("host status publication recovered after {d} consecutive failures", .{self.status_write_failures});
        self.status_write_failures = 0;
    }
};

fn writeAutomationMediaAck(endpoint: *ProviderEndpoint, id: u64, buffer: *[64]u8) bool {
    const ack = media_commands.formatAck(id, false, buffer) catch return false;
    return endpoint.write(ack);
}

fn peerPid(stream: std.Io.net.Stream) ?posix.pid_t {
    var pid: c.pid_t = 0;
    var length: c.socklen_t = @sizeOf(c.pid_t);
    if (c.getsockopt(
        stream.socket.handle,
        c.SOL_LOCAL,
        c.LOCAL_PEERPID,
        &pid,
        &length,
    ) != 0) return null;
    return pid;
}

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const home = init.environ_map.get("HOME") orelse return error.MissingHome;
    const data_root = try std.fs.path.join(allocator, &.{ home, "Library", "Application Support", "Weaver" });
    defer allocator.free(data_root);
    const audio_authorization_marker = try std.fs.path.join(allocator, &.{ data_root, "audio-authorization" });
    defer allocator.free(audio_authorization_marker);
    const art_cache_root = try std.fs.path.join(allocator, &.{ home, "Library", "Caches", "weaver", "art" });
    defer allocator.free(art_cache_root);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--authorize-audio")) {
        try std.Io.Dir.cwd().createDirPath(init.io, data_root);
        return authorizeAudio(init.io, audio_authorization_marker);
    }
    const runtime_root = try runtimeRoot(allocator, data_root, init.environ_map.get("TMPDIR"));
    defer allocator.free(runtime_root);
    const control_path = try std.fs.path.join(allocator, &.{ runtime_root, "control.sock" });
    defer allocator.free(control_path);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--probe")) return controlRequest(init.io, control_path, "probe\n");
    if (args.len == 2 and std.mem.eql(u8, args[1], "--probe-reload-ready")) return controlRequest(init.io, control_path, "probe\n");
    if (args.len == 2 and std.mem.eql(u8, args[1], "--signal-reload")) return controlRequest(init.io, control_path, "reload\n");
    if (args.len == 2 and std.mem.eql(u8, args[1], "--signal-down")) return controlRequest(init.io, control_path, "down\n");

    try std.Io.Dir.cwd().createDirPath(init.io, data_root);
    const lock_path = try std.fmt.allocPrint(allocator, "{s}.lock", .{runtime_root});
    defer allocator.free(lock_path);
    const lock = std.Io.Dir.cwd().createFile(init.io, lock_path, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
        .permissions = @enumFromInt(0o600),
    }) catch |err| switch (err) {
        error.WouldBlock => return,
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(init.io, lock_path) catch {};
    defer lock.close(init.io);

    const repo_root = if (init.environ_map.get("WEAVER_REPO_ROOT")) |path|
        try allocator.dupe(u8, path)
    else
        try repositoryRoot(init.io, allocator);
    defer allocator.free(repo_root);
    const runtime_exe = try std.fs.path.join(allocator, &.{ repo_root, "runtime", "zig-out", "bin", "weaver-widget" });
    defer allocator.free(runtime_exe);
    const cli_script = try std.fs.path.join(allocator, &.{ repo_root, "cli", "dist", "index.js" });
    defer allocator.free(cli_script);
    const adapter_paths = try mediaAdapterPaths(init.io, allocator, repo_root);
    defer adapter_paths.deinit(allocator);
    try std.Io.Dir.cwd().createDirPath(init.io, art_cache_root);
    const art_cache_root_z = try allocator.dupeZ(u8, art_cache_root);
    defer allocator.free(art_cache_root_z);
    if (c.weaver_secure_private_dir(art_cache_root_z.ptr) != 0) return error.InsecureArtCacheRoot;
    var media_art_cache = try art_cache.Cache.init(init.io, allocator, art_cache_root);
    defer media_art_cache.deinit();
    var media_provider: system_providers.MediaProvider = .{
        .io = init.io,
        .allocator = allocator,
        .script_path = adapter_paths.script,
        .framework_path = adapter_paths.framework,
        .cache = &media_art_cache,
        .platform_supported = c.weaver_macos_media_supported() != 0,
        .command_test_outcome = if (c.weaver_macos_automation_seam() != 0) .declined else null,
    };
    defer media_provider.deinit();
    cleanupStaleChildren(init.io, allocator, runtime_root, runtime_exe);
    std.Io.Dir.cwd().deleteTree(init.io, runtime_root) catch {};
    try std.Io.Dir.cwd().createDirPath(init.io, runtime_root);
    const runtime_root_z = try allocator.dupeZ(u8, runtime_root);
    defer allocator.free(runtime_root_z);
    // The root name is predictable and may fall back to sticky /tmp, so a
    // pre-created entry could be attacker-owned; endpoints only live in a
    // directory proven to be ours, a real directory, and mode 0700.
    if (c.weaver_secure_private_dir(runtime_root_z.ptr) != 0) return error.InsecureRuntimeRoot;
    defer std.Io.Dir.cwd().deleteTree(init.io, runtime_root) catch {};

    const registry_path = try std.fs.path.join(allocator, &.{ data_root, "registry.json" });
    defer allocator.free(registry_path);
    const status_path = try std.fs.path.join(allocator, &.{ data_root, "status.json" });
    defer allocator.free(status_path);
    const status_temp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{status_path});
    defer allocator.free(status_temp_path);
    cleanupBackendStatusFiles(init.io, data_root);
    const control = try ControlServer.start(init.io, allocator, control_path);
    defer control.deinit();

    var host: Host = .{
        .io = init.io,
        .allocator = allocator,
        .environ_map = init.environ_map,
        .registry_path = registry_path,
        .status_path = status_path,
        .status_temp_path = status_temp_path,
        .runtime_exe = runtime_exe,
        .cli_script = cli_script,
        .runtime_root = runtime_root,
        .audio_authorization_marker = audio_authorization_marker,
        .media_provider = &media_provider,
        .art_cache_root = art_cache_root,
        .automation_seam = c.weaver_macos_automation_seam() != 0,
        .render_host_name = init.environ_map.get(render_host_name_environment) orelse render_host_default_name,
    };
    defer host.audio_provider.deinit();
    try host.loadRegistry();
    // launchd and logout deliver SIGTERM; without a handler the host would die
    // uncleanly, orphaning widgets and the runtime root until the next start.
    if (c.weaver_install_termination_handler() != 0) return error.SignalHandlerFailed;
    var stopping = false;
    var next_cost_ms: u64 = 0;
    var next_provider_ms: u64 = 0;
    var audio_availability = host.audio_provider.availability;
    var media_availability = host.media_provider.availabilityLabel();
    while (!stopping) {
        if (c.weaver_termination_requested() != 0) break;
        var acknowledge_reload = false;
        if (control.take()) |command| switch (command) {
            .reload => {
                host.loadRegistry() catch {
                    control.complete(.failed);
                    continue;
                };
                acknowledge_reload = true;
            },
            .down => {
                control.complete(.ok);
                stopping = true;
            },
        };
        const now = monotonicMilliseconds();
        host.superviseRenderHost(now);
        host.supervise(now);
        host.drainMediaCommands(now);
        host.sampleAudio(now);
        // MediaProvider timestamps adapter frames and watchdog attempts with
        // Zig's awake clock. Keep its publication tick in that same domain;
        // CLOCK_MONOTONIC has a different epoch on macOS.
        host.sampleMedia(system_providers.mediaClockMilliseconds(init.io));
        const audio_availability_changed = audio_availability != host.audio_provider.availability;
        audio_availability = host.audio_provider.availability;
        const current_media_availability = host.media_provider.availabilityLabel();
        const media_availability_changed = !std.mem.eql(u8, media_availability, current_media_availability);
        media_availability = current_media_availability;
        if (now >= next_provider_ms) {
            host.sampleProviders();
            next_provider_ms = now + 1000;
        }
        if (acknowledge_reload or audio_availability_changed or media_availability_changed or now >= next_cost_ms) {
            host.sampleCosts(now);
            host.writeStatus(now);
            next_cost_ms = now + 2000;
        }
        if (acknowledge_reload) control.complete(.ok);
        if (!stopping) std.Io.sleep(init.io, .fromMilliseconds(if (host.hasAudioSubscribers()) 30 else 50), .awake) catch {};
    }
    for (&host.slots) |*slot| if (slot.platform.process != null) host.stopSlot(slot, true);
    host.stopRenderHost();
    host.audio_provider.setActive(false, monotonicMilliseconds());
    host.media_provider.setActive(false);
    // The down acknowledgement is sent before slot teardown. Detached command
    // workers have the adapter helper's 2.5 s hard timeout; keep provider
    // storage alive for one bounded grace window, then fail closed rather than
    // returning with a worker still holding its pointer.
    if (!host.media_provider.waitForCommandWorkers(3000)) {
        std.log.err("macOS media command worker exceeded its bounded shutdown window", .{});
        std.process.exit(1);
    }
    host.writeStatus(monotonicMilliseconds());
}

fn cleanupBackendStatusFiles(io: std.Io, directory_path: []const u8) void {
    var directory = std.Io.Dir.cwd().openDir(io, directory_path, .{ .iterate = true }) catch |err| {
        std.log.warn("could not inspect renderer status sidecars: {s}", .{@errorName(err)});
        return;
    };
    defer directory.close(io);
    var iterator = directory.iterate();
    while (iterator.next(io) catch |err| {
        std.log.warn("renderer status sidecar scan stopped: {s}", .{@errorName(err)});
        return;
    }) |entry| {
        if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, "status.json.backend-")) continue;
        directory.deleteFile(io, entry.name) catch |err| {
            std.log.warn("could not remove orphan renderer status sidecar {s}: {s}", .{ entry.name, @errorName(err) });
        };
    }
}

const MediaAdapterPaths = struct {
    script: []u8,
    framework: []u8,

    fn deinit(self: MediaAdapterPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.script);
        allocator.free(self.framework);
    }
};

fn mediaAdapterPaths(io: std.Io, allocator: std.mem.Allocator, repo_root: []const u8) !MediaAdapterPaths {
    const executable_dir = try std.process.executableDirPathAlloc(io, allocator);
    defer allocator.free(executable_dir);
    const app_macos_dir = std.mem.endsWith(u8, executable_dir, "/Weaverd.app/Contents/MacOS");
    const root = if (app_macos_dir)
        try std.fs.path.join(allocator, &.{ executable_dir, "..", "Resources", "mediaremote-adapter" })
    else
        try std.fs.path.join(allocator, &.{ repo_root, "host", "zig-out", "share", "weaver", "mediaremote-adapter" });
    defer allocator.free(root);
    return .{
        .script = try std.fs.path.join(allocator, &.{ root, "mediaremote-adapter.pl" }),
        .framework = try std.fs.path.join(allocator, &.{ root, "MediaRemoteAdapter.framework" }),
    };
}

fn authorizeAudio(io: std.Io, marker_path: []const u8) !void {
    var provider: audio.Provider = .{};
    defer provider.deinit();
    provider.setAuthorized(true);
    const deadline = monotonicMilliseconds() + 5 * 60 * 1000;
    while (monotonicMilliseconds() < deadline) {
        const now = monotonicMilliseconds();
        provider.setActive(true, now);
        _ = provider.poll(now);
        switch (provider.availability) {
            .live => {
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = marker_path, .data = "authorized\n" });
                std.debug.print("Weaver system audio authorized\n", .{});
                return;
            },
            .permission_denied => return error.AudioPermissionDenied,
            .device_unavailable => return error.AudioDeviceUnavailable,
            .capture_failed => return error.AudioCaptureFailed,
            else => {},
        }
        try std.Io.sleep(io, .fromMilliseconds(20), .awake);
    }
    return error.AudioAuthorizationTimedOut;
}

fn authorizationMtime(io: std.Io, marker_path: []const u8) ?i128 {
    const marker = std.Io.Dir.cwd().statFile(io, marker_path, .{}) catch return null;
    const executable = std.process.executablePathAlloc(io, std.heap.page_allocator) catch return null;
    defer std.heap.page_allocator.free(executable);
    const binary = std.Io.Dir.cwd().statFile(io, executable, .{}) catch return null;
    return if (marker.mtime.nanoseconds >= binary.mtime.nanoseconds) marker.mtime.nanoseconds else null;
}

fn controlRequest(io: std.Io, path: []const u8, request: []const u8) !void {
    const address = try std.Io.net.UnixAddress.init(path);
    const stream = address.connect(io) catch return error.HostNotRunning;
    defer stream.close(io);
    var write_buffer: [64]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(request);
    try writer.interface.flush();
    var read_buffer: [64]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    const response = try reader.interface.takeDelimiterExclusive('\n');
    if (std.mem.eql(u8, response, "ok")) return;
    if (std.mem.eql(u8, response, "failed")) return error.RegistryReloadFailed;
    return error.HostControlFailed;
}

/// A crashed host cannot rely on process-group teardown the way the Windows
/// Job object can. The replacement host reaps only marker-owned PIDs whose
/// live executable still exactly matches this checkout's runtime, avoiding
/// both orphan Widgets and PID-reuse collateral damage.
fn cleanupStaleChildren(io: std.Io, allocator: std.mem.Allocator, runtime_root: []const u8, runtime_exe: []const u8) void {
    var directory = std.Io.Dir.cwd().openDir(io, runtime_root, .{ .iterate = true }) catch return;
    defer directory.close(io);
    var iterator = directory.iterate();
    while (iterator.next(io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, "child-") or !std.mem.endsWith(u8, entry.name, ".pid")) continue;
        const pid_text = entry.name["child-".len .. entry.name.len - ".pid".len];
        const pid = std.fmt.parseInt(posix.pid_t, pid_text, 10) catch continue;
        if (pid <= 0) continue;
        const marker_path = std.fs.path.join(allocator, &.{ runtime_root, entry.name }) catch continue;
        defer allocator.free(marker_path);
        const marker_exe = std.Io.Dir.cwd().readFileAlloc(io, marker_path, allocator, .limited(max_path_bytes)) catch continue;
        defer allocator.free(marker_exe);
        if (!std.mem.eql(u8, marker_exe, runtime_exe)) continue;
        var actual_path: [c.WEAVER_PROCESS_PATH_CAPACITY]u8 = undefined;
        const actual_len = c.weaver_process_path(pid, &actual_path, actual_path.len);
        if (actual_len <= 0 or !std.mem.eql(u8, actual_path[0..@intCast(actual_len)], runtime_exe)) continue;
        posix.kill(-pid, .KILL) catch posix.kill(pid, .KILL) catch {};
    }
}

fn runtimeRoot(allocator: std.mem.Allocator, data_root: []const u8, temporary_root: ?[]const u8) ![]u8 {
    const requested_root = temporary_root orelse "/tmp";
    var candidate = try std.fmt.allocPrint(allocator, "{s}/weaver-{d}-{x}", .{ requested_root, posix.system.getuid(), std.hash.Wyhash.hash(0, data_root) });
    if (candidate.len + "/widget-ffffffffffffffffffffffffffffffff.sock".len <= std.Io.net.UnixAddress.max_len) return candidate;
    allocator.free(candidate);
    candidate = try std.fmt.allocPrint(allocator, "/tmp/weaver-{d}-{x}", .{ posix.system.getuid(), std.hash.Wyhash.hash(0, data_root) });
    return candidate;
}

fn repositoryRoot(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    const bin_dir = try std.process.executableDirPathAlloc(io, allocator);
    defer allocator.free(bin_dir);
    const zig_out = std.fs.path.dirname(bin_dir) orelse return error.ExecutablePathFailed;
    const host_dir = std.fs.path.dirname(zig_out) orelse return error.ExecutablePathFailed;
    const repo = std.fs.path.dirname(host_dir) orelse return error.ExecutablePathFailed;
    return allocator.dupe(u8, repo);
}

fn monotonicMilliseconds() u64 {
    var timestamp: posix.timespec = undefined;
    if (posix.errno(posix.system.clock_gettime(.MONOTONIC, &timestamp)) != .SUCCESS) return 0;
    const nanoseconds = @as(i128, timestamp.sec) * std.time.ns_per_s + timestamp.nsec;
    return @intCast(@max(0, nanoseconds) / std.time.ns_per_ms);
}

test "runtime socket root is short, per-user, and data-root-specific" {
    const first = try runtimeRoot(std.testing.allocator, "/Users/test/Library/Application Support/Weaver", "/var/folders/ab/cdefghijklmnopqrstuvwxyz/T/");
    defer std.testing.allocator.free(first);
    const second = try runtimeRoot(std.testing.allocator, "/Users/other/Library/Application Support/Weaver", "/tmp");
    defer std.testing.allocator.free(second);
    try std.testing.expect(std.mem.startsWith(u8, first, "/tmp/weaver-"));
    try std.testing.expect(first.len + "/widget-ffffffffffffffffffffffffffffffff.sock".len <= std.Io.net.UnixAddress.max_len);
    try std.testing.expect(!std.mem.eql(u8, first, second));
}

test "provider socket peer pid rejects a same-user hijacker pid" {
    var path_buffer: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/tmp/weaver-peer-test-{d}.sock", .{posix.system.getpid()});
    const endpoint = try ProviderEndpoint.start(std.testing.io, std.testing.allocator, path);
    defer endpoint.deinit();
    try endpoint.bind(posix.system.getpid() + 1);
    const address = try std.Io.net.UnixAddress.init(path);
    const stream = try address.connect(std.testing.io);
    defer stream.close(std.testing.io);
    try std.Io.sleep(std.testing.io, .fromMilliseconds(50), .awake);
    endpoint.mutex.lockUncancelable(std.testing.io);
    defer endpoint.mutex.unlock(std.testing.io);
    try std.testing.expect(endpoint.stream == null);
}

test "provider socket discards an unterminated command at EOF" {
    var path_buffer: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/tmp/weaver-command-eof-test-{d}.sock", .{posix.system.getpid()});
    const endpoint = try ProviderEndpoint.start(std.testing.io, std.testing.allocator, path);
    defer endpoint.deinit();
    try endpoint.bind(posix.system.getpid());
    const address = try std.Io.net.UnixAddress.init(path);
    const stream = try address.connect(std.testing.io);
    // LOCAL_PEERPID is only available while the peer is alive. Keep this
    // in-process client open until the accept thread has authenticated it;
    // otherwise a fast close can turn this framing test into a PID-race test.
    var accepted = false;
    for (0..100) |_| {
        endpoint.mutex.lockUncancelable(std.testing.io);
        accepted = endpoint.stream != null;
        endpoint.mutex.unlock(std.testing.io);
        if (accepted) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
    }
    try std.testing.expect(accepted);
    {
        defer stream.close(std.testing.io);
        var write_buffer: [256]u8 = undefined;
        var writer = stream.writer(std.testing.io, &write_buffer);
        try writer.interface.writeAll("{\"command\":\"media\",\"verb\":\"play\",\"id\":1}");
        try writer.interface.flush();
    }
    for (0..100) |_| {
        if (endpoint.command_queue.malformed.load(.acquire)) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
    }
    try std.testing.expect(endpoint.command_queue.malformed.load(.acquire));
    try std.testing.expect(endpoint.takeCommand() == null);
}

test "provider socket dispatches a short command while the widget stays connected" {
    var path_buffer: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/tmp/weaver-command-live-test-{d}.sock", .{posix.system.getpid()});
    const endpoint = try ProviderEndpoint.start(std.testing.io, std.testing.allocator, path);
    defer endpoint.deinit();
    try endpoint.bind(posix.system.getpid());
    const address = try std.Io.net.UnixAddress.init(path);
    const stream = try address.connect(std.testing.io);
    defer stream.close(std.testing.io);

    var accepted = false;
    for (0..100) |_| {
        endpoint.mutex.lockUncancelable(std.testing.io);
        accepted = endpoint.stream != null;
        endpoint.mutex.unlock(std.testing.io);
        if (accepted) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
    }
    try std.testing.expect(accepted);

    var write_buffer: [128]u8 = undefined;
    var writer = stream.writer(std.testing.io, &write_buffer);
    try writer.interface.writeAll("{\"command\":\"media\",\"verb\":\"play\",\"id\":17}\n");
    try writer.interface.flush();

    var command: ?media_commands.Command = null;
    for (0..100) |_| {
        command = endpoint.takeCommand();
        if (command != null) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
    }
    try std.testing.expect(command != null);
    try std.testing.expectEqual(@as(u64, 17), command.?.id);
    try std.testing.expectEqual(media_commands.Verb.play, command.?.verb);
    try std.Io.sleep(std.testing.io, .fromMilliseconds(25), .awake);
    endpoint.mutex.lockUncancelable(std.testing.io);
    const still_connected = endpoint.stream != null;
    endpoint.mutex.unlock(std.testing.io);
    try std.testing.expect(still_connected);

    try writer.interface.writeAll("{\"command\":\"media\",\"verb\":\"pause\",\"id\":18}\n");
    try writer.interface.flush();
    command = null;
    for (0..100) |_| {
        command = endpoint.takeCommand();
        if (command != null) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
    }
    try std.testing.expect(command != null);
    try std.testing.expectEqual(@as(u64, 18), command.?.id);
    try std.testing.expectEqual(media_commands.Verb.pause, command.?.verb);
}

test "backpressured acknowledgement cannot delay unrelated widget supervision" {
    var unrelated: supervisor.Slot(struct {}) = .{};
    try unrelated.setRegistration(.{
        .name = "Unrelated",
        .sourcePath = "/owned/unrelated",
        .enabled = true,
        .dev = false,
    });
    unrelated.state = .starting;

    const started_ns = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds;
    // Compile-time injection models the EAGAIN/partial-send result at the
    // exact production primitive without making the test depend on kernel
    // socket-buffer sizing. The false branch (and this seam) disappear from
    // production; the real branch above performs exactly one nonblocking
    // send.
    try std.testing.expect(!ProviderEndpoint.sendCompleteNonblockingImpl(
        true,
        -1,
        "{\"command\":\"mediaAck\",\"id\":1,\"ok\":true}\n",
    ));
    // This is the next widget's turn on the same loop. The old retry loop held
    // it for one second; the single nonblocking attempt must not.
    try std.testing.expectEqual(
        supervisor.SlotAction.launch,
        supervisor.nextSlotAction(&unrelated, true, false, false, 0),
    );
    const elapsed_ns = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds - started_ns;
    try std.testing.expect(elapsed_ns < 100 * std.time.ns_per_ms);
}

test "hosted automation ack crosses the authenticated provider socket" {
    var path_buffer: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/tmp/weaver-command-ack-test-{d}.sock", .{posix.system.getpid()});
    const endpoint = try ProviderEndpoint.start(std.testing.io, std.testing.allocator, path);
    defer endpoint.deinit();
    try endpoint.bind(posix.system.getpid());
    const address = try std.Io.net.UnixAddress.init(path);
    const stream = try address.connect(std.testing.io);
    defer stream.close(std.testing.io);

    var accepted = false;
    for (0..100) |_| {
        endpoint.mutex.lockUncancelable(std.testing.io);
        accepted = endpoint.stream != null;
        endpoint.mutex.unlock(std.testing.io);
        if (accepted) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
    }
    try std.testing.expect(accepted);

    var ack_buffer: [64]u8 = undefined;
    try std.testing.expect(writeAutomationMediaAck(endpoint, 7, &ack_buffer));
    var received: [64]u8 = undefined;
    var ack_len: usize = 0;
    for (0..100) |_| {
        const read = c.recv(
            stream.socket.handle,
            received[ack_len..].ptr,
            received.len - ack_len,
            c.MSG_DONTWAIT,
        );
        if (read > 0) {
            ack_len += @intCast(read);
            if (std.mem.indexOfScalar(u8, received[0..ack_len], '\n') != null or ack_len == received.len) break;
            continue;
        }
        if (read == 0) break;
        switch (posix.errno(read)) {
            .INTR => continue,
            .AGAIN => try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake),
            else => return error.TestUnexpectedResult,
        }
    }
    try std.testing.expectEqualStrings("{\"ack\":7,\"ok\":false}\n", received[0..ack_len]);
}
