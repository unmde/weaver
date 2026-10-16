const std = @import("std");
const backoff = @import("backoff.zig");
const registry = @import("registry.zig");

pub const max_widgets: usize = 32;
pub const max_name_bytes: usize = 256;
pub const max_path_bytes: usize = 2048;

pub const RunState = enum { disabled, starting, running, backoff, stopped, source_missing };

pub fn runStateLabel(state: RunState) []const u8 {
    return if (state == .source_missing) "source missing" else @tagName(state);
}

pub const Subscription = enum { cpu, memory, audio, media };

pub fn Slot(comptime PlatformState: type) type {
    return struct {
        const Self = @This();

        platform: PlatformState = .{},
        used: bool = false,
        enabled: bool = false,
        dev: bool = false,
        name_buffer: [max_name_bytes]u8 = undefined,
        name_len: usize = 0,
        source_buffer: [max_path_bytes]u8 = undefined,
        source_len: usize = 0,
        state: RunState = .disabled,
        wants_cpu: bool = false,
        wants_memory: bool = false,
        wants_audio: bool = false,
        wants_media: bool = false,
        wants_media_transport: bool = false,
        wants_gpu: bool = false,
        cpu_sent: bool = false,
        memory_sent: bool = false,
        media_sent: bool = false,
        artifact_mtime: i128 = 0,
        started_ms: u64 = 0,
        next_restart_ms: u64 = 0,
        crash_times: [backoff.history_capacity]u64 = [_]u64{0} ** backoff.history_capacity,
        crash_count: usize = 0,
        reason_buffer: [256]u8 = undefined,
        reason_len: usize = 0,

        pub fn name(self: *const Self) []const u8 {
            return self.name_buffer[0..self.name_len];
        }
        pub fn source(self: *const Self) []const u8 {
            return self.source_buffer[0..self.source_len];
        }
        pub fn reason(self: *const Self) []const u8 {
            return self.reason_buffer[0..self.reason_len];
        }

        pub fn setRegistration(self: *Self, value: registry.Registration) !void {
            if (value.name.len > self.name_buffer.len or value.sourcePath.len > self.source_buffer.len) return error.RegistrationTooLong;
            @memcpy(self.name_buffer[0..value.name.len], value.name);
            @memcpy(self.source_buffer[0..value.sourcePath.len], value.sourcePath);
            self.name_len = value.name.len;
            self.source_len = value.sourcePath.len;
            self.enabled = value.enabled;
            self.dev = value.dev;
            self.used = true;
            if (!value.enabled) self.state = .disabled;
        }

        pub fn setReason(self: *Self, comptime format: []const u8, args: anytype) void {
            var writer = std.Io.Writer.fixed(&self.reason_buffer);
            writer.print(format, args) catch {};
            self.reason_len = writer.buffered().len;
        }
    };
}

pub fn RendererState(comptime PlatformState: type) type {
    return struct {
        platform: PlatformState = .{},
        started_ms: u64 = 0,
        next_restart_ms: u64 = 0,
        crash_count: usize = 0,
    };
}

/// Widget slots, each written only when first taken: most installs use a
/// few of max_widgets, and the rest stay untouched pages (5.8 KiB a slot on
/// Windows, 2026-10-16).
pub fn Slots(comptime PlatformState: type) type {
    return struct {
        const Self = @This();
        storage: [max_widgets]Slot(PlatformState) = undefined,
        /// Slots taken so far; a freed one stays here, unused, for reuse.
        len: usize = 0,

        pub fn all(self: *Self) []Slot(PlatformState) {
            return self.storage[0..self.len];
        }

        pub fn allConst(self: *const Self) []const Slot(PlatformState) {
            return self.storage[0..self.len];
        }

        /// A free slot, reusing a freed one before writing a new one.
        pub fn take(self: *Self) ?usize {
            for (self.all(), 0..) |*slot, index| if (!slot.used) return index;
            if (self.len == max_widgets) return null;
            self.storage[self.len] = .{};
            self.len += 1;
            return self.len - 1;
        }
    };
}

