const std = @import("std");
const supervisor = @import("supervisor.zig");
const art_cache = @import("art_cache.zig");
const audio = @import("audio.zig");
const backoff = @import("backoff.zig");
const media = @import("media.zig");
const media_commands = @import("media_commands.zig");
const providers = @import("providers.zig");
const provider_protocol = @import("provider_protocol.zig");
const registry = @import("registry.zig");

const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
    @cInclude("psapi.h");
    @cInclude("tlhelp32.h");
});

const mutex_name = std.unicode.utf8ToUtf16LeStringLiteral("Local\\WeaverHostSingletonV2");
const shutdown_event_name = std.unicode.utf8ToUtf16LeStringLiteral("Local\\WeaverHostShutdownV2");
const reload_event_name = std.unicode.utf8ToUtf16LeStringLiteral("Local\\WeaverHostReloadV2");
const reload_signal_mutex_name = std.unicode.utf8ToUtf16LeStringLiteral("Local\\WeaverHostReloadSignalV2");
const reload_success_event_name = std.unicode.utf8ToUtf16LeStringLiteral("Local\\WeaverHostReloadSuccessV2");
const reload_failure_event_name = std.unicode.utf8ToUtf16LeStringLiteral("Local\\WeaverHostReloadFailureV2");
const env_pipe_name = std.unicode.utf8ToUtf16LeStringLiteral("WEAVER_HOST_PIPE");
const env_backend_file = std.unicode.utf8ToUtf16LeStringLiteral("WEAVER_BACKEND_FILE");
const env_renderer_pipe = std.unicode.utf8ToUtf16LeStringLiteral("WEAVER_RENDERER_PIPE");
const env_renderer_log = std.unicode.utf8ToUtf16LeStringLiteral("WEAVER_RENDERER_LOG");
const env_art_cache = std.unicode.utf8ToUtf16LeStringLiteral("WEAVER_ART_CACHE");
const env_crash_breadcrumb = std.unicode.utf8ToUtf16LeStringLiteral("WEAVER_CRASH_BREADCRUMB");
const max_widgets = supervisor.max_widgets;

/// Auto-reset event the supervision loop waits on: provider pipe readers
/// and media executors set it when they queue work, so the loop sleeps
/// until there is something to do instead of polling.
var work_event: c.HANDLE = null;

fn signalWork() void {
    if (work_event) |event| _ = c.SetEvent(event);
}
const max_path_bytes: usize = 2048;
const invalid_handle = c.INVALID_HANDLE_VALUE;

const MediaCommandResult = struct {
    id: u64,
    outcome: media.Provider.CommandOutcome,
};

/// One bounded worker belongs to one transport-capable widget. SMTC async
/// waits never run on the global supervision loop, while FIFO remains local
/// to that widget and the host loop remains the sole endpoint writer.
const MediaCommandExecutor = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    provider: *media.Provider,
    thread: std.Thread,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    commands: [media_commands.queue_capacity]media_commands.Command = undefined,
    command_head: usize = 0,
    command_count: usize = 0,
    results: [media_commands.queue_capacity]MediaCommandResult = undefined,
    result_head: usize = 0,
    result_count: usize = 0,
    stopping: bool = false,

    fn start(io: std.Io, allocator: std.mem.Allocator, provider: *media.Provider) !*MediaCommandExecutor {
        const self = try allocator.create(MediaCommandExecutor);
        errdefer allocator.destroy(self);
        self.* = .{ .io = io, .allocator = allocator, .provider = provider, .thread = undefined };
        self.thread = try std.Thread.spawn(.{ .stack_size = 128 * 1024 }, threadMain, .{self});
        return self;
    }

    fn deinit(self: *MediaCommandExecutor) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
        self.thread.join();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    fn submit(self: *MediaCommandExecutor, command: media_commands.Command) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stopping or self.command_count == self.commands.len) return false;
        const index = (self.command_head + self.command_count) % self.commands.len;
        self.commands[index] = command;
        self.command_count += 1;
        self.condition.signal(self.io);
        return true;
    }

    fn takeResult(self: *MediaCommandExecutor) ?MediaCommandResult {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.result_count == 0) return null;
        const result = self.results[self.result_head];
        self.result_head = (self.result_head + 1) % self.results.len;
        self.result_count -= 1;
        self.condition.signal(self.io);
        return result;
    }

    fn threadMain(self: *MediaCommandExecutor) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (self.command_count == 0 and !self.stopping) {
                self.condition.waitUncancelable(self.io, &self.mutex);
            }
            if (self.stopping) {
                self.mutex.unlock(self.io);
                return;
            }
            const command = self.commands[self.command_head];
            self.command_head = (self.command_head + 1) % self.commands.len;
            self.command_count -= 1;
            self.mutex.unlock(self.io);

            const result: MediaCommandResult = .{
                .id = command.id,
                .outcome = self.provider.command(command.verb, command.seek_ms),
            };
            self.mutex.lockUncancelable(self.io);
            while (self.result_count == self.results.len and !self.stopping) {
                self.condition.waitUncancelable(self.io, &self.mutex);
            }
            if (self.stopping) {
                self.mutex.unlock(self.io);
                return;
            }
            const index = (self.result_head + self.result_count) % self.results.len;
            self.results[index] = result;
            self.result_count += 1;
            self.mutex.unlock(self.io);
            signalWork();
        }
    }
};

