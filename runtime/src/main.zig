const std = @import("std");
const builtin = @import("builtin");
const weaver_build_options = @import("weaver_build_options");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const geometry_mod = @import("geometry.zig");
const dev_reload = @import("dev_reload.zig");
const image_paths = @import("image_paths.zig");
const js_engine = @import("js_engine.zig");
const manifest_mod = @import("manifest.zig");
const provider_mod = @import("provider.zig");
const platform = @import("platform/root.zig");
const storage_mod = @import("storage.zig");
const windows_monitor = if (builtin.os.tag == .windows) @import("platform/windows_monitor.zig") else struct {};
const tree_mod = @import("tree.zig");
const widget_log = @import("widget_log.zig");

comptime {
    if (native_sdk.platform.max_windows != 1 or
        native_sdk.platform.max_views != 1 or
        native_sdk.platform.max_webviews != 1 or
        native_sdk.runtime.max_canvas_commands_per_view != 2048 or
        native_sdk.runtime.max_canvas_path_elements_per_view != 2048 or
        native_sdk.runtime.max_canvas_widget_nodes_per_view != 1024)
    {
        @compileError("Weaver runtime must be built with the Native SDK widget profile");
    }
}

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);
pub const std_options: std.Options = .{ .logFn = widget_log.logFn };

pub const Model = struct {
    tree: tree_mod.Tree = .{},
    engine: ?*js_engine.Engine = null,
    provider: provider_mod.Client = .{},
    io: ?std.Io = null,
    storage: ?*storage_mod.Store = null,
    origins: []const []const u8 = &.{},
    bundle_path: []const u8 = &.{},
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
    /// Last origin we consider settled (launch placement or the last
    /// persisted drag), in the platform's logical window space. Null
    /// until the first platform frame report names the launch position.
    frame_origin: ?[2]f32 = null,
    pending_frame: ?geometry_mod.Saved = null,
};

const ArmedTimer = struct { id: u64 = 0, interval_ms: u64 = 0 };
fn bridgeTimerCapacity() usize {
    return @import("bridge.zig").max_timers;
}
// Image receipt (2026-07-30): executing every shipped example measured six
// retained images at worst (noro-shell). Sixteen leaves 2.7x slot headroom and
// pins the Native SDK's runtime-wide registry. Pixel buffers are undefined
// fixed address space and pages touch only as images register.
const max_images: usize = 16;
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

pub const Msg = union(enum) {
    timer: native_sdk.EffectTimer,
    press: native_sdk.canvas.WidgetPressEvent,
    double_press: native_sdk.canvas.WidgetPressEvent,
    right_press: native_sdk.canvas.WidgetPressEvent,
    slider: tree_mod.NodeId,
    canvas_frame: u64,
    external_wake: struct { provider: bool, dev_reload: bool },
    frame_moved: geometry_mod.Saved,
};

const WidgetApp = native_sdk.UiAppWithFeatures(Model, Msg, .{ .runtime_markup = false });
const WidgetUi = WidgetApp.Ui;
const Effects = WidgetApp.Effects;
var rendered_presents: u64 = 0;
var first_render_ns: u64 = 0;
var logged_backend: bool = false;
var logged_present_path: bool = false;
var last_backend: native_sdk.platform.GpuSurfaceBackend = .none;
var requested_software_backend: bool = false;
var diagnostic_runtime: ?*native_sdk.Runtime = null;
var wake_runtime = std.atomic.Value(usize).init(0);
var dev_reload_pending = std.atomic.Value(bool).init(false);
var provider_wake_pending = std.atomic.Value(bool).init(false);
var backend_status_io: ?std.Io = null;
var backend_status_path: ?[]const u8 = null;
var projection_failed_this_view: bool = false;
var projection_failure_latched: bool = false;

