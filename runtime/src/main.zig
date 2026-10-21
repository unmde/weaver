const std = @import("std");
const builtin = @import("builtin");
const weaver_build_options = @import("weaver_build_options");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const geometry_mod = @import("geometry.zig");
const gradient_mod = @import("gradients.zig");
const dev_reload = @import("dev_reload.zig");
const image_paths = @import("image_paths.zig");
const js_engine = @import("js_engine.zig");
const host_control = @import("host_control.zig");
const manifest_mod = @import("manifest.zig");
const provider_mod = @import("provider.zig");
const platform = @import("platform/root.zig");
const storage_mod = @import("storage.zig");
const windows_monitor = if (builtin.os.tag == .windows) @import("platform/windows_monitor.zig") else struct {};
const tree_mod = @import("tree.zig");
const widget_diagnostic = @import("widget_diagnostic.zig");
const capture_warnings = @import("capture_warnings.zig");
const widget_log = @import("widget_log.zig");
const crash_record = @import("crash_record.zig");

/// Small objects that live as long as a widget: its engine, the arena its
/// manifest, paths and stores live in, and the image resolver's paths. The C
/// heap packs them; `page_allocator` rounds each to whole 4 KiB pages.
const small_allocator = std.heap.c_allocator;
const small_fs = @import("small_fs.zig");
const provider_service = if (builtin.os.tag == .windows) @import("provider_service.zig") else struct {};
const dev_widgets_mod = if (builtin.os.tag == .windows) @import("dev_widgets.zig") else struct {};
const daemon_mod = if (builtin.os.tag == .windows) @import("daemon.zig") else struct {};
const host_lifecycle = if (builtin.os.tag == .windows) @import("host_lifecycle.zig") else struct {};
const host_contract = @import("host_contract");

comptime {
    if (native_sdk.platform.max_windows != max_host_widgets or
        native_sdk.platform.max_views != max_host_widgets or
        native_sdk.platform.max_webviews != 1 or
        native_sdk.runtime.max_canvas_commands_per_view != 2048 or
        native_sdk.runtime.max_canvas_path_elements_per_view != 2048 or
        native_sdk.runtime.max_canvas_widget_nodes_per_view != 1024)
    {
        @compileError("Weaver runtime must be built with the Native SDK widget profile");
    }
}

/// Widgets one runtime process hosts: one Native window and canvas each.
/// Matches the daemon's registry (host/src/supervisor.zig max_widgets), so
/// every registered widget fits one host. Pinned by runtime/build.zig's
/// widget-windows.
pub const max_host_widgets: usize = 32;

pub const panic = std.debug.FullPanic(recordPanic);

/// A panic is recorded as a crash (`crash_record`) before Native's
/// diagnostics run, since they may fail in turn. A daemon host then fails
/// fast, so Windows restarts it: Native's capture ends in Zig's abort, an
/// ordinary exit Windows never restarts.
fn recordPanic(msg: []const u8, ra: ?usize) noreturn {
    crash_record.notePanic();
    if (builtin.os.tag == .windows and crash_record.failsFast()) {
        crash_record.writePanicNote(msg, ra);
        crash_record.failFast(crash_record.panic_code);
    }
    native_sdk.debug.capturePanic(msg, ra);
}

/// Zig's segfault handler (on in Debug and ReleaseSafe builds) catches a
/// fault before the crash record's unhandled-exception filter and ends in
/// Zig's abort. In a daemon host the fault is recorded and fails fast
/// instead, as in ReleaseFast, where Zig installs no handler.
pub const debug = struct {
    pub fn handleSegfault(addr: ?usize, name: []const u8, context: ?std.debug.CpuContextPtr) noreturn {
        if (builtin.os.tag == .windows and crash_record.failsFast()) {
            const access_violation: u32 = 0xC000_0005;
            crash_record.noteCrash(access_violation);
            crash_record.failFast(access_violation);
        }
        std.debug.defaultHandleSegfault(addr, name, context);
    }
};
pub const std_options: std.Options = .{ .logFn = widget_log.logFn };

pub const Model = struct {
    tree: tree_mod.Tree = .{},
    /// Everything this widget allocates for its life, freed when it unloads.
    arena: ?std.heap.ArenaAllocator = null,
    engine: ?*js_engine.Engine = null,
    provider: provider_mod.Client = .{},
    io: ?std.Io = null,
    storage: ?*storage_mod.Store = null,
    origins: []const []const u8 = &.{},
    bundle_path: []const u8 = &.{},
    /// Where the bundle is, and the SDK runtime `weaver bundle` left out
    /// beside it (bridge.zig).
    bundle_directory: ?[]const u8 = null,
    dev_seen_mtime: i128 = 0,
    timer_fires: u64 = 0,
    armed_timers: [bridgeTimerCapacity()]ArmedTimer = [_]ArmedTimer{.{}} ** bridgeTimerCapacity(),
    fetch_poll_armed: bool = false,
    provider_poll_armed: bool = false,
    provider_poll_interval_ms: u64 = 1000,
    has_provider_subscriptions: bool = false,
    media_deadline_ms: u64 = 0,
    provider_frames: u64 = 0,
    provider_batch_logged: bool = false,
    provider_dispatch_failures: u64 = 0,
    slider_values: [tree_mod.max_nodes]f32 = @splat(0),
    images: [max_images]ImageAsset = [_]ImageAsset{.{}} ** max_images,
    image_count: usize = 0,
    image_states: [max_images]ImageState = [_]ImageState{.{}} ** max_images,
    image_state_count: usize = 0,
    image_tree_generation: u64 = 0,
    image_epoch: u64 = 1,
    image_resolver: ?*const image_paths.Resolver = null,
    media_transport_enabled: bool = false,
    geometry: ?*const geometry_mod.Store = null,
    fonts: []const manifest_mod.Font = &.{},
    /// Last placement we consider settled (launch placement or the last
    /// persisted drag or resize): the origin in the platform's logical
    /// window space and the content zoom. Null until the first platform
    /// frame report names the launch placement.
    settled_frame: ?geometry_mod.Saved = null,
    pending_frame: ?geometry_mod.Saved = null,
    /// This widget's place in the host: its window and canvas labels, the
    /// `HostMsg.widget` of its messages, and the namespace of its Native
    /// timer keys, image ids, and font ids.
    slot: u16 = 0,
    window: WindowSpec = .{},
    /// Where `publishBackendStatus` tells the daemon this widget's renderer.
    backend_status_path: ?[]const u8 = null,
    /// This widget's declared fonts, in `fonts` order, under the ids their
    /// contents were registered with (`assignFontIds`).
    font_registrations: []HostApp.FontRegistration = &.{},
    /// This widget's log; a Model that never loaded a widget (tests) logs
    /// nowhere.
    log: *widget_log.Sink = &unopened_log,
    rendered_presents: u64 = 0,
    first_render_ns: u64 = 0,
    logged_backend: bool = false,
    logged_present_path: bool = false,
    last_backend: native_sdk.platform.GpuSurfaceBackend = .none,
    projection_failure_latched: bool = false,
    /// The current view was refused by `depthLimitPanel`; capture fails on
    /// it like a render exception so the receipt names the problem.
    depth_limit_exceeded: bool = false,
    /// Its own latch, so another projection failure cannot swallow the report.
    depth_limit_reported: bool = false,
};

var unopened_log: widget_log.Sink = .{};

/// A widget resizes by its edges and corners, and the resize scales it:
/// the content keeps the manifest `size` as its logical size and renders
/// at the device scale times the user's zoom (ADR 0023). Windows only for
/// now — the macOS host has no content zoom yet, and a plain AppKit
/// resize would reflow fixed-size widget layouts instead of scaling them.
const resize_scales_widgets = builtin.os.tag == .windows;

/// Where a widget's window opens and how it behaves, from its manifest and
/// any persisted drag or resize.
const WindowSpec = struct {
    name: []const u8 = "",
    frame: native_sdk.geometry.RectF = native_sdk.geometry.RectF.init(0, 0, 1, 1),
    layer: NativeWindowLayers = .{ .shell = .normal, .startup = .normal },
    click_through: bool = false,
    backend: native_sdk.app_manifest.GpuSurfaceBackend = .software,
    /// A persisted drag placed the window, not the manifest anchor.
    dragged: bool = false,
    /// The persisted user resize: `frame` stays the manifest `size` (the
    /// content's logical size) and the window opens this much larger.
    zoom: f32 = 1,
    primary_display_anchor: ?native_sdk.PrimaryDisplayAnchor = null,
};

/// Slot 0 renders in the scene's main window and the others are declared
/// windows, except in an anchored host, whose main window is a hidden one
/// of its own and every widget is a declared window: then any widget, the
/// first included, can come and go without the process (`anchored_host`).
/// Labels are fixed per slot so a slot's identity survives rebuilds and
/// automation can address it. A widget that replaces another in its slot
/// opens under the same labels: Native recycles a closed window's record
/// when its label opens again.
const main_window_label = "main";
const main_canvas_label = "widget-canvas";
const slot_window_labels = slotLabels("widget-");
const slot_canvas_labels = slotLabels("widget-canvas-");

fn slotLabels(comptime prefix: []const u8) [max_host_widgets][]const u8 {
    @setEvalBranchQuota(100_000);
    var labels: [max_host_widgets][]const u8 = undefined;
    for (&labels, 0..) |*label, slot| label.* = std.fmt.comptimePrint("{s}{d}", .{ prefix, slot });
    return labels;
}

/// The daemon host on Windows (`weaver-widget --host` with no directories,
/// ADR 0022): its main window is a hidden anchor that owns the app, and
/// every widget is a declared window. Dev, capture and other platforms keep
/// slot 0 in the main window. Set once, before the app starts.
var anchored_host = false;

/// The daemon's management thread (daemon.zig) and the loads and unloads
/// it posts, waiting for the UI thread (`applyControl`).
var daemon: if (builtin.os.tag == .windows) ?*daemon_mod.Daemon else ?*anyopaque = null;
var control_mailbox: host_control.Mailbox = .{};
/// What a widget the daemon adds loads with.
var control_environment: ?HostEnvironment = null;
/// The anchored host's own providers: every widget it runs subscribes to
/// them in process, and its dev widgets through their pipes. Windows only.
var host_providers: if (builtin.os.tag == .windows) ?*provider_service.Service else ?*anyopaque = null;

/// The first slot that renders in a declared window.
fn firstDeclaredSlot() u16 {
    return if (anchored_host) 0 else 1;
}

/// The slots an anchored host can fill: Native's window budget
/// (`platform.max_windows`, equal to `max_host_widgets`) less the anchor.
const max_anchored_widgets: usize = max_host_widgets - 1;

comptime {
    // The daemon hands out the slots, and the record names each one.
    if (builtin.os.tag == .windows and daemon_mod.max_hosted_widgets != max_anchored_widgets) {
        @compileError("daemon.max_hosted_widgets must be max_anchored_widgets");
    }
    if (host_contract.record_slots != max_host_widgets) @compileError("host_contract.record_slots must be max_host_widgets");
}

fn windowLabel(slot: u16) []const u8 {
    return if (slot < firstDeclaredSlot()) main_window_label else slot_window_labels[slot];
}

fn canvasLabel(slot: u16) []const u8 {
    return if (slot < firstDeclaredSlot()) main_canvas_label else slot_canvas_labels[slot];
}

fn slotForWindowLabel(label: []const u8) ?u16 {
    if (std.mem.eql(u8, label, main_window_label)) return if (anchored_host) null else 0;
    for (slot_window_labels[firstDeclaredSlot()..], firstDeclaredSlot()..) |candidate, slot| {
        if (std.mem.eql(u8, candidate, label)) return @intCast(slot);
    }
    return null;
}

fn slotForCanvasLabel(label: []const u8) ?u16 {
    if (std.mem.eql(u8, label, main_canvas_label)) return if (anchored_host) null else 0;
    for (slot_canvas_labels[firstDeclaredSlot()..], firstDeclaredSlot()..) |candidate, slot| {
        if (std.mem.eql(u8, candidate, label)) return @intCast(slot);
    }
    return null;
}

const ArmedTimer = struct { id: u64 = 0, interval_ms: u64 = 0 };
fn bridgeTimerCapacity() usize {
    return @import("bridge.zig").max_timers;
}
// Image receipt (2026-07-30): executing every shipped example measured six
// retained images at worst (noro-shell). Sixteen leaves 2.7x slot headroom and
// matches the Native SDK registry's per-window share, so every hosted widget
// can fill its sixteen. Native allocates pixels as images register.
const max_images: usize = 16;

comptime {
    // A heap range per hosted widget, plus one for a dev hot swap's candidate.
    if (js_engine.max_engines != max_host_widgets + 1) {
        @compileError("js_engine.max_engines must be max_host_widgets + 1");
    }
    if (native_sdk.max_registered_canvas_images < max_images * max_host_widgets) {
        @compileError("the Native image registry must hold max_images for every hosted widget");
    }
}
// Alias the Native SDK's receipted 512x512 RGBA registry bound so decoding,
// upload, and CLI validation cannot acquire independent pixel budgets.
const max_image_rgba_bytes: usize = native_sdk.max_registered_canvas_image_pixel_bytes;
// The historical generated grille measured 1,025,239 encoded bytes after it
// was squeezed under the old 1 MiB cap. 2 MiB leaves 1,071,913 bytes headroom;
// reads allocate actual file length, so unused allowance costs no memory.
// Pinned by cli/src/index.ts maxImageStreamBytes.
const max_image_stream_bytes: usize = 2 * 1024 * 1024;
// One initial decode plus two retries absorbs an atomic-save race without an
// unbounded retry loop. Attempts retain no additional payload memory.
const max_image_load_attempts: u8 = 3;
const fetch_poll_key: u64 = 0x7766_6574_6368;
const provider_poll_key: u64 = 0x7770_726f_7669;
const media_deadline_key: u64 = 0x776d_6465_6164;
const geometry_save_key: u64 = 0x7767_656f_6d65;
const ImageAsset = struct { id: u64 = 0, bytes: []const u8 = &.{} };
const ImageState = struct {
    id: tree_mod.NodeId = 0,
    lifetime: u64 = 0,
    epoch: u64 = 0,
    observed: ?[:0]u8 = null,
    observed_valid: bool = false,
    load_failure_count: u8 = 0,
    registered: bool = false,
    failure: ?anyerror = null,
    failure_label: [160]u8 = @splat(0),
    failure_label_len: usize = 0,
};

const CaptureProviderFixture = struct {
    schema: []const u8,
    frames: []const std.json.Value,
    commands: []const provider_mod.CaptureMediaCommand = &.{},
};

pub const Msg = union(enum) {
    timer: native_sdk.EffectTimer,
    press: native_sdk.canvas.WidgetPressEvent,
    double_press: native_sdk.canvas.WidgetPressEvent,
    right_press: native_sdk.canvas.WidgetPressEvent,
    slider: tree_mod.NodeId,
    canvas_frame: u64,
    /// A presented frame laid a canvas out at a size the SDK has not been
    /// told yet. The dispatch itself carries the fix: `syncNativeState` runs
    /// before `update` and fires `onCanvasResize`.
    canvas_layout: void,
    external_wake: struct { provider: bool, dev_reload: bool },
    frame_moved: geometry_mod.Saved,
};

/// One widget's Msg, addressed to it. Every widget in the process shares
/// one Native app, so each message names the widget slot it belongs to.
pub const HostMsg = struct {
    widget: u16,
    msg: Msg,
};

/// `HostMsg.widget` for the external-wake Msg: every widget checks its own
/// pending provider and dev-reload wakes.
const every_widget: u16 = std.math.maxInt(u16);

/// Every widget this process runs, by slot. In an anchored host slots fill
/// and empty as the daemon adds and removes widgets.
pub const Host = struct {
    widgets: [max_host_widgets]?*Model = @splat(null),
};

const HostApp = native_sdk.UiAppWithFeatures(Host, HostMsg, .{ .runtime_markup = false });
const WidgetUi = HostApp.Ui;
const Effects = HostApp.Effects;

/// One widget's handle on the shared effects channel. Native timer keys and
/// image ids are runtime-wide, so a widget's own keys and ids carry its
/// slot in the bits above `slot_shift`; its timers fire back as Msgs
/// addressed to it.
const WidgetEffects = struct {
    fx: *Effects,
    slot: u16,

    fn startTimer(self: WidgetEffects, key: u64, interval_ms: u64, mode: native_sdk.TimerMode) void {
        self.fx.startTimer(.{ .key = slotted(self.slot, key), .interval_ms = @min(interval_ms, max_timer_interval_ms), .mode = mode, .on_fire = hostTimerMsg });
    }

    fn cancelTimer(self: WidgetEffects, key: u64) void {
        self.fx.cancelTimer(slotted(self.slot, key));
    }

    fn registerImageBytes(self: WidgetEffects, id: u64, bytes: []const u8) !void {
        _ = try self.fx.registerImageBytes(slotted(self.slot, id), bytes);
    }

    fn unregisterImage(self: WidgetEffects, id: u64) bool {
        return self.fx.unregisterImage(slotted(self.slot, id));
    }
};

/// Longest timer interval a widget can arm: 2^31 - 1 ms (24.8 days), the
/// ceiling browsers give setTimeout/setInterval. Longer authored intervals
/// fire at the ceiling instead of overflowing Native's nanosecond deadline.
const max_timer_interval_ms: u64 = std.math.maxInt(i32);

/// Widget-local timer keys (JS timer ids, the fixed poll keys) and image
/// node ids all sit below this bit.
const slot_shift: u6 = 56;

fn slotted(slot: u16, local: u64) u64 {
    std.debug.assert(local < (@as(u64, 1) << slot_shift));
    return (@as(u64, slot) << slot_shift) | local;
}

fn hostTimerMsg(timer: native_sdk.EffectTimer) HostMsg {
    var local = timer;
    local.key = timer.key & ((@as(u64, 1) << slot_shift) - 1);
    return .{ .widget = @intCast(timer.key >> slot_shift), .msg = .{ .timer = local } };
}

var diagnostic_runtime: ?*native_sdk.Runtime = null;
var wake_runtime = std.atomic.Value(usize).init(0);
/// Set off the loop thread by each widget's provider and dev-reload
/// listeners; drained by the `every_widget` wake Msg.
var dev_reload_pending: [max_host_widgets]std.atomic.Value(bool) = @splat(.init(false));
var provider_wake_pending: [max_host_widgets]std.atomic.Value(bool) = @splat(.init(false));
var backend_status_io: ?std.Io = null;
/// Set by a failed projection during the view build in progress.
var projection_failed_this_view: bool = false;

fn initEffects(model: *Model, effects: WidgetEffects) void {
    for (model.images[0..model.image_count]) |image| {
        _ = effects.registerImageBytes(image.id, image.bytes) catch |err| {
            if (findImageState(model, @intCast(image.id))) |state| {
                recordImageFailure(state, err, image.bytes, "initial image decode/register");
            } else {
                std.log.err("initial image decode/register failed: image={d}, cause={s}", .{ image.id, @errorName(err) });
            }
            continue;
        };
        if (findImageState(model, @intCast(image.id))) |state| {
            state.registered = true;
            clearImageFailure(state);
        }
    }
    syncTimers(model, effects);
}

/// One SDK timer delivery is one JS batch. All retained-tree ops complete
/// before update returns, after which UiApp derives and presents once.
fn update(model: *Model, msg: Msg, effects: WidgetEffects) void {
    // A per-launch provider endpoint has no reconnection protocol. A runtime-
    // detected macOS command write failure is therefore process-fatal: exit
    // after the current JS/native batch and let host crash supervision create
    // a replacement PID with a fresh authenticated endpoint.
    defer exitOnFatalProviderChannel(model);
    defer synchronizeImages(model, effects) catch |err| {
        std.log.err("widget image synchronization failed: {s}", .{@errorName(err)});
    };
    switch (msg) {
        .timer => |timer| {
            if (timer.outcome != .fired) {
                std.log.err("widget timer was rejected", .{});
                return;
            }
            if (timer.key == geometry_save_key) {
                persistGeometry(model);
                return;
            }
            if (timer.key == fetch_poll_key) {
                (model.engine orelse return).drainFetches() catch |err| {
                    std.log.err("widget fetch completion failed: {s}", .{@errorName(err)});
                };
                syncTimers(model, effects);
                return;
            }
            if (timer.key == provider_poll_key) {
                dispatchProviderFrames(model, effects, "provider poll");
                syncTimers(model, effects);
                return;
            }
            if (timer.key == media_deadline_key) {
                model.media_deadline_ms = 0;
                dispatchProviderFrames(model, effects, "media deadline");
                syncTimers(model, effects);
                return;
            }
            if (model.provider_poll_interval_ms <= 33) {
                dispatchProviderFrames(model, effects, "timer");
            }
            const before = model.tree.generation;
            (model.engine orelse return).fireTimer(timer.key, timer.timestamp_ns) catch |err| {
                std.log.err("widget timer callback failed: {s}", .{@errorName(err)});
                return;
            };
            syncTimers(model, effects);
            model.timer_fires += 1;
            if (model.timer_fires % 300 == 0) {
                std.log.info("widget timer: {d} callbacks, generation {d}, changed={}", .{ model.timer_fires, model.tree.generation, before != model.tree.generation });
            }
        },
        .press => |event| dispatchPressEvent(model, effects, "press", event),
        .double_press => |event| dispatchPressEvent(model, effects, "doublepress", event),
        .right_press => |event| dispatchPressEvent(model, effects, "rightpress", event),
        .slider => |id| {
            const value = model.slider_values[id - 1];
            (model.engine orelse return).fireEvent(id, "change", .{ .number = value }) catch |err| {
                std.log.err("widget slider callback failed: {s}", .{@errorName(err)});
            };
            syncTimers(model, effects);
        },
        .frame_moved => |moved| {
            const known = model.settled_frame orelse {
                // The first platform report names the launch placement
                // (creation/focus echo). The anchor — or the restored
                // placement — stays authoritative until the user actually
                // moves or resizes the window.
                model.settled_frame = moved;
                return;
            };
            if (!placementChanged(known, moved)) return;
            model.settled_frame = moved;
            model.pending_frame = moved;
            // OS drags and resizes report continuously. Re-starting the same key
            // REPLACES the pending one-shot, so the disk write lands
            // once, after the gesture settles.
            effects.startTimer(geometry_save_key, 400, .one_shot);
        },
        .canvas_layout => {},
        .canvas_frame => |timestamp_ns| {
            if (model.provider_poll_interval_ms <= 33) {
                dispatchProviderFrames(model, effects, "canvas frame");
            }
            (model.engine orelse return).fireCanvasFrames(timestamp_ns) catch |err| {
                std.log.err("widget canvas frame callback failed: {s}", .{@errorName(err)});
            };
            syncTimers(model, effects);
        },
        .external_wake => |wake| {
            if (wake.provider) {
                dispatchProviderFrames(model, effects, "provider wake");
            }
            if (wake.dev_reload) {
                reloadIfChanged(model, effects) catch |err| {
                    std.log.err("dev hot swap failed; keeping previous bundle: {s}", .{@errorName(err)});
                };
            }
            syncTimers(model, effects);
        },
    }
}