const WindowsSlotState = struct {
    process: c.HANDLE = null,
    pid: u32 = 0,
    pipe: c.HANDLE = invalid_handle,
    write_event: c.HANDLE = null,
    command_shutdown_event: c.HANDLE = null,
    command_thread: ?std.Thread = null,
    command_stopping: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    test_before_command_read: c.HANDLE = null,
    test_resume_command_read: c.HANDLE = null,
    media_command_executor: ?*MediaCommandExecutor = null,
    command_queue: media_commands.Queue = .{},
    command_rate: media_commands.RateLimiter = .{},
    previous_process_ticks: u64 = 0,
    previous_sample_ms: u64 = 0,
    private_samples: [15]u64 = [_]u64{0} ** 15,
    cpu_samples: [15]f64 = [_]f64{0} ** 15,
    sample_count: usize = 0,
    sample_cursor: usize = 0,
    backend_path_buffer: [max_path_bytes]u8 = undefined,
    backend_path_len: usize = 0,
    pipe_name_buffer: [256]u8 = undefined,
    pipe_name_len: usize = 0,
    /// The widget runs inside the shared host (`SharedHost`) rather than
    /// a process of its own; `process` stays null.
    hosted: bool = false,

    fn backendPath(self: *const WindowsSlotState) []const u8 {
        return self.backend_path_buffer[0..self.backend_path_len];
    }

    fn pipeName(self: *const WindowsSlotState) []const u8 {
        return self.pipe_name_buffer[0..self.pipe_name_len];
    }

    fn averages(self: *const WindowsSlotState) struct { private_mb: f64, cpu: f64 } {
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

const Slot = supervisor.Slot(WindowsSlotState);

const WindowsRendererState = struct {
    process: c.HANDLE = null,
    pid: u32 = 0,
    previous_process_ticks: u64 = 0,
    previous_sample_ms: u64 = 0,
    private_samples: [15]u64 = [_]u64{0} ** 15,
    cpu_samples: [15]f64 = [_]f64{0} ** 15,
    sample_count: usize = 0,
    sample_cursor: usize = 0,

    fn averages(self: *const WindowsRendererState) struct { private_mb: f64, cpu: f64 } {
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

const RendererState = supervisor.RendererState(WindowsRendererState);

/// Every widget not in `--dev` runs in one `weaver-widget --host` process
/// (ADR 0020). Hosted slots hold no process of their own: they are
/// `members` of this process, in `--host` argument order, and a host exit
/// is settled once for all of them. The breadcrumb names the widget that
/// was running when the process died, so its crash is charged to it alone.
const SharedHost = struct {
    process: WindowsRendererState = .{},
    started_ms: u64 = 0,
    launches: u64 = 0,
    members: [max_widgets]usize = undefined,
    member_count: usize = 0,
    breadcrumb_mapping: c.HANDLE = null,
    breadcrumb: ?*volatile u32 = null,
    threads: u32 = 0,

    fn memberSlots(self: *const SharedHost) []const usize {
        return self.members[0..self.member_count];
    }
};

const Host = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    registry_path: []const u8,
    status_path: []const u8,
    status_temp_path: []const u8,
    runtime_exe: []const u8,
    renderer_exe: []const u8,
    renderer_pipe_name: []const u8,
    renderer_log_path: []const u8,
    cli_script: []const u8,
    art_cache_root: []const u8,
    force_software: bool,
    renderer: RendererState = .{},
    shared: SharedHost = .{},
    slots: [max_widgets]Slot = [_]Slot{.{}} ** max_widgets,
    sampler: providers.Sampler = .{},
    audio_provider: audio.Provider = .{},
    media_provider: media.Provider = .{},
    previous_cpu: [8192]u8 = undefined,
    previous_cpu_len: usize = 0,
    previous_memory: [512]u8 = undefined,
    previous_memory_len: usize = 0,
    system_frames: u64 = 0,
    previous_media: [media.max_media_frame_bytes]u8 = undefined,
    previous_media_len: usize = 0,
    audio_pipe_frames: u64 = 0,
    media_pipe_frames: u64 = 0,
    thread_sample_ms: u64 = 0,
    slot_threads: [max_widgets]u32 = [_]u32{0} ** max_widgets,
    renderer_threads: u32 = 0,
    status_write_failures: u64 = 0,
    renderer_failure_count: u64 = 0,
    renderer_failure_reason: [256]u8 = undefined,
    renderer_failure_reason_len: usize = 0,

    fn loadRegistry(self: *Host) !void {
        const owned_bytes = std.Io.Dir.cwd().readFileAlloc(self.io, self.registry_path, self.allocator, .limited(256 * 1024)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (owned_bytes) |bytes| self.allocator.free(bytes);
        const bytes = owned_bytes orelse "{\"widgets\":[]}";
        const parsed = try registry.parse(self.allocator, bytes);
        defer parsed.deinit();
        try supervisor.reconcile(&self.slots, parsed.value.widgets, self);
    }

    pub fn running(self: *const Host, index: usize) bool {
        return self.slots[index].platform.process != null or self.slots[index].platform.hosted;
    }

    pub fn stop(self: *Host, index: usize, graceful: bool) void {
        self.stopSlot(&self.slots[index], graceful);
    }

    fn supervise(self: *Host, now_ms: u64) void {
        self.superviseRenderer(now_ms);
        self.settleSharedHostExit(now_ms);
        var launch_host = false;
        for (&self.slots) |*slot| {
            if (!slot.used or !slot.enabled) continue;
            const process_running = slot.platform.process != null or slot.platform.hosted;
            const process_exited = if (slot.platform.process) |process| c.WaitForSingleObject(process, 0) == c.WAIT_OBJECT_0 else false;
            switch (supervisor.nextSlotAction(slot, self.sourceExists(slot.source()), process_running, process_exited, now_ms)) {
                .none => {},
                .stop_missing => self.stopSlot(slot, true),
                .handle_exit => self.handleExit(slot, now_ms),
                .launch => if (slot.dev) {
                    self.launch(slot, now_ms) catch |err| {
                        self.closePipe(slot);
                        supervisor.recordLaunchFailure(slot, now_ms, err);
                    };
                } else {
                    launch_host = true;
                },
            }
        }
        if (launch_host) self.launchSharedHost(now_ms);
        self.superviseRenderer(now_ms);
    }

    /// A `--dev` widget keeps a process of its own: its hot-swap listener
    /// and dev reloads touch only it.
    fn launch(self: *Host, slot: *Slot, now_ms: u64) !void {
        try self.prepareSlot(slot, now_ms);
        const dist = try self.distPath(slot);
        defer self.allocator.free(dist);
        const command = try std.fmt.allocPrint(self.allocator, "\"{s}\" --dev \"{s}\"", .{ self.runtime_exe, dist });
        defer self.allocator.free(command);
        if (slot.platform.pipe_name_len > 0) try setEnv(self.allocator, env_pipe_name, slot.platform.pipeName());
        defer if (slot.platform.pipe_name_len > 0) clearEnv(env_pipe_name);
        try setEnv(self.allocator, env_backend_file, slot.platform.backendPath());
        defer clearEnv(env_backend_file);
        try self.setSharedEnv(slot.wants_gpu, slot.wants_media);
        defer self.clearSharedEnv();
        const started = try self.startProcess(command);
        slot.platform.process = started.process;
        slot.platform.pid = started.pid;
        errdefer self.stopSlot(slot, false);
        try self.connectSlot(slot, slot.platform.process, slot.platform.pid, now_ms);
    }

    fn distPath(self: *Host, slot: *const Slot) ![]const u8 {
        return std.fs.path.join(self.allocator, &.{ slot.source(), "dist" });
    }

    /// Bundle, read the manifest, and open the slot's provider pipe and
    /// backend status file: everything a launch needs before a process exists.
    fn prepareSlot(self: *Host, slot: *Slot, now_ms: u64) !void {
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
        supervisor.selectManifest(slot, manifest.value.subscribe, manifest.value.capabilities, manifest.value.renderBackend, self.force_software);
        if (slot.wants_gpu) self.ensureRenderer(now_ms) catch {
            // ensureRenderer records the named failure for status and owns
            // retry/backoff. The widget may still start so it can reconnect
            // as soon as the shared renderer recovers.
        };
        slot.platform.pipe_name_len = 0;
        if (slot.wants_cpu or slot.wants_memory or slot.wants_audio or slot.wants_media or slot.wants_media_transport) {
            const pipe_name = try std.fmt.bufPrint(&slot.platform.pipe_name_buffer, "\\\\.\\pipe\\weaver-{d}-{x}", .{ c.GetCurrentProcessId(), std.hash.Wyhash.hash(now_ms, slot.name()) });
            slot.platform.pipe_name_len = pipe_name.len;
            const pipe_name_w = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, pipe_name);
            defer self.allocator.free(pipe_name_w);
            slot.platform.pipe = c.CreateNamedPipeW(
                pipe_name_w.ptr,
                c.PIPE_ACCESS_DUPLEX | c.FILE_FLAG_OVERLAPPED,
                c.PIPE_TYPE_BYTE | c.PIPE_READMODE_BYTE | c.PIPE_WAIT,
                1,
                8192,
                8192,
                0,
                null,
            );
            if (slot.platform.pipe == invalid_handle) return error.CreatePipeFailed;
        }
        const backend_hash = std.hash.Wyhash.hash(0, slot.name());
        const backend_path = try std.fmt.bufPrint(&slot.platform.backend_path_buffer, "{s}.backend-{x}", .{ self.status_path, backend_hash });
        slot.platform.backend_path_len = backend_path.len;
        std.Io.Dir.cwd().deleteFile(self.io, backend_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    /// Process-wide environment every widget of a launch shares.
    fn setSharedEnv(self: *Host, wants_gpu: bool, wants_media: bool) !void {
        if (wants_gpu) try setEnv(self.allocator, env_renderer_pipe, self.renderer_pipe_name);
        if (wants_media) try setEnv(self.allocator, env_art_cache, self.art_cache_root);
    }

    fn clearSharedEnv(_: *Host) void {
        clearEnv(env_renderer_pipe);
        clearEnv(env_art_cache);
    }

    const Started = struct { process: c.HANDLE, pid: u32 };

    fn startProcess(self: *Host, command: []const u8) !Started {
        const command_w = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, command);
        defer self.allocator.free(command_w);
        var startup: c.STARTUPINFOW = std.mem.zeroes(c.STARTUPINFOW);
        startup.cb = @sizeOf(c.STARTUPINFOW);
        var process_info: c.PROCESS_INFORMATION = std.mem.zeroes(c.PROCESS_INFORMATION);
        if (c.CreateProcessW(null, command_w.ptr, null, null, 0, c.CREATE_NO_WINDOW, null, null, &startup, &process_info) == 0) return error.CreateProcessFailed;
        _ = c.CloseHandle(process_info.hThread);
        self.thread_sample_ms = 0;
        return .{ .process = process_info.hProcess, .pid = process_info.dwProcessId };
    }

    /// Accept the slot's provider pipe from `process` and start serving it,
    /// then mark the slot running.
    fn connectSlot(self: *Host, slot: *Slot, process: c.HANDLE, pid: u32, now_ms: u64) !void {
        if (slot.platform.pipe != invalid_handle) {
            // A hosted widget that fails to load reports it in its status
            // file and never connects; stop waiting as soon as it says so.
            const failure_report: ?FailureReport = if (slot.dev) null else .{ .io = self.io, .path = slot.platform.backendPath() };
            if (!connectPipe(slot.platform.pipe, process, pid, 5_000, failure_report)) return error.ConnectPipeFailed;
            slot.platform.write_event = c.CreateEventW(null, 0, 0, null) orelse return error.CreateEventFailed;
            slot.platform.command_shutdown_event = c.CreateEventW(null, 1, 0, null) orelse return error.CreateEventFailed;
            slot.platform.command_stopping.store(0, .release);
            slot.platform.command_thread = try std.Thread.spawn(
                .{ .stack_size = 256 * 1024 },
                commandReaderMain,
                .{&slot.platform},
            );
            if (slot.wants_media_transport) {
                slot.platform.media_command_executor = try MediaCommandExecutor.start(
                    self.io,
                    self.allocator,
                    &self.media_provider,
                );
            }
        }
        supervisor.markRunning(slot, now_ms, self.artifactMtime(slot.source()));
        slot.platform.previous_process_ticks = processTicks(process);
        slot.platform.previous_sample_ms = now_ms;
        slot.platform.sample_count = 0;
        slot.platform.sample_cursor = 0;
    }

    /// (Re)start the shared host with every hosted slot that should run:
    /// the running members and the ones whose (re)start is due. Slots that
    /// fail to prepare or connect are charged a launch failure; the rest
    /// run.
    fn launchSharedHost(self: *Host, now_ms: u64) void {
        if (self.shared.process.process != null) self.stopSharedHost(true);
        var members: [max_widgets]usize = undefined;
        var member_count: usize = 0;
        var wants_gpu = false;
        var wants_media = false;
        for (&self.slots, 0..) |*slot, index| {
            if (!slot.used or !slot.enabled or slot.dev) continue;
            const due = slot.state == .starting or slot.state == .running or (slot.state == .backoff and now_ms >= slot.next_restart_ms);
            if (!due or !self.sourceExists(slot.source())) continue;
            self.prepareSlot(slot, now_ms) catch |err| {
                self.closePipe(slot);
                supervisor.recordLaunchFailure(slot, now_ms, err);
                continue;
            };
            members[member_count] = index;
            member_count += 1;
            wants_gpu = wants_gpu or slot.wants_gpu;
            wants_media = wants_media or slot.wants_media;
        }
        if (member_count == 0) return;
        const started = self.startSharedHost(members[0..member_count], wants_gpu, wants_media) catch |err| {
            for (members[0..member_count]) |index| {
                self.closePipe(&self.slots[index]);
                supervisor.recordLaunchFailure(&self.slots[index], now_ms, err);
            }
            self.closeBreadcrumb();
            return;
        };
        self.shared.process = .{ .process = started.process, .pid = started.pid, .previous_process_ticks = processTicks(started.process), .previous_sample_ms = now_ms };
        self.shared.started_ms = now_ms;
        self.shared.members = members;
        self.shared.member_count = member_count;
        // The host loads widgets in argument order, so their pipes connect
        // in that order too.
        for (members[0..member_count]) |index| {
            const slot = &self.slots[index];
            self.connectSlot(slot, started.process, started.pid, now_ms) catch |err| {
                self.closePipe(slot);
                // The host died while starting: the slot stays a member so
                // the exit is settled once and the breadcrumb decides who
                // pays, instead of every unconnected widget being charged.
                if (c.WaitForSingleObject(started.process, 0) == c.WAIT_OBJECT_0) {
                    slot.platform.hosted = true;
                    slot.platform.pid = started.pid;
                    continue;
                }
                // A widget that failed to load never connects its pipe; its
                // status file says why, and it stops like any load failure
                // instead of restarting the host on a backoff.
                if (!self.stopOnReportedLoadFailure(slot)) supervisor.recordLaunchFailure(slot, now_ms, err);
                continue;
            };
            slot.platform.hosted = true;
            slot.platform.pid = started.pid;
        }
    }

    fn startSharedHost(self: *Host, members: []const usize, wants_gpu: bool, wants_media: bool) !Started {
        var command: std.Io.Writer.Allocating = .init(self.allocator);
        defer command.deinit();
        try command.writer.print("\"{s}\" --host", .{self.runtime_exe});
        for (members, 0..) |index, argument| {
            const slot = &self.slots[index];
            const dist = try self.distPath(slot);
            defer self.allocator.free(dist);
            try command.writer.print(" \"{s}\"", .{dist});
            var name_buffer: [64]u8 = undefined;
            if (slot.platform.pipe_name_len > 0) try setEnvUtf8(self.allocator, try std.fmt.bufPrint(&name_buffer, "WEAVER_HOST_PIPE_{d}", .{argument}), slot.platform.pipeName());
            try setEnvUtf8(self.allocator, try std.fmt.bufPrint(&name_buffer, "WEAVER_BACKEND_FILE_{d}", .{argument}), slot.platform.backendPath());
        }
        defer for (0..members.len) |argument| {
            var name_buffer: [64]u8 = undefined;
            clearEnvUtf8(self.allocator, std.fmt.bufPrint(&name_buffer, "WEAVER_HOST_PIPE_{d}", .{argument}) catch unreachable);
            clearEnvUtf8(self.allocator, std.fmt.bufPrint(&name_buffer, "WEAVER_BACKEND_FILE_{d}", .{argument}) catch unreachable);
        };
        try self.setSharedEnv(wants_gpu, wants_media);
        defer self.clearSharedEnv();
        try self.openBreadcrumb();
        defer clearEnv(env_crash_breadcrumb);
        return self.startProcess(command.written());
    }

    /// A fresh 4-byte mapping per launch: the host writes the running
    /// widget's argument position into it; zero means none yet.
    fn openBreadcrumb(self: *Host) !void {
        self.closeBreadcrumb();
        self.shared.launches += 1;
        var name_buffer: [96]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "Local\\WeaverHostBreadcrumb-{d}-{d}", .{ c.GetCurrentProcessId(), self.shared.launches });
        const name_w = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, name);
        defer self.allocator.free(name_w);
        const mapping = c.CreateFileMappingW(invalid_handle, null, c.PAGE_READWRITE, 0, @sizeOf(u32), name_w.ptr) orelse return error.CreateBreadcrumbFailed;
        const view = c.MapViewOfFile(mapping, c.FILE_MAP_ALL_ACCESS, 0, 0, @sizeOf(u32)) orelse {
            _ = c.CloseHandle(mapping);
            return error.CreateBreadcrumbFailed;
        };
        self.shared.breadcrumb_mapping = mapping;
        self.shared.breadcrumb = @ptrCast(@alignCast(view));
        self.shared.breadcrumb.?.* = 0;
        try setEnv(self.allocator, env_crash_breadcrumb, name);
    }

    fn closeBreadcrumb(self: *Host) void {
        if (self.shared.breadcrumb) |view| _ = c.UnmapViewOfFile(@volatileCast(view));
        if (self.shared.breadcrumb_mapping) |mapping| _ = c.CloseHandle(mapping);
        self.shared.breadcrumb = null;
        self.shared.breadcrumb_mapping = null;
    }

    /// The shared host exited: charge the crash to the widget the
    /// breadcrumb names and restart the others at once. With no widget
    /// named, the fault was the platform's and every member pays it.
    fn settleSharedHostExit(self: *Host, now_ms: u64) void {
        const process = self.shared.process.process orelse return;
        if (c.WaitForSingleObject(process, 0) != c.WAIT_OBJECT_0) return;
        var exit_code: c.DWORD = 1;
        _ = c.GetExitCodeProcess(process, &exit_code);
        const crumb = if (self.shared.breadcrumb) |view| view.* else 0;
        const blamed: ?usize = if (crumb == 0 or crumb > self.shared.member_count) null else self.shared.members[crumb - 1];
        for (self.shared.memberSlots()) |index| {
            const slot = &self.slots[index];
            if (!slot.platform.hosted) continue;
            self.releaseHostedSlot(slot);
            if (!self.sourceExists(slot.source())) {
                _ = supervisor.nextSlotAction(slot, false, false, false, now_ms);
            } else if (blamed == null or blamed.? == index) {
                supervisor.recordCrash(slot, now_ms, exit_code);
            } else {
                slot.state = .starting;
                slot.next_restart_ms = 0;
            }
        }
        if (blamed) |index| std.log.warn("shared widget host exited with code {d} while running '{s}'", .{ exit_code, self.slots[index].name() });
        self.closeSharedHost();
    }

    /// Stop the shared host. Members still due to run restart with the next
    /// launch; the caller decides the state of the slot it is stopping.
    fn stopSharedHost(self: *Host, graceful: bool) void {
        const process = self.shared.process.process orelse return;
        if (graceful) {
            closeWindowsForProcess(self.shared.process.pid);
            if (c.WaitForSingleObject(process, 1500) != c.WAIT_OBJECT_0) _ = c.TerminateProcess(process, 0);
        } else _ = c.TerminateProcess(process, 0);
        _ = c.WaitForSingleObject(process, 1000);
        for (self.shared.memberSlots()) |index| {
            const slot = &self.slots[index];
            if (!slot.platform.hosted) continue;
            self.releaseHostedSlot(slot);
            if (slot.state == .running) {
                slot.state = .starting;
                slot.next_restart_ms = 0;
            }
        }
        self.closeSharedHost();
    }

    /// A widget the shared host could not load writes `failed:<error>` to its
    /// backend status file instead of a renderer. Loading is deterministic
    /// (a broken bundle or manifest), so the slot stops until it is
    /// reinstalled or its source changes, rather than restarting every
    /// other widget on a backoff.
    fn noteHostedLoadFailures(self: *Host) void {
        for (self.shared.memberSlots()) |index| {
            const slot = &self.slots[index];
            if (!slot.platform.hosted) continue;
            _ = self.stopOnReportedLoadFailure(slot);
        }
    }

    /// Stop `slot` if the host reported that it could not load it.
    fn stopOnReportedLoadFailure(self: *Host, slot: *Slot) bool {
        if (slot.platform.backend_path_len == 0) return false;
        var buffer: [96]u8 = undefined;
        const text = std.Io.Dir.cwd().readFile(self.io, slot.platform.backendPath(), &buffer) catch return false;
        if (!std.mem.startsWith(u8, text, "failed:")) return false;
        // Consumed: the status row carries the error from here on.
        std.Io.Dir.cwd().deleteFile(self.io, slot.platform.backendPath()) catch {};
        self.releaseHostedSlot(slot);
        slot.state = .stopped;
        slot.setReason("widget did not load in the shared host: {s}; see 'weaver logs {s}'", .{ text["failed:".len..], slot.name() });
        return true;
    }

    fn releaseHostedSlot(self: *Host, slot: *Slot) void {
        self.closePipe(slot);
        slot.platform.hosted = false;
        slot.platform.pid = 0;
    }

    fn closeSharedHost(self: *Host) void {
        if (self.shared.process.process) |process| _ = c.CloseHandle(process);
        self.shared.process = .{};
        self.shared.member_count = 0;
        self.thread_sample_ms = 0;
        self.closeBreadcrumb();
    }

    fn rendererDesired(self: *const Host) bool {
        return supervisor.rendererDesired(&self.slots, self.force_software);
    }

    fn superviseRenderer(self: *Host, now_ms: u64) void {
        const renderer_running = self.renderer.platform.process != null;
        const exited = if (self.renderer.platform.process) |process| c.WaitForSingleObject(process, 0) == c.WAIT_OBJECT_0 else false;
        switch (supervisor.nextRendererAction(renderer_running, exited, self.rendererDesired(), now_ms, self.renderer.next_restart_ms)) {
            .none => {},
            .handle_exit => {
                const process = self.renderer.platform.process.?;
                var exit_code: c.DWORD = 1;
                _ = c.GetExitCodeProcess(process, &exit_code);
                _ = c.CloseHandle(process);
                self.renderer.platform.process = null;
                self.renderer.platform.pid = 0;
                self.thread_sample_ms = 0;
                supervisor.recordRendererExit(&self.renderer, now_ms);
                self.noteRendererFailure(
                    "renderer process exited: code={d}; retrying in {d}ms",
                    .{ exit_code, self.renderer.next_restart_ms -| now_ms },
                );
            },
            .stop => {
                const process = self.renderer.platform.process.?;
                _ = c.TerminateProcess(process, 0);
                _ = c.WaitForSingleObject(process, 1000);
                _ = c.CloseHandle(process);
                self.renderer = .{};
                self.thread_sample_ms = 0;
            },
            .launch => self.ensureRenderer(now_ms) catch {
                self.renderer.next_restart_ms = now_ms + 1000;
            },
        }
    }

    fn ensureRenderer(self: *Host, now_ms: u64) !void {
        if (self.force_software or self.renderer.platform.process != null or now_ms < self.renderer.next_restart_ms) return;
        self.startRenderer(now_ms) catch |err| {
            self.noteRendererFailure(
                "renderer launch failed: {s}; retrying in 1000ms",
                .{@errorName(err)},
            );
            return err;
        };
        self.noteRendererRecovery();
    }

    fn startRenderer(self: *Host, now_ms: u64) !void {
        const command = try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{self.renderer_exe});
        defer self.allocator.free(command);
        const command_w_const = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, command);
        defer self.allocator.free(command_w_const);
        const command_w = try self.allocator.dupeZ(u16, command_w_const);
        defer self.allocator.free(command_w);
        const pipe_w = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, self.renderer_pipe_name);
        defer self.allocator.free(pipe_w);
        const log_w = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, self.renderer_log_path);
        defer self.allocator.free(log_w);
        if (c.SetEnvironmentVariableW(env_renderer_pipe, pipe_w.ptr) == 0) return error.SetEnvironmentFailed;
        if (c.SetEnvironmentVariableW(env_renderer_log, log_w.ptr) == 0) return error.SetEnvironmentFailed;
        defer {
            _ = c.SetEnvironmentVariableW(env_renderer_pipe, null);
            _ = c.SetEnvironmentVariableW(env_renderer_log, null);
        }
        var startup: c.STARTUPINFOW = std.mem.zeroes(c.STARTUPINFOW);
        startup.cb = @sizeOf(c.STARTUPINFOW);
        var info: c.PROCESS_INFORMATION = std.mem.zeroes(c.PROCESS_INFORMATION);
        if (c.CreateProcessW(null, command_w.ptr, null, null, 0, c.CREATE_NO_WINDOW, null, null, &startup, &info) == 0) return error.CreateRendererFailed;
        _ = c.CloseHandle(info.hThread);
        self.renderer.platform.process = info.hProcess;
        self.renderer.platform.pid = info.dwProcessId;
        self.thread_sample_ms = 0;
        self.renderer.started_ms = now_ms;
        self.renderer.platform.previous_process_ticks = processTicks(info.hProcess);
        self.renderer.platform.previous_sample_ms = now_ms;
        self.renderer.platform.sample_count = 0;
        self.renderer.platform.sample_cursor = 0;
    }

    fn noteRendererFailure(self: *Host, comptime format: []const u8, args: anytype) void {
        self.renderer_failure_count += 1;
        if (self.renderer_failure_count == 1) {
            var writer = std.Io.Writer.fixed(&self.renderer_failure_reason);
            writer.print(format, args) catch {
                writer = std.Io.Writer.fixed(&self.renderer_failure_reason);
                writer.writeAll("renderer unavailable; retrying") catch unreachable;
            };
            self.renderer_failure_reason_len = writer.buffered().len;
            std.log.err(
                "{s}; affected GPU widgets expose this failure through weaver status; repeated failures are suppressed until recovery",
                .{self.renderer_failure_reason[0..self.renderer_failure_reason_len]},
            );
        }
    }

    fn noteRendererRecovery(self: *Host) void {
        if (self.renderer_failure_count == 0) return;
        std.log.info("renderer recovered after {d} consecutive failures", .{self.renderer_failure_count});
        self.renderer_failure_count = 0;
        self.renderer_failure_reason_len = 0;
    }

    fn handleExit(self: *Host, slot: *Slot, now_ms: u64) void {
        var exit_code: c.DWORD = 1;
        _ = c.GetExitCodeProcess(slot.platform.process, &exit_code);
        self.closeProcess(slot);
        if (!self.sourceExists(slot.source())) {
            _ = supervisor.nextSlotAction(slot, false, false, false, now_ms);
            return;
        }
        supervisor.recordCrash(slot, now_ms, exit_code);
    }

    fn stopSlot(self: *Host, slot: *Slot, graceful: bool) void {
        // One widget leaves the shared host by restarting it without them.
        if (slot.platform.hosted) return self.stopSharedHost(graceful);
        if (slot.platform.process) |process| {
            if (graceful) {
                closeWindowsForProcess(slot.platform.pid);
                if (c.WaitForSingleObject(process, 1500) != c.WAIT_OBJECT_0) _ = c.TerminateProcess(process, 0);
            } else _ = c.TerminateProcess(process, 0);
            _ = c.WaitForSingleObject(process, 1000);
        }
        self.closeProcess(slot);
    }

    fn closeProcess(self: *Host, slot: *Slot) void {
        self.closePipe(slot);
        if (slot.platform.process) |process| _ = c.CloseHandle(process);
        slot.platform.process = null;
        slot.platform.pid = 0;
        self.thread_sample_ms = 0;
        slot.platform.previous_process_ticks = 0;
    }

    fn closePipe(_: *Host, slot: *Slot) void {
        if (slot.platform.pipe == invalid_handle) return;
        slot.platform.command_queue.stop();
        slot.platform.command_stopping.store(1, .release);
        if (slot.platform.command_shutdown_event) |event| _ = c.SetEvent(event);
        _ = c.CancelIoEx(slot.platform.pipe, null);
        if (slot.platform.command_thread) |thread| thread.join();
        slot.platform.command_thread = null;
        if (slot.platform.media_command_executor) |executor| executor.deinit();
        slot.platform.media_command_executor = null;
        _ = c.DisconnectNamedPipe(slot.platform.pipe);
        _ = c.CloseHandle(slot.platform.pipe);
        slot.platform.pipe = invalid_handle;
        if (slot.platform.write_event) |event| _ = c.CloseHandle(event);
        slot.platform.write_event = null;
        if (slot.platform.command_shutdown_event) |event| _ = c.CloseHandle(event);
        slot.platform.command_shutdown_event = null;
        slot.platform.command_queue = .{};
        slot.platform.command_rate = .{};
    }

    fn sampleCosts(self: *Host, now_ms: u64) void {
        sampleProcess(&self.shared.process, now_ms);
        for (&self.slots) |*slot| {
            const process = slot.platform.process orelse continue;
            var counters: c.PROCESS_MEMORY_COUNTERS_EX = std.mem.zeroes(c.PROCESS_MEMORY_COUNTERS_EX);
            counters.cb = @sizeOf(c.PROCESS_MEMORY_COUNTERS_EX);
            if (c.GetProcessMemoryInfo(process, @ptrCast(&counters), @sizeOf(c.PROCESS_MEMORY_COUNTERS_EX)) == 0) continue;
            const ticks = processTicks(process);
            const elapsed_ms = now_ms -| slot.platform.previous_sample_ms;
            const tick_delta = ticks -| slot.platform.previous_process_ticks;
            const cpu = if (elapsed_ms == 0) 0 else 100.0 * @as(f64, @floatFromInt(tick_delta)) / 10_000.0 / @as(f64, @floatFromInt(elapsed_ms));
            slot.platform.private_samples[slot.platform.sample_cursor] = counters.PrivateUsage;
            slot.platform.cpu_samples[slot.platform.sample_cursor] = @round(cpu * 10.0) / 10.0;
            slot.platform.sample_cursor = (slot.platform.sample_cursor + 1) % slot.platform.private_samples.len;
            slot.platform.sample_count = @min(slot.platform.sample_count + 1, slot.platform.private_samples.len);
            slot.platform.previous_process_ticks = ticks;
            slot.platform.previous_sample_ms = now_ms;
        }
        if (self.renderer.platform.process) |process| {
            var counters: c.PROCESS_MEMORY_COUNTERS_EX = std.mem.zeroes(c.PROCESS_MEMORY_COUNTERS_EX);
            counters.cb = @sizeOf(c.PROCESS_MEMORY_COUNTERS_EX);
            if (c.GetProcessMemoryInfo(process, @ptrCast(&counters), @sizeOf(c.PROCESS_MEMORY_COUNTERS_EX)) != 0) {
                const ticks = processTicks(process);
                const elapsed_ms = now_ms -| self.renderer.platform.previous_sample_ms;
                const tick_delta = ticks -| self.renderer.platform.previous_process_ticks;
                const cpu = if (elapsed_ms == 0) 0 else 100.0 * @as(f64, @floatFromInt(tick_delta)) / 10_000.0 / @as(f64, @floatFromInt(elapsed_ms));
                self.renderer.platform.private_samples[self.renderer.platform.sample_cursor] = counters.PrivateUsage;
                self.renderer.platform.cpu_samples[self.renderer.platform.sample_cursor] = @round(cpu * 10.0) / 10.0;
                self.renderer.platform.sample_cursor = (self.renderer.platform.sample_cursor + 1) % self.renderer.platform.private_samples.len;
                self.renderer.platform.sample_count = @min(self.renderer.platform.sample_count + 1, self.renderer.platform.private_samples.len);
                self.renderer.platform.previous_process_ticks = ticks;
                self.renderer.platform.previous_sample_ms = now_ms;
            }
        }
    }

    /// Every child process the loop must notice exiting: the shared host,
    /// the renderer, and `--dev` widgets.
    fn collectProcessHandles(self: *const Host, handles: *[c.MAXIMUM_WAIT_OBJECTS]c.HANDLE, count: *usize) void {
        if (self.shared.process.process) |process| append(handles, count, process);
        if (self.renderer.platform.process) |process| append(handles, count, process);
        for (&self.slots) |*slot| {
            if (slot.platform.process) |process| append(handles, count, process);
        }
    }

    fn append(handles: *[c.MAXIMUM_WAIT_OBJECTS]c.HANDLE, count: *usize, handle: c.HANDLE) void {
        if (count.* == handles.len) return;
        handles[count.*] = handle;
        count.* += 1;
    }

    fn sampleProviders(self: *Host) void {
        var any = false;
        for (&self.slots, 0..) |*slot, index| if (self.running(index) and (slot.wants_cpu or slot.wants_memory)) {
            any = true;
            break;
        };
        if (!any) return;
        const sample = self.sampler.sample() catch return orelse return;
        var cpu_buffer: [8192]u8 = undefined;
        const cpu = providers.formatCpu(sample.cpu, &cpu_buffer) catch return;
        var memory_buffer: [512]u8 = undefined;
        const memory = providers.formatMemory(sample.memory, &memory_buffer) catch return;
        const cpu_changed = !std.mem.eql(u8, cpu, self.previous_cpu[0..self.previous_cpu_len]);
        const memory_changed = !std.mem.eql(u8, memory, self.previous_memory[0..self.previous_memory_len]);
        for (&self.slots) |*slot| {
            if (slot.platform.pipe == invalid_handle) continue;
            if (provider_protocol.deliveryNeeded(slot.wants_cpu, slot.cpu_sent, cpu_changed) and writePipe(&slot.platform, cpu)) {
                slot.cpu_sent = true;
                self.system_frames += 1;
            }
            if (provider_protocol.deliveryNeeded(slot.wants_memory, slot.memory_sent, memory_changed) and writePipe(&slot.platform, memory)) {
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
            if (slot.platform.pipe == invalid_handle or !slot.wants_audio) continue;
            if (writePipe(&slot.platform, encoded)) delivered = true;
        }
        if (delivered) self.audio_pipe_frames += 1;
    }

    fn sampleMedia(self: *Host, now_ms: u64) void {
        const active = self.hasMediaSubscribers();
        self.media_provider.setActive(active, now_ms);
        if (!active) return;
        const frame = self.media_provider.poll(now_ms) orelse return;
        var buffer: [media.max_media_frame_bytes]u8 = undefined;
        const encoded = media.formatFrame(&frame, &buffer) catch |err| {
            std.log.err("media frame exceeded protocol bound or failed to encode: {s}", .{@errorName(err)});
            return;
        };
        const changed = !std.mem.eql(u8, encoded, self.previous_media[0..self.previous_media_len]);
        var delivered = false;
        for (&self.slots) |*slot| {
            if (slot.platform.pipe == invalid_handle or !slot.wants_media) continue;
            if ((!slot.media_sent or changed) and writePipe(&slot.platform, encoded)) {
                slot.media_sent = true;
                delivered = true;
            }
        }
        if (delivered) self.media_pipe_frames += 1;
        @memcpy(self.previous_media[0..encoded.len], encoded);
        self.previous_media_len = encoded.len;
    }

    fn drainMediaCommands(self: *Host, now_ms: u64) void {
        var ack_buffer: [64]u8 = undefined;
        for (&self.slots) |*slot| {
            if (slot.platform.pipe == invalid_handle) continue;
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
                            if (!writePipe(&slot.platform, ack)) {
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
            while (slot.platform.command_queue.takeNack()) |id| {
                const ack = media_commands.formatAck(id, false, &ack_buffer) catch continue;
                if (!writePipe(&slot.platform, ack)) {
                    channel_failed = true;
                    break;
                }
            }
            if (channel_failed) {
                self.restartAfterMediaChannelFailure(slot, now_ms);
                continue;
            }
            while (slot.platform.command_queue.take()) |command| {
                const allowed = media_commands.authorize(slot.wants_media_transport, &slot.platform.command_rate, now_ms);
                if (!allowed) {
                    const ack = media_commands.formatAck(command.id, false, &ack_buffer) catch continue;
                    if (!writePipe(&slot.platform, ack)) {
                        channel_failed = true;
                        break;
                    }
                    continue;
                }
                const executor = slot.platform.media_command_executor orelse {
                    channel_failed = true;
                    break;
                };
                if (!executor.submit(command)) {
                    channel_failed = true;
                    break;
                }
            }
            if (channel_failed) {
                self.restartAfterMediaChannelFailure(slot, now_ms);
                continue;
            }
            if (slot.platform.command_queue.malformed.swap(false, .acq_rel)) {
                std.log.warn("dropping malformed media command frame from widget {s}", .{slot.name()});
            }
        }
    }

    fn restartAfterMediaChannelFailure(self: *Host, slot: *Slot, now_ms: u64) void {
        std.log.warn("restarting widget {s} after fatal provider channel failure", .{slot.name()});
        self.stopSlot(slot, false);
        supervisor.recordChannelFailure(slot, now_ms);
    }

    fn writeStatus(self: *Host, now_ms: u64) void {
        if (self.thread_sample_ms == 0 or now_ms -| self.thread_sample_ms >= 30_000) {
            self.slot_threads = [_]u32{0} ** max_widgets;
            self.renderer_threads = 0;
            self.shared.threads = 0;
            collectThreadCounts(self, &self.slot_threads, &self.renderer_threads);
            self.thread_sample_ms = now_ms;
        }
        var entries: [max_widgets + 2]supervisor.StatusEntry = undefined;
        var entry_count: usize = 0;
        var backend_allocations = [_]?[]u8{null} ** max_widgets;
        defer for (backend_allocations) |value| if (value) |bytes| self.allocator.free(bytes);
        if (self.shared.process.process != null) {
            const average = self.shared.process.averages();
            entries[entry_count] = .{
                .name = "host",
                .pid = self.shared.process.pid,
                .private_mb = average.private_mb,
                .cpu_percent = average.cpu,
                .threads = self.shared.threads,
                .backend = "-",
                .uptime_seconds = (now_ms -| self.shared.started_ms) / 1000,
                .state = .running,
                .reason = "",
                .host_row = true,
            };
            entry_count += 1;
        }
        if (self.renderer.platform.process != null) {
            const average = self.renderer.platform.averages();
            entries[entry_count] = .{
                .name = "renderer",
                .pid = self.renderer.platform.pid,
                .private_mb = average.private_mb,
                .cpu_percent = average.cpu,
                .threads = self.renderer_threads,
                .backend = "gpu",
                .uptime_seconds = (now_ms -| self.renderer.started_ms) / 1000,
                .state = .running,
                .reason = "",
            };
            entry_count += 1;
        }
        for (&self.slots, 0..) |*slot, slot_index| {
            if (!slot.used) continue;
            const average = slot.platform.averages();
            var backend: []const u8 = "-";
            if ((slot.platform.process != null or slot.platform.hosted) and slot.platform.backend_path_len > 0) {
                backend_allocations[slot_index] = std.Io.Dir.cwd().readFileAlloc(self.io, slot.platform.backendPath(), self.allocator, .limited(16)) catch null;
                if (backend_allocations[slot_index]) |value| backend = value;
            }
            const slot_reason = slot.reason();
            const reason = if (slot_reason.len > 0)
                slot_reason
            else if (slot.wants_gpu and self.renderer_failure_reason_len > 0)
                self.renderer_failure_reason[0..self.renderer_failure_reason_len]
            else
                "";
            entries[entry_count] = .{
                .name = slot.name(),
                .pid = slot.platform.pid,
                .private_mb = average.private_mb,
                .cpu_percent = average.cpu,
                .threads = if (slot.platform.hosted) 0 else self.slot_threads[slot_index],
                .backend = backend,
                .uptime_seconds = if (slot.platform.process != null or slot.platform.hosted) (now_ms -| slot.started_ms) / 1000 else 0,
                .state = slot.state,
                .reason = reason,
                .hosted = slot.platform.hosted,
            };
            entry_count += 1;
        }
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        supervisor.writeStatus(&output.writer, c.GetCurrentProcessId(), .{
            .system_subscribers = supervisor.systemSubscriberCount(&self.slots, self),
            .system_sample_count = self.sampler.sample_calls,
            .system_frames = self.system_frames,
            .audio_capture_active = self.audio_provider.capture != null,
            .audio_silent = self.audio_provider.silent,
            .audio_pipe_frames = self.audio_pipe_frames,
            .media_pipe_frames = self.media_pipe_frames,
            .media_availability = "available",
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
            .create_no_window = true,
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.BundleFailed,
            else => return error.BundleFailed,
        }
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
};

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "--signal-down")) return signalEvent(shutdown_event_name);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--signal-reload")) return signalReloadAndWait();
    if (args.len == 2 and std.mem.eql(u8, args[1], "--probe")) {
        const handle = c.OpenMutexW(c.SYNCHRONIZE, 0, mutex_name);
        if (handle == null) return error.HostNotRunning;
        _ = c.CloseHandle(handle);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--probe-reload-ready")) {
        const handle = c.OpenMutexW(c.SYNCHRONIZE, 0, mutex_name);
        if (handle == null) return error.HostNotRunning;
        _ = c.CloseHandle(handle);
        const ready = c.OpenEventW(c.SYNCHRONIZE, 0, reload_failure_event_name);
        if (ready == null) return error.HostNotRunning;
        _ = c.CloseHandle(ready);
        return;
    }
    const mutex = c.CreateMutexW(null, 0, mutex_name) orelse return error.CreateMutexFailed;
    defer _ = c.CloseHandle(mutex);
    if (c.GetLastError() == c.ERROR_ALREADY_EXISTS) return;
    const shutdown_event = c.CreateEventW(null, 1, 0, shutdown_event_name) orelse return error.CreateEventFailed;
    defer _ = c.CloseHandle(shutdown_event);
    const reload_event = c.CreateEventW(null, 0, 0, reload_event_name) orelse return error.CreateEventFailed;
    defer _ = c.CloseHandle(reload_event);
    const reload_success_event = c.CreateEventW(null, 1, 0, reload_success_event_name) orelse return error.CreateEventFailed;
    defer _ = c.CloseHandle(reload_success_event);
    const reload_failure_event = c.CreateEventW(null, 1, 0, reload_failure_event_name) orelse return error.CreateEventFailed;
    defer _ = c.CloseHandle(reload_failure_event);
    const local_app_data = init.environ_map.get("LOCALAPPDATA") orelse return error.MissingLocalAppData;
    const directory = try std.fs.path.join(allocator, &.{ local_app_data, "weaver" });
    defer allocator.free(directory);
    try std.Io.Dir.cwd().createDirPath(init.io, directory);
    const registry_path = try std.fs.path.join(allocator, &.{ directory, "registry.json" });
    defer allocator.free(registry_path);
    const status_path = try std.fs.path.join(allocator, &.{ directory, "status.json" });
    defer allocator.free(status_path);
    const status_temp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{status_path});
    defer allocator.free(status_temp_path);
    cleanupBackendStatusFiles(init.io, directory);
    const art_cache_root = try std.fs.path.join(allocator, &.{ directory, "artcache" });
    defer allocator.free(art_cache_root);
    var media_art_cache = try art_cache.Cache.init(init.io, allocator, art_cache_root);
    defer media_art_cache.deinit();
    const repo_root = try repositoryRoot(allocator);
    defer allocator.free(repo_root);
    const runtime_exe = try std.fs.path.join(allocator, &.{ repo_root, "runtime", "zig-out", "bin", "weaver-widget.exe" });
    defer allocator.free(runtime_exe);
    const renderer_exe = try std.fs.path.join(allocator, &.{ repo_root, "renderer", "zig-out", "bin", "weaver-renderer.exe" });
    defer allocator.free(renderer_exe);
    const renderer_pipe_name = try std.fmt.allocPrint(allocator, "\\\\.\\pipe\\weaver-renderer-{d}", .{c.GetCurrentProcessId()});
    defer allocator.free(renderer_pipe_name);
    const renderer_log_path = try std.fmt.allocPrint(allocator, "{s}.renderer.log", .{status_path});
    defer allocator.free(renderer_log_path);
    std.Io.Dir.cwd().deleteFile(init.io, renderer_log_path) catch {};
    const cli_script = try std.fs.path.join(allocator, &.{ repo_root, "cli", "dist", "index.js" });
    defer allocator.free(cli_script);
    var host: Host = .{
        .io = init.io,
        .allocator = allocator,
        .repo_root = repo_root,
        .registry_path = registry_path,
        .status_path = status_path,
        .status_temp_path = status_temp_path,
        .runtime_exe = runtime_exe,
        .renderer_exe = renderer_exe,
        .renderer_pipe_name = renderer_pipe_name,
        .renderer_log_path = renderer_log_path,
        .cli_script = cli_script,
        .art_cache_root = art_cache_root,
        .force_software = if (init.environ_map.get("WEAVER_FORCE_SOFTWARE")) |value| std.mem.eql(u8, value, "1") else false,
    };
    host.media_provider.cache = &media_art_cache;
    defer host.audio_provider.deinit();
    defer host.media_provider.deinit();
    try host.loadRegistry();
    work_event = c.CreateEventW(null, 0, 0, null) orelse return error.CreateEventFailed;
    defer {
        _ = c.CloseHandle(work_event);
        work_event = null;
    }
    var next_provider_ms: u64 = 0;
    var next_cost_ms: u64 = 0;
    while (true) {
        // Sleep until something happens: a signal, queued pipe work, or a
        // child process exiting. Live audio needs its 10 ms drain and
        // media its 250 ms poll; otherwise the loop wakes at most once a
        // second, for provider samples, status, and backoff restarts.
        var handles: [c.MAXIMUM_WAIT_OBJECTS]c.HANDLE = undefined;
        var handle_count: usize = 0;
        for ([_]c.HANDLE{ shutdown_event, reload_event, work_event }) |handle| {
            handles[handle_count] = handle;
            handle_count += 1;
        }
        host.collectProcessHandles(&handles, &handle_count);
        const now_before = c.GetTickCount64();
        const due_ms = @min(next_provider_ms, next_cost_ms) -| now_before;
        const wait_ms: c.DWORD = if (host.hasAudioSubscribers()) 10 else if (host.hasMediaSubscribers()) 250 else @intCast(@min(due_ms, 1000));
        const wait = c.WaitForMultipleObjects(@intCast(handle_count), &handles, 0, wait_ms);
        if (wait == c.WAIT_OBJECT_0) break;
        if (wait == c.WAIT_OBJECT_0 + 1) {
            host.loadRegistry() catch {
                _ = c.SetEvent(reload_failure_event);
                continue;
            };
            _ = c.SetEvent(reload_success_event);
        }
        const now = c.GetTickCount64();
        host.supervise(now);
        host.drainMediaCommands(now);
        host.sampleAudio(now);
        host.sampleMedia(now);
        if (now >= next_provider_ms) {
            host.sampleProviders();
            next_provider_ms = now + 1000;
        }
        if (now >= next_cost_ms) {
            host.noteHostedLoadFailures();
            host.sampleCosts(now);
            host.writeStatus(now);
            next_cost_ms = now + 2000;
        }
    }
    host.stopSharedHost(true);
    for (&host.slots) |*slot| if (slot.platform.process != null) host.stopSlot(slot, true);
    if (host.renderer.platform.process) |process| {
        _ = c.TerminateProcess(process, 0);
        _ = c.WaitForSingleObject(process, 1000);
        _ = c.CloseHandle(process);
        host.renderer.platform.process = null;
    }
    host.writeStatus(c.GetTickCount64());
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