pub fn reconcile(slots: anytype, registrations: []const registry.Registration, adapter: anytype) !void {
    var seen = [_]bool{false} ** max_widgets;
    for (registrations) |registration| {
        const index = findSlot(slots.all(), registration.name) orelse slots.take() orelse return error.RegistryFull;
        seen[index] = true;
        const slot = &slots.storage[index];
        const source_changed = slot.used and !std.mem.eql(u8, slot.source(), registration.sourcePath);
        const dev_changed = slot.used and slot.dev != registration.dev;
        if (source_changed or dev_changed) adapter.stop(index, true);
        try slot.setRegistration(registration);
        if (registration.enabled and (source_changed or dev_changed)) {
            slot.crash_times = [_]u64{0} ** backoff.history_capacity;
            slot.crash_count = 0;
            slot.state = .starting;
            slot.next_restart_ms = 0;
            slot.reason_len = 0;
        }
        if (!registration.enabled and adapter.running(index)) adapter.stop(index, true);
        if (!registration.enabled) slot.state = .disabled;
        if (registration.enabled and slot.state == .disabled) slot.state = .starting;
        const artifact = adapter.artifactMtime(slot.source());
        if (adapter.running(index) and artifact != 0 and artifact != slot.artifact_mtime) {
            adapter.stop(index, true);
            slot.state = .starting;
        } else if (slot.state == .stopped and artifact != 0 and artifact != slot.artifact_mtime) {
            // A crash-latched slot has no live process, so the running()
            // branch above never notices a reinstall. A new artifact is a
            // new program: it gets a fresh crash budget and a launch,
            // otherwise a fixed bundle stays silently dead until the host
            // itself restarts.
            slot.crash_times = [_]u64{0} ** backoff.history_capacity;
            slot.crash_count = 0;
            slot.next_restart_ms = 0;
            slot.reason_len = 0;
            slot.state = .starting;
        }
    }
    for (slots.all(), 0..) |*slot, index| {
        if (!slot.used or seen[index]) continue;
        adapter.stop(index, true);
        slot.* = .{};
    }
}

pub const SlotAction = enum { none, stop_missing, handle_exit, launch };

pub fn nextSlotAction(slot: anytype, source_exists: bool, process_running: bool, process_exited: bool, now_ms: u64) SlotAction {
    if (!slot.used or !slot.enabled) return .none;
    if (!source_exists) {
        slot.state = .source_missing;
        slot.next_restart_ms = 0;
        slot.setReason("registered source path does not exist", .{});
        return if (process_running) .stop_missing else .none;
    }
    if (slot.state == .source_missing) {
        slot.state = .starting;
        slot.reason_len = 0;
    }
    if (slot.state == .stopped) return .none;
    if (process_running) return if (process_exited) .handle_exit else .none;
    if ((slot.state == .starting or slot.state == .backoff) and now_ms >= slot.next_restart_ms) return .launch;
    return .none;
}

pub fn selectManifest(
    slot: anytype,
    subscriptions: []const []const u8,
    capabilities: []const []const u8,
    render_backend: []const u8,
    force_software: bool,
) void {
    slot.wants_cpu = false;
    slot.wants_memory = false;
    slot.wants_audio = false;
    slot.wants_media = false;
    slot.wants_media_transport = false;
    slot.wants_gpu = !force_software and std.mem.eql(u8, render_backend, "gpu");
    for (subscriptions) |name| {
        if (std.mem.eql(u8, name, "cpu")) slot.wants_cpu = true;
        if (std.mem.eql(u8, name, "memory")) slot.wants_memory = true;
        if (std.mem.eql(u8, name, "audio")) slot.wants_audio = true;
        if (std.mem.eql(u8, name, "media")) slot.wants_media = true;
    }
    for (capabilities) |name| {
        if (std.mem.eql(u8, name, "media-transport")) slot.wants_media_transport = true;
    }
}

