//! The anchored host's providers (ADR 0022 step 3). Each provider (system
//! sampling, audio, media) runs on a worker thread of its own, which
//! initialises COM where the provider uses it and creates, polls and
//! destroys its objects. A worker starts with its first subscriber and waits,
//! holding no provider objects, while nothing subscribes. Media commands run
//! on a thread per widget that sends them, as weaverd ran them, so one
//! widget's slow command never delays another's. The UI thread only
//! subscribes, unsubscribes and submits commands; it never runs provider
//! code.
//!
//! Hosted widgets subscribe in process: frames and acknowledgements land in
//! their provider client's queues (provider_windows.Client.initLocal). Dev
//! widgets subscribe through their pipe (dev_widgets.zig). What weaverd did
//! when it ran these providers holds here:
//! - a widget gets only the providers its manifest subscribes to, and may
//!   command media only if it declares `media-transport`;
//! - at most five accepted commands a second per widget
//!   (media_commands.RateLimiter); every command is acknowledged, with
//!   `ok:false` when it is refused, rate limited or declined;
//! - a command the media session cannot carry (SMTC timed out or threw)
//!   fails that widget's channel: it gets nothing more, and the daemon
//!   (daemon.zig), which reads `takeFailures`, restarts it on its crash
//!   budget;
//! - frames never wake a widget (its provider timer drains them); an
//!   acknowledgement does;
//! - cpu, memory and media frames reach a widget when they changed or it
//!   has none yet; audio frames, every one;
//! - the counters keep their meaning (`Status`).
const std = @import("std");
const host_providers = @import("host_providers");
const protocol = @import("provider_protocol.zig");
const widget_log = @import("widget_log.zig");

const art_cache = host_providers.art_cache;
const audio = host_providers.audio;
const media = host_providers.media;
const media_commands = host_providers.media_commands;
const system = host_providers.providers;
const system_protocol = host_providers.provider_protocol;

const win = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
});

/// Subscribers at once. The daemon registers at most 32 widgets
/// (host/src/supervisor.zig max_widgets), each either hosted or a dev
/// widget, and a widget unsubscribes before its replacement subscribes: 32
/// is the most a registry reaches. Twice that is a tripwire.
pub const max_subscribers: usize = 64;

/// How often the system sampler runs while anything subscribes: weaverd's
/// cadence, which `percent` frames were designed around.
const system_interval_ms: u64 = 1000;

/// Set by `native.testCrash("provider")` in `-Dautomation-seam` builds
/// (bridge.zig): the system provider's worker faults at its next sample, so
/// a crash on a provider thread can be tested on a real host.
pub var test_crash_requested: std.atomic.Value(bool) = .init(false);
/// How often the audio worker polls the capture while anything subscribes:
/// weaverd's wait while it had an audio subscriber. The provider paces its
/// own 30 Hz frames (audio.zig advanceDeadline) on top of this.
const audio_interval_ms: u64 = 10;
/// The longest the media worker sleeps between polls: the media provider
/// polls SMTC once a second (media.zig) and says when its next poll is due.
const media_max_wait_ms: u64 = 1000;
/// Command threads at once: one per widget that commands media, and one
/// that unsubscribed mid-command keeps its thread until that command
/// returns (at most 2.5 s, media.zig). Twice the 32 widgets a registry holds
/// (see max_subscribers) is a tripwire.
pub const max_command_lanes: usize = max_subscribers;
/// Initial stack commit of a worker thread, the least Windows grants
/// (std.Thread). The stack grows on demand within the image's reservation
/// (16 MiB, runtime/build.zig), which the art cache's file calls need.
const worker_stack_bytes: usize = 64 * 1024;

pub const Kind = enum { system, audio, media, commands };
const kind_count = @typeInfo(Kind).@"enum".fields.len;

/// What a widget's manifest asks of the providers.
pub const Wants = struct {
    cpu: bool = false,
    memory: bool = false,
    audio: bool = false,
    media: bool = false,
    /// It declares `media-transport`: it may command the media session.
    media_transport: bool = false,

    pub fn fromManifest(subscribe: []const []const u8, capabilities: []const []const u8) Wants {
        var wants: Wants = .{};
        for (subscribe) |name| {
            if (std.mem.eql(u8, name, "cpu")) wants.cpu = true;
            if (std.mem.eql(u8, name, "memory")) wants.memory = true;
            if (std.mem.eql(u8, name, "audio")) wants.audio = true;
            if (std.mem.eql(u8, name, "media")) wants.media = true;
        }
        for (capabilities) |name| {
            if (std.mem.eql(u8, name, "media-transport")) wants.media_transport = true;
        }
        return wants;
    }

    /// Whether it needs a channel to the providers at all.
    pub fn any(self: Wants) bool {
        return self.cpu or self.memory or self.audio or self.media or self.media_transport;
    }

    fn needs(self: Wants, kind: Kind) bool {
        return switch (kind) {
            .system => self.cpu or self.memory,
            .audio => self.audio,
            .media => self.media,
            // A widget's command thread starts with its first command.
            .commands => false,
        };
    }
};

/// What a subscriber's `notify` is told about.
pub const Delivery = enum {
    /// A frame landed in its queues.
    frame,
    /// An acknowledgement landed in its queues.
    ack,
    /// Its channel failed: nothing more will land.
    failed,
};

/// A subscriber, as the daemon knows it: a hosted widget's slot in the
/// host, or a dev widget's id (its slot in the daemon's registry).
pub const Owner = union(enum) {
    hosted: u16,
    dev: u16,

    fn bit(self: Owner) u32 {
        return switch (self) {
            .hosted, .dev => |id| @as(u32, 1) << @intCast(id),
        };
    }
};

/// What became of an acknowledgement a subscriber was given.
pub const AckStore = enum {
    stored,
    /// No command of its waits for it any more (its client gave up on it):
    /// dropped, as a late ack from a pipe was.
    unknown,
    /// No room: the client broke the protocol's bounds, which fails its
    /// channel.
    full,
};