fn signalEvent(name: [*:0]const u16) !void {
    const event = c.OpenEventW(c.EVENT_MODIFY_STATE, 0, name) orelse return error.HostNotRunning;
    defer _ = c.CloseHandle(event);
    if (c.SetEvent(event) == 0) return error.SignalFailed;
}

fn signalReloadAndWait() !void {
    const signal_mutex = c.CreateMutexW(null, 0, reload_signal_mutex_name) orelse return error.CreateMutexFailed;
    defer _ = c.CloseHandle(signal_mutex);
    const mutex_wait = c.WaitForSingleObject(signal_mutex, 10_000);
    if (mutex_wait != c.WAIT_OBJECT_0 and mutex_wait != c.WAIT_ABANDONED) return error.ReloadSignalBusy;
    defer _ = c.ReleaseMutex(signal_mutex);

    const desired_access = c.SYNCHRONIZE | c.EVENT_MODIFY_STATE;
    const success_event = c.OpenEventW(desired_access, 0, reload_success_event_name) orelse return error.HostNotRunning;
    defer _ = c.CloseHandle(success_event);
    const failure_event = c.OpenEventW(desired_access, 0, reload_failure_event_name) orelse return error.HostNotRunning;
    defer _ = c.CloseHandle(failure_event);
    const reload_event = c.OpenEventW(c.EVENT_MODIFY_STATE, 0, reload_event_name) orelse return error.HostNotRunning;
    defer _ = c.CloseHandle(reload_event);
    if (c.ResetEvent(success_event) == 0 or c.ResetEvent(failure_event) == 0) return error.SignalFailed;
    if (c.SetEvent(reload_event) == 0) return error.SignalFailed;
    const acknowledgements = [_]c.HANDLE{ success_event, failure_event };
    const wait = c.WaitForMultipleObjects(acknowledgements.len, &acknowledgements, 0, 10_000);
    if (wait == c.WAIT_OBJECT_0) return;
    if (wait == c.WAIT_OBJECT_0 + 1) return error.RegistryReloadFailed;
    return error.RegistryReloadTimedOut;
}