fn exitOnFatalProviderChannel(model: *const Model) void {
    if (!model.provider.fatalChannelFailure()) return;
    std.log.err("fatal provider command channel failure; exiting for supervised restart", .{});
    std.process.exit(1);
}

fn dispatchPressEvent(model: *Model, effects: WidgetEffects, kind: []const u8, event: native_sdk.canvas.WidgetPressEvent) void {
    const id = retainedPressNodeId(&model.tree, event.target_id) orelse {
        std.log.warn("widget {s} target {d} has no retained node", .{ kind, event.target_id });
        return;
    };
    (model.engine orelse return).fireEvent(id, kind, .{ .press = .{
        .x = event.x,
        .y = event.y,
        .width = event.width,
        .height = event.height,
    } }) catch |err| {
        std.log.err("widget {s} callback failed: {s}", .{ kind, @errorName(err) });
    };
    syncTimers(model, effects);
}

fn retainedPressNodeId(tree: *const tree_mod.Tree, target_id: native_sdk.canvas.ObjectId) ?tree_mod.NodeId {
    var id: tree_mod.NodeId = 1;
    while (id <= tree_mod.max_nodes) : (id += 1) {
        const node = tree.nodeConst(id) catch continue;
        const kind: native_sdk.canvas.WidgetKind = switch (node.kind) {
            .button => .panel,
            .slider => .slider,
            else => continue,
        };
        if (native_sdk.canvas.globalWidgetId(kind, native_sdk.canvas.uiKey(id)) == target_id) return id;
    }
    return null;
}

test "interaction projection retains exact channels and press identity" {
    const background = native_sdk.canvas.Color.rgba8(10, 20, 30, 255);
    const border = native_sdk.canvas.Color.rgba8(40, 50, 60, 255);
    const projected = nativeInteractionStyle(.{ .background = background, .opacity = 0.65, .border_color = border }).?;
    try std.testing.expectEqualDeep(background, projected.background.?);
    try std.testing.expectEqual(@as(f32, 0.65), projected.opacity.?);
    try std.testing.expectEqualDeep(border, projected.border.?);

    var tree: tree_mod.Tree = .{};
    const id = try tree.createNode(.button);
    const target_id = native_sdk.canvas.globalWidgetId(.panel, native_sdk.canvas.uiKey(id));
    try std.testing.expectEqual(id, retainedPressNodeId(&tree, target_id).?);

    const slider_id = try tree.createNode(.slider);
    const slider_target_id = native_sdk.canvas.globalWidgetId(.slider, native_sdk.canvas.uiKey(slider_id));
    try std.testing.expectEqual(slider_id, retainedPressNodeId(&tree, slider_target_id).?);
}

/// A dragged position or resized zoom is user state, not widget source
/// (ADR 0004/0011/0023): it lands in its own per-widget geometry record,
/// never in the installed manifest and never in the widget's JS-visible
/// storage doc.
fn persistGeometry(model: *Model) void {
    const pending = model.pending_frame orelse return;
    model.pending_frame = null;
    const store = model.geometry orelse return;
    store.save(pending) catch |err| {
        std.log.warn("widget could not persist its placement: {s}; path={s}", .{ @errorName(err), store.path });
        return;
    };
    std.log.info("widget placement persisted x={d} y={d} zoom={d}; path={s}", .{ pending.x, pending.y, pending.zoom, store.path });
}

/// Half a logical pixel of origin or a thousandth of zoom: below that a
/// report is the same placement (focus echoes, rounding), not a gesture.
fn placementChanged(known: geometry_mod.Saved, moved: geometry_mod.Saved) bool {
    const same_origin = @abs(known.x - moved.x) < 0.5 and @abs(known.y - moved.y) < 0.5;
    return !same_origin or @abs(known.zoom - moved.zoom) >= 0.001;
}

test "placement changes on a move or a resize, not on an echo" {
    const settled: geometry_mod.Saved = .{ .x = 100, .y = 200, .scale = 1.5, .zoom = 1 };
    try std.testing.expect(!placementChanged(settled, settled));
    try std.testing.expect(!placementChanged(settled, .{ .x = 100.3, .y = 199.8, .scale = 1.5, .zoom = 1.0004 }));
    try std.testing.expect(placementChanged(settled, .{ .x = 160, .y = 200, .scale = 1.5, .zoom = 1 }));
    try std.testing.expect(placementChanged(settled, .{ .x = 100, .y = 200, .scale = 1.5, .zoom = 1.5 }));
}

test "a window frame report becomes origin, device scale, and zoom" {
    const zoomed = onWindowFrame(.{ .frame = native_sdk.geometry.RectF.init(640, 120, 300, 290), .scale_factor = 2.25, .content_zoom = 1.5 }).frame_moved;
    try std.testing.expectEqual(@as(f32, 640), zoomed.x);
    try std.testing.expectEqual(@as(f32, 120), zoomed.y);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), zoomed.scale, 0.0001);
    try std.testing.expectEqual(@as(f32, 1.5), zoomed.zoom);
    // A host that reports no zoom (0, or a window that never scales) is zoom 1.
    const plain = onWindowFrame(.{ .frame = native_sdk.geometry.RectF.init(0, 0, 300, 290), .scale_factor = 1.25, .content_zoom = 0 }).frame_moved;
    try std.testing.expectEqual(@as(f32, 1), plain.zoom);
    try std.testing.expectEqual(@as(f32, 1.25), plain.scale);
}

/// A content-scaling window's reported scale carries the user zoom; the
/// record keeps the plain device scale beside the zoom.
fn onWindowFrame(event: native_sdk.runtime.WindowFrameEvent) Msg {
    const zoom = if (std.math.isFinite(event.content_zoom) and event.content_zoom > 0) event.content_zoom else 1;
    return Msg{ .frame_moved = .{
        .x = event.frame.x,
        .y = event.frame.y,
        .scale = event.scale_factor / zoom,
        .zoom = zoom,
    } };
}

fn drainProviderFrames(model: *Model, _: WidgetEffects) !void {
    const count = try (model.engine orelse return).drainProviders();
    if (count == 0) return;
    model.provider_frames += count;
    const first_drain = model.provider_frames == count;
    const first_multi_frame_batch = count > 1 and !model.provider_batch_logged;
    if (first_drain or first_multi_frame_batch) {
        std.log.info("widget provider frames applied count={d}", .{count});
    }
    if (count > 1) model.provider_batch_logged = true;
}

fn dispatchProviderFrames(model: *Model, effects: WidgetEffects, trigger: []const u8) void {
    drainProviderFrames(model, effects) catch |err| {
        model.provider_dispatch_failures += 1;
        if (model.provider_dispatch_failures == 1) {
            std.log.err(
                "widget provider dispatch degraded during {s}: {s}; repeated failures are suppressed until recovery",
                .{ trigger, @errorName(err) },
            );
        }
        return;
    };
    if (model.provider_dispatch_failures != 0) {
        std.log.info("widget provider dispatch recovered after {d} consecutive failures", .{model.provider_dispatch_failures});
        model.provider_dispatch_failures = 0;
    }
}

fn reloadIfChanged(model: *Model, effects: WidgetEffects) !void {
    const io = model.io orelse return;
    const stat = try std.Io.Dir.cwd().statFile(io, model.bundle_path, .{});
    const mtime = stat.mtime.nanoseconds;
    if (mtime == model.dev_seen_mtime) return;

    const source = try std.Io.Dir.cwd().readFileAlloc(io, model.bundle_path, std.heap.page_allocator, .limited(manifest_mod.max_bundle_bytes));
    defer std.heap.page_allocator.free(source);
    const old_engine = model.engine orelse return error.MissingEngine;
    const snapshot = old_engine.captureHotSwap(std.heap.page_allocator);
    defer if (snapshot) |bytes| std.heap.page_allocator.free(bytes);

    // @sizeOf(Tree) measured 4,334,144 bytes after the receipted node-cap
    // raise. Keeping the
    // candidate on the heap prevents ReleaseFast from folding it into the
    // update callback's stack frame, where it would consume most of
    // QuickJS's recorded C-stack allowance.
    const candidate_tree = try native_sdk.lazy_commit.create(tree_mod.Tree);
    tree_mod.resetEmpty(candidate_tree, std.heap.page_allocator);
    var candidate_tree_moved = false;
    defer {
        if (!candidate_tree_moved) candidate_tree.deinit();
        native_sdk.lazy_commit.destroy(candidate_tree);
    }
    var preserved = snapshot != null;
    const candidate = evaluateCandidate(model, candidate_tree, source, snapshot) catch |err| switch (err) {
        error.HotSwapMismatch => block: {
            preserved = false;
            candidate_tree.deinit();
            tree_mod.resetEmpty(candidate_tree, std.heap.page_allocator);
            break :block try evaluateCandidate(model, candidate_tree, source, null);
        },
        else => return err,
    };
    candidate_tree.generation = model.tree.generation +% 1;
    model.image_epoch +%= 1;
    if (model.image_epoch == 0) model.image_epoch = 1;
    model.tree.deinit();
    model.tree.moveFrom(candidate_tree);
    candidate_tree_moved = true;
    candidate.setTree(&model.tree);
    model.engine = candidate;
    old_engine.destroy(small_allocator);
    model.dev_seen_mtime = mtime;
    syncTimers(model, effects);
    std.log.info("dev hot swap applied ({s} root hook state)", .{if (preserved) "preserved" else "fresh"});
}

fn evaluateCandidate(model: *Model, tree: *tree_mod.Tree, source: []const u8, seed: ?[]const u8) !*js_engine.Engine {
    const storage = model.storage orelse return error.MissingStorage;
    const candidate = try js_engine.Engine.create(
        small_allocator,
        tree,
        storage,
        model.origins,
        &model.provider,
        model.media_transport_enabled,
        false,
    );
    errdefer candidate.destroy(small_allocator);
    candidate.bridge_state.bundle_directory = model.bundle_directory;
    if (seed) |value| try candidate.setHotSwapSeed(value);
    try candidate.evaluate(source, "bundle.js");
    if (candidate.renderFailed()) return error.CandidateFirstRenderFailed;
    if (tree.root == null) return error.CandidateDidNotRenderRoot;
    if (seed != null and !candidate.hotSwapAccepted()) return error.HotSwapMismatch;
    return candidate;
}

fn syncTimers(model: *Model, effects: WidgetEffects) void {
    const engine = model.engine orelse return;
    for (&model.armed_timers) |*armed| {
        if (armed.id == 0) continue;
        var live = false;
        for (engine.timers()) |timer| {
            if (timer.active and timer.id == armed.id) {
                live = true;
                break;
            }
        }
        if (!live) {
            effects.cancelTimer(armed.id);
            armed.* = .{};
        }
    }
    for (engine.timers()) |timer| {
        if (!timer.active) continue;
        var slot: ?*ArmedTimer = null;
        for (&model.armed_timers) |*armed| {
            if (armed.id == timer.id) {
                slot = armed;
                break;
            }
            if (slot == null and armed.id == 0) slot = armed;
        }
        const armed = slot orelse continue;
        if (armed.id == timer.id and armed.interval_ms == timer.interval_ms) continue;
        effects.startTimer(timer.id, timer.interval_ms, .repeating);
        armed.* = .{ .id = timer.id, .interval_ms = timer.interval_ms };
    }
    if (engine.hasActiveFetches() and !model.fetch_poll_armed) {
        effects.startTimer(fetch_poll_key, 25, .repeating);
        model.fetch_poll_armed = true;
    } else if (!engine.hasActiveFetches() and model.fetch_poll_armed) {
        effects.cancelTimer(fetch_poll_key);
        model.fetch_poll_armed = false;
    }
    var has_fast_clock = engine.hasCanvasFrames();
    if (!has_fast_clock) for (engine.timers()) |timer| {
        if (timer.active and timer.interval_ms <= 40) {
            has_fast_clock = true;
            break;
        }
    };
    const needs_provider_timer = providerTimerNeeded(
        model.has_provider_subscriptions,
        model.provider_poll_interval_ms,
        has_fast_clock,
    );
    // Audio providers need a low-latency drain while a canvas is active, but
    // silence deliberately stops that clock. Polling the empty pipe ring at
    // 30 Hz was the measured 3.75-4.48% hosted-idle residual. A 1 Hz resume
    // probe makes silence effectively idle; the first resumed frame re-arms
    // the canvas clock and provider delivery returns to its 30 Hz path.
    const provider_interval_ms = if (model.provider_poll_interval_ms <= 33 and !has_fast_clock) @as(u64, 1000) else model.provider_poll_interval_ms;
    if (needs_provider_timer and !model.provider_poll_armed) {
        effects.startTimer(provider_poll_key, provider_interval_ms, .repeating);
        model.provider_poll_armed = true;
    } else if (!needs_provider_timer and model.provider_poll_armed) {
        effects.cancelTimer(provider_poll_key);
        model.provider_poll_armed = false;
    }
    const deadline_ms = engine.nextMediaDeadlineMs();
    if (deadline_ms) |deadline| {
        if (model.media_deadline_ms != deadline) {
            const now_ms = model.provider.nowMilliseconds();
            effects.startTimer(media_deadline_key, mediaDeadlineDelay(deadline, now_ms), .one_shot);
            model.media_deadline_ms = deadline;
        }
    } else if (model.media_deadline_ms != 0) {
        effects.cancelTimer(media_deadline_key);
        model.media_deadline_ms = 0;
    }
}

fn providerTimerNeeded(has_subscriptions: bool, poll_interval_ms: u64, has_fast_clock: bool) bool {
    return has_subscriptions and !(poll_interval_ms <= 33 and has_fast_clock);
}

fn hasHostProviderSubscription(subscriptions: []const []const u8) bool {
    for (subscriptions) |subscription| {
        // `time` is synthesized by the runtime's native timer and never has a
        // weaverd endpoint. Only host-backed subscriptions need this drain.
        if (!std.mem.eql(u8, subscription, "time")) return true;
    }
    return false;
}

fn mediaDeadlineDelay(deadline_ms: u64, now_ms: u64) u64 {
    return @max(deadline_ms -| now_ms, 1);
}

/// Stable global keys map runtime layout feedback back to retained nodes:
/// sliders keep their optimistic drag value, while canvases publish their
/// resolved content-box dimensions to JS only when layout actually changes.
fn syncNativeState(model: *Model, layout: native_sdk.canvas.WidgetLayoutTree) void {
    const CanvasResize = struct { id: tree_mod.NodeId, width: f32, height: f32 };
    var canvas_resizes: [tree_mod.max_canvases]CanvasResize = undefined;
    var canvas_resize_count: usize = 0;
    for (&model.tree.nodes, 0..) |*node, index| {
        if (!model.tree.isNodeSlotOccupied(index) or (node.kind != .slider and node.kind != .canvas)) continue;
        const id: tree_mod.NodeId = @intCast(index + 1);
        const widget_id = native_sdk.canvas.globalWidgetId(if (node.kind == .slider) .slider else .stack, .{ .int = id });
        for (layout.nodes) |layout_node| {
            if (layout_node.widget.id != widget_id) continue;
            if (node.kind == .slider) {
                model.slider_values[index] = layout_node.widget.value * node.max;
            } else {
                const frame = layout_node.frame.normalized();
                if ((model.tree.setCanvasLayout(id, frame.width, frame.height) catch false) and canvas_resize_count < canvas_resizes.len) {
                    canvas_resizes[canvas_resize_count] = .{ .id = id, .width = frame.width, .height = frame.height };
                    canvas_resize_count += 1;
                }
            }
            break;
        }
    }
    const engine = model.engine orelse return;
    for (canvas_resizes[0..canvas_resize_count]) |resize| {
        engine.fireCanvasResize(resize.id, resize.width, resize.height) catch |err| {
            std.log.err("widget canvas resize callback failed: {s}", .{@errorName(err)});
        };
    }
}

fn onFrame(model: *Model, frame: native_sdk.platform.GpuFrame) ?Msg {
    if (!model.logged_backend) {
        model.logged_backend = true;
        std.log.info("widget host surface backend={s}", .{@tagName(frame.backend)});
        publishBackendStatus(model, frame.backend);
    } else if (frame.backend != model.last_backend) {
        if ((model.last_backend == .d3d11 or model.last_backend == .metal) and frame.backend == .software) {
            std.log.warn("widget renderer demoted {s} -> software", .{@tagName(model.last_backend)});
        } else if (model.last_backend == .software and (frame.backend == .d3d11 or frame.backend == .metal)) {
            std.log.info("widget renderer promoted software -> {s}", .{@tagName(frame.backend)});
        } else {
            std.log.info("widget renderer backend changed {s} -> {s}", .{ @tagName(model.last_backend), @tagName(frame.backend) });
        }
        publishBackendStatus(model, frame.backend);
    }
    model.last_backend = frame.backend;
    if (!model.logged_present_path) {
        if (diagnostic_runtime) |runtime| {
            var view_buffer: [1]native_sdk.platform.ViewInfo = undefined;
            for (runtime.listViews(frame.window_id, &view_buffer)) |view_info| {
                if (!std.mem.eql(u8, view_info.label, frame.label)) continue;
                model.logged_present_path = true;
                std.log.info("widget presenter path={s}", .{@tagName(view_info.gpu_present_path)});
            }
        }
    }
    const engine = model.engine orelse return null;
    if (canvasLayoutStale(model, frame)) return Msg{ .canvas_layout = {} };
    const canvas_clock = engine.hasCanvasFrames();
    if (!canvas_clock) return null;
    // Hybrid presentation now rejects a clean completion revision before it
    // reaches the renderer. The completion event itself is the 60 Hz canvas
    // clock, so do not suppress it by comparing the pre-present revision in
    // the platform event; doing so parks max-rate canvases after frame one.
    if (model.first_render_ns == 0) model.first_render_ns = frame.timestamp_ns;
    model.rendered_presents += 1;
    if (model.rendered_presents % 300 == 0) {
        const elapsed_ns = frame.timestamp_ns -| model.first_render_ns;
        std.log.info("widget present: {d} rendered frames in {d} ms", .{ model.rendered_presents, elapsed_ns / std.time.ns_per_ms });
    }
    return Msg{ .canvas_frame = frame.timestamp_ns };
}

/// Layout sizes a canvas after the retained tree is built, but the SDK learns
/// that size only through `syncNativeState`, which Native runs at the start of
/// the next dispatch. A widget with nothing else to dispatch (a fixed-clock
/// capture, a live widget before its first event) would draw at its
/// class-declared size forever. So a presented frame whose canvas layout
/// disagrees with what the tree last published requests exactly one dispatch.
/// The comparison mirrors `syncNativeState` so the two agree after that sync.
fn canvasLayoutStale(model: *const Model, frame: native_sdk.platform.GpuFrame) bool {
    const runtime = diagnostic_runtime orelse return false;
    const layout = runtime.canvasWidgetLayout(frame.window_id, frame.label) catch return false;
    for (&model.tree.canvases, 0..) |*canvas_state, index| {
        if (!model.tree.canvas_occupied.isSet(index) or canvas_state.owner == 0) continue;
        const widget_id = native_sdk.canvas.globalWidgetId(.stack, native_sdk.canvas.uiKey(canvas_state.owner));
        for (layout.nodes) |layout_node| {
            if (layout_node.widget.id != widget_id) continue;
            const laid_out = layout_node.frame.normalized();
            if (@max(laid_out.width, 0) != canvas_state.layout_width or @max(laid_out.height, 0) != canvas_state.layout_height) return true;
            break;
        }
    }
    return false;
}

fn view(ui: *WidgetUi, model: *Model) WidgetUi.Node {
    if (widget_log.failed(model.log)) {
        const foreground = native_sdk.canvas.Color.rgba8(255, 226, 230, 255);
        const label = ui.text(.{
            .text_scale = 0.86,
            .wrap = true,
            .text_max_lines = 5,
            .style = .{ .foreground = foreground },
        }, "WidgetLogUnavailable\nThe per-widget log cannot be written. Check the log directory and available disk space.");
        return ui.panel(.{
            .window_drag = true,
            .padding = 12,
            .grow = 1,
            .cross = .center,
            .main = .center,
            .style = .{
                .background = native_sdk.canvas.Color.rgba8(52, 12, 18, 255),
                .foreground = foreground,
            },
        }, .{label});
    }
    projection_failed_this_view = false;
    const root_id = model.tree.root orelse return projectionFailurePanel(ui, true);
    const depth = loweredDepth(model, root_id);
    model.depth_limit_exceeded = depth > native_sdk.canvas.max_widget_depth;
    if (model.depth_limit_exceeded) return depthLimitPanel(ui, model, depth);
    model.depth_limit_reported = false;
    const result = buildNode(ui, model, root_id, true);
    if (!projection_failed_this_view and model.projection_failure_latched) {
        std.log.info("widget native projection recovered after a degraded frame", .{});
        model.projection_failure_latched = false;
    }
    return result;
}

/// The retained TSX projection depends on the authored tree plus the global
/// log-failure fallback. Immediate Canvas pixels deliberately use their own
/// generation and are projected by `projectSameViewUpdate` below.
fn viewRevision(model: *const Model) u64 {
    return model.tree.generation *% 2 +% @intFromBool(widget_log.failed(model.log));
}

/// Native surface requests are one-shot. A registered canvas callback owns
/// the next request even when its retained commands are byte-for-byte
/// unchanged; clearing the callback after dispatch leaves the surface idle.
fn rearmCanvasFrameIfRegistered(
    runtime: *native_sdk.Runtime,
    window_id: native_sdk.platform.WindowId,
    canvas_label: []const u8,
    registered: bool,
) anyerror!void {
    if (!registered) return;
    _ = try runtime.requestCanvasFrame(window_id, canvas_label);
}