/// One widget's subscription. Its owner fills the first six fields and
/// keeps it at a fixed address from `subscribe` to `unsubscribe`. The three
/// callbacks run under the service's lock, on whichever thread delivered,
/// so they must not block or call back into the service.
pub const Subscriber = struct {
    wants: Wants,
    owner: Owner,
    /// Where its frames land.
    queues: *protocol.Queues,
    context: *anyopaque,
    /// Keep an acknowledgement for it.
    store_ack: *const fn (context: *anyopaque, id: u64, ok: bool) AckStore,
    /// Told of each delivery.
    notify: *const fn (context: *anyopaque, delivery: Delivery) void,

    // The service's, under its lock.
    subscription: u64 = 0,
    cpu_sent: bool = false,
    memory_sent: bool = false,
    media_sent: bool = false,
    failed: bool = false,
    rate: media_commands.RateLimiter = .{},
    /// Its command thread, from its first accepted command.
    lane: ?*anyopaque = null,
};

/// The channels that failed since the daemon last asked: a bit per hosted
/// slot and per dev id.
pub const Failures = struct {
    hosted: u32 = 0,
    dev: u32 = 0,
};

/// The providers' counters, as weaverd's status has always published them
/// (host/src/supervisor.zig ProviderStatus). One change: a frame for a dev
/// widget counts when it is queued for its pipe, where weaverd counted it
/// once written. A queued frame can still be replaced by a newer one, or
/// lost with a pipe that fails (which restarts the widget).
pub const Status = struct {
    /// System samples taken: one a second while anything subscribes to cpu
    /// or memory.
    system_sample_count: u64 = 0,
    /// cpu and memory frames delivered, one per subscriber that got one.
    system_frames: u64 = 0,
    /// Audio frames that reached at least one subscriber.
    audio_frames: u64 = 0,
    /// Media frames that reached at least one subscriber.
    media_frames: u64 = 0,
    audio_capture_active: bool = false,
    audio_silent: bool = true,
    audio_availability: audio.Availability = .idle,
    audio_capture_starts: u64 = 0,
    audio_provider_frames: u64 = 0,
    audio_last_error: i32 = 0,
};

/// What a media command came to.
pub const Outcome = enum { accepted, declined, channel_failure };

/// One system sample, as frames.
pub const SystemFrames = struct {
    cpu: []const u8,
    cpu_changed: bool,
    memory: []const u8,
    memory_changed: bool,
};

pub const MediaFrame = struct {
    line: []const u8,
    changed: bool,
};

pub const Service = ServiceType(WindowsSources);