pub fn markRunning(slot: anytype, now_ms: u64, artifact_mtime: i128) void {
    slot.state = .running;
    slot.started_ms = now_ms;
    slot.reason_len = 0;
    slot.artifact_mtime = artifact_mtime;
    slot.cpu_sent = false;
    slot.memory_sent = false;
    slot.media_sent = false;
}

pub fn recordCrash(slot: anytype, now_ms: u64, exit_code: ?u32) void {
    if (backoff.recordCrash(&slot.crash_times, &slot.crash_count, now_ms)) {
        slot.state = .stopped;
        slot.setReason("runtime process crashed after 3 restart attempts within 5 minutes{s}{?d}", .{ if (exit_code != null) ": exit_code=" else "", exit_code });
        return;
    }
    slot.state = .backoff;
    slot.next_restart_ms = now_ms + backoff.delayMs(slot.crash_count);
    slot.setReason("runtime process crashed{s}{?d}; restart {d} in {d}s", .{
        if (exit_code != null) ": exit_code=" else "",
        exit_code,
        slot.crash_count,
        backoff.delayMs(slot.crash_count) / 1000,
    });
}

pub fn recordLaunchFailure(slot: anytype, now_ms: u64, err: anyerror) void {
    if (backoff.recordCrash(&slot.crash_times, &slot.crash_count, now_ms)) {
        slot.state = .stopped;
        slot.setReason("launch failed after 3 restart attempts within 5 minutes: {s}", .{@errorName(err)});
        return;
    }
    slot.state = .backoff;
    slot.next_restart_ms = now_ms + backoff.delayMs(slot.crash_count);
    slot.setReason("launch failed: {s}; restart {d} in {d}s", .{
        @errorName(err),
        slot.crash_count,
        backoff.delayMs(slot.crash_count) / 1000,
    });
}

/// A fatal provider/command channel is process-fatal because the authenticated
/// endpoint is intentionally created once per widget launch. Reuse the crash
/// budget and backoff so a replacement process receives a fresh endpoint.
pub fn recordChannelFailure(slot: anytype, now_ms: u64) void {
    if (backoff.recordCrash(&slot.crash_times, &slot.crash_count, now_ms)) {
        slot.state = .stopped;
        slot.setReason("provider channel failed after 3 restart attempts within 5 minutes", .{});
        return;
    }
    slot.state = .backoff;
    slot.next_restart_ms = now_ms + backoff.delayMs(slot.crash_count);
    slot.setReason("provider channel failed; restart {d} in {d}s", .{
        slot.crash_count,
        backoff.delayMs(slot.crash_count) / 1000,
    });
}

pub fn rendererDesired(slots: anytype, force_software: bool) bool {
    if (force_software) return false;
    for (slots) |slot| {
        if (slot.used and slot.enabled and slot.wants_gpu and slot.state != .stopped and slot.state != .source_missing) return true;
    }
    return false;
}

pub const RendererAction = enum { none, stop, handle_exit, launch };

pub fn nextRendererAction(running: bool, exited: bool, desired: bool, now_ms: u64, next_restart_ms: u64) RendererAction {
    if (running) {
        if (exited) return .handle_exit;
        if (!desired) return .stop;
        return .none;
    }
    return if (desired and now_ms >= next_restart_ms) .launch else .none;
}

pub fn recordRendererExit(renderer: anytype, now_ms: u64) void {
    renderer.crash_count += 1;
    const delays = [_]u64{ 1000, 5000, 30_000 };
    renderer.next_restart_ms = now_ms + delays[@min(renderer.crash_count - 1, delays.len - 1)];
}

pub fn hasSubscription(slots: anytype, subscription: Subscription, adapter: anytype) bool {
    return subscriptionCount(slots, subscription, adapter) > 0;
}