/// Canvas callbacks mutate fixed command storage in `Tree.canvases`; the
/// retained Native layout already owns the corresponding widget geometry.
/// Re-point the retained slices (their lengths may change), emit once for all
/// canvases, and keep TSX construction + flex layout off the frame loop.
fn projectSameViewUpdate(
    runtime: *native_sdk.Runtime,
    window_id: native_sdk.platform.WindowId,
    canvas_label: []const u8,
    model: *const Model,
    msg: Msg,
) anyerror!bool {
    // The update has already run by the time projection starts. Observe the
    // current callback state before specializing by message: a provider wake
    // can register fps="display" from idle and must start the one-shot native
    // frame chain, while a canvas callback can clear itself and must not
    // request another tick. Paint diffing cannot own animation lifetime: an
    // honest animation may draw identical commands on successive ticks.
    try rearmCanvasFrameIfRegistered(
        runtime,
        window_id,
        canvas_label,
        (model.engine orelse return true).hasCanvasFrames(),
    );

    switch (msg) {
        // Both carry fresh canvas commands that the retained tree must show
        // without a rebuild: a draw tick, or the redraw that follows a layout
        // size reaching the SDK.
        .canvas_frame, .canvas_layout => {},
        else => return true,
    }

    var updates: [tree_mod.max_canvases]native_sdk.runtime.CanvasWidgetImmediateUpdate = undefined;
    var update_count: usize = 0;
    for (&model.tree.canvases, 0..) |*canvas_state, canvas_index| {
        if (!model.tree.canvas_occupied.isSet(canvas_index)) continue;
        const id = canvas_state.owner;
        if (id == 0) continue;
        const node = try model.tree.nodeConst(id);
        // These decorations are also stored in `immediate_commands`; until
        // the batch API carries a composed metadata tail, keep their exact
        // semantics by taking the ordinary rebuild path.
        if (!node.hover_style.isEmpty() or !node.pressed_style.isEmpty() or
            node.shadow != null or node.text_shadow != null or node.iconPathSlice().len != 0 or
            node.radius_top_left >= 0 or node.radius_top_right >= 0 or
            node.radius_bottom_right >= 0 or node.radius_bottom_left >= 0)
        {
            return false;
        }
        updates[update_count] = .{
            .id = native_sdk.canvas.globalWidgetId(.stack, native_sdk.canvas.uiKey(id)),
            .commands = canvas_state.slice(),
        };
        update_count += 1;
    }
    if (update_count > 0) {
        _ = try runtime.setCanvasWidgetImmediateCommands(window_id, canvas_label, updates[0..update_count]);
    }
    return true;
}

fn noteProjectionFailure(model: *Model, comptime format: []const u8, args: anytype) void {
    projection_failed_this_view = true;
    if (model.projection_failure_latched) return;
    model.projection_failure_latched = true;
    std.log.err(format ++ "; marking this frame degraded and suppressing repeats until recovery", args);
}

fn projectionFailurePanel(ui: *WidgetUi, is_root: bool) WidgetUi.Node {
    projection_failed_this_view = true;
    return ui.panel(.{
        .window_drag = is_root,
        .grow = 1,
        .style = .{ .background = native_sdk.canvas.Color.rgba8(98, 16, 28, 255) },
    }, .{});
}

/// Whether `buildNode` emits a node's retained children. Leaves (text,
/// slider, icon, image, canvas) draw themselves and drop any children.
fn emitsChildren(kind: tree_mod.Kind) bool {
    return switch (kind) {
        .column, .row, .stack, .panel, .button => true,
        .text, .slider, .icon, .image, .canvas => false,
    };
}

/// Native levels `buildNode` emits for this subtree. Painted layouts and
/// `<panel>` lower to a panel around a layout node (two levels), as does a
/// failed image's labelled box. `weaver check` estimates this statically
/// (`LoweredWidgetDepthLimit` in cli/src/index.ts); this count is the
/// authoritative one.
fn loweredDepth(model: *const Model, id: tree_mod.NodeId) usize {
    const node = model.tree.nodeConst(id) catch return 1;
    const own: usize = switch (node.kind) {
        .panel => 2,
        .column, .row, .stack => if (hasPaintStyle(node)) 2 else 1,
        .image => if (findImageStateConst(model, id)) |image_state| (if (image_state.failure != null) 2 else 1) else 1,
        else => 1,
    };
    if (!emitsChildren(node.kind)) return own;
    var deepest: usize = 0;
    for (node.children[0..node.child_count]) |child| deepest = @max(deepest, loweredDepth(model, child));
    return own + deepest;
}

/// Native's layout refuses a tree deeper than `max_widget_depth`, which left
/// the widget blank with no error, and building a tree a few hundred levels
/// deep overflowed the native stack first (~70 KiB per level) and killed the
/// process. Refuse the whole view by name before building any of it.
fn depthLimitPanel(ui: *WidgetUi, model: *Model, depth: usize) WidgetUi.Node {
    const limit = native_sdk.canvas.max_widget_depth;
    if (!model.depth_limit_reported) {
        model.depth_limit_reported = true;
        widget_diagnostic.report(
            "WidgetDepthExceeded: the widget tree nests {d} levels; the limit is max_widget_depth={d}, asked for {d}. Painted <row>/<column>/<stack> elements and <panel> count as two levels. Flatten nested containers or move deep content into a <canvas>.",
            .{ depth, limit, depth },
        );
    }
    projection_failed_this_view = true;
    model.projection_failure_latched = true;
    const foreground = native_sdk.canvas.Color.rgba8(255, 226, 230, 255);
    const message = std.fmt.allocPrint(ui.arena, "WidgetDepthExceeded\nThis widget nests {d} levels; the limit is {d}. Flatten nested containers.", .{ depth, limit }) catch
        "WidgetDepthExceeded\nThis widget nests too many levels. Flatten nested containers.";
    const label = ui.text(.{
        .text_scale = 0.86,
        .wrap = true,
        .text_max_lines = 5,
        .style = .{ .foreground = foreground },
    }, message);
    return ui.panel(.{
        .window_drag = true,
        .padding = 12,
        .grow = 1,
        .cross = .center,
        .main = .center,
        .style = .{
            .background = native_sdk.canvas.Color.rgba8(52, 12, 18, 255),
            .foreground = foreground,
        },
    }, .{label});
}

fn hasPaintStyle(node: *const tree_mod.Node) bool {
    return node.background != null or node.border_color != null or node.border_width > 0 or node.radius > 0 or
        node.radius_top_left >= 0 or node.radius_top_right >= 0 or node.radius_bottom_right >= 0 or node.radius_bottom_left >= 0 or node.shadow != null or
        node.backgroundGradientSlice().len > 0 or !node.hover_style.isEmpty() or !node.pressed_style.isEmpty();
}

fn nativeInteractionStyle(style: tree_mod.InteractionStyle) ?native_sdk.canvas.WidgetInteractionStyle {
    if (style.isEmpty()) return null;
    return .{
        .background = style.background,
        .foreground = style.text_color,
        .opacity = if (style.opacity >= 0) style.opacity else null,
        .border = style.border_color,
        .shadow = if (!style.shadow_set)
            .inherit
        else if (style.shadow) |shadow|
            .{ .value = .{
                .offset = shadow.offset,
                .blur = shadow.blur,
                .spread = shadow.spread,
                .color = shadow.color,
                .inset = style.shadow_inset,
            } }
        else
            .none,
    };
}

fn attachEffects(ui: *WidgetUi, model: *Model, retained: *const tree_mod.Node, font_id: ?native_sdk.canvas.FontId, source: WidgetUi.Node) WidgetUi.Node {
    var icon_elements: ?[]const native_sdk.canvas.PathElement = null;
    const corner_radii: native_sdk.canvas.WidgetCornerRadii = .{
        .top_left = nativeCornerRadius(retained.radius_top_left),
        .top_right = nativeCornerRadius(retained.radius_top_right),
        .bottom_right = nativeCornerRadius(retained.radius_bottom_right),
        .bottom_left = nativeCornerRadius(retained.radius_bottom_left),
    };
    const gradient_commands = gradient_mod.decode(ui.arena, retained.backgroundGradientSlice()) catch |err| block: {
        if (retained.backgroundGradientSlice().len > 0) noteProjectionFailure(model, "widget gradient projection failed: cause={s}", .{@errorName(err)});
        break :block &.{};
    };
    if (retained.iconPathSlice().len > 0) {
        const element_count = native_sdk.canvas.normalized_path.countElements(retained.iconPathSlice()) catch |err| block: {
            std.log.err("bundle emitted invalid normalized icon path: {s}", .{@errorName(err)});
            break :block 0;
        };
        if (element_count > 0) {
            if (ui.arena.alloc(native_sdk.canvas.PathElement, element_count)) |elements| {
                icon_elements = native_sdk.canvas.normalized_path.parse(retained.iconPathSlice(), elements) catch |err| block: {
                    std.log.err("bundle icon path decode failed: {s}", .{@errorName(err)});
                    break :block null;
                };
            } else |_| {
                std.log.err("bundle icon path exceeds the Native UI arena", .{});
            }
        }
    }
    const count = @as(usize, @intFromBool(retained.shadow != null)) +
        @as(usize, @intFromBool(retained.text_shadow != null)) +
        @as(usize, @intFromBool(font_id != null)) +
        @as(usize, @intFromBool(icon_elements != null)) +
        @as(usize, @intFromBool(!corner_radii.isDefault())) +
        gradient_commands.len;
    if (count == 0) return source;
    const existing = source.widget.immediate_commands;
    const combined = ui.arena.alloc(native_sdk.canvas.ImmediateCanvasCommand, existing.len + count) catch |err| {
        noteProjectionFailure(model, "widget effect projection failed: cause={s}", .{@errorName(err)});
        return source;
    };
    @memcpy(combined[0..existing.len], existing);
    var cursor: usize = existing.len;
    @memcpy(combined[cursor .. cursor + gradient_commands.len], gradient_commands);
    cursor += gradient_commands.len;
    if (retained.shadow) |shadow| {
        combined[cursor] = .{ .box_shadow = .{
            .offset = shadow.offset,
            .blur = shadow.blur,
            .spread = shadow.spread,
            .color = shadow.color,
            .inset = retained.shadow_inset,
        } };
        cursor += 1;
    }
    if (retained.text_shadow) |shadow| {
        combined[cursor] = .{ .text_shadow = shadow };
        cursor += 1;
    }
    if (font_id) |id| {
        combined[cursor] = .{ .text_font = id };
        cursor += 1;
    }
    if (!corner_radii.isDefault()) {
        combined[cursor] = .{ .corner_radii = corner_radii };
        cursor += 1;
    }
    if (icon_elements) |elements| {
        combined[cursor] = .{ .icon_path = .{
            .view_box = retained.icon_view_box,
            .elements = elements,
            .stroke_width = retained.icon_stroke,
        } };
        cursor += 1;
    }
    std.debug.assert(cursor == combined.len);
    var result = source;
    result.widget.immediate_commands = combined;
    return result;
}

fn buildNode(ui: *WidgetUi, model: *Model, id: tree_mod.NodeId, is_root: bool) WidgetUi.Node {
    const retained = model.tree.nodeConst(id) catch |err| {
        noteProjectionFailure(model, "widget retained-node projection failed: node={d}, cause={s}", .{ id, @errorName(err) });
        return projectionFailurePanel(ui, is_root);
    };
    // Leaves drop their retained children; building them anyway would only
    // spend stack (and, deep enough, overflow it) for nodes nobody draws.
    const child_count: usize = if (emitsChildren(retained.kind)) retained.child_count else 0;
    const children = ui.arena.alloc(WidgetUi.Node, child_count) catch |err| {
        noteProjectionFailure(
            model,
            "widget child projection capacity exhausted: node={d}, asked for {d}, cause={s}",
            .{ id, retained.child_count, @errorName(err) },
        );
        return projectionFailurePanel(ui, is_root);
    };
    for (retained.children[0..child_count], 0..) |child_id, index| {
        children[index] = buildNode(ui, model, child_id, false);
    }
    return buildElement(ui, model, id, retained, is_root, children);
}

// One node from its already-built children. noinline so the recursion in
// buildNode stays small: each element kind's options and Node temporaries
// (~68 KiB together) live here, in a frame that returns before the next
// sibling recurses, instead of in every level of the tree.
noinline fn buildElement(
    ui: *WidgetUi,
    model: *Model,
    id: tree_mod.NodeId,
    retained: *const tree_mod.Node,
    is_root: bool,
    children: []WidgetUi.Node,
) WidgetUi.Node {
    var options: WidgetUi.ElementOptions = .{
        .global_key = .{ .int = id },
        // Every widget drags by its whole surface: the root is one OS
        // window-drag region, and press-claiming widgets inside it
        // (buttons, sliders) become exclusion rects automatically, so
        // their interactions win over the drag. The OS owns the pointer
        // for the whole gesture — no JS round-trip, no re-render.
        .window_drag = is_root,
        .padding = retained.padding,
        .padding_top = if (retained.padding_top >= 0) retained.padding_top else null,
        .padding_right = if (retained.padding_right >= 0) retained.padding_right else null,
        .padding_bottom = if (retained.padding_bottom >= 0) retained.padding_bottom else null,
        .padding_left = if (retained.padding_left >= 0) retained.padding_left else null,
        .margin_top = retained.margin_top,
        .margin_right = retained.margin_right,
        .margin_bottom = retained.margin_bottom,
        .margin_left = retained.margin_left,
        .gap = retained.gap,
        .opacity = retained.opacity,
        .grow = retained.grow,
        .shrink = retained.shrink,
        .self_align = switch (retained.align_self) {
            .auto => null,
            .start => .start,
            .center => .center,
            .end => .end,
            .stretch => .stretch,
        },
        .flex_wrap = retained.flex_wrap,
        .clip_content = retained.overflow_hidden,
        .width = if (retained.width >= 0) retained.width else null,
        .height = if (retained.height >= 0) retained.height else null,
        .min_width = retained.min_width,
        .min_height = retained.min_height,
        .max_width = if (retained.max_width >= 0) retained.max_width else null,
        .max_height = if (retained.max_height >= 0) retained.max_height else null,
        .width_percent = retained.width_percent,
        .height_percent = retained.height_percent,
        .aspect_ratio = retained.aspect_ratio,
        .image_fit = retained.image_fit,
        .image_tile = retained.image_tile,
        .cross = switch (retained.cross_align) {
            .start => .start,
            .center => .center,
            .end, .baseline => .end,
            .stretch => .stretch,
        },
        .main = switch (retained.main_align) {
            .start => .start,
            .center => .center,
            .end => .end,
            .between => .space_between,
            .around => .space_around,
            .evenly => .space_evenly,
        },
        .style = .{
            .background = retained.background,
            .foreground = retained.text_color,
            .radius = if (retained.radius >= 0) retained.radius else null,
            .border = retained.border_color,
            .stroke_width = retained.border_width,
            .quiet_hover = true,
        },
        .hover_style = nativeInteractionStyle(retained.hover_style),
        .pressed_style = nativeInteractionStyle(retained.pressed_style),
        .on_press_event = if (retained.handles_press) press_msgs[model.slot] else null,
        .on_double_press_event = if (retained.handles_double_press) double_press_msgs[model.slot] else null,
        .on_right_press_event = if (retained.handles_right_press) right_press_msgs[model.slot] else null,
        .on_change = if (retained.handles_change) HostMsg{ .widget = model.slot, .msg = .{ .slider = id } } else null,
    };
    // Weaver buttons use Native's panel primitive so TSX utility styling is
    // the complete visual contract. Preserve the control semantics explicitly:
    // automation and assistive clients should still see a named button, not an
    // anonymous group whose text happens to be painted by a child.
    if (retained.kind == .button) {
        options.semantics.role = .button;
        const explicit_label = retained.accessibilityLabelSlice();
        options.semantics.label = if (explicit_label.len != 0) explicit_label else firstDescendantText(&model.tree, id);
        options.semantics.focusable = retained.handles_press;
        options.semantics.actions.press = retained.handles_press;
    } else if (retained.kind == .slider) {
        options.semantics.label = retained.accessibilityLabelSlice();
    }
    if (retained.kind == .text) {
        options.text_alignment = switch (retained.text_align) {
            .start => .start,
            .center => .center,
            .end => .end,
        };
        options.text_line_height = if (retained.line_height > 0) retained.line_height * 14 * retained.font_scale else 0;
        options.text_letter_spacing = retained.letter_spacing;
        options.text_tabular_numbers = retained.tabular_nums;
        options.text_max_lines = @intFromFloat(@floor(std.math.clamp(retained.line_clamp, 0, 64)));
        options.wrap = retained.line_clamp > 0;
        options.overflow = if (retained.truncate or retained.line_clamp > 0) .ellipsis else .clip;
        if (retained.truncate or retained.line_clamp > 0) {
            options.text_scale = retained.font_scale;
            options.text_weight = switch (retained.font_weight) {
                .light, .regular => .regular,
                .medium => .medium,
                .semibold, .bold => .bold,
            };
            return attachEffects(ui, model, retained, resolveFontId(model, retained), ui.text(options, retained.textSlice()));
        }
        const span = [_]native_sdk.canvas.TextSpan{.{
            .text = retained.textSlice(),
            .weight = switch (retained.font_weight) {
                .light, .regular => .regular,
                .medium => .medium,
                .semibold, .bold => .bold,
            },
            .scale = retained.font_scale,
        }};
        return attachEffects(ui, model, retained, resolveFontId(model, retained), ui.paragraph(options, &span));
    }
    const result = switch (retained.kind) {
        // SDK layout-only rows/columns/stacks do not paint their own style.
        // A styled layout is contractually a painted box around its layout
        // primitive: the panel owns paint/effects and the inner node keeps
        // child layout. This is especially important for stacks because a
        // Native stack with immediate commands is an immediate-canvas leaf.
        .column => if (hasPaintStyle(retained)) block: {
            const column_options: WidgetUi.ElementOptions = .{
                .gap = retained.gap,
                .grow = 1,
                .cross = options.cross,
                .main = options.main,
                .flex_wrap = retained.flex_wrap,
            };
            options.gap = 0;
            break :block ui.panel(options, .{ui.column(column_options, children)});
        } else ui.column(options, children),
        .row => if (hasPaintStyle(retained)) block: {
            const row_options: WidgetUi.ElementOptions = .{
                .gap = retained.gap,
                .grow = 1,
                .cross = options.cross,
                .main = options.main,
                .flex_wrap = retained.flex_wrap,
            };
            options.gap = 0;
            break :block ui.panel(options, .{ui.row(row_options, children)});
        } else ui.row(options, children),
        .stack => if (hasPaintStyle(retained)) block: {
            const stack_options: WidgetUi.ElementOptions = .{
                .grow = 1,
                .cross = options.cross,
                .main = options.main,
            };
            options.gap = 0;
            break :block ui.panel(options, .{ui.stack(stack_options, children)});
        } else ui.stack(options, children),
        // `<panel>` is a painted box with column layout (CONTRACT: "a styled
        // box; column layout"). Native's panel kind overlays its children, so
        // the panel owns paint and effects while an inner column owns child
        // layout, exactly like a styled `<column>`.
        .panel => block: {
            const column_options: WidgetUi.ElementOptions = .{
                .gap = retained.gap,
                .grow = 1,
                .cross = options.cross,
                .main = options.main,
                .flex_wrap = retained.flex_wrap,
            };
            options.gap = 0;
            break :block ui.panel(options, .{ui.column(column_options, children)});
        },
        .icon => ui.el(.icon, options, .{}),
        .button => ui.panel(options, children),
        .slider => ui.el(.slider, block: {
            options.value = std.math.clamp(retained.value / retained.max, 0, 1);
            break :block options;
        }, .{}),
        .image => block: {
            if (findImageStateConst(model, id)) |image_state| {
                if (image_state.failure) |_| {
                    options.cross = .center;
                    options.main = .center;
                    options.style.background = native_sdk.canvas.Color.rgba8(52, 12, 18, 255);
                    options.style.foreground = native_sdk.canvas.Color.rgba8(255, 226, 230, 255);
                    const label_options: WidgetUi.ElementOptions = .{
                        .text_scale = 0.72,
                        .text_alignment = .center,
                        .wrap = true,
                        .text_max_lines = 3,
                        .style = .{ .foreground = native_sdk.canvas.Color.rgba8(255, 226, 230, 255) },
                    };
                    break :block ui.panel(options, .{ui.text(label_options, imageFailureLabel(image_state))});
                }
            }
            options.image = slotted(model.slot, id);
            break :block ui.image(options);
        },
        .canvas => ui.immediateCanvas(options, (model.tree.canvasStateConst(id) catch |err| {
            noteProjectionFailure(model, "widget canvas projection failed: node={d}, cause={s}", .{ id, @errorName(err) });
            return projectionFailurePanel(ui, is_root);
        }).slice()),
        .text => unreachable,
    };
    return attachEffects(ui, model, retained, null, result);
}

/// Press handlers take only the event, so each slot gets its own comptime
/// constructor that addresses the Msg to that widget.
const press_msgs = pressMsgs(.press);
const double_press_msgs = pressMsgs(.double_press);
const right_press_msgs = pressMsgs(.right_press);

fn pressMsgs(comptime tag: std.meta.Tag(Msg)) [max_host_widgets]WidgetUi.PressMsgFn {
    var fns: [max_host_widgets]WidgetUi.PressMsgFn = undefined;
    for (&fns, 0..) |*make_fn, slot| {
        make_fn.* = struct {
            fn make(press: native_sdk.canvas.WidgetPressEvent) HostMsg {
                return .{ .widget = slot, .msg = @unionInit(Msg, @tagName(tag), press) };
            }
        }.make;
    }
    return fns;
}

fn firstDescendantText(tree: *const tree_mod.Tree, id: tree_mod.NodeId) []const u8 {
    const node = tree.nodeConst(id) catch return "";
    if (node.kind == .text and node.text_len != 0) return node.textSlice();
    for (node.children[0..node.child_count]) |child_id| {
        const text = firstDescendantText(tree, child_id);
        if (text.len != 0) return text;
    }
    return "";
}

fn resolveFontId(model: *const Model, node: *const tree_mod.Node) ?native_sdk.canvas.FontId {
    const id = resolveManifestFontId(node, model.fonts) orelse return null;
    if (id == native_sdk.canvas.default_mono_font_id) return id;
    for (model.fonts, model.font_registrations) |font, registration| {
        if (font.id == id) return registration.id;
    }
    return null;
}

fn resolveManifestFontId(node: *const tree_mod.Node, fonts: []const manifest_mod.Font) ?native_sdk.canvas.FontId {
    const requested = node.fontFamilySlice();
    // Null means "use Native's ordinary sans + weight resolution" and
    // keeps the overwhelmingly common path free of a metadata command.
    if (requested.len == 0 or std.mem.eql(u8, requested, "sans")) return null;
    if (std.mem.eql(u8, requested, "mono")) return native_sdk.canvas.default_mono_font_id;
    for (fonts) |font| if (std.mem.eql(u8, requested, font.stem)) return font.id;
    var best: ?manifest_mod.Font = null;
    var best_distance: u8 = std.math.maxInt(u8);
    for (fonts) |font| {
        if (!std.mem.eql(u8, requested, font.family)) continue;
        const distance: u8 = @intCast(@abs(@as(i8, @intCast(@intFromEnum(node.font_weight))) - @as(i8, @intCast(@intFromEnum(font.weight)))));
        if (distance < best_distance) {
            best = font;
            best_distance = distance;
        }
    }
    return if (best) |font| font.id else null;
}

/// Faces the runtime has, by content. Native font ids are permanent, so a
/// face registers once: every widget that ships it, and a widget loaded
/// again, shares its id. Widgets load one at a time (`Loader`,
/// `WidgetLoad`), so the table needs no lock.
const ContentFont = struct { hash: u64, len: usize, id: native_sdk.canvas.FontId, registered: bool = false };
var content_fonts: [native_sdk.runtime.max_registered_canvas_fonts]ContentFont = undefined;
var content_font_count: usize = 0;