fn repositoryRoot(allocator: std.mem.Allocator) ![]u8 {
    var path_w: [32768]u16 = undefined;
    const length = c.GetModuleFileNameW(null, &path_w, path_w.len);
    if (length == 0 or length == path_w.len) return error.ExecutablePathFailed;
    const path = try std.unicode.utf16LeToUtf8Alloc(allocator, path_w[0..length]);
    defer allocator.free(path);
    const bin_dir = std.fs.path.dirname(path) orelse return error.ExecutablePathFailed;
    const zig_out = std.fs.path.dirname(bin_dir) orelse return error.ExecutablePathFailed;
    const host_dir = std.fs.path.dirname(zig_out) orelse return error.ExecutablePathFailed;
    const repo = std.fs.path.dirname(host_dir) orelse return error.ExecutablePathFailed;
    return allocator.dupe(u8, repo);
}

fn sampleProcess(state: *WindowsRendererState, now_ms: u64) void {
    const process = state.process orelse return;
    var counters: c.PROCESS_MEMORY_COUNTERS_EX = std.mem.zeroes(c.PROCESS_MEMORY_COUNTERS_EX);
    counters.cb = @sizeOf(c.PROCESS_MEMORY_COUNTERS_EX);
    if (c.GetProcessMemoryInfo(process, @ptrCast(&counters), @sizeOf(c.PROCESS_MEMORY_COUNTERS_EX)) == 0) return;
    const ticks = processTicks(process);
    const elapsed_ms = now_ms -| state.previous_sample_ms;
    const tick_delta = ticks -| state.previous_process_ticks;
    const cpu = if (elapsed_ms == 0) 0 else 100.0 * @as(f64, @floatFromInt(tick_delta)) / 10_000.0 / @as(f64, @floatFromInt(elapsed_ms));
    state.private_samples[state.sample_cursor] = counters.PrivateUsage;
    state.cpu_samples[state.sample_cursor] = @round(cpu * 10.0) / 10.0;
    state.sample_cursor = (state.sample_cursor + 1) % state.private_samples.len;
    state.sample_count = @min(state.sample_count + 1, state.private_samples.len);
    state.previous_process_ticks = ticks;
    state.previous_sample_ms = now_ms;
}