/// The service around a set of provider sources: `WindowsSources` in the
/// host, a fake in tests. A source is touched only by its own worker
/// thread. Sources provides:
///   prepare(kind) !void            allocate the kind's state (any thread)
///   threadStart(kind) / threadStop(kind)   on the worker, around its loop
///   sampleSystem() ?SystemFrames
///   setAudioActive(bool, now_ms), pollAudio(now_ms) ?[]const u8,
///   audioStatus(*Status)
///   setMediaActive(bool, now_ms), pollMedia(now_ms) ?MediaFrame,
///   mediaWaitMs(now_ms) u64
///   command(media_commands.Command) Outcome
pub fn ServiceType(comptime Sources: type) type {
    return struct {
        const Self = @This();

        lock: win.SRWLOCK = std.mem.zeroes(win.SRWLOCK),
        sources: Sources,
        subscribers: [max_subscribers]?*Subscriber = @splat(null),
        next_subscription: u64 = 1,
        workers: [kind_count]Worker = @splat(.{}),
        stopping: bool = false,
        status: Status = .{},
        failures: Failures = .{},
        /// Set when a channel fails, so the daemon wakes to restart that
        /// widget instead of polling `takeFailures`.
        failure_signal: ?win.HANDLE = null,
        lanes: [max_command_lanes]?*CommandLane = @splat(null),

        const Worker = struct {
            thread: ?std.Thread = null,
            /// Auto-reset: its subscribers changed, or the service is
            /// stopping.
            event: win.HANDLE = null,
        };

        /// One widget's media commands, run in order on a thread of their
        /// own (weaverd's MediaCommandExecutor). When the widget
        /// unsubscribes, the thread finishes the command it is running,
        /// drops the rest and exits; `reapLanes` joins it.
        const CommandLane = struct {
            service: *Self,
            /// Under the service's lock; null once it unsubscribed.
            subscriber: ?*Subscriber,
            thread: std.Thread = undefined,
            /// Auto-reset: a command arrived, or the lane is ending.
            event: win.HANDLE,
            done: std.atomic.Value(bool) = .init(false),
            commands: [media_commands.queue_capacity]media_commands.Command = undefined,
            head: usize = 0,
            count: usize = 0,
        };

        /// A service with no subscribers and no threads. It must stay at
        /// this address once anything subscribes.
        pub fn init(sources: Sources) Self {
            return .{ .sources = sources };
        }

        /// Stop every worker and command thread, which destroys their
        /// provider objects.
        pub fn deinit(self: *Self) void {
            self.acquire();
            self.stopping = true;
            for (std.enums.values(Kind)) |kind| self.signal(kind);
            for (self.lanes) |entry| if (entry) |lane| {
                _ = win.SetEvent(lane.event);
            };
            self.release();
            for (&self.workers) |*worker| {
                if (worker.thread) |thread| thread.join();
                if (worker.event) |event| _ = win.CloseHandle(event);
                worker.* = .{};
            }
            for (&self.lanes) |*entry| if (entry.*) |lane| {
                lane.thread.join();
                freeLane(lane);
                entry.* = null;
            };
        }

        /// Start delivering to `subscriber` what its `wants` name. Fails
        /// when `max_subscribers` already subscribe, or a worker it needs
        /// cannot start.
        pub fn subscribe(self: *Self, subscriber: *Subscriber) !void {
            switch (subscriber.owner) {
                .hosted, .dev => |id| if (id >= 32) return error.ProviderOwnerOutOfRange,
            }
            self.acquire();
            defer self.release();
            const index = for (self.subscribers, 0..) |existing, index| {
                if (existing == null) break index;
            } else {
                std.log.warn("provider subscription refused: max_subscribers={d}, asked for {d}", .{ max_subscribers, max_subscribers + 1 });
                return error.ProviderSubscribersFull;
            };
            for (std.enums.values(Kind)) |kind| {
                if (subscriber.wants.needs(kind)) try self.ensureWorker(kind);
            }
            subscriber.subscription = self.next_subscription;
            self.next_subscription += 1;
            subscriber.cpu_sent = false;
            subscriber.memory_sent = false;
            subscriber.media_sent = false;
            subscriber.failed = false;
            subscriber.rate = .{};
            subscriber.lane = null;
            self.subscribers[index] = subscriber;
            for (std.enums.values(Kind)) |kind| {
                if (subscriber.wants.needs(kind)) self.signal(kind);
            }
        }

        /// Stop delivering to `subscriber`. When this returns, no worker
        /// touches it again; a command of its still running is dropped.
        pub fn unsubscribe(self: *Self, subscriber: *Subscriber) void {
            self.acquire();
            defer self.release();
            const index = self.indexOf(subscriber) orelse return;
            self.subscribers[index] = null;
            self.clearFailure(subscriber.owner);
            if (laneOf(subscriber)) |lane| {
                lane.subscriber = null;
                _ = win.SetEvent(lane.event);
                subscriber.lane = null;
            }
            self.reapLanes();
            for (std.enums.values(Kind)) |kind| {
                if (subscriber.wants.needs(kind)) self.signal(kind);
            }
        }

        /// A media command from `subscriber`. It is acknowledged later by
        /// its command thread, or at once with `ok:false` when the widget
        /// lacks `media-transport` or is over its rate.
        pub fn submit(self: *Self, subscriber: *Subscriber, command: media_commands.Command) void {
            self.submitAt(subscriber, command, win.GetTickCount64());
        }

        pub fn submitAt(self: *Self, subscriber: *Subscriber, command: media_commands.Command, now_ms: u64) void {
            self.acquire();
            defer self.release();
            if (self.indexOf(subscriber) == null) return;
            if (subscriber.failed or !media_commands.authorize(subscriber.wants.media_transport, &subscriber.rate, now_ms)) {
                return self.deliverAck(subscriber, command.id, false);
            }
            const lane = self.ensureLane(subscriber) catch return self.failLocked(subscriber);
            // Five accepted a second, each done within 2.5 s: a lane of
            // eight (weaverd's) fills only when the media session hangs,
            // and then failed the channel in weaverd too.
            if (lane.count == lane.commands.len) return self.failLocked(subscriber);
            lane.commands[(lane.head + lane.count) % lane.commands.len] = command;
            lane.count += 1;
            _ = win.SetEvent(lane.event);
        }

        /// Fail `subscriber`'s channel: a dev widget's pipe broke, or its
        /// client broke the protocol.
        pub fn fail(self: *Self, subscriber: *Subscriber) void {
            self.acquire();
            defer self.release();
            if (self.indexOf(subscriber) == null) return;
            self.failLocked(subscriber);
        }

        /// The counters now.
        pub fn snapshot(self: *Self) Status {
            self.acquire();
            defer self.release();
            return self.status;
        }

        /// Signal `event` whenever a channel fails from now on.
        pub fn setFailureSignal(self: *Self, event: win.HANDLE) void {
            self.acquire();
            defer self.release();
            self.failure_signal = event;
        }

        /// The channels that failed since the last call.
        pub fn takeFailures(self: *Self) Failures {
            self.acquire();
            defer self.release();
            const failures = self.failures;
            self.failures = .{};
            return failures;
        }

        fn acquire(self: *Self) void {
            win.AcquireSRWLockExclusive(&self.lock);
        }

        fn release(self: *Self) void {
            win.ReleaseSRWLockExclusive(&self.lock);
        }

        fn laneOf(subscriber: *const Subscriber) ?*CommandLane {
            return @ptrCast(@alignCast(subscriber.lane orelse return null));
        }

        /// `subscriber`'s command thread, started if it has none.
        fn ensureLane(self: *Self, subscriber: *Subscriber) !*CommandLane {
            if (laneOf(subscriber)) |lane| return lane;
            self.reapLanes();
            const index = for (self.lanes, 0..) |entry, index| {
                if (entry == null) break index;
            } else {
                std.log.warn("media command thread refused: max_command_lanes={d}, asked for {d}", .{ max_command_lanes, max_command_lanes + 1 });
                return error.CommandLanesFull;
            };
            const lane = try std.heap.page_allocator.create(CommandLane);
            errdefer std.heap.page_allocator.destroy(lane);
            const event = win.CreateEventW(null, 0, 0, null) orelse return error.ProviderWorkerUnavailable;
            errdefer _ = win.CloseHandle(event);
            lane.* = .{ .service = self, .subscriber = subscriber, .event = event };
            lane.thread = std.Thread.spawn(.{ .stack_size = worker_stack_bytes }, laneMain, .{lane}) catch return error.ProviderWorkerUnavailable;
            self.lanes[index] = lane;
            subscriber.lane = lane;
            return lane;
        }

        /// Join the command threads that have exited. They exit only once
        /// their widget unsubscribed, so this never waits on a command.
        fn reapLanes(self: *Self) void {
            for (&self.lanes) |*entry| {
                const lane = entry.* orelse continue;
                if (!lane.done.load(.acquire)) continue;
                lane.thread.join();
                freeLane(lane);
                entry.* = null;
            }
        }

        fn freeLane(lane: *CommandLane) void {
            _ = win.CloseHandle(lane.event);
            std.heap.page_allocator.destroy(lane);
        }

        fn laneMain(lane: *CommandLane) void {
            const self = lane.service;
            self.sources.threadStart(.commands);
            while (true) {
                self.acquire();
                if (self.stopping or lane.subscriber == null) {
                    self.release();
                    break;
                }
                const command: ?media_commands.Command = if (lane.count == 0) null else command: {
                    const next = lane.commands[lane.head];
                    lane.head = (lane.head + 1) % lane.commands.len;
                    lane.count -= 1;
                    break :command next;
                };
                self.release();
                const value = command orelse {
                    _ = win.WaitForSingleObject(lane.event, win.INFINITE);
                    continue;
                };
                const outcome = self.sources.command(value);
                self.acquire();
                // Its widget may have gone while the command ran.
                if (lane.subscriber) |subscriber| if (!subscriber.failed) switch (outcome) {
                    .accepted => self.deliverAck(subscriber, value.id, true),
                    .declined => self.deliverAck(subscriber, value.id, false),
                    .channel_failure => self.failLocked(subscriber),
                };
                self.release();
            }
            self.sources.threadStop(.commands);
            lane.done.store(true, .release);
        }

        fn indexOf(self: *const Self, subscriber: *const Subscriber) ?usize {
            for (self.subscribers, 0..) |existing, index| {
                if (existing == subscriber) return index;
            }
            return null;
        }

        fn signal(self: *Self, kind: Kind) void {
            if (self.workers[@intFromEnum(kind)].event) |event| _ = win.SetEvent(event);
        }

        /// Start `kind`'s worker unless it runs. Under the lock: the worker
        /// takes it as its first act, so it starts after this returns.
        fn ensureWorker(self: *Self, kind: Kind) !void {
            const worker = &self.workers[@intFromEnum(kind)];
            if (worker.thread != null) return;
            try self.sources.prepare(kind);
            if (worker.event == null) worker.event = win.CreateEventW(null, 0, 0, null) orelse return error.ProviderWorkerUnavailable;
            worker.thread = switch (kind) {
                .system => std.Thread.spawn(.{ .stack_size = worker_stack_bytes }, systemMain, .{self}),
                .audio => std.Thread.spawn(.{ .stack_size = worker_stack_bytes }, audioMain, .{self}),
                .media => std.Thread.spawn(.{ .stack_size = worker_stack_bytes }, mediaMain, .{self}),
                // Commands run on their widget's lane (`ensureLane`).
                .commands => unreachable,
            } catch return error.ProviderWorkerUnavailable;
        }

        /// Wait for `kind`'s event, or `timeout_ms`; null waits until it.
        fn wait(self: *Self, kind: Kind, timeout_ms: ?u64) void {
            const event = self.workers[@intFromEnum(kind)].event;
            const ms: win.DWORD = if (timeout_ms) |value| @intCast(@min(value, win.INFINITE - 1)) else win.INFINITE;
            _ = win.WaitForSingleObject(event, ms);
        }

        /// Whether any working subscriber needs `kind`; null once the
        /// service is stopping.
        fn wanted(self: *Self, kind: Kind) ?bool {
            self.acquire();
            defer self.release();
            if (self.stopping) return null;
            for (self.subscribers) |entry| {
                const subscriber = entry orelse continue;
                if (!subscriber.failed and subscriber.wants.needs(kind)) return true;
            }
            return false;
        }

        fn failLocked(self: *Self, subscriber: *Subscriber) void {
            if (subscriber.failed) return;
            subscriber.failed = true;
            if (laneOf(subscriber)) |lane| lane.count = 0;
            switch (subscriber.owner) {
                .hosted => self.failures.hosted |= subscriber.owner.bit(),
                .dev => self.failures.dev |= subscriber.owner.bit(),
            }
            if (self.failure_signal) |event| _ = win.SetEvent(event);
            subscriber.notify(subscriber.context, .failed);
        }

        fn clearFailure(self: *Self, owner: Owner) void {
            switch (owner) {
                .hosted => self.failures.hosted &= ~owner.bit(),
                .dev => self.failures.dev &= ~owner.bit(),
            }
        }

        fn systemMain(self: *Self) void {
            self.sources.threadStart(.system);
            defer self.sources.threadStop(.system);
            var next_ms: u64 = 0;
            while (self.wanted(.system)) |wanted_now| {
                if (!wanted_now) {
                    self.wait(.system, null);
                    continue;
                }
                const now = win.GetTickCount64();
                if (now < next_ms) {
                    self.wait(.system, next_ms - now);
                    continue;
                }
                next_ms = now + system_interval_ms;
                if (@import("weaver_build_options").automation_seam and test_crash_requested.load(.acquire)) {
                    const nowhere: *allowzero volatile u32 = @ptrFromInt(0);
                    nowhere.* = 1;
                }
                self.publishSystem(self.sources.sampleSystem());
            }
        }

        fn audioMain(self: *Self) void {
            self.sources.threadStart(.audio);
            defer self.sources.threadStop(.audio);
            while (self.wanted(.audio)) |wanted_now| {
                const now = win.GetTickCount64();
                self.sources.setAudioActive(wanted_now, now);
                self.publishAudio(if (wanted_now) self.sources.pollAudio(now) else null);
                self.wait(.audio, if (wanted_now) audio_interval_ms else null);
            }
            self.sources.setAudioActive(false, win.GetTickCount64());
            self.publishAudio(null);
        }

        fn mediaMain(self: *Self) void {
            self.sources.threadStart(.media);
            defer self.sources.threadStop(.media);
            while (self.wanted(.media)) |wanted_now| {
                const now = win.GetTickCount64();
                self.sources.setMediaActive(wanted_now, now);
                if (!wanted_now) {
                    self.wait(.media, null);
                    continue;
                }
                if (self.sources.pollMedia(now)) |frame| self.publishMedia(frame);
                self.wait(.media, @max(1, @min(media_max_wait_ms, self.sources.mediaWaitMs(win.GetTickCount64()))));
            }
            self.sources.setMediaActive(false, win.GetTickCount64());
        }

        fn deliverAck(self: *Self, subscriber: *Subscriber, id: u64, ok: bool) void {
            switch (subscriber.store_ack(subscriber.context, id, ok)) {
                .stored => subscriber.notify(subscriber.context, .ack),
                .unknown => {},
                .full => self.failLocked(subscriber),
            }
        }

        fn publishSystem(self: *Self, frames: ?SystemFrames) void {
            self.acquire();
            defer self.release();
            self.status.system_sample_count += 1;
            const sample = frames orelse return;
            for (self.subscribers) |entry| {
                const subscriber = entry orelse continue;
                if (subscriber.failed) continue;
                if (system_protocol.deliveryNeeded(subscriber.wants.cpu, subscriber.cpu_sent, sample.cpu_changed)) {
                    deliverFrame(subscriber, sample.cpu);
                    subscriber.cpu_sent = true;
                    self.status.system_frames += 1;
                }
                if (system_protocol.deliveryNeeded(subscriber.wants.memory, subscriber.memory_sent, sample.memory_changed)) {
                    deliverFrame(subscriber, sample.memory);
                    subscriber.memory_sent = true;
                    self.status.system_frames += 1;
                }
            }
        }

        fn publishAudio(self: *Self, line: ?[]const u8) void {
            self.acquire();
            defer self.release();
            self.sources.audioStatus(&self.status);
            const frame = line orelse return;
            var delivered = false;
            for (self.subscribers) |entry| {
                const subscriber = entry orelse continue;
                if (subscriber.failed or !subscriber.wants.audio) continue;
                deliverFrame(subscriber, frame);
                delivered = true;
            }
            if (delivered) self.status.audio_frames += 1;
        }

        fn publishMedia(self: *Self, frame: MediaFrame) void {
            self.acquire();
            defer self.release();
            var delivered = false;
            for (self.subscribers) |entry| {
                const subscriber = entry orelse continue;
                if (subscriber.failed or !subscriber.wants.media) continue;
                if (subscriber.media_sent and !frame.changed) continue;
                deliverFrame(subscriber, frame.line);
                subscriber.media_sent = true;
                delivered = true;
            }
            if (delivered) self.status.media_frames += 1;
        }
    };
}