fn contentFontId(ttf: []const u8) !native_sdk.canvas.FontId {
    if (knownFontId(ttf)) |id| return id;
    const hash = std.hash.Wyhash.hash(0, ttf);
    if (content_font_count == content_fonts.len) return error.FontRegistryFull;
    const id: native_sdk.canvas.FontId = native_sdk.canvas.min_registered_font_id + content_font_count;
    content_fonts[content_font_count] = .{ .hash = hash, .len = ttf.len, .id = id };
    content_font_count += 1;
    return id;
}

/// Give a loaded widget's faces their content ids. Only a widget that
/// loaded takes entries in the table, and only if all its new faces fit: a
/// widget refused for a full table must not use up ids the host can never
/// give back.
fn assignFontIds(model: *Model) !void {
    var new_faces: usize = 0;
    for (model.font_registrations, 0..) |registration, index| {
        if (knownFontId(registration.ttf) != null) continue;
        const repeated = for (model.font_registrations[0..index]) |earlier| {
            if (sameFace(earlier.ttf, registration.ttf)) break true;
        } else false;
        if (!repeated) new_faces += 1;
    }
    if (content_font_count + new_faces > content_fonts.len) {
        std.log.warn("font registry full: max_registered_canvas_fonts={d}, {d} in use, this widget asked for {d} more", .{ content_fonts.len, content_font_count, new_faces });
        return error.FontRegistryFull;
    }
    for (model.font_registrations) |*registration| registration.id = contentFontId(registration.ttf) catch unreachable;
}

fn knownFontId(ttf: []const u8) ?native_sdk.canvas.FontId {
    const hash = std.hash.Wyhash.hash(0, ttf);
    for (content_fonts[0..content_font_count]) |font| {
        if (font.hash == hash and font.len == ttf.len) return font.id;
    }
    return null;
}

fn sameFace(a: []const u8, b: []const u8) bool {
    return a.len == b.len and std.hash.Wyhash.hash(0, a) == std.hash.Wyhash.hash(0, b);
}

/// Register a widget's faces the runtime does not have yet: an anchored
/// host loads widgets after its app installed its fonts.
fn registerWidgetFonts(runtime: *native_sdk.Runtime, model: *const Model) !void {
    for (model.font_registrations) |registration| {
        const entry = for (content_fonts[0..content_font_count]) |*font| {
            if (font.id == registration.id) break font;
        } else unreachable;
        if (entry.registered) continue;
        try runtime.registerCanvasFont(registration.id, registration.ttf);
        entry.registered = true;
    }
}

/// A widget's declared faces, read from its directory and checked; their
/// ids come once it has loaded (`assignFontIds`).
fn fontRegistrations(io: std.Io, allocator: std.mem.Allocator, directory: []const u8, fonts: []const manifest_mod.Font) ![]HostApp.FontRegistration {
    const registrations = try allocator.alloc(HostApp.FontRegistration, fonts.len);
    for (fonts, 0..) |font, index| {
        for (fonts[0..index]) |earlier| {
            if (earlier.id == font.id) {
                std.log.err("font \"{s}\" reuses font id {d} of \"{s}\"; every face needs its own id", .{ font.name, font.id, earlier.name });
                return error.DuplicateFontId;
            }
        }
        const path = try std.fs.path.join(allocator, &.{ directory, font.file });
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(native_sdk.runtime.max_registered_canvas_font_bytes));
        // Parse here so an unreadable face fails this widget's load, not
        // the host's shared font registration.
        _ = native_sdk.canvas.font_ttf.Face.parse(bytes) catch {
            std.log.err("font \"{s}\" ({s}) failed to parse: {s}", .{ font.name, font.file, native_sdk.canvas.font_ttf.parseFailureReason(bytes) orelse "not a parseable TrueType face" });
            return error.FontParseFailed;
        };
        registrations[index] = .{ .id = 0, .name = font.name, .ttf = bytes };
    }
    return registrations;
}

fn nativeCornerRadius(retained: f32) ?f32 {
    return if (retained >= 0) retained else null;
}

fn loadLocalImages(io: std.Io, allocator: std.mem.Allocator, directory: []const u8, model: *Model) !void {
    for (&model.tree.nodes, 0..) |*node, index| {
        if (!model.tree.isNodeSlotOccupied(index) or node.kind != .image) continue;
        const source = node.sourceSlice();
        if (!image_paths.isLocalAssetPath(source)) {
            std.log.err("RemoteImageUnsupported: <image> remote sources arrive in M3; use a local widget path", .{});
            return error.RemoteImageUnsupported;
        }
        if (model.image_count == max_images) return error.TooManyImages;
        const relative = if (std.mem.startsWith(u8, source, "./") or std.mem.startsWith(u8, source, ".\\")) source[2..] else source;
        const path = try std.fs.path.join(allocator, &.{ directory, relative });
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_image_stream_bytes));
        model.images[model.image_count] = .{ .id = @intCast(index + 1), .bytes = bytes };
        model.image_count += 1;
    }
}

fn seedImageStates(model: *Model) !void {
    const resolver = model.image_resolver orelse return;
    for (model.images[0..model.image_count]) |image| {
        const id: tree_mod.NodeId = @intCast(image.id);
        const node = try model.tree.nodeConst(id);
        const resolved = try resolver.resolve(node.sourceSlice());
        const state = try addImageState(model, id, node.lifetime);
        state.observed = resolved.path;
        state.observed_valid = true;
    }
    model.image_tree_generation = model.tree.generation;
}

fn deinitImageStates(model: *Model) void {
    for (model.image_states[0..model.image_state_count]) |*state| {
        if (state.observed) |observed| small_allocator.free(observed);
    }
    model.image_state_count = 0;
}

fn findImageState(model: *Model, id: tree_mod.NodeId) ?*ImageState {
    for (model.image_states[0..model.image_state_count]) |*state| {
        if (state.id == id) return state;
    }
    return null;
}

fn addImageState(model: *Model, id: tree_mod.NodeId, lifetime: u64) !*ImageState {
    if (model.image_state_count == model.image_states.len) return error.TooManyImages;
    const state = &model.image_states[model.image_state_count];
    state.* = .{ .id = id, .lifetime = lifetime, .epoch = model.image_epoch };
    model.image_state_count += 1;
    return state;
}

fn removeImageState(model: *Model, effects: WidgetEffects, index: usize) void {
    const state = &model.image_states[index];
    if (state.registered) _ = effects.unregisterImage(state.id);
    if (state.observed) |observed| small_allocator.free(observed);
    model.image_state_count -= 1;
    if (index != model.image_state_count) model.image_states[index] = model.image_states[model.image_state_count];
    model.image_states[model.image_state_count] = .{};
}

fn replaceObserved(state: *ImageState, observed: [:0]u8, valid: bool) void {
    if (state.observed) |previous| small_allocator.free(previous);
    state.observed = observed;
    state.observed_valid = valid;
    state.load_failure_count = 0;
}

fn rememberRawSource(state: *ImageState, source: []const u8) !void {
    replaceObserved(state, try small_allocator.dupeZ(u8, source), false);
}

fn observedEquals(state: *const ImageState, source: []const u8, valid: bool) bool {
    return state.observed_valid == valid and if (state.observed) |observed| std.mem.eql(u8, observed, source) else false;
}

fn recordImageLoadFailure(state: *ImageState, observed: [:0]u8) void {
    const prior_failure_count = if (observedEquals(state, observed, true)) state.load_failure_count else 0;
    replaceObserved(state, observed, true);
    state.load_failure_count = @min(prior_failure_count + 1, max_image_load_attempts);
}

fn observedImageLoadSettled(state: *const ImageState, source: []const u8) bool {
    if (!observedEquals(state, source, true)) return false;
    return state.load_failure_count == 0 or state.load_failure_count >= max_image_load_attempts;
}

fn invalidImageSourceError(err: anyerror) bool {
    return switch (err) {
        error.InvalidImageSource,
        error.ArtPathOutsideCache,
        error.WidgetAssetEscapesRoot,
        error.ArtPathTooLong,
        => true,
        else => false,
    };
}

fn synchronizeImageNode(model: *Model, effects: WidgetEffects, id: tree_mod.NodeId, node: *const tree_mod.Node) !void {
    const resolver = model.image_resolver orelse return;
    const state = findImageState(model, id) orelse try addImageState(model, id, node.lifetime);
    const resolved = resolver.resolve(node.sourceSlice()) catch |err| {
        if (observedEquals(state, node.sourceSlice(), false)) return;
        if (invalidImageSourceError(err) and state.registered) {
            _ = effects.unregisterImage(id);
            state.registered = false;
        }
        try rememberRawSource(state, node.sourceSlice());
        state.failure = err;
        state.failure_label_len = 0;
        if (invalidImageSourceError(err)) {
            std.log.err("image source rejected by widget/art-cache containment: {s}", .{@errorName(err)});
        } else {
            std.log.err("image source could not be resolved; prior registration is retained but the widget is showing a failure placeholder: {s}", .{@errorName(err)});
        }
        return;
    };
    if (observedImageLoadSettled(state, resolved.path)) {
        small_allocator.free(resolved.path);
        return;
    }
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        model.io orelse return error.MissingIo,
        resolved.path,
        std.heap.page_allocator,
        .limited(max_image_stream_bytes),
    ) catch |err| {
        recordImageLoadFailure(state, resolved.path);
        state.failure = err;
        state.failure_label_len = 0;
        std.log.err("image reload read failed; prior registration is retained but the widget is showing a failure placeholder: {s}", .{@errorName(err)});
        return;
    };
    defer std.heap.page_allocator.free(bytes);
    _ = effects.registerImageBytes(id, bytes) catch |err| {
        recordImageLoadFailure(state, resolved.path);
        recordImageFailure(state, err, bytes, "image reload decode/register");
        return;
    };
    replaceObserved(state, resolved.path, true);
    state.registered = true;
    clearImageFailure(state);
}

test "a widget's image paths are freed by the allocator that made them" {
    const root = ".zig-cache/weaver-image-state-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root);
    const image = root ++ "/cover.img";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = image, .data = "image" });
    var resolver = try image_paths.Resolver.init(std.testing.io, small_allocator, root, null);
    defer resolver.deinit();
    var state: ImageState = .{};
    // A resolved path, a raw source and a failure each replace the last.
    replaceObserved(&state, (try resolver.resolve("cover.img")).path, true);
    try rememberRawSource(&state, "missing.img");
    recordImageLoadFailure(&state, (try resolver.resolve("cover.img")).path);
    if (state.observed) |observed| small_allocator.free(observed);
}

test "image reload failures retry twice then settle until the source changes" {
    var state: ImageState = .{};
    defer if (state.observed) |observed| small_allocator.free(observed);

    recordImageLoadFailure(&state, try small_allocator.dupeZ(u8, "first.img"));
    try std.testing.expect(!observedImageLoadSettled(&state, "first.img"));
    try std.testing.expectEqual(@as(u8, 1), state.load_failure_count);

    recordImageLoadFailure(&state, try small_allocator.dupeZ(u8, "first.img"));
    try std.testing.expect(!observedImageLoadSettled(&state, "first.img"));
    try std.testing.expectEqual(@as(u8, 2), state.load_failure_count);

    recordImageLoadFailure(&state, try small_allocator.dupeZ(u8, "first.img"));
    try std.testing.expect(observedImageLoadSettled(&state, "first.img"));
    try std.testing.expectEqual(max_image_load_attempts, state.load_failure_count);

    recordImageLoadFailure(&state, try small_allocator.dupeZ(u8, "second.img"));
    try std.testing.expect(!observedImageLoadSettled(&state, "second.img"));
    try std.testing.expectEqual(@as(u8, 1), state.load_failure_count);

    replaceObserved(&state, try small_allocator.dupeZ(u8, "second.img"), true);
    try std.testing.expect(observedImageLoadSettled(&state, "second.img"));
    try std.testing.expectEqual(@as(u8, 0), state.load_failure_count);
}

/// Runs after every app-loop turn, but the generation equality is the static
/// fast path. A changed image is decoded before its same-ID resource is
/// replaced; invalid/dead/reused nodes are unregistered explicitly.
fn synchronizeImages(model: *Model, effects: WidgetEffects) !void {
    if (model.tree.generation == model.image_tree_generation) return;
    const synchronized_generation = model.tree.generation;

    var state_index: usize = 0;
    while (state_index < model.image_state_count) {
        const state = &model.image_states[state_index];
        const node = model.tree.nodeConst(state.id) catch {
            removeImageState(model, effects, state_index);
            continue;
        };
        if (node.kind != .image or node.lifetime != state.lifetime or state.epoch != model.image_epoch) {
            removeImageState(model, effects, state_index);
            continue;
        }
        state_index += 1;
    }

    for (&model.tree.nodes, 0..) |*node, index| {
        if (!model.tree.isNodeSlotOccupied(index) or node.kind != .image) continue;
        try synchronizeImageNode(model, effects, @intCast(index + 1), node);
    }
    model.image_tree_generation = synchronized_generation;
}

const NativeWindowLayers = struct {
    shell: native_sdk.app_manifest.WindowLayer,
    startup: native_sdk.WindowLayer,
};

fn nativeWindowLayers(manifest_layer: []const u8) NativeWindowLayers {
    if (std.mem.eql(u8, manifest_layer, "desktop")) return .{ .shell = .bottom, .startup = .bottom };
    if (std.mem.eql(u8, manifest_layer, "topmost")) return .{ .shell = .topmost, .startup = .topmost };
    return .{ .shell = .normal, .startup = .normal };
}

/// A widget's Model, allocated and set one field at a time: `.{}` would copy
/// the whole default image (4.3 MB, almost all of it the retained tree's
/// node and canvas arenas) and make it resident before the tree uses a slot.
/// The tree starts through `resetEmpty`, which leaves the arenas untouched,
/// and the Model is committed as it is touched (native_sdk.lazy_commit), so
/// those arenas cost nothing until the tree uses them.
fn createModel() !*Model {
    const model = try native_sdk.lazy_commit.create(Model);
    inline for (std.meta.fields(Model)) |field| {
        if (comptime std.mem.eql(u8, field.name, "tree")) {
            tree_mod.resetEmpty(&model.tree, std.heap.page_allocator);
        } else {
            @field(model, field.name) = field.defaultValue().?;
        }
    }
    return model;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const all_args = try init.minimal.args.toSlice(allocator);
    // Every widget runs in the shared, frozen realm (js_engine.zig), in the
    // host, under `weaver dev` and in capture alike, so a widget behaves
    // the same everywhere. A leading `--own-realms` gives each widget a
    // realm of its own instead.
    const own_realms = all_args.len >= 2 and std.mem.eql(u8, all_args[1], "--own-realms");
    js_engine.shared_realm_enabled = !own_realms;
    const args = if (own_realms) rest: {
        const rest = try allocator.alloc([:0]const u8, all_args.len - 1);
        rest[0] = all_args[0];
        @memcpy(rest[1..], all_args[2..]);
        break :rest rest;
    } else all_args;
    // The CLI's client verbs (host_lifecycle.zig): a short-lived process
    // that only touches the host's named objects and files.
    if (builtin.os.tag == .windows and args.len == 2) if (host_lifecycle.Verb.parse(args[1])) |verb| {
        const data_root = platform.dataRoot(allocator, init.environ_map.get("LOCALAPPDATA"), null) catch {
            std.debug.print("weaver-widget {s}: LOCALAPPDATA is not set; the widget host keeps its files under %LOCALAPPDATA%\\weaver\n", .{args[1]});
            std.process.exit(@intFromEnum(host_lifecycle.Exit.failed));
        };
        const paths = try host_lifecycle.Paths.of(allocator, data_root);
        std.process.exit(@intFromEnum(host_lifecycle.run(verb, init.io, allocator, paths, own_realms)));
    };
    // Shared render host mode: this process becomes the one Metal-owning
    // renderer every macOS widget talks to (weaverd spawns and supervises
    // it; docs/macos-memory-handoff.md carries the receipts). It never
    // loads a widget bundle.
    if (comptime weaver_build_options.render_host_enabled) {
        if (args.len == 3 and std.mem.eql(u8, args[1], "--render-host")) {
            const seam = struct {
                extern fn native_sdk_appkit_render_host_run(name: [*:0]const u8) c_int;
            };
            const name_z = try allocator.dupeZ(u8, args[2]);
            if (seam.native_sdk_appkit_render_host_run(name_z.ptr) != 0) return error.RenderHostStartFailed;
            return;
        }
    }
    const capture_state_root = init.environ_map.get("WEAVER_CAPTURE_STATE_ROOT");
    if (capture_state_root == null and args.len >= 2 and std.mem.eql(u8, args[1], "--host")) {
        if (builtin.os.tag == .windows and args.len >= 3 and std.mem.eql(u8, args[2], host_contract.restart_of_flag)) {
            return runHost(init, &.{}, false, true, try restartedLaunch(init, args));
        }
        return runHost(init, args[2..], false, true, null);
    }
    const dev = capture_state_root == null and args.len == 3 and std.mem.eql(u8, args[1], "--dev");
    if ((!dev and args.len != 2) or (dev and args.len != 3)) {
        // The render-host form is parsed only on macOS; advertise it only
        // where it is accepted.
        std.debug.print(if (weaver_build_options.render_host_enabled)
            "usage: weaver-widget [--own-realms] [--dev] <widget-directory> | weaver-widget [--own-realms] --host <widget-directory>... | weaver-widget --render-host <bootstrap-name>\n"
        else
            "usage: weaver-widget [--own-realms] [--dev] <widget-directory> | weaver-widget [--own-realms] --host <widget-directory>...\n", .{});
        return error.InvalidArguments;
    }
    const directory_arg: usize = if (dev) 2 else 1;
    return runHost(init, args[directory_arg .. directory_arg + 1], dev, false, null);
}