fn setEnv(allocator: std.mem.Allocator, name: [*:0]const u16, value: []const u8) !void {
    const value_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, value);
    defer allocator.free(value_w);
    if (c.SetEnvironmentVariableW(name, value_w.ptr) == 0) return error.SetEnvironmentFailed;
}

fn clearEnv(name: [*:0]const u16) void {
    _ = c.SetEnvironmentVariableW(name, null);
}

fn setEnvUtf8(allocator: std.mem.Allocator, name: []const u8, value: []const u8) !void {
    const name_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, name);
    defer allocator.free(name_w);
    try setEnv(allocator, name_w.ptr, value);
}

fn clearEnvUtf8(allocator: std.mem.Allocator, name: []const u8) void {
    const name_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, name) catch return;
    defer allocator.free(name_w);
    clearEnv(name_w.ptr);
}

fn processTicks(process: c.HANDLE) u64 {
    var created: c.FILETIME = undefined;
    var exited: c.FILETIME = undefined;
    var kernel: c.FILETIME = undefined;
    var user: c.FILETIME = undefined;
    if (c.GetProcessTimes(process, &created, &exited, &kernel, &user) == 0) return 0;
    return fileTime(kernel) + fileTime(user);
}

fn fileTime(value: c.FILETIME) u64 {
    return (@as(u64, value.dwHighDateTime) << 32) | value.dwLowDateTime;
}