pub fn subscriptionCount(slots: anytype, subscription: Subscription, adapter: anytype) u32 {
    var count: u32 = 0;
    for (slots, 0..) |slot, index| {
        if (!adapter.running(index)) continue;
        const wanted = switch (subscription) {
            .cpu => slot.wants_cpu,
            .memory => slot.wants_memory,
            .audio => slot.wants_audio,
            .media => slot.wants_media,
        };
        if (wanted) count += 1;
    }
    return count;
}

pub fn systemSubscriberCount(slots: anytype, adapter: anytype) u32 {
    var count: u32 = 0;
    for (slots, 0..) |slot, index| {
        if (adapter.running(index) and (slot.wants_cpu or slot.wants_memory)) count += 1;
    }
    return count;
}

pub const ProviderStatus = struct {
    system_subscribers: u32,
    system_sample_count: u64,
    system_frames: u64,
    audio_capture_active: bool,
    audio_silent: bool,
    audio_pipe_frames: u64,
    media_pipe_frames: u64,
    media_availability: []const u8,
    media_subscribers: u32,
    audio_availability: []const u8 = "idle",
    audio_subscribers: u32 = 0,
    audio_capture_starts: u64 = 0,
    audio_provider_frames: u64 = 0,
    audio_last_error: i32 = 0,
};

pub const StatusEntry = struct {
    name: []const u8,
    pid: u32,
    private_mb: f64,
    cpu_percent: f64,
    threads: u32,
    backend: []const u8,
    uptime_seconds: u64,
    state: RunState,
    reason: []const u8,
    /// The widget runs inside the shared host process: its memory and CPU
    /// are the host row's, not its own.
    hosted: bool = false,
    /// This row is the shared widget host process itself.
    host_row: bool = false,
};