/// `--host --restart-of <generation> --localappdata <path>`: Windows
/// restarted a crashed daemon host (host_contract.restart_of_flag). Windows
/// gives a restarted process the user's default environment, so the
/// profile the crashed host ran against comes from the command line, and
/// replaces LOCALAPPDATA before anything reads it. Returns the crashed
/// host's generation.
fn restartedLaunch(init: std.process.Init, args: []const []const u8) !u64 {
    const usage = "weaver-widget --host " ++ host_contract.restart_of_flag ++ " <generation> " ++ host_contract.local_app_data_flag ++ " <path>: the command line Windows restarts a crashed widget host with";
    if (args.len != 6 or !std.mem.eql(u8, args[4], host_contract.local_app_data_flag) or args[5].len == 0) {
        std.debug.print("usage: {s}\n", .{usage});
        return error.InvalidArguments;
    }
    const generation = std.fmt.parseInt(u64, args[3], 10) catch {
        std.debug.print("usage: {s}; '{s}' is not a generation\n", .{ usage, args[3] });
        return error.InvalidArguments;
    };
    try init.environ_map.put("LOCALAPPDATA", args[5]);
    // Children (the renderer, dev widgets, the bundler) read the process's.
    var wide: [1024:0]u16 = undefined;
    const length = try std.unicode.utf8ToUtf16Le(&wide, args[5]);
    if (length >= wide.len) return error.NameTooLong;
    wide[length] = 0;
    if (SetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA"), &wide) == 0) return error.SetEnvironmentFailed;
    return generation;
}

/// Process-wide inputs every widget load shares.
const HostEnvironment = struct {
    init: std.process.Init,
    data_root: []const u8,
    log_directory: []const u8,
    capture_state_root: ?[]const u8,
    /// Where media artwork lives (WEAVER_ART_CACHE): the daemon host's own
    /// under its data root, a dev widget's from its environment, none in
    /// capture.
    art_cache_root: ?[]const u8,
    force_software: bool,
    dev: bool,
    /// Launched as `--host`: per-widget settings arrive as
    /// `<NAME>_<argument>` environment variables.
    hosted: bool,

    /// A per-widget environment setting: `name` for a one-widget launch,
    /// `name_<argument>` for the widget at that `--host` position.
    fn widgetSetting(self: HostEnvironment, comptime name: []const u8, argument: u16) ?[]const u8 {
        if (!self.hosted) return self.init.environ_map.get(name);
        var buffer: [name.len + 8]u8 = undefined;
        const key = std.fmt.bufPrint(&buffer, name ++ "_{d}", .{argument}) catch unreachable;
        return self.init.environ_map.get(key);
    }

    /// The channels of the widget at `--host` position `argument`.
    fn channels(self: HostEnvironment, argument: u16) WidgetChannels {
        return .{
            .backend_file = self.widgetSetting("WEAVER_BACKEND_FILE", argument),
            .host_pipe = self.widgetSetting("WEAVER_HOST_PIPE", argument),
            .host_endpoint = self.widgetSetting("WEAVER_HOST_ENDPOINT", argument),
        };
    }
};

/// Where a widget and the daemon talk: named by environment variables for
/// a widget on the command line, by its `add` command for one the daemon
/// adds to an anchored host.
const WidgetChannels = struct {
    /// Where the widget reports its renderer, or why it did not load.
    backend_file: ?[]const u8 = null,
    host_pipe: ?[]const u8 = null,
    host_endpoint: ?[]const u8 = null,
};

/// Stack for a thread that loads widgets: the UI thread's reservation
/// (runtime/build.zig), because bundles evaluate on it under the same
/// QuickJS recursion guard.
const loader_stack_bytes: usize = 16 * 1024 * 1024;

/// Run every widget in `directories` in this one process: one Native app,
/// one window per widget. Slot 0 is the scene's main window. A single
/// directory is the ordinary one-widget runtime.
///
/// A `--host` with no directories (Windows) is the daemon instead
/// (daemon.zig): it starts with no widget, reads the registry itself, and
/// adds and removes widgets while the others keep running. `restart_of` is
/// the crashed host's generation when Windows restarted it.
fn runHost(init: std.process.Init, directories: []const []const u8, dev: bool, hosted: bool, restart_of: ?u64) !void {
    return hostMain(init, directories, dev, hosted, restart_of) catch |err| {
        // The record says why this host stopped (a daemon host's; others
        // keep none).
        crash_record.markStoppedWith(@errorName(err));
        return err;
    };
}

fn hostMain(init: std.process.Init, directories: []const []const u8, dev: bool, hosted: bool, restart_of: ?u64) !void {
    const allocator = init.arena.allocator();
    anchored_host = hosted and builtin.os.tag == .windows and directories.len == 0;
    if (!anchored_host and directories.len == 0) {
        std.debug.print("weaver-widget --host: no widget directories; with none, --host is the daemon host, which runs only on Windows\n", .{});
        return error.InvalidArguments;
    }
    if (directories.len > max_host_widgets) {
        std.debug.print("weaver-widget --host: {d} widget directories; the limit is max_host_widgets={d}, asked for {d}\n", .{ directories.len, max_host_widgets, directories.len });
        return error.TooManyWidgets;
    }
    if (builtin.os.tag != .windows and directories.len > 1) {
        // Declared windows take an explicit origin; macOS widgets anchor to
        // the primary display through the startup window only.
        std.debug.print("weaver-widget --host runs one widget per process on this platform\n", .{});
        return error.MultiWidgetHostUnsupported;
    }
    const capture_state_root = init.environ_map.get("WEAVER_CAPTURE_STATE_ROOT");
    backend_status_io = init.io;
    const local_app_data = init.environ_map.get("LOCALAPPDATA");
    const home = init.environ_map.get("HOME");
    const data_root = if (capture_state_root) |root| root else try platform.dataRoot(allocator, local_app_data, home);
    // Capture receives its own empty state root from the CLI. Keeping the
    // branch here, beside the ordinary bootstrap, makes it impossible for a
    // headless run to inherit live storage, geometry, or per-widget logs.
    const environment: HostEnvironment = .{
        .init = init,
        .data_root = data_root,
        .log_directory = if (capture_state_root) |root|
            try std.fs.path.join(allocator, &.{ root, "logs" })
        else
            try platform.logsRoot(allocator, local_app_data, home),
        .capture_state_root = capture_state_root,
        .art_cache_root = if (capture_state_root != null)
            null
        else if (anchored_host)
            try std.fs.path.join(allocator, &.{ data_root, "artcache" })
        else
            init.environ_map.get("WEAVER_ART_CACHE"),
        .force_software = if (init.environ_map.get("WEAVER_FORCE_SOFTWARE")) |value| std.mem.eql(u8, value, "1") else false,
        .dev = dev,
        .hosted = hosted,
    };
    // That capture log is deleted with the state root, so widget diagnostics
    // also go to a file the CLI copies into the capture receipt.
    if (capture_state_root) |root| {
        widget_diagnostic.initCaptureSink(init.io, try std.fs.path.join(allocator, &.{ root, "diagnostic.txt" }));
        capture_warnings.initCaptureSink(init.io, try std.fs.path.join(allocator, &.{ root, "warnings.txt" }));
    }

    // A startup error returned from here is a clean stop, not a crash: its
    // record says `stopped` with the error, and Windows does not restart it
    // (ADR 0022).
    defer crash_record.markStopped();
    if (builtin.os.tag == .windows and anchored_host) try startDaemon(init, environment, restart_of);

    var loader: Loader = .{ .environment = environment, .directories = directories };
    const widgets = try loader.run();
    if (widgets.items.len == 0 and !anchored_host) return error.NoWidgetLoaded;
    defer for (widgets.items) |model| unloadWidget(model);

    // Every widget's faces register with the one runtime, once per face
    // (`contentFontId`).
    var fonts: std.ArrayList(HostApp.FontRegistration) = .empty;
    for (widgets.items) |model| {
        for (model.font_registrations) |registration| {
            const known = for (fonts.items) |font| {
                if (font.id == registration.id) break true;
            } else false;
            if (!known) try fonts.append(allocator, registration);
        }
    }

    // The anchor only owns the app; it is never shown and never drawn.
    const anchor_window: WindowSpec = .{
        .name = "Weaver",
        .click_through = true,
    };
    const primary = if (anchored_host) anchor_window else widgets.items[0].window;
    const primary_resizable = resize_scales_widgets and !anchored_host;
    const primary_zoom: ?f32 = if (primary_resizable) primary.zoom else null;
    if (!anchored_host) widget_log.use(widgets.items[0].log);
    const shell_views = [_]native_sdk.ShellView{.{
        .label = main_canvas_label,
        .kind = .gpu_surface,
        .fill = true,
        .role = "Weaver widget canvas",
        .accessibility_label = primary.name,
        .gpu_backend = primary.backend,
        .gpu_pixel_format = .bgra8_unorm,
        .gpu_present_mode = .timer,
        .gpu_alpha_mode = .premultiplied,
        .gpu_color_space = .srgb,
        .gpu_vsync = true,
    }};
    const shell_windows = [_]native_sdk.ShellWindow{.{
        .label = main_window_label,
        .title = primary.name,
        .width = primary.frame.width,
        .height = primary.frame.height,
        .x = primary.frame.x,
        .y = primary.frame.y,
        .resizable = primary_resizable,
        .content_zoom = primary_zoom,
        .restore_state = false,
        .titlebar = .chromeless,
        .transparent = true,
        .layer = primary.layer.shell,
        .click_through = primary.click_through,
        .no_activate = true,
        .views = &shell_views,
    }};
    var tokens = native_sdk.canvas.DesignTokens.theme(.{ .pack = .geist, .color_scheme = .dark });
    tokens.colors.background = native_sdk.canvas.Color.rgba8(0, 0, 0, 0);
    // Committed as it is touched: most of its frame scratch never is.
    const app_state = try native_sdk.lazy_commit.create(HostApp);
    HostApp.initInPlace(app_state, std.heap.page_allocator, .{
        .name = primary.name,
        .scene = .{ .windows = &shell_windows },
        .canvas_label = main_canvas_label,
        .tokens = tokens,
        .fonts = fonts.items,
        .update_fx = hostUpdate,
        .view_revision = hostViewRevision,
        .window_view_revision = hostWindowViewRevision,
        .project_update = hostProjectUpdate,
        .init_fx = hostInitEffects,
        .view = hostView,
        .window_view = hostWindowView,
        .windows_fn = hostWindows,
        .sync = hostSync,
        .window_sync = hostWindowSync,
        .on_frame = hostOnFrame,
        .window_on_frame = hostWindowOnFrame,
        .on_frame_requested = hostOnFrameRequested,
        .on_window_frame = hostOnWindowFrame,
    });
    defer app_state.destroy();
    app_state.model = .{};
    for (widgets.items) |model| app_state.model.widgets[model.slot] = model;

    // `--dev` is a one-widget mode: its listener hot-swaps slot 0.
    var dev_reload_server: dev_reload.Server = .{};
    if (dev) try dev_reload_server.start(
        init.io,
        try std.fs.path.join(allocator, &.{ directories[0], dev_reload.signal_file_name }),
        wakeFns(&dev_reload_pending)[0],
    );
    defer if (dev) {
        dev_reload_server.deinit();
        dev_reload_pending[0].store(false, .release);
    };
    defer {
        wake_runtime.store(0, .release);
        for (&provider_wake_pending) |*pending| pending.store(false, .release);
    }
    var app = app_state.app();
    app.start_fn = startRendererDiagnostics;
    if (capture_state_root != null) {
        app.capture_clock_advance_fn = advanceCaptureClock;
        app.capture_pending_fn = capturePendingWork;
        app.capture_validate_fn = validateCapture;
    }
    // Its own frame, below every live one: inlined, its marker would sit
    // inside this function's frame, above some of its live variables.
    if (builtin.os.tag == .windows and anchored_host) @call(.never_inline, discardDeadStack, .{});
    runner.runWithOptions(app, .{
        .app_name = "weaver-widget",
        .window_title = primary.name,
        .bundle_id = "com.weaver.widget",
        .default_frame = primary.frame,
        // A dragged origin places the window explicitly (macOS reads the
        // frame only when restore is set, then clamps it in AppKit); the
        // manifest anchor stays the placement until that first drag.
        .restore_state = primary.dragged,
        // Weaver owns placement persistence (debounced, per-widget,
        // atomic). The substrate's bundle-id-keyed store would make
        // every widget process rewrite one shared windows.zon on each
        // move tick.
        .persist_window_state = false,
        .primary_display_anchor = if (builtin.os.tag == .macos and !primary.dragged) primary.primary_display_anchor else null,
        .startup_window_layer = primary.layer.startup,
        .startup_click_through = primary.click_through,
        .startup_window_show = if (anchored_host) .hidden else null,
        .startup_resizable = primary_resizable,
        .startup_content_zoom = primary_zoom,
        .js_window_api = false,
    }, init) catch |err| {
        std.log.err("widget runtime stopped after platform callback failure: {s}", .{@errorName(err)});
        return err;
    };
}

/// Everything the daemon host needs before any widget loads (ADR 0022):
/// the lifecycle checks, control, its crash record and its request for a
/// restart, the renderer pipe its widgets connect to, the providers (their
/// workers start with their first subscriber), a job only it holds for its
/// dev widgets and renderer, and the management thread's state. The
/// management thread itself starts with the runtime
/// (`startRendererDiagnostics`).
fn startDaemon(init: std.process.Init, environment: HostEnvironment, restart_of: ?u64) !void {
    const allocator = std.heap.page_allocator;
    // Windows restarts only a crash its error reporting handles, and a
    // parent can turn that off for its children (rm-bench/restart-spike: a
    // host started from Git Bash inherits SEM_NOGPFAULTERRORBOX and was
    // never restarted).
    _ = SetErrorMode(0);
    // No console: notes go to <logs>\host.log.
    std.Io.Dir.cwd().createDirPath(init.io, environment.log_directory) catch {};
    host_lifecycle.logToFile(environment.log_directory);
    host_lifecycle.logStart(restart_of);
    const paths = try host_lifecycle.Paths.of(allocator, environment.data_root);
    // Windows can restart this host before the crashed one has exited, and
    // that one owns the singleton until it has: wait for it, outside the
    // lifecycle lock so `weaver down` meanwhile is not held.
    if (restart_of != null) if (crash_record.read(paths.record)) |crashed| {
        const began = GetTickCount64();
        const gone = host_lifecycle.waitForExit(crashed, host_contract.predecessor_wait_ms);
        std.debug.print("weaver-widget --host: the crashed host (pid {d}) {s} after {d} ms\n", .{ crashed.pid, if (gone) "had exited" else "had not exited (predecessor_wait_ms); starting anyway", GetTickCount64() - began });
    };
    // Starting is ordered with `weaver up` and `weaver down` by the
    // lifecycle lock (host_lifecycle.zig), held until control is published.
    const lock = host_lifecycle.Lock.acquire(host_contract.host_lock_wait_ms) catch {
        std.debug.print("weaver-widget --host: another 'weaver up' or 'weaver down' held the lifecycle lock for host_lock_wait_ms={d}; this host exits\n", .{host_contract.host_lock_wait_ms});
        daemon_mod.exitProcess(host_contract.exit_lifecycle_busy);
    };
    defer lock.release();
    // `weaver down` ran since this start was decided: a pending restart,
    // or a `weaver up` that lost the race, ends here.
    if (host_lifecycle.stopMarked(paths)) {
        std.debug.print("weaver-widget --host: 'weaver down' left the stop marker at {s}; this host exits\n", .{paths.marker});
        lock.release();
        daemon_mod.exitProcess(host_contract.exit_stopped);
    }
    // Windows restarted this host for a crash; a host `weaver up` started
    // since then consumed that crash's record, and runs or ran after it.
    if (restart_of) |crashed| {
        const current = crash_record.read(paths.record);
        if (current == null) if (crash_record.openFailure(paths.record)) |err| {
            std.debug.print("weaver-widget --host: restarted for generation {d}, but could not read the record at {s} (Win32 error {d}); without it this host cannot quarantine the widget the crash blames, so it exits. Close whatever holds the file open, then run 'weaver up'\n", .{ crashed, paths.record, err });
            lock.release();
            daemon_mod.exitProcess(host_contract.exit_record_unavailable);
        };
        if (current == null or current.?.generation != crashed) {
            std.debug.print("weaver-widget --host: restarted for generation {d}, but the record now holds {?d}: a newer host started since; this host exits\n", .{ crashed, if (current) |record| record.generation else null });
            lock.release();
            daemon_mod.exitProcess(host_contract.exit_superseded);
        }
    }
    // The singleton comes first, before any widget loads: a second host
    // leaves at once.
    const singleton = daemon_mod.Objects.claim() catch |err| switch (err) {
        error.AlreadyRunning => {
            std.debug.print("weaver-widget --host: another widget host is already running for this user; this one exits\n", .{});
            lock.release();
            daemon_mod.exitProcess(host_contract.exit_already_running);
        },
        else => return err,
    };
    std.Io.Dir.cwd().createDirPath(init.io, environment.data_root) catch {};
    // From here on, a crash is recorded. Opening the record consumes the
    // previous host's: this start takes the next generation.
    const previous = openRecord(paths.record) catch {
        // The singleton goes before the lock: a `weaver up` waiting on the
        // lock then finds no host, not one on its way out.
        daemon_mod.Objects.release(singleton);
        lock.release();
        daemon_mod.exitProcess(host_contract.exit_record_unavailable);
    };
    // This host runs: control comes up, still before any widget loads.
    const objects = try daemon_mod.Objects.publish(singleton);
    var now: u64 = 0;
    GetSystemTimeAsFileTime(&now);
    const plan = host_contract.RestartPlan.of(previous, restart_of != null, now);
    const registration: host_lifecycle.Registration = if (crash_record.generation()) |generation|
        host_lifecycle.registerRestart(plan, generation, init.environ_map.get("LOCALAPPDATA").?, !js_engine.shared_realm_enabled)
    else
        .{ .request = .none };
    crash_record.noteRestart(plan, registration.request, registration.hresult, registration.line_len);
    // Crashes fail fast from here on, so Windows restarts this host.
    var log_buffers: native_sdk.debug.LogPathBuffers = .{};
    const native_logs = try native_sdk.debug.resolveLogPaths(&log_buffers, "com.weaver.widget", native_sdk.debug.envFromMap(init.environ_map), init.environ_map.get("NATIVE_SDK_LOG_DIR"));
    std.Io.Dir.cwd().createDirPath(init.io, native_logs.log_dir) catch {};
    crash_record.routeCrashesToWindows(native_logs.panic_file);
    const renderer_pipe_name = try std.fmt.allocPrint(allocator, "\\\\.\\pipe\\weaver-renderer-{d}", .{platform.currentProcessId()});
    try daemon_mod.exportRendererPipe(renderer_pipe_name);
    // Widgets resolve media artwork under the art cache (image_paths), so
    // it must exist before any loads; the media worker owns what is in it.
    const art_cache_root = environment.art_cache_root.?;
    std.Io.Dir.cwd().createDirPath(init.io, art_cache_root) catch |err| {
        std.debug.print("weaver-widget --host: the art cache {s} could not be created: {s}; media artwork is unavailable\n", .{ art_cache_root, @errorName(err) });
    };
    const service = try allocator.create(provider_service.Service);
    service.* = .init(.{ .io = init.io, .art_cache_root = art_cache_root });
    host_providers = service;
    const devs = try allocator.create(dev_widgets_mod.DevWidgets);
    devs.* = try .init(service, init.environ_map, .{ .renderer_pipe = renderer_pipe_name, .art_cache = art_cache_root });
    control_environment = environment;
    daemon = try daemon_mod.Daemon.create(.{
        .io = init.io,
        .environment = init.environ_map,
        .data_directory = environment.data_root,
        .renderer_pipe_name = renderer_pipe_name,
        .force_software = environment.force_software,
        .service = service,
        .devs = devs,
        .post = postControl,
        .previous = previous,
        .host_note = try host_lifecycle.hostNote(allocator, previous, restart_of != null, plan, registration, !js_engine.shared_realm_enabled),
    }, objects);
}

/// Open the host's record (crash_record.open), retrying while it is in use
/// for up to `record_open_wait_ms`: it stays in use for a moment after a
/// crashed host has exited. A host that still cannot open it must not run:
/// it could not quarantine the widget the last crash blames, and would run
/// it again. `weaver up` and `weaver status` name the file and the error
/// (host_lifecycle.zig `recordUnavailable`, `describeDown`).
fn openRecord(path: []const u8) !?host_contract.Record {
    const began = GetTickCount64();
    var attempts: u32 = 0;
    while (true) {
        attempts += 1;
        const previous = crash_record.open(path) catch |err| {
            const waited = GetTickCount64() - began;
            if (err == error.RecordInUse and waited < host_contract.record_open_wait_ms) {
                Sleep(50);
                continue;
            }
            std.debug.print("weaver-widget --host: could not open the record at {s}: {s} (Win32 error {d}, {d} attempts over {d} ms); without it this host cannot quarantine the widget the last crash blames, so it exits. Close whatever holds the file open, then run 'weaver up'\n", .{ path, @errorName(err), crash_record.open_error, attempts, waited });
            return err;
        };
        if (attempts > 1) std.debug.print("weaver-widget --host: the record opened after {d} attempts over {d} ms\n", .{ attempts, GetTickCount64() - began });
        return previous;
    }
}

/// Give back the main thread's stack pages below the caller's frame before
/// the host settles into its event loop. Startup runs std.Io's Windows path
/// helpers on this thread: directory creation and path conversion have
/// 262 KiB and 197 KiB frames (dirCreateDirWindows, wToPrefixedFileW), and
/// every page they touched stayed resident for the host's life (deep dive,
/// 2026-10-17: 524 KiB of main-thread stack, 256 KiB of it in use once the
/// widgets tick). Below the caller those pages are dead; discarded, Windows
/// drops them, and a later call that reaches as deep gets fresh pages.
/// Must not be inlined (see its call).
fn discardDeadStack() void {
    const page = std.heap.page_size_min;
    const tib = &std.os.windows.teb().NtTib;
    const low = @intFromPtr(tib.StackLimit);
    var here: u8 = 0;
    // Slack under this frame for DiscardVirtualMemory's own stack: 4,296
    // bytes plus saved registers on KernelBase 10.0.26100 (review of #117);
    // eight pages leave room for other Windows builds.
    const high = std.mem.alignBackward(usize, @intFromPtr(&here), page) -| 8 * page;
    if (high <= low) return;
    _ = DiscardVirtualMemory(@ptrFromInt(low), high - low);
}

extern "kernel32" fn DiscardVirtualMemory(address: *anyopaque, size: usize) callconv(.winapi) u32;
extern "kernel32" fn SetErrorMode(mode: u32) callconv(.winapi) u32;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const u16, value: ?[*:0]const u16) callconv(.winapi) c_int;
extern "kernel32" fn GetSystemTimeAsFileTime(time: *u64) callconv(.winapi) void;

/// Hand the daemon's load or unload to the UI thread (`applyControl`).
fn postControl(pending: *host_control.Pending) void {
    control_mailbox.post(pending);
    requestExternalWake("control");
}

/// Loads every widget on a short-lived thread. Loading reads manifests,
/// bundles, fonts, images and stores through std.Io, whose Windows file
/// calls take 256-512 KiB stack frames; a thread's stack is released when it
/// exits, where the UI thread's high-water mark would stay resident for the
/// host's whole life.
const Loader = struct {
    environment: HostEnvironment,
    directories: []const []const u8,
    widgets: std.ArrayList(*Model) = .empty,
    failure: ?anyerror = null,

    fn run(self: *Loader) !std.ArrayList(*Model) {
        const thread = try std.Thread.spawn(.{ .stack_size = loader_stack_bytes }, load, .{self});
        thread.join();
        if (self.failure) |err| return err;
        return self.widgets;
    }

    fn load(self: *Loader) void {
        const allocator = self.environment.init.arena.allocator();
        std.Io.Dir.cwd().createDirPath(self.environment.init.io, self.environment.log_directory) catch |err| {
            self.failure = err;
            return;
        };
        for (self.directories, 0..) |directory, argument| {
            const slot: u16 = @intCast(self.widgets.items.len);
            const model = loadWidget(self.environment, directory, slot, self.environment.channels(@intCast(argument))) catch |err| {
                // One widget's broken install must not keep the others off
                // the desktop; a lone widget fails the process as it always
                // has.
                if (self.directories.len == 1) {
                    self.failure = err;
                    return;
                }
                std.debug.print("weaver-widget --host: skipping {s}: {s}\n", .{ directory, @errorName(err) });
                reportLoadFailure(self.environment.init.io, self.environment.channels(@intCast(argument)).backend_file, err);
                continue;
            };
            self.widgets.append(allocator, model) catch |err| {
                self.failure = err;
                return;
            };
        }
    }
};