fn collectThreadCounts(host: *Host, slot_counts: *[max_widgets]u32, renderer_count: *u32) void {
    const snapshot = c.CreateToolhelp32Snapshot(c.TH32CS_SNAPTHREAD, 0);
    if (snapshot == invalid_handle) return;
    defer _ = c.CloseHandle(snapshot);
    var entry: c.THREADENTRY32 = std.mem.zeroes(c.THREADENTRY32);
    entry.dwSize = @sizeOf(c.THREADENTRY32);
    if (c.Thread32First(snapshot, &entry) == 0) return;
    while (true) {
        if (entry.th32OwnerProcessID == host.renderer.platform.pid) renderer_count.* += 1;
        if (host.shared.process.pid != 0 and entry.th32OwnerProcessID == host.shared.process.pid) host.shared.threads += 1;
        for (&host.slots, 0..) |slot, index| {
            if (slot.platform.pid != 0 and entry.th32OwnerProcessID == slot.platform.pid) slot_counts[index] += 1;
        }
        if (c.Thread32Next(snapshot, &entry) == 0) break;
    }
}

fn commandReaderMain(platform: *WindowsSlotState) void {
    const event = c.CreateEventW(null, 0, 0, null) orelse return;
    defer _ = c.CloseHandle(event);
    // Every exit and every fed chunk is work for the supervision loop.
    defer signalWork();
    var framer: media_commands.Framer = .{};
    var chunk: [512]u8 = undefined;
    while (true) {
        if (platform.command_stopping.load(.acquire) != 0) return;
        var read: c.DWORD = 0;
        _ = c.ResetEvent(event);
        var overlapped: c.OVERLAPPED = std.mem.zeroes(c.OVERLAPPED);
        overlapped.hEvent = event;
        if (platform.test_before_command_read) |barrier| {
            _ = c.SetEvent(barrier);
            if (platform.test_resume_command_read) |resume_event| _ = c.WaitForSingleObject(resume_event, c.INFINITE);
        }
        if (platform.command_stopping.load(.acquire) != 0) return;
        if (c.ReadFile(platform.pipe, &chunk, chunk.len, &read, &overlapped) == 0) {
            if (c.GetLastError() != c.ERROR_IO_PENDING) {
                framer.finish(&platform.command_queue);
                return;
            }
            const shutdown = platform.command_shutdown_event orelse {
                framer.finish(&platform.command_queue);
                return;
            };
            const handles = [_]c.HANDLE{ event, shutdown };
            const wait = c.WaitForMultipleObjects(handles.len, &handles, 0, c.INFINITE);
            if (wait == c.WAIT_OBJECT_0 + 1) {
                _ = c.CancelIoEx(platform.pipe, &overlapped);
                var cancelled: c.DWORD = 0;
                _ = c.GetOverlappedResult(platform.pipe, &overlapped, &cancelled, 1);
                return;
            }
            if (wait != c.WAIT_OBJECT_0 or c.GetOverlappedResult(platform.pipe, &overlapped, &read, 0) == 0) {
                framer.finish(&platform.command_queue);
                return;
            }
        }
        if (platform.command_stopping.load(.acquire) != 0) return;
        if (read == 0) {
            framer.finish(&platform.command_queue);
            return;
        }
        if (!framer.feed(&platform.command_queue, chunk[0..read])) return;
        signalWork();
    }
}