/// Frames are formatted as pipe lines; a queue holds a line without its
/// newline, as the pipe reader's framing leaves it.
fn deliverFrame(subscriber: *Subscriber, line: []const u8) void {
    subscriber.queues.pushFrame(std.mem.trimEnd(u8, line, "\n"));
    subscriber.notify(subscriber.context, .frame);
}

/// `Subscriber.store_ack` for a subscriber whose acknowledgements land in
/// its `queues` (a widget's provider client), as they did from a pipe.
pub fn storeQueuedAck(queues: *protocol.Queues, id: u64, ok: bool) AckStore {
    return if (queues.deliverAck(id, ok)) .stored else .unknown;
}

extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, flags: u32) callconv(.winapi) i32;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
const coinit_multithreaded: u32 = 0;

/// The real providers: NtQuerySystemInformation, WASAPI loopback, SMTC and
/// the art cache. Each kind's state is allocated when its worker first
/// starts, so a host whose widgets never subscribe never pays for it.
pub const WindowsSources = struct {
    io: std.Io,
    /// The art cache's directory (WEAVER_ART_CACHE): the media worker owns
    /// the cache, and widgets read its files by the paths in media frames.
    art_cache_root: ?[]const u8,
    system: ?*SystemState = null,
    audio: ?*AudioState = null,
    media: ?*MediaState = null,

    const SystemState = struct {
        sampler: system.Sampler = .{},
        // weaverd's buffers: a cpu frame for 256 cores (max_cores) at
        // "100.0," each is 1,846 bytes; memory frames are under 200.
        cpu: [8192]u8 = undefined,
        previous_cpu: [8192]u8 = undefined,
        previous_cpu_len: usize = 0,
        memory: [512]u8 = undefined,
        previous_memory: [512]u8 = undefined,
        previous_memory_len: usize = 0,
    };

    const AudioState = struct {
        provider: audio.Provider = .{},
        // An audio frame: 32 bands at "1.000," and the rms, under 300 bytes.
        line: [512]u8 = undefined,
    };

    const MediaState = struct {
        provider: media.Provider = .{},
        cache: ?art_cache.Cache = null,
        line: [media.max_media_frame_bytes]u8 = undefined,
        previous: [media.max_media_frame_bytes]u8 = undefined,
        previous_len: usize = 0,
    };

    /// The commands worker's provider: `command` touches no provider state
    /// (it acquires the SMTC session per command), so it needs none of the
    /// media worker's.
    var command_provider: media.Provider = .{};

    pub fn prepare(self: *WindowsSources, kind: Kind) !void {
        const allocator = std.heap.page_allocator;
        switch (kind) {
            .system => if (self.system == null) {
                self.system = try allocator.create(SystemState);
                self.system.?.* = .{};
            },
            .audio => if (self.audio == null) {
                self.audio = try allocator.create(AudioState);
                self.audio.?.* = .{};
            },
            .media => if (self.media == null) {
                self.media = try allocator.create(MediaState);
                self.media.?.* = .{};
            },
            .commands => {},
        }
    }

    pub fn threadStart(self: *WindowsSources, kind: Kind) void {
        widget_log.detachThread();
        if (kind == .system) return;
        // Every provider but the sampler is COM (WASAPI) or WinRT (SMTC).
        _ = CoInitializeEx(null, coinit_multithreaded);
        if (kind != .media) return;
        const state = self.media.?;
        const root = self.art_cache_root orelse return;
        state.cache = art_cache.Cache.init(self.io, std.heap.page_allocator, root) catch |err| cache: {
            std.debug.print("weaver-widget: media artwork disabled: the art cache at {s} could not open: {s}\n", .{ root, @errorName(err) });
            break :cache null;
        };
        if (state.cache) |*cache| state.provider.cache = cache;
    }

    pub fn threadStop(self: *WindowsSources, kind: Kind) void {
        switch (kind) {
            .system => return,
            .audio => self.audio.?.provider.deinit(),
            .media => {
                const state = self.media.?;
                state.provider.deinit();
                state.provider.cache = null;
                if (state.cache) |*cache| cache.deinit();
                state.cache = null;
            },
            .commands => {},
        }
        CoUninitialize();
    }

    pub fn sampleSystem(self: *WindowsSources) ?SystemFrames {
        const state = self.system.?;
        const sample = (state.sampler.sample() catch return null) orelse return null;
        const cpu = system.formatCpu(sample.cpu, &state.cpu) catch return null;
        const memory = system.formatMemory(sample.memory, &state.memory) catch return null;
        const frames: SystemFrames = .{
            .cpu = cpu,
            .cpu_changed = !std.mem.eql(u8, cpu, state.previous_cpu[0..state.previous_cpu_len]),
            .memory = memory,
            .memory_changed = !std.mem.eql(u8, memory, state.previous_memory[0..state.previous_memory_len]),
        };
        @memcpy(state.previous_cpu[0..cpu.len], cpu);
        state.previous_cpu_len = cpu.len;
        @memcpy(state.previous_memory[0..memory.len], memory);
        state.previous_memory_len = memory.len;
        return frames;
    }

    pub fn setAudioActive(self: *WindowsSources, active: bool, now_ms: u64) void {
        self.audio.?.provider.setActive(active, now_ms);
    }

    pub fn pollAudio(self: *WindowsSources, now_ms: u64) ?[]const u8 {
        const state = self.audio.?;
        const frame = state.provider.poll(now_ms) orelse return null;
        return audio.formatFrame(frame, &state.line) catch null;
    }

    pub fn audioStatus(self: *WindowsSources, status: *Status) void {
        const provider = &self.audio.?.provider;
        status.audio_capture_active = provider.capture != null;
        status.audio_silent = provider.silent;
        status.audio_availability = provider.availability;
        status.audio_capture_starts = provider.capture_starts;
        status.audio_provider_frames = provider.frame_count;
        status.audio_last_error = provider.last_error;
    }

    pub fn setMediaActive(self: *WindowsSources, active: bool, now_ms: u64) void {
        self.media.?.provider.setActive(active, now_ms);
    }

    pub fn pollMedia(self: *WindowsSources, now_ms: u64) ?MediaFrame {
        const state = self.media.?;
        const frame = state.provider.poll(now_ms) orelse return null;
        // max_media_frame_bytes bounds every frame (media.zig's receipt).
        const line = media.formatFrame(&frame, &state.line) catch return null;
        const changed = !std.mem.eql(u8, line, state.previous[0..state.previous_len]);
        @memcpy(state.previous[0..line.len], line);
        state.previous_len = line.len;
        return .{ .line = state.previous[0..line.len], .changed = changed };
    }

    /// Until the media provider's next poll, or its next attempt to open
    /// the session.
    pub fn mediaWaitMs(self: *WindowsSources, now_ms: u64) u64 {
        const provider = &self.media.?.provider;
        const due = if (provider.session != null) provider.next_poll_ms else provider.next_open_ms;
        return due -| now_ms;
    }

    pub fn command(_: *WindowsSources, value: media_commands.Command) Outcome {
        return switch (command_provider.command(value.verb, value.seek_ms)) {
            .accepted => .accepted,
            .declined => .declined,
            .channel_failure => .channel_failure,
        };
    }
};