/// Load one widget into `slot`: its manifest, log, storage, placement,
/// provider channel, and engine, then evaluate its bundle. What it
/// allocates lives in the widget's arena (`freeModel`).
fn loadWidget(environment: HostEnvironment, directory: []const u8, slot: u16, channels: WidgetChannels) !*Model {
    const init = environment.init;
    const capture_state_root = environment.capture_state_root;
    const model = try createModel();
    model.arena = .init(small_allocator);
    const allocator = (&model.arena.?).allocator();
    // A failed load must stop the provider reader and free the engine
    // before the Model goes: the host keeps running the other widgets.
    errdefer {
        unloadWidget(model);
        freeModel(model);
    }
    const loaded = try manifest_mod.load(init.io, allocator, std.heap.page_allocator, directory);
    // The engine compiles the source; keeping it would hold every widget's
    // bundle text resident for the life of the host (a dev hot swap reads
    // the file again).
    defer std.heap.page_allocator.free(loaded.bundle);
    model.slot = slot;
    model.backend_status_path = if (channels.backend_file) |path| try allocator.dupe(u8, path) else null;
    const log_name = try safeLogName(allocator, loaded.manifest.name);
    model.log = try allocator.create(widget_log.Sink);
    model.log.* = .{};
    try widget_log.init(model.log, init.io, try std.fs.path.join(allocator, &.{ environment.log_directory, log_name }));
    widget_log.use(model.log);
    std.log.info("widget runtime starting pid={d}{s}{s}", .{
        platform.currentProcessId(),
        if (environment.dev) " dev=true" else "",
        if (slot != 0) " hosted=true" else "",
    });

    const capture_provider_fixture = if (init.environ_map.get("WEAVER_CAPTURE_PROVIDER_FIXTURE")) |path|
        try loadCaptureProviderFixture(init.io, allocator, path, loaded.manifest.subscribe, loaded.manifest.capabilities)
    else
        null;
    const storage = try allocator.create(storage_mod.Store);
    storage.* = try storage_mod.Store.init(init.io, allocator, environment.data_root, loaded.manifest.name);
    const bundle_path = try std.fs.path.join(allocator, &.{ directory, "bundle.js" });
    const bundle_stat = try std.Io.Dir.cwd().statFile(init.io, bundle_path, .{});
    const geometry_store = try allocator.create(geometry_mod.Store);
    geometry_store.* = try geometry_mod.Store.init(init.io, allocator, environment.data_root, loaded.manifest.name);
    // A dragged position (and resized zoom) outranks the manifest anchor,
    // but only while it still lands on an attached display; a stale record
    // (monitor unplugged) falls back to the anchor at zoom 1. macOS
    // validates in AppKit at creation (constrainFrame), so only Windows
    // pre-checks here.
    const loaded_geometry = geometry_store.load(allocator) catch |err| geometry: {
        std.log.warn("widget geometry ignored: {s}; path={s}", .{ @errorName(err), geometry_store.path });
        break :geometry null;
    };
    const dragged: ?geometry_mod.Saved = if (loaded_geometry) |saved| geometry: {
        if (draggedOriginVisible(saved, loaded.manifest.size)) break :geometry saved;
        std.log.warn(
            "widget geometry ignored because the saved window no longer intersects an attached display: x={d} y={d} scale={d}; path={s}",
            .{ saved.x, saved.y, saved.scale, geometry_store.path },
        );
        break :geometry null;
    } else null;
    var frame = manifest_mod.desktopFrame(loaded.manifest);
    if (dragged) |saved| {
        std.log.info("widget using persisted placement x={d} y={d} zoom={d}; manifest anchor and size are overridden until the geometry record is removed: path={s}", .{ saved.x, saved.y, saved.zoom, geometry_store.path });
        frame.x = saved.x;
        frame.y = saved.y;
        // The Windows host reads a (0,0) origin as "let the system
        // place it"; nudge the exact corner case off the sentinel.
        if (builtin.os.tag == .windows and frame.x == 0 and frame.y == 0) frame.x = 0.01;
    }
    model.window = .{
        .name = loaded.manifest.name,
        .frame = frame,
        .layer = nativeWindowLayers(loaded.manifest.layer),
        .click_through = loaded.manifest.clickThrough,
        .backend = declaredGpuBackend(loaded.manifest.renderBackend, environment.force_software),
        .dragged = dragged != null,
        .zoom = if (dragged) |saved| saved.zoom else 1,
        .primary_display_anchor = manifest_mod.primaryDisplayAnchor(loaded.manifest),
    };
    const image_resolver = try allocator.create(image_paths.Resolver);
    image_resolver.* = try image_paths.Resolver.init(
        init.io,
        small_allocator,
        directory,
        environment.art_cache_root,
    );
    model.image_resolver = image_resolver;
    // Fonts load with the widget, so a missing face is this widget's
    // load failure, not the host's.
    model.font_registrations = try fontRegistrations(init.io, allocator, directory, loaded.manifest.fonts);

    model.geometry = geometry_store;
    model.fonts = loaded.manifest.fonts;
    if (dragged) |saved| model.settled_frame = saved;
    if (capture_provider_fixture) |fixture| {
        const capture_command_fixture = try allocator.create(provider_mod.CaptureCommandFixture);
        capture_command_fixture.* = .{ .commands = fixture.commands };
        model.provider.initCaptureFixture(init.io, capture_command_fixture);
    } else if (builtin.os.tag == .windows and host_providers != null and capture_state_root == null) {
        // In the anchored host: the host's own providers, in process.
        const wants = provider_service.Wants.fromManifest(loaded.manifest.subscribe, loaded.manifest.capabilities);
        if (wants.any()) {
            try model.provider.initLocal(init.io, host_providers.?, wants, slot);
        } else {
            try model.provider.init(init.io, null);
        }
    } else {
        try model.provider.init(init.io, if (capture_state_root == null)
            platform.providerEndpoint(channels.host_pipe, channels.host_endpoint)
        else
            null);
    }
    if (builtin.os.tag == .macos and weaver_build_options.automation_seam) {
        const automation = init.environ_map.get("WEAVER_AUTOMATION");
        const failure_path = init.environ_map.get("WEAVER_PROVIDER_TEST_FAIL_SEND");
        if (automation != null and std.mem.eql(u8, automation.?, "1") and failure_path != null) {
            model.provider.setAutomationSendFailurePath(failure_path.?);
        }
    }
    model.provider.setWake(wakeFns(&provider_wake_pending)[slot]);
    model.has_provider_subscriptions = hasHostProviderSubscription(loaded.manifest.subscribe);
    model.media_transport_enabled = for (loaded.manifest.capabilities) |capability| {
        if (std.mem.eql(u8, capability, "media-transport")) break true;
    } else false;
    const engine = try js_engine.Engine.create(
        small_allocator,
        &model.tree,
        storage,
        loaded.manifest.origins,
        &model.provider,
        model.media_transport_enabled,
        capture_state_root != null,
    );
    // The widget's arena owns a copy: `directory` belongs to the request.
    engine.bridge_state.bundle_directory = try allocator.dupe(u8, directory);
    if (capture_state_root != null) {
        if (init.environ_map.get("WEAVER_CAPTURE_CLOCK_EPOCH_MS")) |value| {
            const epoch_ms = std.fmt.parseInt(u64, value, 10) catch return error.CaptureClockInvalid;
            try engine.setCaptureClock(epoch_ms);
        }
    }
    // Its turns mark the crash record with its slot and bundle.
    engine.crash_slot = slot;
    engine.crash_bundle = std.hash.Wyhash.hash(0, loaded.bundle);
    model.engine = engine;
    model.io = init.io;
    model.storage = storage;
    model.origins = loaded.manifest.origins;
    model.bundle_path = bundle_path;
    model.bundle_directory = engine.bridge_state.bundle_directory;
    model.dev_seen_mtime = bundle_stat.mtime.nanoseconds;
    for (loaded.manifest.subscribe) |provider| {
        if (std.mem.eql(u8, provider, "audio")) model.provider_poll_interval_ms = 33;
    }
    try engine.evaluate(loaded.bundle, "bundle.js");
    if (capture_provider_fixture) |fixture| {
        for (fixture.frames) |frame_value| {
            var frame_writer = try std.Io.Writer.Allocating.initCapacity(std.heap.page_allocator, 256);
            defer frame_writer.deinit();
            try frame_writer.writer.print("{f}", .{std.json.fmt(frame_value, .{})});
            try engine.dispatchProviderFixture(frame_writer.written());
        }
    }
    if (init.environ_map.get("WEAVER_MEMORY_RECEIPT")) |value| {
        if (value.len != 0 and !std.mem.eql(u8, value, "0")) {
            const usage = engine.memoryUsage();
            std.log.info(
                "widget memory receipt model_bytes={d} host_app_bytes={d} tree_bytes={d} node_bytes={d} canvas_state_bytes={d} engine_bytes={d} quickjs_widget_heap_bytes={d} quickjs_widget_heap_grown_bytes={d} quickjs_runtime_malloc_bytes={d} quickjs_memory_used_bytes={d} quickjs_atoms_bytes={d} quickjs_strings_bytes={d} quickjs_objects_bytes={d} quickjs_properties_bytes={d} quickjs_shapes_bytes={d} quickjs_functions_bytes={d} quickjs_function_code_bytes={d}",
                .{
                    @sizeOf(Model),
                    @sizeOf(HostApp),
                    @sizeOf(tree_mod.Tree),
                    @sizeOf(tree_mod.Node),
                    @sizeOf(tree_mod.CanvasState),
                    @sizeOf(js_engine.Engine),
                    engine.heapBytes(),
                    engine.heapGrownBytes(),
                    usage.malloc_size,
                    usage.memory_used_size,
                    usage.atom_size,
                    usage.str_size,
                    usage.obj_size,
                    usage.prop_size,
                    usage.shape_size,
                    usage.js_func_size,
                    usage.js_func_code_size,
                },
            );
        }
    }
    if (model.tree.root == null) {
        std.log.err("widget bundle completed without rendering a root; expected the default widget() registration to render synchronously", .{});
        model.tree.showError("WidgetDidNotRenderRoot\nThe bundle completed without rendering a widget root.");
    }
    if (model.provider.fatalChannelFailure()) return error.FatalProviderChannelFailure;
    // Its bundle ran: now it may take font ids (`assignFontIds`). A widget
    // whose faces do not fit fails here, like any other load failure.
    try assignFontIds(model);
    if (loadLocalImages(init.io, allocator, directory, model)) |_| {
        seedImageStates(model) catch |err| {
            std.log.err("initial widget image state failed: {s}", .{@errorName(err)});
            var buffer: [tree_mod.max_text_bytes]u8 = undefined;
            const visible = std.fmt.bufPrint(&buffer, "image initialization failed\n{s}", .{@errorName(err)}) catch "image initialization failed; see the per-widget log";
            model.tree.showError(visible);
            model.image_count = 0;
        };
    } else |err| {
        std.log.err("initial widget image load failed: {s}", .{@errorName(err)});
        var buffer: [tree_mod.max_text_bytes]u8 = undefined;
        const visible = std.fmt.bufPrint(&buffer, "image load failed\n{s}", .{@errorName(err)}) catch "image load failed; see the per-widget log";
        model.tree.showError(visible);
        model.image_count = 0;
    }
    return model;
}

/// The daemon reads `failed:<error>` from the widget's backend status file
/// as "this widget did not load"; a running widget writes its renderer there.
fn reportLoadFailure(io: std.Io, backend_file: ?[]const u8, err: anyerror) void {
    const path = backend_file orelse return;
    var buffer: [96]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "failed:{s}", .{@errorName(err)}) catch "failed:";
    small_fs.write(io, path, text) catch {};
}

fn unloadWidget(model: *Model) void {
    widget_log.use(model.log);
    if (model.engine) |engine| engine.destroy(small_allocator);
    model.engine = null;
    model.provider.deinit();
    deinitImageStates(model);
    model.tree.deinit();
    if (model.image_resolver) |resolver| @constCast(resolver).deinit();
    model.image_resolver = null;
    widget_log.deinit(model.log);
}

/// Free an unloaded widget's Model and everything its load allocated.
fn freeModel(model: *Model) void {
    if (model.arena) |*arena| arena.deinit();
    native_sdk.lazy_commit.destroy(model);
}

/// Carry out the daemon's waiting command, if there is one. Runs on the
/// UI thread, between widget turns.
fn applyControl(host: *Host, effects: *Effects) void {
    const pending = control_mailbox.take() orelse return;
    defer pending.done.set(control_environment.?.init.io);
    const outcome = switch (pending.command) {
        .add => |add| addWidget(host, effects, add),
        .remove => |remove| removeWidget(host, effects, remove.id),
    };
    if (outcome) |_| {} else |err| pending.failure = err;
}

fn addWidget(host: *Host, effects: *Effects, add: host_control.Add) anyerror!void {
    if (add.id >= max_anchored_widgets) {
        std.log.err("control add refused: max_anchored_widgets={d}, asked for slot {d}", .{ max_anchored_widgets, add.id });
        return error.SlotOutOfRange;
    }
    if (host.widgets[add.id] != null) return error.SlotTaken;
    const started_ms = platform.monotonicMilliseconds();
    var load: WidgetLoad = .{
        .directory = add.dir,
        .slot = add.id,
        .channels = .{ .backend_file = add.backend },
    };
    const model = try load.run();
    errdefer {
        unloadWidget(model);
        freeModel(model);
    }
    try registerWidgetFonts(diagnostic_runtime.?, model);
    host.widgets[add.id] = model;
    initEffects(enter(model), .{ .fx = effects, .slot = add.id });
    std.log.info("widget added to the running host slot={d} load_ms={d}", .{ add.id, platform.monotonicMilliseconds() - started_ms });
}

/// Loads a widget the daemon adds on a short-lived thread, as `Loader`
/// does and for the same reason. The UI thread waits for it, so the
/// bundle evaluates while no other widget's code runs.
const WidgetLoad = struct {
    directory: []const u8,
    slot: u16,
    channels: WidgetChannels,
    model: ?*Model = null,
    failure: ?anyerror = null,

    fn run(self: *WidgetLoad) !*Model {
        const thread = try std.Thread.spawn(.{ .stack_size = loader_stack_bytes }, load, .{self});
        thread.join();
        if (self.failure) |err| return err;
        return self.model.?;
    }

    fn load(self: *WidgetLoad) void {
        self.model = loadWidget(control_environment.?, self.directory, self.slot, self.channels) catch |err| {
            self.failure = err;
            return;
        };
    }
};

fn removeWidget(host: *Host, effects: *Effects, slot: u16) anyerror!void {
    if (slot >= max_host_widgets) return error.SlotOutOfRange;
    const model = host.widgets[slot] orelse return error.NoWidgetInSlot;
    retireWidget(enter(model), .{ .fx = effects, .slot = slot });
    host.widgets[slot] = null;
    unloadWidget(model);
    freeModel(model);
    // Its provider reader has stopped; a wake it raised is stale.
    provider_wake_pending[slot].store(false, .release);
    dev_reload_pending[slot].store(false, .release);
}

/// Hand back what a widget holds in the shared Native runtime before it
/// unloads: its unsaved dragged position, its timers, its images.
fn retireWidget(model: *Model, effects: WidgetEffects) void {
    persistGeometry(model);
    for (model.armed_timers) |armed| {
        if (armed.id != 0) effects.cancelTimer(armed.id);
    }
    for ([_]u64{ fetch_poll_key, provider_poll_key, media_deadline_key, geometry_save_key }) |key| effects.cancelTimer(key);
    for (model.images[0..model.image_count]) |image| _ = effects.unregisterImage(image.id);
    for (model.image_states[0..model.image_state_count]) |state| {
        if (state.registered) _ = effects.unregisterImage(state.id);
    }
}

/// Route this process's logging to `model` and return it: every host hook
/// enters the widget it is about to run.
fn enter(model: *Model) *Model {
    widget_log.use(model.log);
    return model;
}

fn widgetAt(host: *const Host, slot: u16) ?*Model {
    if (slot >= host.widgets.len) return null;
    return host.widgets[slot];
}

/// The widget in `slot`, entered: its code is about to run.
fn widgetFor(host: *const Host, slot: u16) ?*Model {
    return enter(widgetAt(host, slot) orelse return null);
}

fn widgetForWindow(host: *const Host, window_label: []const u8) ?*Model {
    return widgetFor(host, slotForWindowLabel(window_label) orelse return null);
}

fn hostInitEffects(host: *Host, effects: *Effects) void {
    for (host.widgets) |slot_model| {
        const model = slot_model orelse continue;
        initEffects(enter(model), .{ .fx = effects, .slot = model.slot });
    }
}

fn hostUpdate(host: *Host, message: HostMsg, effects: *Effects) void {
    if (message.widget == every_widget) {
        // The provider and dev-reload listeners run off-thread. They only
        // publish their widget's pending bit and request a platform frame;
        // this turns that frame boundary into the ordinary update/rebuild
        // path for each widget with a wake. Static widgets therefore
        // hot-swap without borrowing a GPU completion from animation,
        // input, or resize. The daemon's control commands ride it too.
        applyControl(host, effects);
        for (host.widgets) |slot_model| {
            const model = slot_model orelse continue;
            const provider = provider_wake_pending[model.slot].swap(false, .acq_rel);
            const dev = dev_reload_pending[model.slot].swap(false, .acq_rel);
            if (!provider and !dev) continue;
            update(enter(model), .{ .external_wake = .{ .provider = provider, .dev_reload = dev } }, .{ .fx = effects, .slot = model.slot });
        }
        return;
    }
    const model = widgetFor(host, message.widget) orelse return;
    update(model, message.msg, .{ .fx = effects, .slot = message.widget });
}

fn hostView(ui: *WidgetUi, host: *const Host) WidgetUi.Node {
    if (anchored_host) return ui.panel(.{}, .{});
    return view(ui, widgetFor(host, 0).?);
}

fn hostWindowView(ui: *WidgetUi, host: *const Host, window_label: []const u8) WidgetUi.Node {
    const model = widgetForWindow(host, window_label) orelse return projectionFailurePanel(ui, true);
    return view(ui, model);
}

fn hostViewRevision(host: *const Host) u64 {
    if (anchored_host) return 0;
    return viewRevision(widgetAt(host, 0).?);
}

fn hostWindowViewRevision(host: *const Host, window_label: []const u8) u64 {
    return viewRevision(widgetAt(host, slotForWindowLabel(window_label) orelse return 0) orelse return 0);
}

/// A same-revision update for the widget whose canvas this is; every other
/// widget's canvas already shows it. The wake Msg reaches every widget.
fn hostProjectUpdate(
    runtime: *native_sdk.Runtime,
    window_id: native_sdk.platform.WindowId,
    canvas_label: []const u8,
    host: *const Host,
    message: HostMsg,
) anyerror!bool {
    const slot = slotForCanvasLabel(canvas_label) orelse return true;
    if (message.widget != slot and message.widget != every_widget) return true;
    const model = widgetFor(host, slot) orelse return true;
    return projectSameViewUpdate(runtime, window_id, canvas_label, model, message.msg);
}

fn hostSync(host: *Host, layout: native_sdk.canvas.WidgetLayoutTree) void {
    if (anchored_host) return;
    syncNativeState(widgetFor(host, 0).?, layout);
}

fn hostWindowSync(host: *Host, window_label: []const u8, layout: native_sdk.canvas.WidgetLayoutTree) void {
    syncNativeState(widgetForWindow(host, window_label) orelse return, layout);
}

fn hostOnFrame(host: *const Host, frame: native_sdk.platform.GpuFrame) ?HostMsg {
    if (anchored_host) return null;
    const msg = onFrame(widgetFor(host, 0).?, frame) orelse return null;
    return .{ .widget = 0, .msg = msg };
}

fn hostWindowOnFrame(host: *const Host, window_label: []const u8, frame: native_sdk.platform.GpuFrame) ?HostMsg {
    const model = widgetForWindow(host, window_label) orelse return null;
    const msg = onFrame(model, frame) orelse return null;
    return .{ .widget = model.slot, .msg = msg };
}

fn hostOnFrameRequested(host: *const Host) ?HostMsg {
    const wake: HostMsg = .{ .widget = every_widget, .msg = .{ .external_wake = .{ .provider = false, .dev_reload = false } } };
    if (control_mailbox.waiting()) return wake;
    for (host.widgets) |slot_model| {
        const model = slot_model orelse continue;
        if (provider_wake_pending[model.slot].load(.acquire) or dev_reload_pending[model.slot].load(.acquire)) return wake;
    }
    return null;
}

/// Every frame report maps to a Msg; the model decides what is a real
/// move. During the drag itself the OS owns the window — nothing here
/// touches JS or invalidates the presented surface.
fn hostOnWindowFrame(event: native_sdk.runtime.WindowFrameEvent) ?HostMsg {
    const runtime = diagnostic_runtime orelse return null;
    var buffer: [native_sdk.platform.max_windows]native_sdk.platform.WindowInfo = undefined;
    for (runtime.listWindows(&buffer)) |info| {
        if (info.id != event.id) continue;
        const slot = slotForWindowLabel(info.label) orelse return null;
        return .{ .widget = slot, .msg = onWindowFrame(event) };
    }
    return null;
}

/// Every slot past the main window's opens as a declared window: placed,
/// layered and rendered exactly like a startup window.
fn hostWindows(host: *const Host, scratch: *HostApp.WindowsScratch) []const HostApp.WindowDescriptor {
    var count: usize = 0;
    for (host.widgets[firstDeclaredSlot()..]) |slot_model| {
        const model = slot_model orelse continue;
        scratch.windows[count] = .{
            .label = windowLabel(model.slot),
            .canvas_label = canvasLabel(model.slot),
            .title = model.window.name,
            .width = model.window.frame.width,
            .height = model.window.frame.height,
            .x = model.window.frame.x,
            .y = model.window.frame.y,
            .resizable = resize_scales_widgets,
            .content_zoom = if (resize_scales_widgets) model.window.zoom else null,
            .titlebar = .chromeless,
            .transparent = true,
            .layer = model.window.layer.shell,
            .click_through = model.window.click_through,
            .no_activate = true,
            .gpu_backend = model.window.backend,
        };
        count += 1;
    }
    return scratch.windows[0..count];
}

/// One comptime wake callback per slot: the provider and dev-reload
/// listeners take a context-free function.
fn wakeFns(comptime pending: *[max_host_widgets]std.atomic.Value(bool)) [max_host_widgets]*const fn () void {
    var fns: [max_host_widgets]*const fn () void = undefined;
    inline for (0..max_host_widgets) |slot| {
        fns[slot] = struct {
            fn wake() void {
                pending[slot].store(true, .release);
                requestExternalWake("widget");
            }
        }.wake;
    }
    return fns;
}

fn captureWidget(context: *anyopaque) *Model {
    const app_state: *HostApp = @ptrCast(@alignCast(context));
    return enter(app_state.model.widgets[0].?);
}

fn advanceCaptureClock(context: *anyopaque, milliseconds: u64) !void {
    const engine = captureWidget(context).engine orelse return error.CaptureClockUnavailable;
    try engine.advanceCaptureClock(milliseconds);
}

fn capturePendingWork(context: *anyopaque) native_sdk.CapturePendingWork {
    const model = captureWidget(context);
    var pending_images: usize = 0;
    for (model.image_states[0..model.image_state_count]) |state| {
        if (!state.registered and state.failure == null) pending_images += 1;
    }
    return .{
        .fetches = if (model.engine) |engine| engine.activeFetchCount() else 0,
        .images = pending_images,
    };
}

fn validateCapture(context: *anyopaque) !void {
    const model = captureWidget(context);
    switch (model.provider.captureCommandValidation()) {
        .valid => {},
        .unexpected => {
            model.provider.logCaptureCommandFailure();
            return error.CaptureMediaCommandUnexpected;
        },
        .mismatch => {
            model.provider.logCaptureCommandFailure();
            return error.CaptureMediaCommandMismatch;
        },
        .missing => {
            model.provider.logCaptureCommandFailure();
            return error.CaptureMediaCommandMissing;
        },
    }
    if (model.engine) |engine| {
        if (engine.renderFailed()) return error.CaptureWidgetFailed;
    }
    if (model.depth_limit_exceeded) return error.CaptureWidgetFailed;
    reportCanvasLayoutMismatches(model);
}

/// A canvas whose retained commands were published for a different layout
/// size than the one it now has is showing stale geometry: typically a blank
/// or clipped bar. The PNG shows the symptom; this warning names the cause so
/// the receipt alone is enough to act on. With `canvasLayoutStale` in place
/// no correct widget reaches it; it is a tripwire for a regression there.
fn reportCanvasLayoutMismatches(model: *const Model) void {
    for (&model.tree.canvases, 0..) |*canvas_state, index| {
        if (!model.tree.canvas_occupied.isSet(index) or canvas_state.owner == 0 or canvas_state.command_count == 0) continue;
        if (canvas_state.command_layout_width == canvas_state.layout_width and canvas_state.command_layout_height == canvas_state.layout_height) continue;
        capture_warnings.report(
            "CanvasDrewForStaleLayout: canvas node {d} drew its last frame for a {d}x{d} layout but layout now gives it {d}x{d}; onFrame did not run after layout sized it",
            .{ canvas_state.owner, canvas_state.command_layout_width, canvas_state.command_layout_height, canvas_state.layout_width, canvas_state.layout_height },
        );
    }
}

fn loadCaptureProviderFixture(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    subscriptions: []const []const u8,
    capabilities: []const []const u8,
) !CaptureProviderFixture {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    const fixture = std.json.parseFromSliceLeaky(CaptureProviderFixture, allocator, bytes, .{
        .ignore_unknown_fields = false,
    }) catch return error.CaptureProviderFixtureInvalid;
    if (!std.mem.eql(u8, fixture.schema, "weaver.provider-fixture.v1")) return error.CaptureProviderFixtureSchemaUnsupported;
    const media_transport_enabled = for (capabilities) |capability| {
        if (std.mem.eql(u8, capability, "media-transport")) break true;
    } else false;
    if (fixture.commands.len > 0 and !media_transport_enabled) return error.CaptureProviderFixtureCapabilityRequired;
    for (fixture.commands) |command| if (!captureMediaCommandValid(command)) return error.CaptureProviderFixtureCommandInvalid;
    for (fixture.frames) |frame| {
        const object = switch (frame) {
            .object => |object| object,
            else => return error.CaptureProviderFrameInvalid,
        };
        const provider_value = object.get("provider") orelse return error.CaptureProviderFrameInvalid;
        const provider = switch (provider_value) {
            .string => |value| value,
            else => return error.CaptureProviderFrameInvalid,
        };
        if (object.get("value") == null) return error.CaptureProviderFrameInvalid;
        const declared = for (subscriptions) |subscription| {
            if (std.mem.eql(u8, provider, subscription) and !std.mem.eql(u8, provider, "time")) break true;
        } else false;
        if (!declared) return error.CaptureProviderFrameUndeclared;
    }
    for (subscriptions) |subscription| {
        if (std.mem.eql(u8, subscription, "time")) continue;
        const supplied = for (fixture.frames) |frame| {
            const object = switch (frame) {
                .object => |object| object,
                else => continue,
            };
            const provider_value = object.get("provider") orelse continue;
            const provider = switch (provider_value) {
                .string => |value| value,
                else => continue,
            };
            if (std.mem.eql(u8, subscription, provider)) break true;
        } else false;
        if (!supplied) {
            std.debug.print("capture provider fixture is missing declared provider {s}\n", .{subscription});
            return error.CaptureProviderFixtureMissingProvider;
        }
    }
    return fixture;
}