pub fn writeStatus(writer: *std.Io.Writer, host_pid: u32, provider_status: ProviderStatus, entries: []const StatusEntry) !void {
    var json: std.json.Stringify = .{ .writer = writer, .options = .{ .whitespace = .indent_2 } };
    try json.beginObject();
    try json.objectField("hostPid");
    try json.write(host_pid);
    try json.objectField("providers");
    try json.beginObject();
    try json.objectField("systemSubscribers");
    try json.write(provider_status.system_subscribers);
    try json.objectField("systemSampleCount");
    try json.write(provider_status.system_sample_count);
    try json.objectField("systemFrames");
    try json.write(provider_status.system_frames);
    try json.objectField("audioCaptureActive");
    try json.write(provider_status.audio_capture_active);
    try json.objectField("audioSilent");
    try json.write(provider_status.audio_silent);
    try json.objectField("audioPipeFrames");
    try json.write(provider_status.audio_pipe_frames);
    try json.objectField("audioAvailability");
    try json.write(provider_status.audio_availability);
    try json.objectField("audioSubscribers");
    try json.write(provider_status.audio_subscribers);
    try json.objectField("audioCaptureStarts");
    try json.write(provider_status.audio_capture_starts);
    try json.objectField("audioProviderFrames");
    try json.write(provider_status.audio_provider_frames);
    try json.objectField("audioLastError");
    try json.write(provider_status.audio_last_error);
    try json.objectField("mediaPipeFrames");
    try json.write(provider_status.media_pipe_frames);
    try json.objectField("mediaAvailability");
    try json.write(provider_status.media_availability);
    try json.objectField("mediaSubscribers");
    try json.write(provider_status.media_subscribers);
    try json.endObject();
    try json.objectField("widgets");
    try json.beginArray();
    for (entries) |entry| {
        try json.beginObject();
        try json.objectField("name");
        try json.write(entry.name);
        try json.objectField("pid");
        try json.write(entry.pid);
        try json.objectField("privateMb");
        try json.write(entry.private_mb);
        try json.objectField("cpuPercent");
        try json.write(entry.cpu_percent);
        try json.objectField("threads");
        try json.write(entry.threads);
        try json.objectField("backend");
        try json.write(entry.backend);
        try json.objectField("uptimeSeconds");
        try json.write(entry.uptime_seconds);
        try json.objectField("state");
        try json.write(runStateLabel(entry.state));
        if (entry.hosted) {
            try json.objectField("hosted");
            try json.write(true);
        }
        if (entry.host_row) {
            try json.objectField("host");
            try json.write(true);
        }
        try json.objectField("reason");
        // A running widget that has never reported a renderer backend is
        // presenting nothing — the window shows no frames. Saying so here
        // is the difference between "running" reading as healthy and the
        // one real tell (backend '-') going unnoticed. Ten seconds skips
        // ordinary startup latency.
        if (!entry.host_row and entry.state == .running and entry.reason.len == 0 and entry.uptime_seconds >= 10 and std.mem.eql(u8, entry.backend, "-")) {
            try json.write("no frames presented (renderer surface not created); check 'weaver logs <name>'");
        } else {
            try json.write(entry.reason);
        }
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
}

fn findSlot(slots: anytype, name: []const u8) ?usize {
    for (slots, 0..) |*slot, index| if (slot.used and std.mem.eql(u8, slot.name(), name)) return index;
    return null;
}

const FakePlatformState = struct { running: bool = false, mtime: i128 = 0 };
const FakeSlot = Slot(FakePlatformState);
const FakeSlots = Slots(FakePlatformState);

const FakeAdapter = struct {
    slots: *FakeSlots,
    stops: usize = 0,

    fn running(self: *@This(), index: usize) bool {
        return self.slots.storage[index].platform.running;
    }
    fn artifactMtime(self: *@This(), source: []const u8) i128 {
        for (self.slots.all()) |slot| if (slot.used and std.mem.eql(u8, slot.source(), source)) return slot.platform.mtime;
        return 0;
    }
    fn stop(self: *@This(), index: usize, _: bool) void {
        self.stops += 1;
        self.slots.storage[index].platform.running = false;
    }
};

test "fake adapter drives reconciliation without platform handles" {
    var slots: FakeSlots = .{};
    var fake: FakeAdapter = .{ .slots = &slots };
    const first = [_]registry.Registration{.{ .name = "Clock", .sourcePath = "/owned/clock-v1", .enabled = true, .dev = false }};
    try reconcile(&slots, &first, &fake);
    try std.testing.expect(slots.storage[0].used);
    try std.testing.expectEqual(RunState.starting, slots.storage[0].state);

    slots.storage[0].platform.running = true;
    slots.storage[0].artifact_mtime = 10;
    slots.storage[0].platform.mtime = 11;
    try reconcile(&slots, &first, &fake);
    try std.testing.expectEqual(@as(usize, 1), fake.stops);
    try std.testing.expectEqual(RunState.starting, slots.storage[0].state);

    try reconcile(&slots, &.{}, &fake);
    try std.testing.expectEqual(@as(usize, 2), fake.stops);
    try std.testing.expect(!slots.storage[0].used);
}

test "reinstalling from a new owned path cannot leave a running slot with no process" {
    var slots: FakeSlots = .{};
    var fake: FakeAdapter = .{ .slots = &slots };
    const first = [_]registry.Registration{.{ .name = "Clock", .sourcePath = "/owned/clock-v1", .enabled = true, .dev = false }};
    try reconcile(&slots, &first, &fake);
    slots.storage[0].platform.running = true;
    markRunning(&slots.storage[0], 100, 10);

    const replacement = [_]registry.Registration{.{ .name = "Clock", .sourcePath = "/owned/clock-v2", .enabled = true, .dev = false }};
    try reconcile(&slots, &replacement, &fake);

    try std.testing.expectEqual(@as(usize, 1), fake.stops);
    try std.testing.expect(!slots.storage[0].platform.running);
    try std.testing.expectEqual(RunState.starting, slots.storage[0].state);
    try std.testing.expectEqual(SlotAction.launch, nextSlotAction(&slots.storage[0], true, false, false, 100));
}

test "a new artifact revives a crash-latched slot with a fresh crash budget" {
    var slots: FakeSlots = .{};
    var fake: FakeAdapter = .{ .slots = &slots };
    const registrations = [_]registry.Registration{.{ .name = "Meter", .sourcePath = "/owned/meter", .enabled = true, .dev = false }};
    try reconcile(&slots, &registrations, &fake);

    // Crash out to the stopped latch.
    markRunning(&slots.storage[0], 100, 10);
    slots.storage[0].platform.mtime = 10;
    recordCrash(&slots.storage[0], 200, 1);
    recordCrash(&slots.storage[0], 300, 1);
    recordCrash(&slots.storage[0], 400, 1);
    recordCrash(&slots.storage[0], 500, 1);
    try std.testing.expectEqual(RunState.stopped, slots.storage[0].state);
    try std.testing.expectEqual(SlotAction.none, nextSlotAction(&slots.storage[0], true, false, false, 600));

    // Same artifact: the latch holds.
    try reconcile(&slots, &registrations, &fake);
    try std.testing.expectEqual(RunState.stopped, slots.storage[0].state);

    // A reinstall (new artifact mtime) resets the crash budget and relaunches.
    slots.storage[0].platform.mtime = 11;
    try reconcile(&slots, &registrations, &fake);
    try std.testing.expectEqual(RunState.starting, slots.storage[0].state);
    try std.testing.expectEqual(@as(usize, 0), slots.storage[0].crash_count);
    try std.testing.expectEqual(@as(usize, 0), slots.storage[0].reason().len);
    try std.testing.expectEqual(SlotAction.launch, nextSlotAction(&slots.storage[0], true, false, false, 600));
}

test "slot state machine preserves subscriptions renderer policy and crash backoff" {
    var slot: FakeSlot = .{};
    try slot.setRegistration(.{ .name = "System", .sourcePath = "/owned/system", .enabled = true, .dev = false });
    slot.state = .starting;
    try std.testing.expectEqual(SlotAction.launch, nextSlotAction(&slot, true, false, false, 0));
    selectManifest(&slot, &.{ "cpu", "memory", "audio", "media" }, &.{"media-transport"}, "gpu", false);
    try std.testing.expect(slot.wants_cpu and slot.wants_memory and slot.wants_audio and slot.wants_media and slot.wants_media_transport and slot.wants_gpu);
    markRunning(&slot, 100, 9);
    try std.testing.expectEqual(RunState.running, slot.state);
    recordCrash(&slot, 200, 7);
    try std.testing.expectEqual(RunState.backoff, slot.state);
    try std.testing.expect(std.mem.indexOf(u8, slot.reason(), "exit_code=7") != null);
    try std.testing.expectEqual(@as(u64, 1200), slot.next_restart_ms);
    try std.testing.expectEqual(SlotAction.none, nextSlotAction(&slot, true, false, false, 1199));
    try std.testing.expectEqual(SlotAction.launch, nextSlotAction(&slot, true, false, false, 1200));
    try std.testing.expect(rendererDesired(&[_]FakeSlot{slot}, false));
    try std.testing.expect(!rendererDesired(&[_]FakeSlot{slot}, true));
}

test "fatal provider channel restarts the slot and restores media delivery and transport" {
    var slots: FakeSlots = .{};
    var slot = &slots.storage[slots.take().?];
    try slot.setRegistration(.{ .name = "Player", .sourcePath = "/owned/player", .enabled = true, .dev = false });
    selectManifest(slot, &.{"media"}, &.{"media-transport"}, "software", false);
    slot.platform.running = true;
    markRunning(slot, 100, 1);

    // The platform host kills the old process/endpoint first.
    slot.platform.running = false;
    recordChannelFailure(slot, 200);
    try std.testing.expectEqual(RunState.backoff, slot.state);
    try std.testing.expect(std.mem.startsWith(u8, slot.reason(), "provider channel failed"));
    try std.testing.expectEqual(SlotAction.none, nextSlotAction(slot, true, false, false, 1199));
    try std.testing.expectEqual(SlotAction.launch, nextSlotAction(slot, true, false, false, 1200));

    // A successful relaunch preserves the manifest contract and creates a
    // fresh authenticated endpoint, so both lanes become live again.
    slot.platform.running = true;
    markRunning(slot, 1200, 1);
    var fake: FakeAdapter = .{ .slots = &slots };
    try std.testing.expect(hasSubscription(slots.all(), .media, &fake));
    try std.testing.expect(slot.wants_media_transport);
    try std.testing.expect(!slot.media_sent);
}

test "launch backoff preserves the named cause developers need" {
    var slot: FakeSlot = .{};
    try slot.setRegistration(.{ .name = "Broken", .sourcePath = "/owned/broken", .enabled = true, .dev = false });
    slot.state = .starting;

    recordLaunchFailure(&slot, 200, error.CreateProcessFailed);

    try std.testing.expectEqual(RunState.backoff, slot.state);
    try std.testing.expect(std.mem.indexOf(u8, slot.reason(), "launch failed: CreateProcessFailed") != null);
    try std.testing.expectEqual(SlotAction.none, nextSlotAction(&slot, true, false, false, 1199));
    try std.testing.expectEqual(SlotAction.launch, nextSlotAction(&slot, true, false, false, 1200));
}

test "portable status serializer keeps the public state spelling" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const entries = [_]StatusEntry{.{
        .name = "Clock",
        .pid = 42,
        .private_mb = 12.5,
        .cpu_percent = 0.1,
        .threads = 6,
        .backend = "gpu",
        .uptime_seconds = 9,
        .state = .source_missing,
        .reason = "registered source path does not exist",
    }};
    try writeStatus(&output.writer, 7, .{
        .system_subscribers = 0,
        .system_sample_count = 0,
        .system_frames = 0,
        .audio_capture_active = false,
        .audio_silent = true,
        .audio_pipe_frames = 0,
        .media_pipe_frames = 0,
        .media_availability = "unavailable",
        .media_subscribers = 1,
    }, &entries);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"state\": \"source missing\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"hostPid\": 7") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"mediaAvailability\": \"unavailable\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"mediaSubscribers\": 1") != null);
}