fn writePipe(platform: *WindowsSlotState, bytes: []const u8) bool {
    const event = platform.write_event orelse return false;
    _ = c.ResetEvent(event);
    var overlapped: c.OVERLAPPED = std.mem.zeroes(c.OVERLAPPED);
    overlapped.hEvent = event;
    var written: c.DWORD = 0;
    if (c.WriteFile(platform.pipe, bytes.ptr, @intCast(bytes.len), &written, &overlapped) == 0) {
        if (c.GetLastError() != c.ERROR_IO_PENDING) return false;
        if (c.WaitForSingleObject(event, 1000) != c.WAIT_OBJECT_0) {
            _ = c.CancelIoEx(platform.pipe, &overlapped);
            var cancelled_bytes: c.DWORD = 0;
            _ = c.GetOverlappedResult(platform.pipe, &overlapped, &cancelled_bytes, 1);
            return false;
        }
        if (c.GetOverlappedResult(platform.pipe, &overlapped, &written, 0) == 0) return false;
    }
    return written == bytes.len;
}

/// The status file a hosted widget writes `failed:<error>` to when it does
/// not load.
const FailureReport = struct {
    io: std.Io,
    path: []const u8,

    fn reported(self: FailureReport) bool {
        var buffer: [16]u8 = undefined;
        const text = std.Io.Dir.cwd().readFile(self.io, self.path, &buffer) catch return false;
        return std.mem.startsWith(u8, text, "failed:");
    }
};