fn captureMediaCommandValid(command: provider_mod.CaptureMediaCommand) bool {
    const is_seek = std.mem.eql(u8, command.verb, "seek");
    const known_verb = is_seek or std.mem.eql(u8, command.verb, "play") or std.mem.eql(u8, command.verb, "pause") or
        std.mem.eql(u8, command.verb, "next") or std.mem.eql(u8, command.verb, "previous");
    if (!known_verb or is_seek != (command.seekMs != null)) return false;
    return command.seekMs == null or command.seekMs.? <= provider_mod.max_safe_integer;
}

test "runtime startup window layer mirrors the dynamic manifest" {
    const desktop = nativeWindowLayers("desktop");
    try std.testing.expectEqual(native_sdk.app_manifest.WindowLayer.bottom, desktop.shell);
    try std.testing.expectEqual(native_sdk.WindowLayer.bottom, desktop.startup);
    const normal = nativeWindowLayers("normal");
    try std.testing.expectEqual(native_sdk.app_manifest.WindowLayer.normal, normal.shell);
    try std.testing.expectEqual(native_sdk.WindowLayer.normal, normal.startup);
    const topmost = nativeWindowLayers("topmost");
    try std.testing.expectEqual(native_sdk.app_manifest.WindowLayer.topmost, topmost.shell);
    try std.testing.expectEqual(native_sdk.WindowLayer.topmost, topmost.startup);
}

test "capture media command seek must round-trip through JavaScript exactly" {
    try std.testing.expect(captureMediaCommandValid(.{ .verb = "seek", .seekMs = provider_mod.max_safe_integer }));
    try std.testing.expect(!captureMediaCommandValid(.{ .verb = "seek", .seekMs = provider_mod.max_safe_integer + 1 }));
}

fn buildNodeForTest(
    ui: *WidgetUi,
    model: *Model,
    id: tree_mod.NodeId,
    is_root: bool,
) WidgetUi.Node {
    return buildNode(ui, model, id, is_root);
}

fn findImageStateConst(model: *const Model, id: tree_mod.NodeId) ?*const ImageState {
    for (model.image_states[0..model.image_state_count]) |*state| {
        if (state.id == id) return state;
    }
    return null;
}

fn imageFailureLabel(state: *const ImageState) []const u8 {
    if (state.failure_label_len != 0) return state.failure_label[0..state.failure_label_len];
    return if (state.failure) |err| @errorName(err) else "ImageUnavailable";
}

fn clearImageFailure(state: *ImageState) void {
    state.failure = null;
    state.failure_label_len = 0;
}

fn recordImageFailure(state: *ImageState, err: anyerror, encoded: []const u8, context: []const u8) void {
    state.failure = err;
    state.failure_label_len = 0;
    if (err == error.ImageTooLarge) {
        if (encodedImageDimensions(encoded)) |dimensions| {
            const pixels = std.math.mul(usize, dimensions.width, dimensions.height) catch std.math.maxInt(usize);
            const asked = std.math.mul(usize, pixels, 4) catch std.math.maxInt(usize);
            const label = std.fmt.bufPrint(
                &state.failure_label,
                "ImageTooLarge\n{d}x{d} RGBA={d}\nmax_image_rgba_bytes={d}",
                .{ dimensions.width, dimensions.height, asked, max_image_rgba_bytes },
            ) catch unreachable;
            state.failure_label_len = label.len;
            std.log.err(
                "{s} failed: ImageTooLarge; dimensions={d}x{d}, max_image_rgba_bytes={d}, asked for {d}",
                .{ context, dimensions.width, dimensions.height, max_image_rgba_bytes, asked },
            );
            return;
        }
        const label = std.fmt.bufPrint(
            &state.failure_label,
            "ImageTooLarge\nmax_image_rgba_bytes={d}",
            .{max_image_rgba_bytes},
        ) catch unreachable;
        state.failure_label_len = label.len;
    } else if (err == error.ImageRegistryFull) {
        const label = std.fmt.bufPrint(
            &state.failure_label,
            "ImageRegistryFull\nmax_images={d}, asked for {d}",
            .{ max_images, max_images + 1 },
        ) catch unreachable;
        state.failure_label_len = label.len;
        std.log.err(
            "{s} failed: ImageRegistryFull; max_images={d}, asked for {d}",
            .{ context, max_images, max_images + 1 },
        );
        return;
    }
    std.log.err("{s} failed: cause={s}", .{ context, @errorName(err) });
}

const EncodedImageDimensions = struct { width: usize, height: usize };

fn encodedImageDimensions(bytes: []const u8) ?EncodedImageDimensions {
    const png_signature = "\x89PNG\r\n\x1a\n";
    if (bytes.len >= 24 and std.mem.eql(u8, bytes[0..8], png_signature)) {
        return validImageDimensions(
            std.mem.readInt(u32, bytes[16..20], .big),
            std.mem.readInt(u32, bytes[20..24], .big),
        );
    }
    if (bytes.len >= 10 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"))) {
        return validImageDimensions(
            std.mem.readInt(u16, bytes[6..8], .little),
            std.mem.readInt(u16, bytes[8..10], .little),
        );
    }
    if (bytes.len >= 26 and std.mem.eql(u8, bytes[0..2], "BM")) {
        const width = std.mem.readInt(i32, bytes[18..22], .little);
        const height = std.mem.readInt(i32, bytes[22..26], .little);
        if (width == std.math.minInt(i32) or height == std.math.minInt(i32)) return null;
        return validImageDimensions(@abs(width), @abs(height));
    }
    if (bytes.len >= 4 and bytes[0] == 0xff and bytes[1] == 0xd8) {
        var offset: usize = 2;
        while (offset + 3 < bytes.len) {
            while (offset < bytes.len and bytes[offset] != 0xff) offset += 1;
            while (offset < bytes.len and bytes[offset] == 0xff) offset += 1;
            if (offset >= bytes.len) break;
            const marker = bytes[offset];
            offset += 1;
            if (marker == 0xd8 or marker == 0xd9 or marker == 0x01 or (marker >= 0xd0 and marker <= 0xd7)) continue;
            if (offset + 2 > bytes.len) break;
            const length: usize = std.mem.readInt(u16, bytes[offset..][0..2], .big);
            if (length < 2 or length > bytes.len - offset) break;
            const is_start_of_frame = switch (marker) {
                0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf => true,
                else => false,
            };
            if (is_start_of_frame and length >= 7) {
                return validImageDimensions(
                    std.mem.readInt(u16, bytes[offset + 5 ..][0..2], .big),
                    std.mem.readInt(u16, bytes[offset + 3 ..][0..2], .big),
                );
            }
            offset += length;
        }
    }
    return null;
}

fn validImageDimensions(width: anytype, height: anytype) ?EncodedImageDimensions {
    if (width <= 0 or height <= 0) return null;
    return .{ .width = @intCast(width), .height = @intCast(height) };
}

/// A persisted origin is only trusted while a grabbable corner of the
/// widget (24 physical px each axis) still intersects the virtual
/// desktop — monitors come and go between sessions. Non-Windows
/// platforms answer true: macOS clamps in AppKit at creation.
fn draggedOriginVisible(saved: geometry_mod.Saved, size: [2]f32) bool {
    if (builtin.os.tag != .windows) return true;
    const bounds = windows_monitor.virtualScreen() orelse return true;
    const left = saved.x * saved.scale;
    const top = saved.y * saved.scale;
    const right = left + size[0] * saved.zoom * saved.scale;
    const bottom = top + size[1] * saved.zoom * saved.scale;
    const overlap_x = @min(right, @as(f32, @floatFromInt(bounds.right_px))) - @max(left, @as(f32, @floatFromInt(bounds.left_px)));
    const overlap_y = @min(bottom, @as(f32, @floatFromInt(bounds.bottom_px))) - @max(top, @as(f32, @floatFromInt(bounds.top_px)));
    return overlap_x >= 24 and overlap_y >= 24;
}

fn publishBackendStatus(model: *const Model, backend: native_sdk.platform.GpuSurfaceBackend) void {
    const io = backend_status_io orelse return;
    const path = model.backend_status_path orelse return;
    small_fs.write(io, path, backendStatusLabel(backend)) catch |err| {
        std.log.warn("widget could not publish renderer status: {s}", .{@errorName(err)});
    };
    // The Windows daemon host writes status.json only when something
    // changes or someone asks (daemon.zig): this is a change it cannot see,
    // whether the widget runs in the host or is a dev widget of its own.
    if (builtin.os.tag == .windows) requestHostStatus();
}

/// Ask the daemon host to rewrite status.json (host_contract
/// status_request_event). Nothing to ask when no host runs.
fn requestHostStatus() void {
    const Kernel = struct {
        extern "kernel32" fn OpenEventW(access: u32, inherit: std.os.windows.BOOL, name: [*:0]const u16) callconv(.winapi) ?std.os.windows.HANDLE;
        extern "kernel32" fn SetEvent(event: std.os.windows.HANDLE) callconv(.winapi) std.os.windows.BOOL;
        extern "kernel32" fn CloseHandle(handle: std.os.windows.HANDLE) callconv(.winapi) std.os.windows.BOOL;
    };
    const event_modify_state: u32 = 0x0002;
    const event = Kernel.OpenEventW(event_modify_state, .FALSE, host_contract.status_request_event) orelse return;
    _ = Kernel.SetEvent(event);
    _ = Kernel.CloseHandle(event);
}

fn backendStatusLabel(backend: native_sdk.platform.GpuSurfaceBackend) []const u8 {
    return switch (backend) {
        .metal, .d3d11 => "gpu",
        .software => "software",
        else => "-",
    };
}

fn declaredGpuBackend(render_backend: []const u8, force_software: bool) native_sdk.app_manifest.GpuSurfaceBackend {
    if (force_software) return .software;
    // ADR 0012: every healthy macOS Widget takes the measured Metal path.
    // `renderBackend` is generated internal metadata, not Widget source; it
    // remains the Windows retained/canvas selector until that lane changes.
    if (@import("builtin").os.tag == .macos) return .metal;
    if (std.mem.eql(u8, render_backend, "software")) return .software;
    return switch (@import("builtin").os.tag) {
        .windows => .d3d11,
        .macos => .metal,
        else => .none,
    };
}

/// Capture the live runtime for one present-path diagnostic. Presentation
/// selection itself belongs to Native SDK and follows the declared backend.
fn startRendererDiagnostics(context: *anyopaque, runtime: *native_sdk.Runtime) !void {
    const app_state: *HostApp = @ptrCast(@alignCast(context));
    diagnostic_runtime = runtime;
    wake_runtime.store(@intFromPtr(runtime), .release);
    var wake_pending = false;
    for (app_state.model.widgets) |slot_model| {
        const model = slot_model orelse continue;
        wake_pending = wake_pending or dev_reload_pending[model.slot].load(.acquire) or provider_wake_pending[model.slot].load(.acquire);
        _ = enter(model);
        if (model.window.backend != .software) {
            std.log.info("widget renderer selected={s} presenter=host", .{if (@import("builtin").os.tag == .macos) "metal-composite" else "gpu"});
        } else {
            std.log.info("widget renderer selected=software presenter=pixels", .{});
        }
    }
    if (wake_pending) try runtime.options.platform.services.requestFrame();
    // Every load and unload wakes the runtime, so the daemon's management
    // starts only once it can be woken.
    if (builtin.os.tag == .windows) if (daemon) |management| try management.start();
}

fn requestExternalWake(label: []const u8) void {
    const runtime_address = wake_runtime.load(.acquire);
    if (runtime_address == 0) return;
    const runtime: *native_sdk.Runtime = @ptrFromInt(runtime_address);
    runtime.options.platform.services.requestFrame() catch |err| {
        std.log.err("{s} wake failed: {s}", .{ label, @errorName(err) });
    };
}

fn safeLogName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const base_len = @max(name.len, 6);
    const output = try allocator.alloc(u8, base_len + 4);
    for (name, 0..) |byte, index| {
        output[index] = if (byte < 32 or std.mem.indexOfScalar(u8, "<>:\"/\\|?*", byte) != null) '_' else byte;
    }
    var cursor = name.len;
    while (cursor > 0 and (output[cursor - 1] == '.' or output[cursor - 1] == ' ')) : (cursor -= 1) output[cursor - 1] = '_';
    var end = name.len;
    if (name.len == 0) {
        @memcpy(output[0..6], "widget");
        end = 6;
    }
    @memcpy(output[end .. end + 4], ".log");
    return output[0 .. end + 4];
}

test {
    _ = @import("dev_reload.zig");
    _ = @import("tree.zig");
    _ = @import("geometry.zig");
    _ = @import("manifest.zig");
    _ = @import("network.zig");
    _ = @import("lazy_dll.zig");
    _ = @import("storage.zig");
    _ = @import("provider.zig");
    _ = @import("widget_diagnostic.zig");
    _ = @import("widget_log.zig");
    _ = @import("small_fs.zig");
    _ = @import("host_control.zig");
    _ = @import("crash_record.zig");
    if (builtin.os.tag == .windows) {
        _ = provider_service;
        _ = dev_widgets_mod;
        _ = daemon_mod;
        _ = host_lifecycle;
        _ = @import("provider_windows.zig");
    }
    const automatic_software_backend: native_sdk.app_manifest.GpuSurfaceBackend =
        if (@import("builtin").os.tag == .macos) .metal else .software;
    try std.testing.expectEqual(automatic_software_backend, declaredGpuBackend("software", false));
    try std.testing.expectEqual(native_sdk.app_manifest.GpuSurfaceBackend.software, declaredGpuBackend("gpu", true));
    const native_gpu_backend: native_sdk.app_manifest.GpuSurfaceBackend = switch (@import("builtin").os.tag) {
        .windows => .d3d11,
        .macos => .metal,
        else => .none,
    };
    try std.testing.expectEqual(native_gpu_backend, declaredGpuBackend("gpu", false));
}

test "renderer backend status uses the portable public spelling" {
    try std.testing.expectEqualStrings("gpu", backendStatusLabel(.metal));
    try std.testing.expectEqualStrings("software", backendStatusLabel(.software));
    try std.testing.expectEqualStrings("-", backendStatusLabel(.none));
}

test "registered canvas callbacks rearm identical frames while paused callbacks stay stopped" {
    const TestApp = struct {
        fn app(self: *@This()) native_sdk.App {
            return .{
                .context = self,
                .name = "weaver-canvas-frame-rearm",
                .source = native_sdk.platform.WebViewSource.html("<p>idle</p>"),
            };
        }
    };

    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = native_sdk.geometry.RectF.init(0, 0, 100, 50),
    });

    harness.null_platform.gpu_surface_frame_request_count = 0;
    try rearmCanvasFrameIfRegistered(&harness.runtime, 1, "canvas", false);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.gpu_surface_frame_request_count);
    try rearmCanvasFrameIfRegistered(&harness.runtime, 1, "canvas", true);
    try rearmCanvasFrameIfRegistered(&harness.runtime, 1, "canvas", true);
    try std.testing.expectEqual(@as(usize, 2), harness.null_platform.gpu_surface_frame_request_count);
}

test "registering a display callback from an idle provider update starts its frame chain" {
    const TestApp = struct {
        fn app(self: *@This()) native_sdk.App {
            return .{
                .context = self,
                .name = "weaver-canvas-frame-resume",
                .source = native_sdk.platform.WebViewSource.html("<p>idle</p>"),
            };
        }
    };

    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = native_sdk.geometry.RectF.init(0, 0, 100, 50),
    });

    const model = try std.testing.allocator.create(Model);
    defer std.testing.allocator.destroy(model);
    model.* = .{};
    model.tree.allocator = std.testing.allocator;
    defer model.tree.deinit();
    try model.provider.init(std.testing.io, null);
    defer model.provider.deinit();
    var store: storage_mod.Store = .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .directory = ".",
        .path = "weaver-canvas-frame-resume-storage.json",
        .temporary_path = "weaver-canvas-frame-resume-storage.tmp",
    };
    const engine = try js_engine.Engine.create(
        std.testing.allocator,
        &model.tree,
        &store,
        &.{},
        &model.provider,
        false,
        false,
    );
    defer engine.destroy(std.testing.allocator);
    model.engine = engine;

    const canvas_id = try model.tree.createNode(.canvas);
    try std.testing.expectEqual(@as(tree_mod.NodeId, 1), canvas_id);
    try engine.evaluate("native.onCanvasFrame(1, () => {});", "canvas-frame-resume-test.js");
    try std.testing.expect(engine.hasCanvasFrames());

    harness.null_platform.gpu_surface_frame_request_count = 0;
    try std.testing.expect(try projectSameViewUpdate(
        &harness.runtime,
        1,
        "canvas",
        model,
        .{ .external_wake = .{ .provider = true, .dev_reload = false } },
    ));
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_frame_request_count);
}

test "dev reload crosses requestFrame into the frame-requested hook exactly once" {
    const TestApp = struct {
        host: Host = .{},
        reloads: usize = 0,

        fn app(self: *@This()) native_sdk.App {
            return .{
                .context = self,
                .name = "weaver-dev-reload-wake",
                .source = native_sdk.platform.WebViewSource.html("<p>idle</p>"),
                .frame_requested_fn = frameRequested,
            };
        }

        fn frameRequested(context: *anyopaque, _: *native_sdk.Runtime) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            // The wake Msg addresses every widget; `hostUpdate` then takes
            // each widget's own pending bit, as this does for slot 0.
            if (hostOnFrameRequested(&self.host)) |msg| {
                if (msg.widget == every_widget and dev_reload_pending[0].swap(false, .acq_rel)) self.reloads += 1;
            }
        }
    };

    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const model = try createModel();
    defer native_sdk.lazy_commit.destroy(model);
    var app_state: TestApp = .{ .host = .{} };
    app_state.host.widgets[0] = model;
    const app = app_state.app();
    try harness.start(app);

    dev_reload_pending[0].store(false, .release);
    provider_wake_pending[0].store(false, .release);
    wake_runtime.store(@intFromPtr(&harness.runtime), .release);
    defer {
        wake_runtime.store(0, .release);
        dev_reload_pending[0].store(false, .release);
        provider_wake_pending[0].store(false, .release);
    }
    const notifier = try std.Thread.spawn(.{}, struct {
        fn wake() void {
            wakeFns(&dev_reload_pending)[0]();
        }
    }.wake, .{});
    notifier.join();
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.pendingFrameRequestCount());

    const frame_event = harness.null_platform.takeFrameRequest().?;
    try std.testing.expect(frame_event == .frame_requested);
    try harness.runtime.dispatchPlatformEvent(app, frame_event);
    try std.testing.expectEqual(@as(usize, 1), app_state.reloads);
    try std.testing.expect(hostOnFrameRequested(&app_state.host) == null);
}

test "transport-only capability arms no repeating provider timer" {
    try std.testing.expect(!providerTimerNeeded(false, 1000, false));
    try std.testing.expect(providerTimerNeeded(true, 1000, false));
    try std.testing.expect(!providerTimerNeeded(true, 33, true));
    try std.testing.expect(!hasHostProviderSubscription(&.{"time"}));
    try std.testing.expect(hasHostProviderSubscription(&.{ "time", "media" }));
}

test "media command deadline one-shot is exactly three seconds" {
    try std.testing.expectEqual(@as(u64, 3000), mediaDeadlineDelay(3100, 100));
    try std.testing.expectEqual(@as(u64, 1), mediaDeadlineDelay(3100, 3100));
}

test "corner radius projection preserves authored values and omits retained unset" {
    try std.testing.expectEqual(@as(?f32, 12.5), nativeCornerRadius(12.5));
    try std.testing.expectEqual(@as(?f32, null), nativeCornerRadius(-1));
}

test "painted row lowering preserves flex wrap on the inner layout node" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var model: Model = .{};
    const row = try model.tree.createNode(.row);
    const child = try model.tree.createNode(.panel);
    try model.tree.appendChild(row, child);
    try model.tree.setBackground(row, native_sdk.canvas.Color.rgb8(20, 30, 40));
    try model.tree.setFlexWrap(row, true);

    var ui = WidgetUi.init(arena_state.allocator());
    const built = try ui.finalize(buildNodeForTest(&ui, &model, row, true));
    try std.testing.expectEqual(native_sdk.canvas.WidgetKind.panel, built.root.kind);
    try std.testing.expectEqual(@as(usize, 1), built.root.children.len);
    try std.testing.expectEqual(native_sdk.canvas.WidgetKind.row, built.root.children[0].kind);
    try std.testing.expect(built.root.children[0].layout.flex_wrap);
}

test "painted boxes without a rounded utility project square corners, not the theme radius" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var model: Model = .{};
    const unset = try model.tree.createNode(.stack);
    try model.tree.setBackground(unset, native_sdk.canvas.Color.rgb8(20, 30, 40));
    const zero = try model.tree.createNode(.stack);
    try model.tree.setBackground(zero, native_sdk.canvas.Color.rgb8(20, 30, 40));
    try model.tree.setNumberProp(zero, "radius", 0);

    var ui = WidgetUi.init(arena_state.allocator());
    const built_unset = try ui.finalize(buildNodeForTest(&ui, &model, unset, true));
    try std.testing.expectEqual(native_sdk.canvas.WidgetKind.panel, built_unset.root.kind);
    try std.testing.expectEqual(@as(?f32, 0), built_unset.root.style.radius);
    var zero_ui = WidgetUi.init(arena_state.allocator());
    const built_zero = try zero_ui.finalize(buildNodeForTest(&zero_ui, &model, zero, true));
    try std.testing.expectEqual(@as(?f32, 0), built_zero.root.style.radius);
}

fn nestColumns(model: *Model, levels: usize, painted: bool) !tree_mod.NodeId {
    var inner = try model.tree.createNode(.text);
    for (0..levels) |_| {
        const column = try model.tree.createNode(.column);
        if (painted) try model.tree.setNumberProp(column, "radius", 4);
        try model.tree.appendChild(column, inner);
        inner = column;
    }
    return inner;
}