// Tests run the service over fake sources: the real ones need a desktop
// session's audio device and media session.

const FakeSources = struct {
    audio_active: std.atomic.Value(bool) = .init(false),
    audio_polls: std.atomic.Value(u64) = .init(0),
    commands_run: std.atomic.Value(u64) = .init(0),
    outcome: Outcome = .accepted,
    /// A command with this id waits for `gate` before it returns, once it
    /// has said it started.
    blocked_id: u64 = 0,
    gate: win.HANDLE = null,
    blocked_started: std.atomic.Value(bool) = .init(false),
    started: [kind_count]std.atomic.Value(bool) = @splat(.init(false)),

    pub fn prepare(_: *FakeSources, _: Kind) !void {}
    pub fn threadStart(self: *FakeSources, kind: Kind) void {
        self.started[@intFromEnum(kind)].store(true, .release);
    }
    pub fn threadStop(_: *FakeSources, _: Kind) void {}
    pub fn sampleSystem(_: *FakeSources) ?SystemFrames {
        return null;
    }
    pub fn setAudioActive(self: *FakeSources, active: bool, _: u64) void {
        self.audio_active.store(active, .release);
    }
    pub fn pollAudio(self: *FakeSources, _: u64) ?[]const u8 {
        _ = self.audio_polls.fetchAdd(1, .acq_rel);
        return null;
    }
    pub fn audioStatus(self: *FakeSources, status: *Status) void {
        status.audio_capture_active = self.audio_active.load(.acquire);
    }
    pub fn setMediaActive(_: *FakeSources, _: bool, _: u64) void {}
    pub fn pollMedia(_: *FakeSources, _: u64) ?MediaFrame {
        return null;
    }
    pub fn mediaWaitMs(_: *FakeSources, _: u64) u64 {
        return media_max_wait_ms;
    }
    pub fn command(self: *FakeSources, value: media_commands.Command) Outcome {
        if (value.id == self.blocked_id) {
            self.blocked_started.store(true, .release);
            _ = win.WaitForSingleObject(self.gate, 5000);
        }
        _ = self.commands_run.fetchAdd(1, .acq_rel);
        return self.outcome;
    }
};