test "a running widget with no reported backend gets a no-frames reason" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const providers: ProviderStatus = .{
        .system_subscribers = 0,
        .system_sample_count = 0,
        .system_frames = 0,
        .audio_capture_active = false,
        .audio_silent = true,
        .audio_pipe_frames = 0,
        .media_pipe_frames = 0,
        .media_availability = "unavailable",
        .media_subscribers = 0,
    };
    const stuck = [_]StatusEntry{.{
        .name = "Meter",
        .pid = 42,
        .private_mb = 10,
        .cpu_percent = 0,
        .threads = 4,
        .backend = "-",
        .uptime_seconds = 11,
        .state = .running,
        .reason = "",
    }};
    try writeStatus(&output.writer, 7, providers, &stuck);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "no frames presented") != null);

    // A freshly launched widget keeps its empty reason during startup.
    var fresh_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer fresh_output.deinit();
    const fresh = [_]StatusEntry{.{
        .name = "Meter",
        .pid = 42,
        .private_mb = 10,
        .cpu_percent = 0,
        .threads = 4,
        .backend = "-",
        .uptime_seconds = 2,
        .state = .running,
        .reason = "",
    }};
    try writeStatus(&fresh_output.writer, 7, providers, &fresh);
    try std.testing.expect(std.mem.indexOf(u8, fresh_output.written(), "no frames presented") == null);
}