fn connectPipe(pipe: c.HANDLE, process: c.HANDLE, expected_pid: u32, timeout_ms: u64, failure_report: ?FailureReport) bool {
    const deadline = c.GetTickCount64() +| timeout_ms;
    while (true) {
        const now = c.GetTickCount64();
        if (now >= deadline or !connectPipeOnce(pipe, process, deadline - now, failure_report)) return false;
        const actual_pid = namedPipeClientPid(pipe) orelse {
            _ = c.DisconnectNamedPipe(pipe);
            return false;
        };
        if (actual_pid == expected_pid) return true;
        std.log.warn(
            "rejecting provider pipe client pid={d}; expected widget pid={d}",
            .{ actual_pid, expected_pid },
        );
        // Reset the sole pipe instance before accepting any bytes. The
        // authorized child is the only process permitted to cross this
        // endpoint boundary.
        _ = c.DisconnectNamedPipe(pipe);
    }
}

fn connectPipeOnce(pipe: c.HANDLE, process: c.HANDLE, timeout_ms: u64, failure_report: ?FailureReport) bool {
    const event = c.CreateEventW(null, 0, 0, null) orelse return false;
    defer _ = c.CloseHandle(event);
    var overlapped: c.OVERLAPPED = std.mem.zeroes(c.OVERLAPPED);
    overlapped.hEvent = event;
    if (c.ConnectNamedPipe(pipe, &overlapped) == 0) {
        const pipe_error = c.GetLastError();
        if (pipe_error == c.ERROR_PIPE_CONNECTED) {
            _ = c.SetEvent(event);
        } else if (pipe_error == c.ERROR_IO_PENDING) {
            const handles = [_]c.HANDLE{ event, process };
            // Wait in 100 ms slices when a failure report can end the wait
            // early, otherwise in one.
            const slice_ms: u64 = if (failure_report != null) 100 else timeout_ms;
            var waited_ms: u64 = 0;
            var wait: c.DWORD = c.WAIT_TIMEOUT;
            while (true) {
                const this_slice = @min(slice_ms, timeout_ms - waited_ms);
                wait = c.WaitForMultipleObjects(handles.len, &handles, 0, @intCast(this_slice));
                waited_ms += this_slice;
                if (wait != c.WAIT_TIMEOUT or waited_ms >= timeout_ms) break;
                if (failure_report) |report| if (report.reported()) break;
            }
            if (wait != c.WAIT_OBJECT_0) {
                _ = c.CancelIoEx(pipe, &overlapped);
                var cancelled_bytes: c.DWORD = 0;
                _ = c.GetOverlappedResult(pipe, &overlapped, &cancelled_bytes, 1);
                return false;
            }
            var transferred: c.DWORD = 0;
            if (c.GetOverlappedResult(pipe, &overlapped, &transferred, 0) == 0) return false;
        } else {
            return false;
        }
    }
    return true;
}

fn namedPipeClientPid(pipe: c.HANDLE) ?u32 {
    var pid: c.ULONG = 0;
    if (c.GetNamedPipeClientProcessId(pipe, &pid) == 0) return null;
    return @intCast(pid);
}

fn closeWindowsForProcess(pid: u32) void {
    const Callback = struct {
        fn call(window: c.HWND, process_id: c.LPARAM) callconv(.c) c.BOOL {
            var owner: c.DWORD = 0;
            _ = c.GetWindowThreadProcessId(window, &owner);
            if (owner == @as(u32, @intCast(process_id))) _ = c.PostMessageW(window, c.WM_CLOSE, 0, 0);
            return 1;
        }
    };
    _ = c.EnumWindows(Callback.call, @intCast(pid));
}

test {
    _ = audio;
    _ = registry;
    _ = backoff;
    _ = media;
    _ = providers;
}

test "Windows host command reader closes the cancel-before-read shutdown race" {
    var platform: WindowsSlotState = .{};
    platform.command_shutdown_event = c.CreateEventW(null, 1, 0, null) orelse return error.CreateEventFailed;
    defer _ = c.CloseHandle(platform.command_shutdown_event);
    platform.test_before_command_read = c.CreateEventW(null, 1, 0, null) orelse return error.CreateEventFailed;
    defer _ = c.CloseHandle(platform.test_before_command_read);
    platform.test_resume_command_read = c.CreateEventW(null, 1, 0, null) orelse return error.CreateEventFailed;
    defer _ = c.CloseHandle(platform.test_resume_command_read);
    const thread = try std.Thread.spawn(.{}, commandReaderMain, .{&platform});
    try std.testing.expectEqual(c.WAIT_OBJECT_0, c.WaitForSingleObject(platform.test_before_command_read, 1000));

    // Cancellation occurs while the worker is deterministically between reads.
    platform.command_stopping.store(1, .release);
    _ = c.SetEvent(platform.command_shutdown_event);
    _ = c.CancelIoEx(platform.pipe, null);
    _ = c.SetEvent(platform.test_resume_command_read);
    thread.join();
}

test "provider pipe rejects a connected client whose pid is not the launched child" {
    var name_buffer: [160]u8 = undefined;
    const name = try std.fmt.bufPrint(
        &name_buffer,
        "\\\\.\\pipe\\weaver-hijack-test-{d}-{d}",
        .{ c.GetCurrentProcessId(), c.GetTickCount64() },
    );
    const name_w = try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, name);
    defer std.testing.allocator.free(name_w);
    const pipe = c.CreateNamedPipeW(
        name_w.ptr,
        c.PIPE_ACCESS_DUPLEX | c.FILE_FLAG_OVERLAPPED,
        c.PIPE_TYPE_BYTE | c.PIPE_READMODE_BYTE | c.PIPE_WAIT,
        1,
        512,
        512,
        0,
        null,
    );
    try std.testing.expect(pipe != invalid_handle);
    defer _ = c.CloseHandle(pipe);

    const Connector = struct {
        fn run(path: [*:0]const u16) void {
            const client = c.CreateFileW(path, c.GENERIC_READ | c.GENERIC_WRITE, 0, null, c.OPEN_EXISTING, 0, null);
            if (client != invalid_handle) {
                c.Sleep(500);
                _ = c.CloseHandle(client);
            }
        }
    };
    const connector = try std.Thread.spawn(.{}, Connector.run, .{name_w.ptr});
    defer connector.join();
    try std.testing.expect(!connectPipe(
        pipe,
        c.GetCurrentProcess(),
        c.GetCurrentProcessId() + 1,
        200,
        null,
    ));
}