const TestService = ServiceType(FakeSources);

/// A subscriber that counts what it is told.
const Probe = struct {
    queues: protocol.Queues = .{},
    subscriber: Subscriber = undefined,
    frames: std.atomic.Value(u32) = .init(0),
    acks: std.atomic.Value(u32) = .init(0),
    failed: std.atomic.Value(u32) = .init(0),

    fn init(self: *Probe, wants: Wants, owner: Owner) void {
        self.subscriber = .{ .wants = wants, .owner = owner, .queues = &self.queues, .context = self, .store_ack = storeAck, .notify = notify };
    }

    fn storeAck(context: *anyopaque, id: u64, ok: bool) AckStore {
        const self: *Probe = @ptrCast(@alignCast(context));
        return storeQueuedAck(&self.queues, id, ok);
    }

    fn notify(context: *anyopaque, delivery: Delivery) void {
        const self: *Probe = @ptrCast(@alignCast(context));
        _ = switch (delivery) {
            .frame => self.frames.fetchAdd(1, .acq_rel),
            .ack => self.acks.fetchAdd(1, .acq_rel),
            .failed => self.failed.fetchAdd(1, .acq_rel),
        };
    }

    fn takeFrame(self: *Probe) ?[]const u8 {
        const buffer = struct {
            var bytes: [protocol.frame_line_capacity]u8 = undefined;
        };
        return self.queues.takeFrame(&buffer.bytes);
    }
};

fn waitFor(condition: anytype, comptime predicate: fn (@TypeOf(condition)) bool) !void {
    for (0..200) |_| {
        if (predicate(condition)) return;
        win.Sleep(5);
    }
    return error.TimedOut;
}

fn play(id: u64) media_commands.Command {
    return .{ .id = id, .verb = .play };
}

test "a provider runs only while something subscribes to it" {
    var service = TestService.init(.{});
    defer service.deinit();
    var clock: Probe = .{};
    clock.init(.{}, .{ .hosted = 0 });
    try service.subscribe(&clock.subscriber);
    // A widget that subscribes to nothing starts no provider.
    for (service.workers) |worker| try std.testing.expect(worker.thread == null);

    var meter: Probe = .{};
    meter.init(.{ .audio = true }, .{ .hosted = 1 });
    try service.subscribe(&meter.subscriber);
    try waitFor(&service.sources, struct {
        fn polled(sources: *FakeSources) bool {
            return sources.audio_polls.load(.acquire) > 2 and sources.audio_active.load(.acquire);
        }
    }.polled);

    service.unsubscribe(&meter.subscriber);
    try waitFor(&service.sources, struct {
        fn idle(sources: *FakeSources) bool {
            return !sources.audio_active.load(.acquire);
        }
    }.idle);
    // Idle: the worker waits and polls nothing.
    win.Sleep(20);
    const polls = service.sources.audio_polls.load(.acquire);
    win.Sleep(60);
    try std.testing.expectEqual(polls, service.sources.audio_polls.load(.acquire));
    try std.testing.expect(!service.snapshot().audio_capture_active);
    service.unsubscribe(&clock.subscriber);
}