fn initEffects(model: *Model, effects: *Effects) void {
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
fn update(model: *Model, msg: Msg, effects: *Effects) void {
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
            const known = model.frame_origin orelse {
                // The first platform report names the launch placement
                // (creation/focus echo). The anchor — or the restored
                // origin — stays authoritative until the user actually
                // moves the window.
                model.frame_origin = .{ moved.x, moved.y };
                return;
            };
            if (@abs(known[0] - moved.x) < 0.5 and @abs(known[1] - moved.y) < 0.5) return;
            model.frame_origin = .{ moved.x, moved.y };
            model.pending_frame = moved;
            // OS drags report continuously. Re-starting the same key
            // REPLACES the pending one-shot, so the disk write lands
            // once, after the gesture settles.
            effects.startTimer(.{
                .key = geometry_save_key,
                .interval_ms = 400,
                .mode = .one_shot,
                .on_fire = Effects.timerMsg(.timer),
            });
        },
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

fn dispatchPressEvent(model: *Model, effects: *Effects, kind: []const u8, event: native_sdk.canvas.WidgetPressEvent) void {
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

/// A dragged position is user state, not widget source (ADR 0004/0011):
/// it lands in its own per-widget geometry record, never in the
/// installed manifest and never in the widget's JS-visible storage doc.
fn persistGeometry(model: *Model) void {
    const pending = model.pending_frame orelse return;
    model.pending_frame = null;
    const store = model.geometry orelse return;
    store.save(pending) catch |err| {
        std.log.warn("widget could not persist dragged position: {s}", .{@errorName(err)});
        return;
    };
    std.log.info("widget position persisted x={d} y={d}", .{ pending.x, pending.y });
}

/// Every frame report maps to a Msg; the model decides what is a real
/// move. During the drag itself the OS owns the window — nothing here
/// touches JS or invalidates the presented surface.
fn onWindowFrame(event: native_sdk.runtime.WindowFrameEvent) ?Msg {
    return Msg{ .frame_moved = .{
        .x = event.frame.x,
        .y = event.frame.y,
        .scale = event.scale_factor,
    } };
}

fn drainProviderFrames(model: *Model, _: *Effects) !void {
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

fn dispatchProviderFrames(model: *Model, effects: *Effects, trigger: []const u8) void {
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

fn reloadIfChanged(model: *Model, effects: *Effects) !void {
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
    const candidate_tree = try std.heap.page_allocator.create(tree_mod.Tree);
    candidate_tree.* = .{};
    var candidate_tree_moved = false;
    defer {
        if (!candidate_tree_moved) candidate_tree.deinit();
        std.heap.page_allocator.destroy(candidate_tree);
    }
    var preserved = snapshot != null;
    const candidate = evaluateCandidate(model, candidate_tree, source, snapshot) catch |err| switch (err) {
        error.HotSwapMismatch => block: {
            preserved = false;
            candidate_tree.deinit();
            candidate_tree.* = .{};
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
    old_engine.destroy(std.heap.page_allocator);
    model.dev_seen_mtime = mtime;
    syncTimers(model, effects);
    std.log.info("dev hot swap applied ({s} root hook state)", .{if (preserved) "preserved" else "fresh"});
}

fn evaluateCandidate(model: *Model, tree: *tree_mod.Tree, source: []const u8, seed: ?[]const u8) !*js_engine.Engine {
    const storage = model.storage orelse return error.MissingStorage;
    const candidate = try js_engine.Engine.create(
        std.heap.page_allocator,
        tree,
        storage,
        model.origins,
        &model.provider,
        model.media_transport_enabled,
    );
    errdefer candidate.destroy(std.heap.page_allocator);
    if (seed) |value| try candidate.setHotSwapSeed(value);
    try candidate.evaluate(source, "bundle.js");
    if (candidate.renderFailed()) return error.CandidateFirstRenderFailed;
    if (tree.root == null) return error.CandidateDidNotRenderRoot;
    if (seed != null and !candidate.hotSwapAccepted()) return error.HotSwapMismatch;
    return candidate;
}

fn syncTimers(model: *Model, effects: *Effects) void {
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
        effects.startTimer(.{
            .key = timer.id,
            .interval_ms = timer.interval_ms,
            .mode = .repeating,
            .on_fire = Effects.timerMsg(.timer),
        });
        armed.* = .{ .id = timer.id, .interval_ms = timer.interval_ms };
    }
    if (engine.hasActiveFetches() and !model.fetch_poll_armed) {
        effects.startTimer(.{
            .key = fetch_poll_key,
            .interval_ms = 25,
            .mode = .repeating,
            .on_fire = Effects.timerMsg(.timer),
        });
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
        effects.startTimer(.{
            .key = provider_poll_key,
            .interval_ms = provider_interval_ms,
            .mode = .repeating,
            .on_fire = Effects.timerMsg(.timer),
        });
        model.provider_poll_armed = true;
    } else if (!needs_provider_timer and model.provider_poll_armed) {
        effects.cancelTimer(provider_poll_key);
        model.provider_poll_armed = false;
    }
    const deadline_ms = engine.nextMediaDeadlineMs();
    if (deadline_ms) |deadline| {
        if (model.media_deadline_ms != deadline) {
            const now_ms = model.provider.nowMilliseconds();
            effects.startTimer(.{
                .key = media_deadline_key,
                .interval_ms = mediaDeadlineDelay(deadline, now_ms),
                .mode = .one_shot,
                .on_fire = Effects.timerMsg(.timer),
            });
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

fn onFrame(model: *const Model, frame: native_sdk.platform.GpuFrame) ?Msg {
    if (!logged_backend) {
        logged_backend = true;
        std.log.info("widget host surface backend={s}", .{@tagName(frame.backend)});
        publishBackendStatus(frame.backend);
    } else if (frame.backend != last_backend) {
        if ((last_backend == .d3d11 or last_backend == .metal) and frame.backend == .software) {
            std.log.warn("widget renderer demoted {s} -> software", .{@tagName(last_backend)});
        } else if (last_backend == .software and (frame.backend == .d3d11 or frame.backend == .metal)) {
            std.log.info("widget renderer promoted software -> {s}", .{@tagName(frame.backend)});
        } else {
            std.log.info("widget renderer backend changed {s} -> {s}", .{ @tagName(last_backend), @tagName(frame.backend) });
        }
        publishBackendStatus(frame.backend);
    }
    last_backend = frame.backend;
    if (!logged_present_path) {
        if (diagnostic_runtime) |runtime| {
            var view_buffer: [1]native_sdk.platform.ViewInfo = undefined;
            for (runtime.listViews(frame.window_id, &view_buffer)) |view_info| {
                if (!std.mem.eql(u8, view_info.label, frame.label)) continue;
                logged_present_path = true;
                std.log.info("widget presenter path={s}", .{@tagName(view_info.gpu_present_path)});
            }
        }
    }
    const engine = model.engine orelse return null;
    const canvas_clock = engine.hasCanvasFrames();
    if (!canvas_clock) return null;
    // Hybrid presentation now rejects a clean completion revision before it
    // reaches the renderer. The completion event itself is the 60 Hz canvas
    // clock, so do not suppress it by comparing the pre-present revision in
    // the platform event; doing so parks max-rate canvases after frame one.
    if (first_render_ns == 0) first_render_ns = frame.timestamp_ns;
    rendered_presents += 1;
    if (rendered_presents % 300 == 0) {
        const elapsed_ns = frame.timestamp_ns -| first_render_ns;
        std.log.info("widget present: {d} rendered frames in {d} ms", .{ rendered_presents, elapsed_ns / std.time.ns_per_ms });
    }
    return Msg{ .canvas_frame = frame.timestamp_ns };
}

/// The dev bundle listener runs off-thread. It only publishes the atomic
/// pending bit and requests a platform frame; this loop-thread hook turns
/// that frame boundary into the ordinary update/rebuild path. Static widgets
/// therefore hot-swap without borrowing a GPU completion from animation,
/// input, or resize.
fn onFrameRequested(_: *const Model) ?Msg {
    const provider = provider_wake_pending.swap(false, .acq_rel);
    const dev = dev_reload_pending.swap(false, .acq_rel);
    if (!provider and !dev) return null;
    return .{ .external_wake = .{ .provider = provider, .dev_reload = dev } };
}

fn view(ui: *WidgetUi, model: *const Model) WidgetUi.Node {
    if (widget_log.failed()) {
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
    const result = buildNode(ui, model, root_id, true);
    if (!projection_failed_this_view and projection_failure_latched) {
        std.log.info("widget native projection recovered after a degraded frame", .{});
        projection_failure_latched = false;
    }
    return result;
}

fn noteProjectionFailure(comptime format: []const u8, args: anytype) void {
    projection_failed_this_view = true;
    if (projection_failure_latched) return;
    projection_failure_latched = true;
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

fn hasPaintStyle(node: *const tree_mod.Node) bool {
    return node.background != null or node.border_color != null or node.border_width > 0 or node.radius > 0 or
        node.radius_top_left >= 0 or node.radius_top_right >= 0 or node.radius_bottom_right >= 0 or node.radius_bottom_left >= 0 or node.shadow != null or
        !node.hover_style.isEmpty() or !node.pressed_style.isEmpty();
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

fn attachEffects(ui: *WidgetUi, retained: *const tree_mod.Node, font_id: ?native_sdk.canvas.FontId, source: WidgetUi.Node) WidgetUi.Node {
    var icon_elements: ?[]const native_sdk.canvas.PathElement = null;
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
        @as(usize, @intFromBool(icon_elements != null));
    if (count == 0) return source;
    const existing = source.widget.immediate_commands;
    const combined = ui.arena.alloc(native_sdk.canvas.ImmediateCanvasCommand, existing.len + count) catch |err| {
        noteProjectionFailure("widget effect projection failed: cause={s}", .{@errorName(err)});
        return source;
    };
    @memcpy(combined[0..existing.len], existing);
    var cursor: usize = existing.len;
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
    if (icon_elements) |elements| {
        combined[cursor] = .{ .icon_path = .{
            .view_box = retained.icon_view_box,
            .elements = elements,
            .stroke_width = retained.icon_stroke,
        } };
    }
    var result = source;
    result.widget.immediate_commands = combined;
    return result;
}

fn buildNode(ui: *WidgetUi, model: *const Model, id: tree_mod.NodeId, is_root: bool) WidgetUi.Node {
    const retained = model.tree.nodeConst(id) catch |err| {
        noteProjectionFailure("widget retained-node projection failed: node={d}, cause={s}", .{ id, @errorName(err) });
        return projectionFailurePanel(ui, is_root);
    };
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
            .radius = if (retained.radius > 0) retained.radius else null,
            .radius_top_left = nativeCornerRadius(retained.radius_top_left),
            .radius_top_right = nativeCornerRadius(retained.radius_top_right),
            .radius_bottom_right = nativeCornerRadius(retained.radius_bottom_right),
            .radius_bottom_left = nativeCornerRadius(retained.radius_bottom_left),
            .border = retained.border_color,
            .stroke_width = retained.border_width,
            .quiet_hover = true,
        },
        .hover_style = nativeInteractionStyle(retained.hover_style),
        .pressed_style = nativeInteractionStyle(retained.pressed_style),
        .on_press_event = if (retained.handles_press) WidgetUi.pressMsg(.press) else null,
        .on_double_press_event = if (retained.handles_double_press) WidgetUi.pressMsg(.double_press) else null,
        .on_right_press_event = if (retained.handles_right_press) WidgetUi.pressMsg(.right_press) else null,
        .on_change = if (retained.handles_change) Msg{ .slider = id } else null,
    };
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
            return attachEffects(ui, retained, resolveFontId(retained, model.fonts), ui.text(options, retained.textSlice()));
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
        return attachEffects(ui, retained, resolveFontId(retained, model.fonts), ui.paragraph(options, &span));
    }
    const children = ui.arena.alloc(WidgetUi.Node, retained.child_count) catch |err| {
        noteProjectionFailure(
            "widget child projection capacity exhausted: node={d}, asked for {d}, cause={s}",
            .{ id, retained.child_count, @errorName(err) },
        );
        return projectionFailurePanel(ui, is_root);
    };
    for (retained.children[0..retained.child_count], 0..) |child_id, index| {
        children[index] = buildNode(ui, model, child_id, false);
    }
    const result = switch (retained.kind) {
        // SDK layout-only rows/columns do not paint their own style. A
        // styled column is contractually a column-layout box, which is the
        // builder's panel primitive; unstyled columns keep the lean node.
        // A styled row gets the same painting panel around its row layout.
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
        .stack => ui.stack(options, children),
        .panel => ui.panel(options, children),
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
            options.image = id;
            break :block ui.image(options);
        },
        .canvas => ui.immediateCanvas(options, (model.tree.canvasStateConst(id) catch |err| {
            noteProjectionFailure("widget canvas projection failed: node={d}, cause={s}", .{ id, @errorName(err) });
            return projectionFailurePanel(ui, is_root);
        }).slice()),
        .text => unreachable,
    };
    return attachEffects(ui, retained, null, result);
}

fn resolveFontId(node: *const tree_mod.Node, fonts: []const manifest_mod.Font) ?native_sdk.canvas.FontId {
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

fn loadFonts(io: std.Io, allocator: std.mem.Allocator, directory: []const u8, fonts: []const manifest_mod.Font) ![]const WidgetApp.FontRegistration {
    const registrations = try allocator.alloc(WidgetApp.FontRegistration, fonts.len);
    for (fonts, 0..) |font, index| {
        const path = try std.fs.path.join(allocator, &.{ directory, font.file });
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(native_sdk.runtime.max_registered_canvas_font_bytes));
        registrations[index] = .{ .id = font.id, .name = font.name, .ttf = bytes };
    }
    return registrations;
}

fn nativeCornerRadius(retained: f32) f32 {
    return if (retained >= 0) retained else -std.math.inf(f32);
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
        if (state.observed) |observed| std.heap.page_allocator.free(observed);
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

fn removeImageState(model: *Model, effects: *Effects, index: usize) void {
    const state = &model.image_states[index];
    if (state.registered) _ = effects.unregisterImage(state.id);
    if (state.observed) |observed| std.heap.page_allocator.free(observed);
    model.image_state_count -= 1;
    if (index != model.image_state_count) model.image_states[index] = model.image_states[model.image_state_count];
    model.image_states[model.image_state_count] = .{};
}

fn replaceObserved(state: *ImageState, observed: [:0]u8, valid: bool) void {
    if (state.observed) |previous| std.heap.page_allocator.free(previous);
    state.observed = observed;
    state.observed_valid = valid;
    state.load_failure_count = 0;
}

fn rememberRawSource(state: *ImageState, source: []const u8) !void {
    replaceObserved(state, try std.heap.page_allocator.dupeZ(u8, source), false);
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

fn synchronizeImageNode(model: *Model, effects: *Effects, id: tree_mod.NodeId, node: *const tree_mod.Node) !void {
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
        std.heap.page_allocator.free(resolved.path);
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

test "image reload failures retry twice then settle until the source changes" {
    var state: ImageState = .{};
    defer if (state.observed) |observed| std.heap.page_allocator.free(observed);

    recordImageLoadFailure(&state, try std.heap.page_allocator.dupeZ(u8, "first.img"));
    try std.testing.expect(!observedImageLoadSettled(&state, "first.img"));
    try std.testing.expectEqual(@as(u8, 1), state.load_failure_count);

    recordImageLoadFailure(&state, try std.heap.page_allocator.dupeZ(u8, "first.img"));
    try std.testing.expect(!observedImageLoadSettled(&state, "first.img"));
    try std.testing.expectEqual(@as(u8, 2), state.load_failure_count);

    recordImageLoadFailure(&state, try std.heap.page_allocator.dupeZ(u8, "first.img"));
    try std.testing.expect(observedImageLoadSettled(&state, "first.img"));
    try std.testing.expectEqual(max_image_load_attempts, state.load_failure_count);

    recordImageLoadFailure(&state, try std.heap.page_allocator.dupeZ(u8, "second.img"));
    try std.testing.expect(!observedImageLoadSettled(&state, "second.img"));
    try std.testing.expectEqual(@as(u8, 1), state.load_failure_count);

    replaceObserved(&state, try std.heap.page_allocator.dupeZ(u8, "second.img"), true);
    try std.testing.expect(observedImageLoadSettled(&state, "second.img"));
    try std.testing.expectEqual(@as(u8, 0), state.load_failure_count);
}

/// Runs after every app-loop turn, but the generation equality is the static
/// fast path. A changed image is decoded before its same-ID resource is
/// replaced; invalid/dead/reused nodes are unregistered explicitly.
fn synchronizeImages(model: *Model, effects: *Effects) !void {
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

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    // Shared render host mode: this process becomes the one Metal-owning
    // renderer every macOS widget talks to (weaverd spawns and supervises
    // it; docs/macos-memory-handoff.md carries the receipts). It never
    // loads a widget bundle.
    if (builtin.os.tag == .macos and args.len == 3 and std.mem.eql(u8, args[1], "--render-host")) {
        const seam = struct {
            extern fn native_sdk_appkit_render_host_run(name: [*:0]const u8) c_int;
        };
        const name_z = try allocator.dupeZ(u8, args[2]);
        if (seam.native_sdk_appkit_render_host_run(name_z.ptr) != 0) return error.RenderHostStartFailed;
        return;
    }
    const dev = args.len == 3 and std.mem.eql(u8, args[1], "--dev");
    if ((!dev and args.len != 2) or (dev and args.len != 3)) {
        // The render-host form is parsed only on macOS; advertise it only
        // where it is accepted.
        std.debug.print(if (builtin.os.tag == .macos)
            "usage: weaver-widget [--dev] <widget-directory> | weaver-widget --render-host <bootstrap-name>\n"
        else
            "usage: weaver-widget [--dev] <widget-directory>\n", .{});
        return error.InvalidArguments;
    }
    const directory = args[if (dev) 2 else 1];
    const loaded = try manifest_mod.load(init.io, allocator, directory);
    const force_software = if (init.environ_map.get("WEAVER_FORCE_SOFTWARE")) |value|
        std.mem.eql(u8, value, "1")
    else
        false;
    const renderer_backend = declaredGpuBackend(loaded.manifest.renderBackend, force_software);
    backend_status_io = init.io;
    backend_status_path = init.environ_map.get("WEAVER_BACKEND_FILE");
    const local_app_data = init.environ_map.get("LOCALAPPDATA");
    const home = init.environ_map.get("HOME");
    const data_root = try platform.dataRoot(allocator, local_app_data, home);
    const log_directory = try platform.logsRoot(allocator, local_app_data, home);
    try std.Io.Dir.cwd().createDirPath(init.io, log_directory);
    const log_name = try safeLogName(allocator, loaded.manifest.name);
    const log_path = try std.fs.path.join(allocator, &.{ log_directory, log_name });
    try widget_log.init(init.io, log_path);
    std.log.info("widget runtime starting pid={d}{s}", .{ platform.currentProcessId(), if (dev) " dev=true" else "" });
    var storage = try storage_mod.Store.init(init.io, allocator, data_root, loaded.manifest.name);
    const bundle_path = try std.fs.path.join(allocator, &.{ directory, "bundle.js" });
    const bundle_stat = try std.Io.Dir.cwd().statFile(init.io, bundle_path, .{});
    var geometry_store = try geometry_mod.Store.init(init.io, allocator, data_root, loaded.manifest.name);
    // A dragged position outranks the manifest anchor, but only while it
    // still lands on an attached display; a stale record (monitor
    // unplugged) falls back to the anchor. macOS validates in AppKit at
    // creation (constrainFrame), so only Windows pre-checks here.
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
        std.log.info("widget using persisted dragged position x={d} y={d}; manifest anchor is overridden until the geometry record is removed", .{ saved.x, saved.y });
        frame.x = saved.x;
        frame.y = saved.y;
        // The Windows host reads a (0,0) origin as "let the system
        // place it"; nudge the exact corner case off the sentinel.
        if (builtin.os.tag == .windows and frame.x == 0 and frame.y == 0) frame.x = 0.01;
    }
    const shell_views = [_]native_sdk.ShellView{.{
        .label = "widget-canvas",
        .kind = .gpu_surface,
        .fill = true,
        .role = "Weaver widget canvas",
        .accessibility_label = loaded.manifest.name,
        .gpu_backend = renderer_backend,
        .gpu_pixel_format = .bgra8_unorm,
        .gpu_present_mode = .timer,
        .gpu_alpha_mode = .premultiplied,
        .gpu_color_space = .srgb,
        .gpu_vsync = true,
    }};
    const shell_windows = [_]native_sdk.ShellWindow{.{
        .label = "main",
        .title = loaded.manifest.name,
        .width = loaded.manifest.size[0],
        .height = loaded.manifest.size[1],
        .x = frame.x,
        .y = frame.y,
        .resizable = false,
        .restore_state = false,
        .titlebar = .chromeless,
        .transparent = true,
        .layer = if (std.mem.eql(u8, loaded.manifest.layer, "desktop")) .bottom else if (std.mem.eql(u8, loaded.manifest.layer, "topmost")) .topmost else .normal,
        .click_through = loaded.manifest.clickThrough,
        .no_activate = true,
        .views = &shell_views,
    }};
    const scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };
    const fonts = try loadFonts(init.io, allocator, directory, loaded.manifest.fonts);
    var image_resolver = try image_paths.Resolver.init(
        init.io,
        std.heap.page_allocator,
        directory,
        init.environ_map.get("WEAVER_ART_CACHE"),
    );
    defer image_resolver.deinit();

    var tokens = native_sdk.canvas.DesignTokens.theme(.{ .pack = .geist, .color_scheme = .dark });
    tokens.colors.background = native_sdk.canvas.Color.rgba8(0, 0, 0, 0);
    const app_state = try WidgetApp.create(std.heap.page_allocator, .{
        .name = loaded.manifest.name,
        .scene = scene,
        .canvas_label = "widget-canvas",
        .tokens = tokens,
        .fonts = fonts,
        .update_fx = update,
        .init_fx = initEffects,
        .view = view,
        .sync = syncNativeState,
        .on_frame = onFrame,
        .on_frame_requested = onFrameRequested,
        .on_window_frame = onWindowFrame,
    });
    defer app_state.destroy();
    defer app_state.model.tree.deinit();
    defer deinitImageStates(&app_state.model);
    app_state.model.geometry = &geometry_store;
    app_state.model.fonts = loaded.manifest.fonts;
    app_state.model.image_resolver = &image_resolver;
    if (dragged) |saved| app_state.model.frame_origin = .{ saved.x, saved.y };
    try app_state.model.provider.init(init.io, platform.providerEndpoint(
        init.environ_map.get("WEAVER_HOST_PIPE"),
        init.environ_map.get("WEAVER_HOST_ENDPOINT"),
    ));
    defer app_state.model.provider.deinit();
    if (builtin.os.tag == .macos and weaver_build_options.automation_seam) {
        const automation = init.environ_map.get("WEAVER_AUTOMATION");
        const failure_path = init.environ_map.get("WEAVER_PROVIDER_TEST_FAIL_SEND");
        if (automation != null and std.mem.eql(u8, automation.?, "1") and failure_path != null) {
            app_state.model.provider.setAutomationSendFailurePath(failure_path.?);
        }
    }
    app_state.model.provider.setWake(notifyProviderWake);
    app_state.model.has_provider_subscriptions = hasHostProviderSubscription(loaded.manifest.subscribe);
    app_state.model.media_transport_enabled = for (loaded.manifest.capabilities) |capability| {
        if (std.mem.eql(u8, capability, "media-transport")) break true;
    } else false;
    const engine = try js_engine.Engine.create(
        std.heap.page_allocator,
        &app_state.model.tree,
        &storage,
        loaded.manifest.origins,
        &app_state.model.provider,
        app_state.model.media_transport_enabled,
    );
    app_state.model.engine = engine;
    defer if (app_state.model.engine) |current| current.destroy(std.heap.page_allocator);
    app_state.model.io = init.io;
    app_state.model.storage = &storage;
    app_state.model.origins = loaded.manifest.origins;
    app_state.model.bundle_path = bundle_path;
    app_state.model.dev_seen_mtime = bundle_stat.mtime.nanoseconds;
    for (loaded.manifest.subscribe) |provider| {
        if (std.mem.eql(u8, provider, "audio")) app_state.model.provider_poll_interval_ms = 33;
    }
    try engine.evaluate(loaded.bundle, "bundle.js");
    if (init.environ_map.get("WEAVER_MEMORY_RECEIPT")) |value| {
        if (value.len != 0 and !std.mem.eql(u8, value, "0")) {
            const usage = engine.memoryUsage();
            std.log.info(
                "widget memory receipt model_bytes={d} widget_app_bytes={d} tree_bytes={d} node_bytes={d} canvas_state_bytes={d} engine_bytes={d} quickjs_malloc_bytes={d} quickjs_memory_used_bytes={d} quickjs_atoms_bytes={d} quickjs_strings_bytes={d} quickjs_objects_bytes={d} quickjs_properties_bytes={d} quickjs_shapes_bytes={d} quickjs_functions_bytes={d} quickjs_function_code_bytes={d}",
                .{
                    @sizeOf(Model),
                    @sizeOf(WidgetApp),
                    @sizeOf(tree_mod.Tree),
                    @sizeOf(tree_mod.Node),
                    @sizeOf(tree_mod.CanvasState),
                    @sizeOf(js_engine.Engine),
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
    if (app_state.model.tree.root == null) {
        std.log.err("widget bundle completed without rendering a root; expected the default widget() registration to render synchronously", .{});
        app_state.model.tree.showError("WidgetDidNotRenderRoot\nThe bundle completed without rendering a widget root.");
    }
    if (app_state.model.provider.fatalChannelFailure()) return error.FatalProviderChannelFailure;
    if (loadLocalImages(init.io, allocator, directory, &app_state.model)) |_| {
        seedImageStates(&app_state.model) catch |err| {
            std.log.err("initial widget image state failed: {s}", .{@errorName(err)});
            var buffer: [tree_mod.max_text_bytes]u8 = undefined;
            const visible = std.fmt.bufPrint(&buffer, "image initialization failed\n{s}", .{@errorName(err)}) catch "image initialization failed; see the per-widget log";
            app_state.model.tree.showError(visible);
            app_state.model.image_count = 0;
        };
    } else |err| {
        std.log.err("initial widget image load failed: {s}", .{@errorName(err)});
        var buffer: [tree_mod.max_text_bytes]u8 = undefined;
        const visible = std.fmt.bufPrint(&buffer, "image load failed\n{s}", .{@errorName(err)}) catch "image load failed; see the per-widget log";
        app_state.model.tree.showError(visible);
        app_state.model.image_count = 0;
    }

    requested_software_backend = renderer_backend == .software;
    const dev_signal_path = try std.fs.path.join(allocator, &.{ directory, dev_reload.signal_file_name });
    var dev_reload_server: dev_reload.Server = .{};
    if (dev) try dev_reload_server.start(init.io, dev_signal_path, notifyDevReload);
    defer if (dev) {
        dev_reload_server.deinit();
        dev_reload_pending.store(false, .release);
    };
    defer {
        wake_runtime.store(0, .release);
        provider_wake_pending.store(false, .release);
    }
    var app = app_state.app();
    app.start_fn = startRendererDiagnostics;
    runner.runWithOptions(app, .{
        .app_name = "weaver-widget",
        .window_title = loaded.manifest.name,
        .bundle_id = "com.weaver.widget",
        .default_frame = frame,
        // A dragged origin places the window explicitly (macOS reads the
        // frame only when restore is set, then clamps it in AppKit); the
        // manifest anchor stays the placement until that first drag.
        .restore_state = dragged != null,
        // Weaver owns placement persistence (debounced, per-widget,
        // atomic). The substrate's bundle-id-keyed store would make
        // every widget process rewrite one shared windows.zon on each
        // move tick.
        .persist_window_state = false,
        .primary_display_anchor = if (builtin.os.tag == .macos and dragged == null) manifest_mod.primaryDisplayAnchor(loaded.manifest) else null,
        .js_window_api = false,
    }, init) catch |err| {
        std.log.err("widget runtime stopped after platform callback failure: {s}", .{@errorName(err)});
        return err;
    };
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
    const right = left + size[0] * saved.scale;
    const bottom = top + size[1] * saved.scale;
    const overlap_x = @min(right, @as(f32, @floatFromInt(bounds.right_px))) - @max(left, @as(f32, @floatFromInt(bounds.left_px)));
    const overlap_y = @min(bottom, @as(f32, @floatFromInt(bounds.bottom_px))) - @max(top, @as(f32, @floatFromInt(bounds.top_px)));
    return overlap_x >= 24 and overlap_y >= 24;
}

fn publishBackendStatus(backend: native_sdk.platform.GpuSurfaceBackend) void {
    const io = backend_status_io orelse return;
    const path = backend_status_path orelse return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = backendStatusLabel(backend) }) catch |err| {
        std.log.warn("widget could not publish renderer status: {s}", .{@errorName(err)});
    };
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
fn startRendererDiagnostics(_: *anyopaque, runtime: *native_sdk.Runtime) !void {
    diagnostic_runtime = runtime;
    wake_runtime.store(@intFromPtr(runtime), .release);
    if (dev_reload_pending.load(.acquire) or provider_wake_pending.load(.acquire)) {
        try runtime.options.platform.services.requestFrame();
    }
    if (!requested_software_backend) {
        std.log.info("widget renderer selected={s} presenter=host", .{if (@import("builtin").os.tag == .macos) "metal-composite" else "gpu"});
        return;
    }
    std.log.info("widget renderer selected=software presenter=pixels", .{});
}

fn notifyDevReload() void {
    dev_reload_pending.store(true, .release);
    requestExternalWake("dev hot-swap");
}

fn notifyProviderWake() void {
    provider_wake_pending.store(true, .release);
    requestExternalWake("provider");
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
    _ = @import("storage.zig");
    _ = @import("provider.zig");
    _ = @import("widget_log.zig");
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

test "dev reload crosses requestFrame into the frame-requested hook exactly once" {
    const TestApp = struct {
        model: Model = .{},
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
            if (onFrameRequested(&self.model)) |msg| {
                switch (msg) {
                    .external_wake => |wake| if (wake.dev_reload) {
                        self.reloads += 1;
                    },
                    else => {},
                }
            }
        }
    };

    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    var app_state: TestApp = .{};
    const app = app_state.app();
    try harness.start(app);

    dev_reload_pending.store(false, .release);
    provider_wake_pending.store(false, .release);
    wake_runtime.store(@intFromPtr(&harness.runtime), .release);
    defer {
        wake_runtime.store(0, .release);
        dev_reload_pending.store(false, .release);
        provider_wake_pending.store(false, .release);
    }
    const notifier = try std.Thread.spawn(.{}, notifyDevReload, .{});
    notifier.join();
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.pendingFrameRequestCount());

    const frame_event = harness.null_platform.takeFrameRequest().?;
    try std.testing.expect(frame_event == .frame_requested);
    try harness.runtime.dispatchPlatformEvent(app, frame_event);
    try std.testing.expectEqual(@as(usize, 1), app_state.reloads);
    try std.testing.expect(onFrameRequested(&app_state.model) == null);
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

test "corner radius projection preserves authored values and maps retained unset in-band" {
    try std.testing.expectEqual(@as(f32, 12.5), nativeCornerRadius(12.5));
    try std.testing.expect(nativeCornerRadius(-1) == -std.math.inf(f32));
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
        .text_font => |font_id| try std.testing.expectEqual(@as(native_sdk.canvas.FontId, 65), font_id),
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
    try std.testing.expectEqual(@as(?native_sdk.canvas.FontId, 65), resolveFontId(try tree.nodeConst(id), &fonts));
    try tree.setFontFamily(id, "Display-Regular");
    try tree.setFontWeight(id, "bold");
    try std.testing.expectEqual(@as(?native_sdk.canvas.FontId, 64), resolveFontId(try tree.nodeConst(id), &fonts));
    try tree.setFontFamily(id, "sans");
    try std.testing.expectEqual(@as(?native_sdk.canvas.FontId, null), resolveFontId(try tree.nodeConst(id), &fonts));
    try tree.setFontFamily(id, "mono");
    try std.testing.expectEqual(@as(?native_sdk.canvas.FontId, native_sdk.canvas.default_mono_font_id), resolveFontId(try tree.nodeConst(id), &fonts));
}

test "retained stack projects overlay kind and rounded content clipping" {
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
    try model.tree.setText(label_id, "overlay");
    try model.tree.appendChild(stack_id, background_id);
    try model.tree.appendChild(stack_id, label_id);

    var ui = WidgetUi.init(arena_state.allocator());
    const projected = buildNodeForTest(&ui, &model, stack_id, false);
    try std.testing.expectEqual(native_sdk.canvas.WidgetKind.stack, projected.widget.kind);
    try std.testing.expect(projected.widget.layout.flags.clip_content);
    try std.testing.expectEqual(@as(?f32, 14), projected.widget.style.radius);
    try std.testing.expectEqual(@as(?f32, 3), projected.widget.style.radius_bottom_left);
    try std.testing.expectEqual(@as(usize, 2), projected.nodes.len);
    try std.testing.expectEqual(native_sdk.canvas.WidgetKind.panel, projected.nodes[0].widget.kind);
    try std.testing.expectEqual(native_sdk.canvas.WidgetKind.text, projected.nodes[1].widget.kind);
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
    try std.testing.expectEqual(@as(?f32, 3), projected.widget.style.radius_top_right);
}