test "lowered depth counts painted layouts as two Native levels" {
    var model: Model = .{};
    // 31 plain columns around a text leaf is 32 levels, the most Native's
    // layout accepts (receipt: weaver capture renders 31 and is blank at 32).
    try std.testing.expectEqual(@as(usize, 32), loweredDepth(&model, try nestColumns(&model, 31, false)));
    try std.testing.expectEqual(@as(usize, 33), loweredDepth(&model, try nestColumns(&model, 16, true)));
    // A leaf's retained children are never built, so they add no depth.
    const slider = try model.tree.createNode(.slider);
    try model.tree.appendChild(slider, try nestColumns(&model, 40, false));
    try std.testing.expectEqual(@as(usize, 1), loweredDepth(&model, slider));
}

test "a tree deeper than max_widget_depth shows a named error instead of building" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var model: Model = .{};
    // Deep enough that building it would recurse far past the limit.
    try model.tree.setRoot(try nestColumns(&model, 300, false));
    // Pre-latch so the one-time diagnostic (a std.log.err, which fails a
    // Zig test) is skipped here; `weaver capture` covers that line.
    model.depth_limit_reported = true;
    defer projection_failed_this_view = false;
    var ui = WidgetUi.init(arena_state.allocator());
    const built = try ui.finalize(view(&ui, &model));
    try std.testing.expect(projection_failed_this_view);
    try std.testing.expect(model.depth_limit_exceeded);
    try std.testing.expectEqual(native_sdk.canvas.WidgetKind.panel, built.root.kind);
    try std.testing.expectEqual(@as(usize, 1), built.root.children.len);
    try std.testing.expect(std.mem.startsWith(u8, built.root.children[0].text, "WidgetDepthExceeded"));
}

test "panel lowers to a painted box around a column so children stack vertically" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var model: Model = .{};
    const panel = try model.tree.createNode(.panel);
    const first = try model.tree.createNode(.text);
    const second = try model.tree.createNode(.text);
    try model.tree.appendChild(panel, first);
    try model.tree.appendChild(panel, second);
    try model.tree.setNumberProp(panel, "gap", 6);

    var ui = WidgetUi.init(arena_state.allocator());
    const built = try ui.finalize(buildNodeForTest(&ui, &model, panel, true));
    try std.testing.expectEqual(native_sdk.canvas.WidgetKind.panel, built.root.kind);
    try std.testing.expectEqual(@as(f32, 0), built.root.layout.gap);
    try std.testing.expectEqual(@as(usize, 1), built.root.children.len);
    const column = built.root.children[0];
    try std.testing.expectEqual(native_sdk.canvas.WidgetKind.column, column.kind);
    try std.testing.expectEqual(@as(f32, 6), column.layout.gap);
    try std.testing.expectEqual(@as(usize, 2), column.children.len);
}

test "attached effects combine builder metadata with box and text shadows" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var model: Model = .{};
    const text_node = try model.tree.createNode(.text);
    try model.tree.setText(text_node, "styled");
    try model.tree.setNumberProp(text_node, "fontScale", 2);
    try model.tree.setTruncate(text_node, true);
    try model.tree.setShadow(text_node, .{
        .offset = .{ .dx = 0, .dy = 1 },
        .blur = 4,
        .spread = 0,
        .color = native_sdk.canvas.Color.rgb8(0, 0, 0),
    });
    try model.tree.setTextShadow(text_node, .{
        .offset = .{ .dx = 1, .dy = 2 },
        .blur = 3,
        .color = native_sdk.canvas.Color.rgb8(10, 20, 30),
    });

    var ui = WidgetUi.init(arena_state.allocator());
    const built = try ui.finalize(buildNodeForTest(&ui, &model, text_node, true));
    try std.testing.expectEqual(@as(usize, 3), built.root.immediate_commands.len);
    switch (built.root.immediate_commands[0]) {
        .text_style => |style| try std.testing.expectEqual(@as(f32, 2), style.scale),
        else => return error.TestExpectedEqual,
    }
    switch (built.root.immediate_commands[1]) {
        .box_shadow => |shadow| try std.testing.expectEqual(@as(f32, 4), shadow.blur),
        else => return error.TestExpectedEqual,
    }
    switch (built.root.immediate_commands[2]) {
        .text_shadow => |shadow| try std.testing.expectEqual(@as(f32, 3), shadow.blur),
        else => return error.TestExpectedEqual,
    }
}

test "gradient-only layout lowers through a painted wrapper and preserves painter order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var model: Model = .{ .tree = .{ .allocator = std.testing.allocator } };
    defer model.tree.deinit();
    const row = try model.tree.createNode(.row);
    const child = try model.tree.createNode(.panel);
    try model.tree.appendChild(row, child);
    try model.tree.setBackgroundGradient(row,
        \\{"v":1,"layers":[{"kind":"linear","start":[0,0.5],"end":[1,0.5],"stops":[{"offset":0,"color":"#FF0000FF"},{"offset":1,"color":"#0000FFFF"}],"spread":"repeat","interpolation":"srgb"},{"kind":"radial","center":[0.25,0.5],"radii":[0.75,1],"stops":[{"offset":0,"color":"#FFFFFFFF"},{"offset":1,"color":"#FFFFFF00"}],"spread":"pad","interpolation":"oklab"}]}
    );

    var ui = WidgetUi.init(arena_state.allocator());
    const built = try ui.finalize(buildNodeForTest(&ui, &model, row, true));
    try std.testing.expectEqual(native_sdk.canvas.WidgetKind.panel, built.root.kind);
    try std.testing.expectEqual(@as(usize, 1), built.root.children.len);
    try std.testing.expectEqual(native_sdk.canvas.WidgetKind.row, built.root.children[0].kind);
    try std.testing.expectEqual(@as(usize, 2), built.root.immediate_commands.len);
    switch (built.root.immediate_commands[0]) {
        .background_gradient => |gradient| switch (gradient) {
            .linear => |linear| {
                try std.testing.expectEqual(native_sdk.canvas.GradientSpread.repeat, linear.spread);
                try std.testing.expectEqual(native_sdk.canvas.GradientInterpolation.srgb, linear.interpolation);
            },
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
    switch (built.root.immediate_commands[1]) {
        .background_gradient => |gradient| switch (gradient) {
            .radial => |radial| {
                try std.testing.expectEqual(native_sdk.geometry.PointF.init(0.25, 0.5), radial.center);
                try std.testing.expectEqual(native_sdk.canvas.GradientInterpolation.oklab, radial.interpolation);
            },
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}

test "path icon projection parses normalized geometry and preserves viewBox stroke and color" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var model: Model = .{ .tree = .{ .allocator = std.testing.allocator } };
    defer model.tree.deinit();
    const icon_node = try model.tree.createNode(.icon);
    try model.tree.setIconPath(icon_node, "M 1 2 L 3 4 C 5 6 7 8 9 10 Z");
    try model.tree.setIconViewBox(icon_node, "-2 -3 30 18");
    try model.tree.setNumberProp(icon_node, "iconStroke", 1.5);
    try model.tree.setNumberProp(icon_node, "width", 48);
    try model.tree.setNumberProp(icon_node, "height", 24);
    try model.tree.setTextColor(icon_node, native_sdk.canvas.Color.rgb8(251, 191, 36));

    var ui = WidgetUi.init(arena_state.allocator());
    const built = try ui.finalize(buildNodeForTest(&ui, &model, icon_node, true));
    try std.testing.expectEqual(native_sdk.canvas.WidgetKind.icon, built.root.kind);
    try std.testing.expectEqual(@as(f32, 48), built.root.frame.width);
    try std.testing.expectEqual(@as(f32, 24), built.root.frame.height);
    try std.testing.expectEqual(@as(usize, 1), built.root.immediate_commands.len);
    switch (built.root.immediate_commands[0]) {
        .icon_path => |path| {
            try std.testing.expectEqual(native_sdk.geometry.RectF.init(-2, -3, 30, 18), path.view_box);
            try std.testing.expectEqual(@as(f32, 1.5), path.stroke_width);
            try std.testing.expectEqual(@as(usize, 4), path.elements.len);
            try std.testing.expectEqual(native_sdk.canvas.PathVerb.cubic_to, path.elements[2].verb);
            try std.testing.expectEqual(native_sdk.geometry.PointF.init(9, 10), path.elements[2].points[2]);
        },
        else => return error.TestExpectedEqual,
    }
}

test "a widget whose new faces do not all fit takes no font ids" {
    const saved_count = content_font_count;
    defer content_font_count = saved_count;
    // One id left.
    content_font_count = content_fonts.len - 1;
    for (content_fonts[0..content_font_count], 0..) |*font, index| font.* = .{ .hash = index, .len = 0, .id = native_sdk.canvas.min_registered_font_id + index };
    const model = try createModel();
    defer native_sdk.lazy_commit.destroy(model);
    var two = [_]HostApp.FontRegistration{ .{ .id = 0, .name = "a", .ttf = "face a" }, .{ .id = 0, .name = "b", .ttf = "face b" } };
    model.font_registrations = &two;
    try std.testing.expectError(error.FontRegistryFull, assignFontIds(model));
    try std.testing.expectEqual(content_fonts.len - 1, content_font_count);
    // The same face twice is one new face, and it fits.
    var repeated = [_]HostApp.FontRegistration{ .{ .id = 0, .name = "a", .ttf = "face a" }, .{ .id = 0, .name = "a2", .ttf = "face a" } };
    model.font_registrations = &repeated;
    try assignFontIds(model);
    try std.testing.expectEqual(content_fonts.len, content_font_count);
    try std.testing.expectEqual(repeated[0].id, repeated[1].id);
}

test "showcase headline keeps exact registered face through bold and text shadow" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var model: Model = .{};
    const text_node = try model.tree.createNode(.text);
    try model.tree.setText(text_node, "SECOND NATURE");
    try model.tree.setNumberProp(text_node, "fontScale", 30.0 / 14.0);
    try model.tree.setNumberProp(text_node, "lineHeight", 1.2);
    try model.tree.setNumberProp(text_node, "letterSpacing", 0.75);
    try model.tree.setFontFamily(text_node, "GeistPixel-Square");
    try model.tree.setFontWeight(text_node, "bold");
    try model.tree.setTextShadow(text_node, .{
        .offset = .{ .dx = 0, .dy = 8 },
        .blur = 10,
        .color = native_sdk.canvas.Color.rgba8(0, 0, 0, 128),
    });
    const fonts = [_]manifest_mod.Font{.{
        .id = 65,
        .name = "GeistPixel-Square.ttf",
        .stem = "GeistPixel-Square",
        .family = "GeistPixel",
        .weight = .regular,
        .file = "assets/GeistPixel-Square.ttf",
    }};
    model.fonts = &fonts;
    // Registered under the id of its contents, not its manifest id.
    var registrations = [_]HostApp.FontRegistration{.{ .id = 70, .name = "GeistPixel-Square.ttf", .ttf = "" }};
    model.font_registrations = &registrations;

    var ui = WidgetUi.init(arena_state.allocator());
    const built = try ui.finalize(buildNodeForTest(&ui, &model, text_node, true));
    try std.testing.expectEqual(@as(usize, 3), built.root.immediate_commands.len);
    switch (built.root.immediate_commands[0]) {
        .text_style => |style| {
            try std.testing.expectEqual(@as(f32, 36), style.line_height);
            try std.testing.expectEqual(@as(f32, 0.75), style.letter_spacing);
        },
        else => return error.TestExpectedEqual,
    }
    switch (built.root.immediate_commands[1]) {
        .text_shadow => |shadow| try std.testing.expectEqual(@as(f32, 10), shadow.blur),
        else => return error.TestExpectedEqual,
    }
    switch (built.root.immediate_commands[2]) {
        .text_font => |font_id| try std.testing.expectEqual(@as(native_sdk.canvas.FontId, 70), font_id),
        else => return error.TestExpectedEqual,
    }
}

test "attached shadows preserve hover and pressed metadata" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var model: Model = .{};
    const panel = try model.tree.createNode(.panel);
    try model.tree.setNumberProp(panel, "hoverOpacity", 0.8);
    try model.tree.setNumberProp(panel, "pressedOpacity", 0.6);
    try model.tree.setInteractionShadow(panel, "pressedShadow", .{
        .offset = .{ .dy = 2 },
        .blur = 4,
        .color = native_sdk.canvas.Color.rgba8(0, 0, 0, 77),
    }, true);
    try model.tree.setInteractionShadowInset(panel, "pressedShadowInset", true);
    try model.tree.setShadow(panel, .{
        .offset = .{ .dx = 0, .dy = 2 },
        .blur = 4,
        .spread = 0,
        .color = native_sdk.canvas.Color.rgb8(0, 0, 0),
    });

    var ui = WidgetUi.init(arena_state.allocator());
    const built = try ui.finalize(buildNodeForTest(&ui, &model, panel, true));
    try std.testing.expectEqual(@as(usize, 3), built.root.immediate_commands.len);
    switch (built.root.immediate_commands[0]) {
        .hover_style => |style| try std.testing.expectEqual(@as(?f32, 0.8), style.opacity),
        else => return error.TestExpectedEqual,
    }
    switch (built.root.immediate_commands[1]) {
        .pressed_style => |style| {
            try std.testing.expectEqual(@as(?f32, 0.6), style.opacity);
            switch (style.shadow) {
                .value => |shadow| {
                    try std.testing.expectEqual(@as(f32, 4), shadow.blur);
                    try std.testing.expect(shadow.inset);
                },
                else => return error.TestExpectedEqual,
            }
        },
        else => return error.TestExpectedEqual,
    }
    switch (built.root.immediate_commands[2]) {
        .box_shadow => |shadow| try std.testing.expectEqual(@as(f32, 4), shadow.blur),
        else => return error.TestExpectedEqual,
    }
}

test "bundled font resolution honors exact stems families and nearest weights" {
    var tree: tree_mod.Tree = .{};
    const id = try tree.createNode(.text);
    const fonts = [_]manifest_mod.Font{
        .{ .id = 64, .name = "Display-Regular.ttf", .stem = "Display-Regular", .family = "Display", .weight = .regular, .file = "Display-Regular.ttf" },
        .{ .id = 65, .name = "Display-Bold.ttf", .stem = "Display-Bold", .family = "Display", .weight = .bold, .file = "Display-Bold.ttf" },
    };
    try tree.setFontFamily(id, "Display");
    try tree.setFontWeight(id, "semibold");
    try std.testing.expectEqual(@as(?native_sdk.canvas.FontId, 65), resolveManifestFontId(try tree.nodeConst(id), &fonts));
    try tree.setFontFamily(id, "Display-Regular");
    try tree.setFontWeight(id, "bold");
    try std.testing.expectEqual(@as(?native_sdk.canvas.FontId, 64), resolveManifestFontId(try tree.nodeConst(id), &fonts));
    try tree.setFontFamily(id, "sans");
    try std.testing.expectEqual(@as(?native_sdk.canvas.FontId, null), resolveManifestFontId(try tree.nodeConst(id), &fonts));
    try tree.setFontFamily(id, "mono");
    try std.testing.expectEqual(@as(?native_sdk.canvas.FontId, native_sdk.canvas.default_mono_font_id), resolveManifestFontId(try tree.nodeConst(id), &fonts));
}

test "painted retained stack keeps overlay children under rounded inset shadow" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var model: Model = .{};
    const stack_id = try model.tree.createNode(.stack);
    const background_id = try model.tree.createNode(.panel);
    const label_id = try model.tree.createNode(.text);
    try model.tree.setNumberProp(stack_id, "width", 120);
    try model.tree.setNumberProp(stack_id, "height", 64);
    try model.tree.setNumberProp(stack_id, "radius", 14);
    try model.tree.setNumberProp(stack_id, "radiusBottomLeft", 3);
    try model.tree.setOverflowHidden(stack_id, true);
    try model.tree.setShadow(stack_id, .{
        .offset = .{ .dx = 0, .dy = 0 },
        .blur = 4,
        .spread = 0,
        .color = native_sdk.canvas.Color.rgb8(0, 0, 0),
    });
    try model.tree.setShadowInset(stack_id, true);
    try model.tree.setText(label_id, "overlay");
    try model.tree.appendChild(stack_id, background_id);
    try model.tree.appendChild(stack_id, label_id);

    var ui = WidgetUi.init(arena_state.allocator());
    const built = try ui.finalize(buildNodeForTest(&ui, &model, stack_id, false));
    try std.testing.expectEqual(native_sdk.canvas.WidgetKind.panel, built.root.kind);
    try std.testing.expect(built.root.layout.flags.clip_content);
    try std.testing.expectEqual(@as(?f32, 14), built.root.style.radius);
    try std.testing.expectEqual(@as(?f32, 3), built.root.cornerRadii().bottom_left);
    try std.testing.expectEqual(@as(usize, 2), built.root.immediate_commands.len);
    switch (built.root.immediate_commands[0]) {
        .box_shadow => |shadow| try std.testing.expect(shadow.inset),
        else => return error.TestExpectedEqual,
    }
    switch (built.root.immediate_commands[1]) {
        .corner_radii => |radii| try std.testing.expectEqual(@as(?f32, 3), radii.bottom_left),
        else => return error.TestExpectedEqual,
    }
    try std.testing.expectEqual(@as(usize, 1), built.root.children.len);
    const overlay = built.root.children[0];
    try std.testing.expectEqual(native_sdk.canvas.WidgetKind.stack, overlay.kind);
    try std.testing.expectEqual(@as(usize, 2), overlay.children.len);
    try std.testing.expectEqual(native_sdk.canvas.WidgetKind.panel, overlay.children[0].kind);
    try std.testing.expectEqual(native_sdk.canvas.WidgetKind.text, overlay.children[1].kind);
}

test "rounded overflow stack projects a canvas child under the native clip" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var model: Model = .{};
    const stack_id = try model.tree.createNode(.stack);
    const canvas_id = try model.tree.createNode(.canvas);
    try model.tree.setNumberProp(stack_id, "width", 100);
    try model.tree.setNumberProp(stack_id, "height", 100);
    try model.tree.setNumberProp(stack_id, "radius", 24);
    try model.tree.setOverflowHidden(stack_id, true);
    try model.tree.setNumberProp(canvas_id, "width", 100);
    try model.tree.setNumberProp(canvas_id, "height", 100);
    try model.tree.appendChild(stack_id, canvas_id);

    var ui = WidgetUi.init(arena_state.allocator());
    const built = try ui.finalize(buildNodeForTest(&ui, &model, stack_id, false));
    try std.testing.expectEqual(native_sdk.canvas.WidgetKind.panel, built.root.kind);
    try std.testing.expect(built.root.layout.flags.clip_content);
    try std.testing.expectEqual(@as(?f32, 24), built.root.style.radius);
    try std.testing.expectEqual(@as(usize, 1), built.root.children.len);
    const overlay = built.root.children[0];
    try std.testing.expectEqual(native_sdk.canvas.WidgetKind.stack, overlay.kind);
    try std.testing.expectEqual(@as(usize, 1), overlay.children.len);
    try std.testing.expectEqual(native_sdk.canvas.WidgetKind.stack, overlay.children[0].kind);
    try std.testing.expectEqual(@as(usize, 0), overlay.children[0].immediate_commands.len);
}

test "styled Weaver button prefers its explicit accessible name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var model: Model = .{};
    const button_id = try model.tree.createNode(.button);
    const label_id = try model.tree.createNode(.text);
    try model.tree.setText(label_id, "Start");
    try model.tree.appendChild(button_id, label_id);
    try model.tree.setAccessibilityLabel(button_id, "Start timer");
    (try model.tree.node(button_id)).handles_press = true;

    var ui = WidgetUi.init(arena_state.allocator());
    const projected = buildNodeForTest(&ui, &model, button_id, false);
    try std.testing.expectEqual(native_sdk.canvas.WidgetRole.button, projected.widget.semantics.role);
    try std.testing.expectEqualStrings("Start timer", projected.widget.semantics.label);
    try std.testing.expect(projected.widget.semantics.actions.press);
}

test "retained slider projects its explicit accessible name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var model: Model = .{};
    const slider_id = try model.tree.createNode(.slider);
    try model.tree.setAccessibilityLabel(slider_id, "Session length");
    (try model.tree.node(slider_id)).handles_change = true;

    var ui = WidgetUi.init(arena_state.allocator());
    const projected = buildNodeForTest(&ui, &model, slider_id, false);
    try std.testing.expectEqual(native_sdk.canvas.WidgetKind.slider, projected.widget.kind);
    try std.testing.expectEqualStrings("Session length", projected.widget.semantics.label);
}

test "retained image projects fit tiling and class corner radii" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var model: Model = .{};
    const image_id = try model.tree.createNode(.image);
    try model.tree.setImageFit(image_id, "contain");
    try model.tree.setImageTile(image_id, true);
    try model.tree.setNumberProp(image_id, "radius", 12);
    try model.tree.setNumberProp(image_id, "radiusTopRight", 3);

    var ui = WidgetUi.init(arena_state.allocator());
    const projected = buildNodeForTest(&ui, &model, image_id, false);
    try std.testing.expectEqual(native_sdk.canvas.WidgetKind.image, projected.widget.kind);
    try std.testing.expectEqual(native_sdk.canvas.ImageFit.contain, projected.widget.image_fit);
    try std.testing.expect(projected.widget.image_tile);
    try std.testing.expectEqual(@as(?f32, 12), projected.widget.style.radius);
    try std.testing.expectEqual(@as(?f32, 3), projected.widget.cornerRadii().top_right);
}

test "a widget's Model is committed as it is touched" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const before = testPrivateBytes();
    const model = try createModel();
    defer native_sdk.lazy_commit.destroy(model);
    // 4.3 MB of node and canvas capacity; a fresh Model touches its fields only.
    try std.testing.expect(@sizeOf(Model) > 4 * 1024 * 1024);
    try std.testing.expect(testPrivateBytes() -| before < 1024 * 1024);
}

/// This process's commit charge (private bytes): what a test pins a
/// structure's commit against.
fn testPrivateBytes() usize {
    const Counters = extern struct {
        cb: u32,
        page_fault_count: u32,
        peak_working_set_size: usize,
        working_set_size: usize,
        quota_peak_paged_pool_usage: usize,
        quota_paged_pool_usage: usize,
        quota_peak_non_paged_pool_usage: usize,
        quota_non_paged_pool_usage: usize,
        pagefile_usage: usize,
        peak_pagefile_usage: usize,
        private_usage: usize,
    };
    const api = struct {
        extern "kernel32" fn K32GetProcessMemoryInfo(process: std.os.windows.HANDLE, counters: *Counters, size: u32) callconv(.winapi) std.os.windows.BOOL;
        extern "kernel32" fn GetCurrentProcess() callconv(.winapi) std.os.windows.HANDLE;
    };
    var counters = std.mem.zeroes(Counters);
    counters.cb = @sizeOf(Counters);
    _ = api.K32GetProcessMemoryInfo(api.GetCurrentProcess(), &counters, counters.cb);
    return counters.private_usage;
}