test "frames reach only their subscribers, and wake none of them; acknowledgements do" {
    var service = TestService.init(.{});
    defer service.deinit();
    var cpu: Probe = .{};
    cpu.init(.{ .cpu = true }, .{ .hosted = 0 });
    var player: Probe = .{};
    player.init(.{ .media = true, .media_transport = true }, .{ .dev = 4 });
    try service.subscribe(&cpu.subscriber);
    try service.subscribe(&player.subscriber);

    const first: SystemFrames = .{ .cpu = "{\"provider\":\"cpu\"}\n", .cpu_changed = true, .memory = "{\"provider\":\"memory\"}\n", .memory_changed = true };
    service.publishSystem(first);
    try std.testing.expectEqualStrings("{\"provider\":\"cpu\"}", cpu.takeFrame().?);
    try std.testing.expect(cpu.takeFrame() == null);
    try std.testing.expect(player.takeFrame() == null);
    // Unchanged cpu is not sent again; a new subscriber gets it once.
    service.publishSystem(.{ .cpu = first.cpu, .cpu_changed = false, .memory = first.memory, .memory_changed = false });
    try std.testing.expect(cpu.takeFrame() == null);
    try std.testing.expectEqual(@as(u64, 1), service.snapshot().system_frames);
    try std.testing.expectEqual(@as(u64, 2), service.snapshot().system_sample_count);

    service.publishMedia(.{ .line = "{\"provider\":\"media\"}\n", .changed = true });
    service.publishMedia(.{ .line = "{\"provider\":\"media\"}\n", .changed = false });
    try std.testing.expectEqualStrings("{\"provider\":\"media\"}", player.takeFrame().?);
    try std.testing.expect(player.takeFrame() == null);
    try std.testing.expectEqual(@as(u64, 1), service.snapshot().media_frames);
    service.publishAudio("{\"provider\":\"audio\"}\n");
    try std.testing.expectEqual(@as(u64, 0), service.snapshot().audio_frames);

    try std.testing.expectEqual(@as(u32, 1), cpu.frames.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), cpu.acks.load(.acquire));
    try std.testing.expect(player.queues.registerAck(7));
    service.submitAt(&player.subscriber, play(7), 1000);
    try waitFor(&player, struct {
        fn acked(probe: *Probe) bool {
            return probe.acks.load(.acquire) == 1;
        }
    }.acked);
    try std.testing.expectEqualDeep(protocol.Ack{ .id = 7, .ok = true }, player.queues.takeAck().?);
    service.unsubscribe(&cpu.subscriber);
    service.unsubscribe(&player.subscriber);
}

test "commands need media-transport and stay within five a second" {
    var service = TestService.init(.{});
    defer service.deinit();
    var reader: Probe = .{};
    reader.init(.{ .media = true }, .{ .hosted = 2 });
    try service.subscribe(&reader.subscriber);
    try std.testing.expect(reader.queues.registerAck(1));
    service.submitAt(&reader.subscriber, play(1), 1000);
    // Refused at once, without reaching the media session.
    try std.testing.expectEqualDeep(protocol.Ack{ .id = 1, .ok = false }, reader.queues.takeAck().?);
    try std.testing.expectEqual(@as(u64, 0), service.sources.commands_run.load(.acquire));

    var player: Probe = .{};
    player.init(.{ .media_transport = true }, .{ .hosted = 3 });
    try service.subscribe(&player.subscriber);
    for (1..7) |id| {
        // The runtime keeps four pending; settle each before the next.
        try std.testing.expect(player.queues.registerAck(id));
        service.submitAt(&player.subscriber, play(id), 2000 + id);
        try waitFor(&player, struct {
            fn acked(probe: *Probe) bool {
                return probe.acks.load(.acquire) > 0;
            }
        }.acked);
        _ = player.acks.swap(0, .acq_rel);
        const ack = player.queues.takeAck().?;
        player.queues.unregisterAck(id);
        try std.testing.expectEqual(@as(u64, id), ack.id);
        // The sixth inside one second is rate limited.
        try std.testing.expectEqual(id <= media_commands.max_verbs_per_second, ack.ok);
    }
    try std.testing.expectEqual(@as(u64, media_commands.max_verbs_per_second), service.sources.commands_run.load(.acquire));
    // A second later it may command again.
    try std.testing.expect(player.queues.registerAck(8));
    service.submitAt(&player.subscriber, play(8), 3100);
    try waitFor(&player, struct {
        fn acked(probe: *Probe) bool {
            return probe.acks.load(.acquire) > 0;
        }
    }.acked);
    try std.testing.expectEqualDeep(protocol.Ack{ .id = 8, .ok = true }, player.queues.takeAck().?);
    service.unsubscribe(&reader.subscriber);
    service.unsubscribe(&player.subscriber);
}

test "one widget's slow command never delays another widget's" {
    const gate = win.CreateEventW(null, 1, 0, null) orelse return error.CreateEventFailed;
    defer _ = win.CloseHandle(gate);
    var service = TestService.init(.{ .blocked_id = 1000, .gate = gate });
    defer service.deinit();
    var slow: Probe = .{};
    slow.init(.{ .media_transport = true }, .{ .hosted = 0 });
    var quick: Probe = .{};
    quick.init(.{ .media_transport = true }, .{ .dev = 1 });
    try service.subscribe(&slow.subscriber);
    try service.subscribe(&quick.subscriber);
    try std.testing.expect(slow.queues.registerAck(1000));
    service.submitAt(&slow.subscriber, play(1000), 1000);
    try std.testing.expect(quick.queues.registerAck(2));
    service.submitAt(&quick.subscriber, play(2), 1000);
    try waitFor(&quick, struct {
        fn acked(probe: *Probe) bool {
            return probe.acks.load(.acquire) == 1;
        }
    }.acked);
    try std.testing.expectEqual(@as(u32, 0), slow.acks.load(.acquire));
    // The slow widget leaves mid-command: its answer is dropped, and its
    // thread is reaped once the command returns.
    try waitFor(&service.sources, struct {
        fn started(sources: *FakeSources) bool {
            return sources.blocked_started.load(.acquire);
        }
    }.started);
    service.unsubscribe(&slow.subscriber);
    _ = win.SetEvent(gate);
    try waitFor(&service, struct {
        fn reapable(value: *TestService) bool {
            for (value.lanes) |entry| if (entry) |lane| if (lane.done.load(.acquire)) return true;
            return false;
        }
    }.reapable);
    try std.testing.expectEqual(@as(u32, 0), slow.acks.load(.acquire));
    service.acquire();
    service.reapLanes();
    var live: usize = 0;
    for (service.lanes) |entry| live += @intFromBool(entry != null);
    service.release();
    try std.testing.expectEqual(@as(usize, 1), live);
    service.unsubscribe(&quick.subscriber);
}

test "an acknowledgement with no room fails the channel; one nobody waits for is dropped" {
    var service = TestService.init(.{});
    defer service.deinit();
    const Bounded = struct {
        probe: Probe = .{},
        answer: AckStore = .full,
        fn storeAck(context: *anyopaque, _: u64, _: bool) AckStore {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.answer;
        }
    };
    var bounded: Bounded = .{};
    bounded.probe.init(.{ .media = true }, .{ .dev = 3 });
    bounded.probe.subscriber.context = &bounded;
    bounded.probe.subscriber.store_ack = Bounded.storeAck;
    bounded.probe.subscriber.notify = struct {
        fn notify(context: *anyopaque, delivery: Delivery) void {
            const self: *Bounded = @ptrCast(@alignCast(context));
            Probe.notify(&self.probe, delivery);
        }
    }.notify;
    try service.subscribe(&bounded.probe.subscriber);
    bounded.answer = .unknown;
    service.submitAt(&bounded.probe.subscriber, play(1), 1000);
    try std.testing.expectEqual(@as(u32, 0), bounded.probe.failed.load(.acquire));
    bounded.answer = .full;
    service.submitAt(&bounded.probe.subscriber, play(2), 1000);
    try std.testing.expectEqual(@as(u32, 1), bounded.probe.failed.load(.acquire));
    try std.testing.expectEqual(Failures{ .dev = 1 << 3 }, service.takeFailures());
    service.unsubscribe(&bounded.probe.subscriber);
}

test "a declined command is acknowledged false" {
    var service = TestService.init(.{ .outcome = .declined });
    defer service.deinit();
    var player: Probe = .{};
    player.init(.{ .media_transport = true }, .{ .hosted = 0 });
    try service.subscribe(&player.subscriber);
    try std.testing.expect(player.queues.registerAck(5));
    service.submitAt(&player.subscriber, play(5), 1000);
    try waitFor(&player, struct {
        fn acked(probe: *Probe) bool {
            return probe.acks.load(.acquire) == 1;
        }
    }.acked);
    try std.testing.expectEqualDeep(protocol.Ack{ .id = 5, .ok = false }, player.queues.takeAck().?);
    service.unsubscribe(&player.subscriber);
}

test "a command the media session cannot carry fails the channel, for the daemon to restart" {
    var service = TestService.init(.{ .outcome = .channel_failure });
    defer service.deinit();
    var player: Probe = .{};
    player.init(.{ .media = true, .media_transport = true }, .{ .hosted = 6 });
    var other: Probe = .{};
    other.init(.{ .media = true }, .{ .dev = 6 });
    try service.subscribe(&player.subscriber);
    try service.subscribe(&other.subscriber);
    try std.testing.expect(player.queues.registerAck(1));
    service.submitAt(&player.subscriber, play(1), 1000);
    try waitFor(&player, struct {
        fn failed(probe: *Probe) bool {
            return probe.failed.load(.acquire) == 1;
        }
    }.failed);
    // No acknowledgement: the runtime settles its pending commands as
    // disconnected. Nothing more reaches it; the other widget is unharmed.
    try std.testing.expect(player.queues.takeAck() == null);
    service.publishMedia(.{ .line = "{\"provider\":\"media\"}", .changed = true });
    try std.testing.expect(player.takeFrame() == null);
    try std.testing.expect(other.takeFrame() != null);
    try std.testing.expect(player.queues.registerAck(2));
    service.submitAt(&player.subscriber, play(2), 1100);
    try std.testing.expectEqualDeep(protocol.Ack{ .id = 2, .ok = false }, player.queues.takeAck().?);

    try std.testing.expectEqual(Failures{ .hosted = 1 << 6 }, service.takeFailures());
    try std.testing.expectEqual(Failures{}, service.takeFailures());
    // A failure of a widget that has since gone is not reported.
    service.fail(&other.subscriber);
    service.unsubscribe(&other.subscriber);
    try std.testing.expectEqual(Failures{}, service.takeFailures());
    service.unsubscribe(&player.subscriber);
}

test "subscriptions past max_subscribers are refused by name" {
    var service = TestService.init(.{});
    defer service.deinit();
    const probes = try std.testing.allocator.alloc(Probe, max_subscribers + 1);
    defer std.testing.allocator.free(probes);
    for (probes, 0..) |*probe, index| {
        probe.* = .{};
        probe.init(.{ .cpu = index == 0 }, .{ .hosted = @intCast(index % 31) });
    }
    for (probes[0..max_subscribers]) |*probe| try service.subscribe(&probe.subscriber);
    try std.testing.expectError(error.ProviderSubscribersFull, service.subscribe(&probes[max_subscribers].subscriber));
    for (probes[0..max_subscribers]) |*probe| service.unsubscribe(&probe.subscriber);
}

test "manifest declarations name what a widget wants" {
    const wants = Wants.fromManifest(&.{ "time", "cpu", "media" }, &.{"media-transport"});
    try std.testing.expectEqual(Wants{ .cpu = true, .media = true, .media_transport = true }, wants);
    try std.testing.expect(!Wants.fromManifest(&.{"time"}, &.{}).any());
    try std.testing.expect(Wants.fromManifest(&.{}, &.{"media-transport"}).any());
}

test {
    _ = host_providers;
}
