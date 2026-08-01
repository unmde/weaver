const std = @import("std");
const tree_mod = @import("tree.zig");
const network = @import("network.zig");
const media_pending = @import("media_pending.zig");
const provider_mod = @import("provider.zig");
const qjs = @import("qjs.zig");
const storage_mod = @import("storage.zig");
const c = qjs.c;

pub const State = struct {
    tree: *tree_mod.Tree,
    storage: *storage_mod.Store,
    provider: *provider_mod.Client,
    origins: []const []const u8,
    media_transport_enabled: bool = false,
    media_tracker: media_pending.Tracker = .{},
    media_callbacks: [max_media_pending]c.JSValue = [_]c.JSValue{qjs.undefinedValue()} ** max_media_pending,
    timers: [max_timers]TimerSlot = [_]TimerSlot{.{}} ** max_timers,
    next_timer_id: u64 = 1,
    event_callback: c.JSValue = qjs.undefinedValue(),
    provider_callback: c.JSValue = qjs.undefinedValue(),
    canvas_resize_callback: c.JSValue = qjs.undefinedValue(),
    canvas_frames: [max_canvas_frames]CanvasFrameSlot = [_]CanvasFrameSlot{.{}} ** max_canvas_frames,
    fetches: [max_fetches]FetchSlot = [_]FetchSlot{.{}} ** max_fetches,
    render_failed: bool = false,
    emit_error_logs: bool = true,
};

// Timer receipt (2026-07-29): executing every shipped widget measured one
// simultaneously active interval. Sixteen leaves 16x headroom for clocks,
// animation, and debounced work. TimerSlot is 40 bytes, so all slots cost
// 640 bytes of fixed metadata; callbacks already live in QuickJS.
pub const max_timers: usize = 16;
// No shipped widget fetches yet. A modeled good polling widget uses two
// simultaneous API calls; four leaves 2x concurrency headroom. FetchSlot is
// 160 bytes (640 bytes total metadata); request/response payloads allocate
// their actual lengths under network.zig's independent byte bounds.
pub const max_fetches: usize = 4;
// One callback slot per receipted canvas slot; deriving it makes a separate
// canvas-frame budget impossible. Each slot is fixed callback metadata only.
pub const max_canvas_frames: usize = tree_mod.max_canvases;
// One callback per protocol command awaiting acknowledgement; the provider
// tracker's receipt and storage live in media_pending.zig.
pub const max_media_pending: usize = media_pending.capacity;
pub const media_ack_timeout_ms: u64 = media_pending.timeout_ms;
// Error-log detail is derived from widget_log's 8 KiB line buffer: 6,000
// bytes leaves >2 KiB for timestamp, scope, error framing, and truncation
// suffix. This is a presentation slice with no additional allocation.
const max_logged_error_detail_bytes: usize = 6000;
// Shipped callback scope labels are under 24 bytes, so 48 leaves >2x label
// headroom. Known one-line bridge diagnostics fit under 128 bytes. Both slices
// feed tree.zig's independent 1 KiB visible-text buffer and allocate nothing.
const max_visible_error_scope_bytes: usize = 48;
const max_visible_error_line_bytes: usize = 128;
// Console output ultimately enters widget_log's 8 KiB line buffer. 6,000
// bytes leaves >2 KiB for logger framing and costs one callback-lifetime stack
// buffer; longer console formatting is presentation, not retained widget data.
const max_console_bytes: usize = 6000;

pub const TimerSlot = struct {
    id: u64 = 0,
    interval_ms: u64 = 0,
    active: bool = false,
    callback: c.JSValue = qjs.undefinedValue(),
};

pub const CanvasFrameSlot = struct {
    node_id: tree_mod.NodeId = 0,
    callback: c.JSValue = qjs.undefinedValue(),
};

pub const FetchSlot = struct {
    active: bool = false,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cancelled: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    thread: ?std.Thread = null,
    resolve: c.JSValue = qjs.undefinedValue(),
    reject: c.JSValue = qjs.undefinedValue(),
    request: network.Request = .{},
    result: network.Result = .{},
};

/// Install the complete M0 capability surface. QuickJS's libc helpers are not
/// linked, so this explicit object is also the widget sandbox boundary.
pub fn install(ctx: *c.JSContext, bridge_state: *State) !void {
    c.JS_SetContextOpaque(ctx, bridge_state);
    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);
    const native = c.JS_NewObject(ctx);
    if (c.JS_IsException(native)) return error.QuickJs;
    errdefer c.JS_FreeValue(ctx, native);
    try setFunction(ctx, native, "createNode", createNode, 1);
    try setFunction(ctx, native, "setProp", setProp, 3);
    try setFunction(ctx, native, "setText", setText, 2);
    try setFunction(ctx, native, "appendChild", appendChild, 2);
    try setFunction(ctx, native, "insertBefore", insertBefore, 3);
    try setFunction(ctx, native, "removeNode", removeNode, 1);
    try setFunction(ctx, native, "setRoot", setRoot, 1);
    try setFunction(ctx, native, "beginBatch", beginBatch, 0);
    try setFunction(ctx, native, "endBatch", endBatch, 0);
    try setFunction(ctx, native, "abortBatch", abortBatch, 0);
    try setFunction(ctx, native, "reportError", reportError, 2);
    try setFunction(ctx, native, "setHandler", setHandler, 3);
    try setFunction(ctx, native, "onEvent", onEvent, 1);
    try setFunction(ctx, native, "hostAvailable", hostAvailable, 0);
    try setFunction(ctx, native, "onProvider", onProvider, 1);
    if (bridge_state.media_transport_enabled) try setFunction(ctx, native, "mediaCommand", mediaCommand, 2);
    try setFunction(ctx, native, "setInterval", setInterval, 1);
    try setFunction(ctx, native, "clearInterval", clearInterval, 1);
    try setFunction(ctx, native, "onTimer", onTimer, 2);
    try setFunction(ctx, native, "setCanvasCommands", setCanvasCommands, 2);
    try setFunction(ctx, native, "onCanvasResize", onCanvasResize, 1);
    try setFunction(ctx, native, "onCanvasFrame", onCanvasFrame, 2);
    try setFunction(ctx, native, "clearCanvasFrame", clearCanvasFrame, 1);
    try setFunction(ctx, native, "fetch", fetch, 4);
    try setFunction(ctx, native, "storageRead", storageRead, 0);
    try setFunction(ctx, native, "storageWrite", storageWrite, 1);
    try setFunction(ctx, native, "log", log, 1);
    if (c.JS_SetPropertyStr(ctx, global, "native", native) < 0) return error.QuickJs;
    const console = c.JS_NewObject(ctx);
    if (c.JS_IsException(console)) return error.QuickJs;
    errdefer c.JS_FreeValue(ctx, console);
    try setFunction(ctx, console, "log", consoleLog, 1);
    try setFunction(ctx, console, "warn", consoleWarn, 1);
    try setFunction(ctx, console, "error", consoleError, 1);
    if (c.JS_SetPropertyStr(ctx, global, "console", console) < 0) return error.QuickJs;
}

pub fn deinit(ctx: *c.JSContext, bridge_state: *State) void {
    settleAllMedia(ctx, bridge_state, "MediaCommandShutdown");
    for (&bridge_state.timers) |*timer| {
        c.JS_FreeValue(ctx, timer.callback);
        timer.* = .{};
    }
    for (&bridge_state.canvas_frames) |*frame| {
        c.JS_FreeValue(ctx, frame.callback);
        frame.* = .{};
    }
    c.JS_FreeValue(ctx, bridge_state.event_callback);
    c.JS_FreeValue(ctx, bridge_state.provider_callback);
    c.JS_FreeValue(ctx, bridge_state.canvas_resize_callback);
    for (&bridge_state.fetches) |*slot| {
        if (slot.thread != null) slot.cancelled.store(1, .release);
    }
    for (&bridge_state.fetches) |*slot| {
        if (slot.thread) |thread| thread.join();
        c.JS_FreeValue(ctx, slot.resolve);
        c.JS_FreeValue(ctx, slot.reject);
        slot.request.deinit(std.heap.page_allocator);
        slot.result.deinit(std.heap.page_allocator);
        slot.* = .{};
    }
}

fn setFunction(ctx: *c.JSContext, object: c.JSValue, name: [*:0]const u8, function: c.JSCFunction, argc: c_int) !void {
    const value = c.JS_NewCFunction2(ctx, function, name, argc, c.JS_CFUNC_generic, 0);
    if (c.JS_IsException(value) or c.JS_SetPropertyStr(ctx, object, name, value) < 0) return error.QuickJs;
}

fn state(ctx: *c.JSContext) *State {
    return @ptrCast(@alignCast(c.JS_GetContextOpaque(ctx).?));
}

fn fail(ctx: *c.JSContext, message: [*:0]const u8) c.JSValue {
    return c.JS_ThrowTypeError(ctx, "%s", message);
}

/// A budget error a developer's agent can act on names the budget, its
/// limit, and what the batch actually asked for; a bare "invalid batch"
/// forced a source read to learn which cap was hit.
fn failFmt(ctx: *c.JSContext, comptime format: []const u8, args: anytype) c.JSValue {
    var buffer: [256]u8 = undefined;
    const message = std.fmt.bufPrintZ(&buffer, format, args) catch "canvas command batch rejected";
    return fail(ctx, message);
}

fn failProp(ctx: *c.JSContext, id: tree_mod.NodeId, key: []const u8, err: anyerror) c.JSValue {
    return failFmt(ctx, "setProp failed: node={d}, property={s}, cause={s}", .{ id, key, @errorName(err) });
}

fn idArg(ctx: *c.JSContext, value: c.JSValueConst) !tree_mod.NodeId {
    var id: u32 = 0;
    if (c.JS_ToUint32(ctx, &id, value) < 0) return error.InvalidArgument;
    return id;
}

fn stringArg(ctx: *c.JSContext, value: c.JSValueConst) !struct { bytes: []const u8, raw: [*c]const u8 } {
    var len: usize = 0;
    const raw = c.JS_ToCStringLen2(ctx, &len, value, false) orelse return error.InvalidArgument;
    return .{ .bytes = raw[0..len], .raw = raw };
}

fn createNode(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 1) return fail(js, "createNode expects one argument");
    const kind_text = stringArg(js, argv[0]) catch return fail(js, "node type must be a string");
    defer c.JS_FreeCString(js, kind_text.raw);
    const kind = tree_mod.Kind.parse(kind_text.bytes) orelse return fail(js, "unsupported node type");
    const bridge_state = state(js);
    const id = bridge_state.tree.createNode(kind) catch |err| return switch (err) {
        error.NodeLimit => failFmt(
            js,
            "node capacity exhausted: max_nodes={d}, asked for {d}",
            .{ tree_mod.max_nodes, bridge_state.tree.nodeCount() + 1 },
        ),
        error.CanvasLimit => failFmt(
            js,
            "canvas capacity exhausted: max_canvases={d}, asked for {d}",
            .{ tree_mod.max_canvases, tree_mod.max_canvases + 1 },
        ),
        else => failFmt(js, "createNode failed: {s}", .{@errorName(err)}),
    };
    return c.JS_NewUint32(js, id);
}

fn setText(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 2) return fail(js, "setText expects id and text");
    const id = idArg(js, argv[0]) catch return fail(js, "invalid node id");
    const value = stringArg(js, argv[1]) catch return fail(js, "text must be a string");
    defer c.JS_FreeCString(js, value.raw);
    state(js).tree.setText(id, value.bytes) catch |err| return switch (err) {
        error.TextTooLong => failFmt(
            js,
            "text capacity exhausted: max_text_bytes={d}, asked for {d}",
            .{ tree_mod.max_text_bytes, value.bytes.len },
        ),
        else => failFmt(js, "setText failed: {s}", .{@errorName(err)}),
    };
    return qjs.undefinedValue();
}

fn appendChild(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 2) return fail(js, "appendChild expects parent and child ids");
    const parent = idArg(js, argv[0]) catch return fail(js, "invalid parent id");
    const child = idArg(js, argv[1]) catch return fail(js, "invalid child id");
    const bridge_state = state(js);
    const asked = if (bridge_state.tree.nodeConst(parent)) |node_value| node_value.child_count + 1 else |_| 0;
    bridge_state.tree.appendChild(parent, child) catch |err| return switch (err) {
        error.ChildLimit => failFmt(
            js,
            "child capacity exhausted: max_children={d}, asked for {d} on parent {d}",
            .{ tree_mod.max_children, asked, parent },
        ),
        else => failFmt(js, "appendChild failed: {s}", .{@errorName(err)}),
    };
    return qjs.undefinedValue();
}

fn insertBefore(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 3) return fail(js, "insertBefore expects parent, child, and before ids");
    const parent = idArg(js, argv[0]) catch return fail(js, "invalid parent id");
    const child = idArg(js, argv[1]) catch return fail(js, "invalid child id");
    const before = idArg(js, argv[2]) catch return fail(js, "invalid before id");
    const bridge_state = state(js);
    const asked = if (bridge_state.tree.nodeConst(parent)) |node_value| node_value.child_count + 1 else |_| 0;
    bridge_state.tree.insertBefore(parent, child, before) catch |err| return switch (err) {
        error.ChildLimit => failFmt(
            js,
            "child capacity exhausted: max_children={d}, asked for {d} on parent {d}",
            .{ tree_mod.max_children, asked, parent },
        ),
        else => failFmt(js, "insertBefore failed: {s}", .{@errorName(err)}),
    };
    return qjs.undefinedValue();
}

fn removeNode(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 1) return fail(js, "removeNode expects one id");
    const id = idArg(js, argv[0]) catch return fail(js, "invalid node id");
    state(js).tree.removeNode(id) catch |err| return failFmt(js, "removeNode failed: node={d}, cause={s}", .{ id, @errorName(err) });
    return qjs.undefinedValue();
}

fn setRoot(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 1) return fail(js, "setRoot expects one id");
    const id = idArg(js, argv[0]) catch return fail(js, "invalid node id");
    state(js).tree.setRoot(id) catch |err| return failFmt(js, "setRoot failed: node={d}, cause={s}", .{ id, @errorName(err) });
    return qjs.undefinedValue();
}

fn beginBatch(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, _: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 0) return fail(js, "beginBatch expects no arguments");
    state(js).tree.beginBatch() catch return fail(js, "render transaction could not snapshot the last committed tree");
    return qjs.undefinedValue();
}

fn endBatch(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, _: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 0) return fail(js, "endBatch expects no arguments");
    const authored_tree = state(js).tree;
    if (!authored_tree.prepareEndBatch()) return qjs.undefinedValue();
    if (authored_tree.canvasAncestorViolation()) |violation| {
        return switch (violation.reason) {
            .clip => failFmt(
                js,
                "CanvasNeedsUnclippedAncestors: canvas node {d} is under overflow-hidden ancestor {d}; a host GPU surface cannot be clipped",
                .{ violation.canvas_id, violation.ancestor_id },
            ),
            .opacity => failFmt(
                js,
                "CanvasNeedsOpaqueAncestors: canvas node {d} is under opacity ancestor {d}; a host GPU surface cannot be placed behind an opacity layer",
                .{ violation.canvas_id, violation.ancestor_id },
            ),
        };
    }
    authored_tree.commitBatch();
    return qjs.undefinedValue();
}

fn abortBatch(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, _: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 0) return fail(js, "abortBatch expects no arguments");
    state(js).tree.abortBatch();
    return qjs.undefinedValue();
}

fn reportError(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 2) return fail(js, "reportError expects scope and details");
    const scope = stringArg(js, argv[0]) catch return fail(js, "reportError scope must be a string");
    defer c.JS_FreeCString(js, scope.raw);
    const details = stringArg(js, argv[1]) catch return fail(js, "reportError details must be a string");
    defer c.JS_FreeCString(js, details.raw);
    const bridge_state = state(js);
    bridge_state.render_failed = true;

    const visible_scope = scope.bytes[0..@min(scope.bytes.len, max_visible_error_scope_bytes)];
    const log_details = details.bytes[0..@min(details.bytes.len, max_logged_error_detail_bytes)];
    if (bridge_state.emit_error_logs) std.log.err("widget {s} failed:\n{s}", .{ visible_scope, log_details });

    var visible_buffer: [tree_mod.max_text_bytes]u8 = undefined;
    const first_line_length = std.mem.indexOfScalar(u8, details.bytes, '\n') orelse details.bytes.len;
    const first_line = details.bytes[0..@min(first_line_length, max_visible_error_line_bytes)];
    const visible = std.fmt.bufPrint(
        &visible_buffer,
        "{s} failed\n{s}",
        .{ visible_scope, first_line },
    ) catch "Widget callback failed; see the per-widget log";
    bridge_state.tree.showError(visible);
    return qjs.undefinedValue();
}

pub fn renderFailed(bridge_state: *const State) bool {
    return bridge_state.render_failed;
}

fn setHandler(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 3) return fail(js, "setHandler expects id, event kind, and enabled");
    const id = idArg(js, argv[0]) catch return fail(js, "invalid node id");
    const kind = stringArg(js, argv[1]) catch return fail(js, "event kind must be a string");
    defer c.JS_FreeCString(js, kind.raw);
    const enabled = c.JS_ToBool(js, argv[2]);
    if (enabled < 0) return fail(js, "handler enabled must be boolean");
    state(js).tree.setHandler(id, kind.bytes, enabled != 0) catch return fail(js, "unsupported event handler");
    return qjs.undefinedValue();
}

/// The SDK installs exactly one event dispatcher. Native nodes retain only
/// handler-presence bits; typed closures stay in the JS reconciler, and every
/// press/change returns through this `(nodeId, kind, payload)` choke point.
fn onEvent(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 1 or !c.JS_IsFunction(js, argv[0])) return fail(js, "onEvent expects one function");
    const bridge_state = state(js);
    c.JS_FreeValue(js, bridge_state.event_callback);
    bridge_state.event_callback = c.JS_DupValue(js, argv[0]);
    return qjs.undefinedValue();
}

fn hostAvailable(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, _: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 0) return fail(js, "hostAvailable expects no arguments");
    return c.JS_NewBool(js, state(js).provider.isAvailable());
}

/// One string callback is the complete host-provider capability. Keeping the
/// JSON-line parsing in the SDK means native IPC never manufactures arbitrary
/// JS object graphs, and the runtime still invokes QuickJS only on its loop.
fn onProvider(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 1 or !c.JS_IsFunction(js, argv[0])) return fail(js, "onProvider expects one function");
    const bridge_state = state(js);
    c.JS_FreeValue(js, bridge_state.provider_callback);
    bridge_state.provider_callback = c.JS_DupValue(js, argv[0]);
    return qjs.undefinedValue();
}

const MediaWireCommand = struct {
    command: []const u8,
    verb: []const u8,
    seekMs: ?u64 = null,
    id: u64,
};

fn mediaCommand(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 2 or !c.JS_IsFunction(js, argv[1])) return fail(js, "mediaCommand expects JSON and a callback");
    const bridge_state = state(js);
    if (!bridge_state.media_transport_enabled) return fail(js, "MediaTransportCapabilityRequired");
    if (!bridge_state.provider.isAvailable()) return fail(js, "MediaChannelUnavailable");
    const value = stringArg(js, argv[0]) catch return fail(js, "mediaCommand expects JSON and a callback");
    defer c.JS_FreeCString(js, value.raw);
    const parsed = std.json.parseFromSlice(MediaWireCommand, std.heap.page_allocator, value.bytes, .{
        .ignore_unknown_fields = false,
    }) catch return fail(js, "MalformedMediaCommand");
    defer parsed.deinit();
    const wire = parsed.value;
    if (!std.mem.eql(u8, wire.command, "media") or wire.id == 0 or wire.id > 9_007_199_254_740_991) return fail(js, "MalformedMediaCommand");
    const known_verb = std.mem.eql(u8, wire.verb, "play") or std.mem.eql(u8, wire.verb, "pause") or
        std.mem.eql(u8, wire.verb, "next") or std.mem.eql(u8, wire.verb, "previous") or std.mem.eql(u8, wire.verb, "seek");
    if (!known_verb or (std.mem.eql(u8, wire.verb, "seek") != (wire.seekMs != null))) return fail(js, "MalformedMediaCommand");
    const id = bridge_state.provider.nextCommandId() catch return fail(js, "MediaCommandIdExhausted");
    const now_ms = bridge_state.provider.nowMilliseconds();
    const index = bridge_state.media_tracker.add(id, now_ms) catch |err| return switch (err) {
        error.PendingLimit => fail(js, "MediaCommandPendingLimit"),
        else => fail(js, "MalformedMediaCommand"),
    };
    if (!bridge_state.provider.registerAck(id)) {
        bridge_state.media_tracker.remove(index);
        return fail(js, "MediaCommandPendingLimit");
    }
    var command_buffer: [provider_mod.max_command_line_bytes]u8 = undefined;
    const command = if (wire.seekMs) |seek_ms|
        std.fmt.bufPrint(
            &command_buffer,
            "{{\"command\":\"media\",\"verb\":\"{s}\",\"seekMs\":{d},\"id\":{d}}}",
            .{ wire.verb, seek_ms, id },
        ) catch {
            bridge_state.provider.unregisterAck(id);
            bridge_state.media_tracker.remove(index);
            return fail(js, "MalformedMediaCommand");
        }
    else
        std.fmt.bufPrint(
            &command_buffer,
            "{{\"command\":\"media\",\"verb\":\"{s}\",\"id\":{d}}}",
            .{ wire.verb, id },
        ) catch {
            bridge_state.provider.unregisterAck(id);
            bridge_state.media_tracker.remove(index);
            return fail(js, "MalformedMediaCommand");
        };
    installMediaCallback(js, bridge_state, index, argv[1]);
    bridge_state.provider.send(command) catch {
        discardMediaCallback(js, bridge_state, index);
        bridge_state.provider.unregisterAck(id);
        bridge_state.media_tracker.remove(index);
        return fail(js, "MediaChannelUnavailable");
    };
    return qjs.undefinedValue();
}

fn installMediaCallback(ctx: *c.JSContext, bridge_state: *State, index: usize, callback: c.JSValueConst) void {
    std.debug.assert(c.JS_IsUndefined(bridge_state.media_callbacks[index]));
    bridge_state.media_callbacks[index] = c.JS_DupValue(ctx, callback);
}

fn discardMediaCallback(ctx: *c.JSContext, bridge_state: *State, index: usize) void {
    c.JS_FreeValue(ctx, bridge_state.media_callbacks[index]);
    bridge_state.media_callbacks[index] = qjs.undefinedValue();
}

fn storageRead(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, _: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 0) return fail(js, "storageRead expects no arguments");
    const bytes = state(js).storage.read() catch |err| return failFmt(js, "storageRead failed: cause={s}", .{@errorName(err)});
    if (bytes) |value| return c.JS_NewStringLen(js, value.ptr, value.len);
    return qjs.nullValue();
}

fn storageWrite(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 1) return fail(js, "storageWrite expects one JSON string");
    const value = stringArg(js, argv[0]) catch return fail(js, "storageWrite expects one JSON string");
    defer c.JS_FreeCString(js, value.raw);
    state(js).storage.write(value.bytes) catch |err| return if (err == error.StorageQuotaExceeded)
        failFmt(js, "StorageQuotaExceeded: max_storage_bytes={d}, asked for {d}", .{ storage_mod.quota_bytes, value.bytes.len })
    else
        failFmt(js, "storageWrite failed: cause={s}", .{@errorName(err)});
    return qjs.undefinedValue();
}

fn setProp(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 3) return fail(js, "setProp expects id, key, and value");
    const id = idArg(js, argv[0]) catch return fail(js, "invalid node id");
    const key = stringArg(js, argv[1]) catch return fail(js, "property key must be a string");
    defer c.JS_FreeCString(js, key.raw);
    if (isColorProperty(key.bytes)) {
        const value = stringArg(js, argv[2]) catch return fail(js, "color property must be #RRGGBBAA");
        defer c.JS_FreeCString(js, value.raw);
        const color = if (value.bytes.len == 0) null else parseColor(value.bytes) orelse return fail(js, "color must be #RRGGBBAA");
        if (std.mem.eql(u8, key.bytes, "background")) {
            state(js).tree.setBackground(id, color) catch |err| return failProp(js, id, key.bytes, err);
        } else if (std.mem.eql(u8, key.bytes, "textColor")) {
            state(js).tree.setTextColor(id, color) catch |err| return failProp(js, id, key.bytes, err);
        } else if (std.mem.eql(u8, key.bytes, "borderColor")) {
            state(js).tree.setBorderColor(id, color) catch |err| return failProp(js, id, key.bytes, err);
        } else {
            state(js).tree.setInteractionColor(id, key.bytes, color) catch |err| return failProp(js, id, key.bytes, err);
        }
    } else if (std.mem.eql(u8, key.bytes, "shadow") or std.mem.eql(u8, key.bytes, "textShadow") or
        std.mem.eql(u8, key.bytes, "hoverShadow") or std.mem.eql(u8, key.bytes, "pressedShadow"))
    {
        const value = stringArg(js, argv[2]) catch return fail(js, "shadow must be a packed string");
        defer c.JS_FreeCString(js, value.raw);
        if (std.mem.eql(u8, key.bytes, "shadow")) {
            const shadow = if (value.bytes.len == 0) null else parseBoxShadow(value.bytes) orelse return fail(js, "shadow must be 'x y blur spread #RRGGBBAA'");
            state(js).tree.setShadow(id, shadow) catch |err| return failProp(js, id, key.bytes, err);
        } else if (std.mem.eql(u8, key.bytes, "textShadow")) {
            const shadow = if (value.bytes.len == 0) null else parseTextShadow(value.bytes) orelse return fail(js, "textShadow must be 'x y blur #RRGGBBAA'");
            state(js).tree.setTextShadow(id, shadow) catch |err| return failProp(js, id, key.bytes, err);
        } else if (value.bytes.len == 0) {
            state(js).tree.setInteractionShadow(id, key.bytes, null, false) catch |err| return failProp(js, id, key.bytes, err);
        } else if (std.mem.eql(u8, value.bytes, "none")) {
            state(js).tree.setInteractionShadow(id, key.bytes, null, true) catch |err| return failProp(js, id, key.bytes, err);
        } else {
            const shadow = parseBoxShadow(value.bytes) orelse return fail(js, "state shadow must be 'x y blur spread #RRGGBBAA' or none");
            state(js).tree.setInteractionShadow(id, key.bytes, shadow, true) catch |err| return failProp(js, id, key.bytes, err);
        }
    } else if (std.mem.eql(u8, key.bytes, "source")) {
        const value = stringArg(js, argv[2]) catch return fail(js, "source must be a string");
        defer c.JS_FreeCString(js, value.raw);
        state(js).tree.setSource(id, value.bytes) catch |err| return if (err == error.TextTooLong)
            failFmt(js, "image source capacity exhausted: max_source_bytes={d}, asked for {d}", .{ tree_mod.max_source_bytes, value.bytes.len })
        else
            failFmt(js, "set image source failed: {s}", .{@errorName(err)});
    } else if (std.mem.eql(u8, key.bytes, "iconPath")) {
        const value = stringArg(js, argv[2]) catch return fail(js, "iconPath must be a string");
        defer c.JS_FreeCString(js, value.raw);
        state(js).tree.setIconPath(id, value.bytes) catch |err| return if (err == error.IconPathTooLong)
            failFmt(js, "icon path capacity exhausted: max_icon_path_bytes={d}, asked for {d}", .{ tree_mod.max_icon_path_bytes, value.bytes.len })
        else
            fail(js, "invalid iconPath");
    } else if (std.mem.eql(u8, key.bytes, "iconViewBox")) {
        const value = stringArg(js, argv[2]) catch return fail(js, "iconViewBox must be a string");
        defer c.JS_FreeCString(js, value.raw);
        state(js).tree.setIconViewBox(id, value.bytes) catch return fail(js, "invalid iconViewBox");
    } else if (std.mem.eql(u8, key.bytes, "imageFit")) {
        const value = stringArg(js, argv[2]) catch return fail(js, "imageFit must be a string");
        defer c.JS_FreeCString(js, value.raw);
        state(js).tree.setImageFit(id, value.bytes) catch return fail(js, "imageFit must be cover, contain, or stretch");
    } else if (std.mem.eql(u8, key.bytes, "fontWeight")) {
        const value = stringArg(js, argv[2]) catch return fail(js, "fontWeight must be a string");
        defer c.JS_FreeCString(js, value.raw);
        state(js).tree.setFontWeight(id, value.bytes) catch return fail(js, "invalid fontWeight");
    } else if (std.mem.eql(u8, key.bytes, "fontFamily")) {
        const value = stringArg(js, argv[2]) catch return fail(js, "fontFamily must be a string");
        defer c.JS_FreeCString(js, value.raw);
        state(js).tree.setFontFamily(id, value.bytes) catch return fail(js, "invalid fontFamily");
    } else if (std.mem.eql(u8, key.bytes, "textAlign")) {
        const value = stringArg(js, argv[2]) catch return fail(js, "textAlign must be a string");
        defer c.JS_FreeCString(js, value.raw);
        state(js).tree.setTextAlign(id, value.bytes) catch return fail(js, "invalid textAlign");
    } else if (std.mem.eql(u8, key.bytes, "crossAlign") or std.mem.eql(u8, key.bytes, "mainAlign") or std.mem.eql(u8, key.bytes, "alignSelf")) {
        const value = stringArg(js, argv[2]) catch return fail(js, "alignment must be a string");
        defer c.JS_FreeCString(js, value.raw);
        if (std.mem.eql(u8, key.bytes, "crossAlign")) {
            state(js).tree.setCrossAlign(id, value.bytes) catch return fail(js, "invalid cross alignment");
        } else if (std.mem.eql(u8, key.bytes, "alignSelf")) {
            state(js).tree.setAlignSelf(id, value.bytes) catch return fail(js, "invalid self alignment");
        } else {
            state(js).tree.setMainAlign(id, value.bytes) catch return fail(js, "invalid main alignment");
        }
    } else if (std.mem.eql(u8, key.bytes, "truncate") or std.mem.eql(u8, key.bytes, "overflowHidden") or std.mem.eql(u8, key.bytes, "flexWrap") or std.mem.eql(u8, key.bytes, "tabularNums") or std.mem.eql(u8, key.bytes, "shadowInset") or std.mem.eql(u8, key.bytes, "hoverShadowInset") or std.mem.eql(u8, key.bytes, "pressedShadowInset") or std.mem.eql(u8, key.bytes, "imageTile")) {
        const value = c.JS_ToBool(js, argv[2]);
        if (value < 0) return fail(js, "property must be boolean");
        if (std.mem.eql(u8, key.bytes, "truncate")) {
            state(js).tree.setTruncate(id, value != 0) catch |err| return failProp(js, id, key.bytes, err);
        } else if (std.mem.eql(u8, key.bytes, "overflowHidden")) {
            state(js).tree.setOverflowHidden(id, value != 0) catch |err| return failProp(js, id, key.bytes, err);
        } else if (std.mem.eql(u8, key.bytes, "flexWrap")) {
            state(js).tree.setFlexWrap(id, value != 0) catch |err| return failProp(js, id, key.bytes, err);
        } else if (std.mem.eql(u8, key.bytes, "tabularNums")) {
            state(js).tree.setTabularNums(id, value != 0) catch |err| return failProp(js, id, key.bytes, err);
        } else if (std.mem.eql(u8, key.bytes, "imageTile")) {
            state(js).tree.setImageTile(id, value != 0) catch |err| return failProp(js, id, key.bytes, err);
        } else if (std.mem.eql(u8, key.bytes, "hoverShadowInset") or std.mem.eql(u8, key.bytes, "pressedShadowInset")) {
            state(js).tree.setInteractionShadowInset(id, key.bytes, value != 0) catch |err| return failProp(js, id, key.bytes, err);
        } else {
            state(js).tree.setShadowInset(id, value != 0) catch |err| return failProp(js, id, key.bytes, err);
        }
    } else {
        var value: f64 = 0;
        if (c.JS_ToFloat64(js, &value, argv[2]) < 0) return fail(js, "property value must be numeric");
        if (std.mem.eql(u8, key.bytes, "value") or std.mem.eql(u8, key.bytes, "max")) {
            state(js).tree.setControlValue(id, key.bytes, @floatCast(value)) catch return fail(js, "unsupported control property");
        } else {
            state(js).tree.setNumberProp(id, key.bytes, @floatCast(value)) catch return fail(js, "unsupported property");
        }
    }
    return qjs.undefinedValue();
}

fn setInterval(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 1) return fail(js, "setInterval expects milliseconds");
    var milliseconds: i64 = 0;
    if (c.JS_ToInt64(js, &milliseconds, argv[0]) < 0 or milliseconds <= 0) return fail(js, "interval must be positive");
    const bridge_state = state(js);
    for (&bridge_state.timers) |*timer| {
        if (timer.active) continue;
        const id = bridge_state.next_timer_id;
        bridge_state.next_timer_id +%= 1;
        timer.* = .{ .id = id, .interval_ms = @intCast(milliseconds), .active = true };
        return c.JS_NewInt64(js, @intCast(id));
    }
    return failFmt(js, "timer capacity exhausted: max_timers={d}, asked for {d}", .{ max_timers, max_timers + 1 });
}

fn clearInterval(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 1) return fail(js, "clearInterval expects one timer id");
    var id: i64 = 0;
    if (c.JS_ToInt64(js, &id, argv[0]) < 0 or id <= 0) return fail(js, "invalid timer id");
    for (&state(js).timers) |*timer| {
        if (!timer.active or timer.id != @as(u64, @intCast(id))) continue;
        c.JS_FreeValue(js, timer.callback);
        timer.* = .{};
        return qjs.undefinedValue();
    }
    return qjs.undefinedValue();
}

/// Register one callback for one native-clocked timer. Timer ids are returned
/// by `setInterval`; this keyed shape keeps concurrent hook/provider timers
/// independent and lets `clearInterval` retire either without a JS dispatcher.
fn onTimer(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 2 or !c.JS_IsFunction(js, argv[1])) return fail(js, "onTimer expects a timer id and function");
    var id: i64 = 0;
    if (c.JS_ToInt64(js, &id, argv[0]) < 0 or id <= 0) return fail(js, "invalid timer id");
    for (&state(js).timers) |*timer| {
        if (!timer.active or timer.id != @as(u64, @intCast(id))) continue;
        c.JS_FreeValue(js, timer.callback);
        timer.callback = c.JS_DupValue(js, argv[1]);
        return qjs.undefinedValue();
    }
    return fail(js, "unknown timer id");
}

/// Scratch for one decoded command batch. File-scope rather than a stack
/// local because the wire budget (32768 f64s = 256 KiB) is too large for a
/// QuickJS callback frame; the engine runs single-threaded per widget
/// process, so one buffer serves every call.
var canvas_wire_scratch: [tree_mod.max_canvas_wire_values]f64 = undefined;

/// Copy one Float64Array command batch at the QuickJS boundary. The wire is
/// intentionally numeric and bounded: JS performs color parsing and command
/// construction, while Zig validates every value before replacing the node's
/// prior batch. No JS object graph survives the call.
fn setCanvasCommands(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 2) return fail(js, "setCanvasCommands expects id and Float64Array");
    const id = idArg(js, argv[0]) catch return fail(js, "invalid canvas node id");
    if (c.JS_GetTypedArrayType(argv[1]) != c.JS_TYPED_ARRAY_FLOAT64) {
        return fail(js, "setCanvasCommands expects id and Float64Array");
    }
    var byte_offset: usize = 0;
    var byte_length: usize = 0;
    var bytes_per_element: usize = 0;
    const array_buffer = c.JS_GetTypedArrayBuffer(js, argv[1], &byte_offset, &byte_length, &bytes_per_element);
    if (c.JS_IsException(array_buffer)) return qjs.exceptionValue();
    defer c.JS_FreeValue(js, array_buffer);
    var buffer_length: usize = 0;
    const buffer = c.JS_GetArrayBuffer(js, &buffer_length, array_buffer) orelse return fail(js, "canvas command buffer is detached");
    if (bytes_per_element != @sizeOf(f64) or byte_length % @sizeOf(f64) != 0 or
        byte_offset > buffer_length or byte_length > buffer_length - byte_offset)
    {
        return fail(js, "canvas command batch must be a valid Float64Array");
    }
    const length = byte_length / @sizeOf(f64);
    if (length > tree_mod.max_canvas_wire_values) {
        return failFmt(js, "canvas command batch is {d} wire values; the limit (max_canvas_wire_values) is {d}", .{ length, tree_mod.max_canvas_wire_values });
    }
    const source: [*]const f64 = @ptrCast(@alignCast(buffer + byte_offset));
    @memcpy(canvas_wire_scratch[0..length], source[0..length]);
    state(js).tree.setCanvasCommands(id, canvas_wire_scratch[0..length]) catch |err| return switch (err) {
        error.CanvasCommandLimit => failFmt(js, "canvas command capacity exhausted: max_canvas_commands={d}, asked for at least {d}", .{ tree_mod.max_canvas_commands, tree_mod.max_canvas_commands + 1 }),
        error.CanvasPointLimit => failFmt(js, "canvas point capacity exhausted: max_canvas_points={d}, asked for at least {d}", .{ tree_mod.max_canvas_points, tree_mod.max_canvas_points + 1 }),
        error.InvalidNode => fail(js, "invalid canvas node id"),
        else => fail(js, "malformed canvas command batch (non-finite value or truncated command)"),
    };
    return qjs.undefinedValue();
}

/// Register a max-rate canvas callback. Its clock is the gpu-surface present
/// completion, not a second OS timer: one visible present produces at most one
/// next frame, so 60 fps animation follows the surface scheduler without a
/// free-running render loop.
fn onCanvasFrame(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 2 or !c.JS_IsFunction(js, argv[1])) return fail(js, "onCanvasFrame expects id and function");
    const id = idArg(js, argv[0]) catch return fail(js, "invalid canvas node id");
    _ = state(js).tree.canvasState(id) catch return fail(js, "invalid canvas node id");
    var free: ?*CanvasFrameSlot = null;
    for (&state(js).canvas_frames) |*slot| {
        if (slot.node_id == id) {
            c.JS_FreeValue(js, slot.callback);
            slot.callback = c.JS_DupValue(js, argv[1]);
            return qjs.undefinedValue();
        }
        if (free == null and slot.node_id == 0) free = slot;
    }
    const slot = free orelse return failFmt(
        js,
        "canvas frame callback capacity exhausted: max_canvas_frames={d}, asked for {d}",
        .{ max_canvas_frames, max_canvas_frames + 1 },
    );
    slot.* = .{ .node_id = id, .callback = c.JS_DupValue(js, argv[1]) };
    return qjs.undefinedValue();
}

fn onCanvasResize(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 1 or !c.JS_IsFunction(js, argv[0])) return fail(js, "onCanvasResize expects one function");
    const bridge_state = state(js);
    c.JS_FreeValue(js, bridge_state.canvas_resize_callback);
    bridge_state.canvas_resize_callback = c.JS_DupValue(js, argv[0]);
    return qjs.undefinedValue();
}

fn clearCanvasFrame(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 1) return fail(js, "clearCanvasFrame expects one id");
    const id = idArg(js, argv[0]) catch return fail(js, "invalid canvas node id");
    for (&state(js).canvas_frames) |*slot| {
        if (slot.node_id != id) continue;
        c.JS_FreeValue(js, slot.callback);
        slot.* = .{};
        break;
    }
    return qjs.undefinedValue();
}

pub fn hasCanvasFrames(bridge_state: *const State) bool {
    for (&bridge_state.canvas_frames) |slot| if (slot.node_id != 0) return true;
    return false;
}

pub fn dispatchCanvasFrames(ctx: *c.JSContext, bridge_state: *State, timestamp_ns: u64) bool {
    const timestamp = c.JS_NewFloat64(ctx, @as(f64, @floatFromInt(timestamp_ns)) / @as(f64, std.time.ns_per_s));
    defer c.JS_FreeValue(ctx, timestamp);
    for (&bridge_state.canvas_frames) |*slot| {
        if (slot.node_id == 0 or !c.JS_IsFunction(ctx, slot.callback)) continue;
        var arguments = [_]c.JSValue{timestamp};
        const result = c.JS_Call(ctx, slot.callback, qjs.undefinedValue(), arguments.len, &arguments);
        const succeeded = !c.JS_IsException(result);
        c.JS_FreeValue(ctx, result);
        if (!succeeded) return false;
    }
    return true;
}

pub fn dispatchCanvasResize(ctx: *c.JSContext, bridge_state: *State, node_id: tree_mod.NodeId, width: f32, height: f32) bool {
    if (!c.JS_IsFunction(ctx, bridge_state.canvas_resize_callback)) return true;
    var arguments = [_]c.JSValue{
        c.JS_NewUint32(ctx, node_id),
        c.JS_NewFloat64(ctx, width),
        c.JS_NewFloat64(ctx, height),
    };
    defer for (&arguments) |argument| c.JS_FreeValue(ctx, argument);
    const result = c.JS_Call(ctx, bridge_state.canvas_resize_callback, qjs.undefinedValue(), arguments.len, &arguments);
    const succeeded = !c.JS_IsException(result);
    c.JS_FreeValue(ctx, result);
    return succeeded;
}

/// `wfetch` uses WinHTTP on Windows and ephemeral NSURLSession on macOS. The
/// bridge copies one bounded request into one of four slots and runs the
/// blocking exchange on a worker; only `drainFetches` touches QuickJS from the
/// Native main loop. Both transports return the original 3xx instead of
/// following it, so no request can escape the exact manifest host checked here.
fn fetch(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 4) return fail(js, "fetch expects url, method, headers JSON, and body");
    const url = stringArg(js, argv[0]) catch return fail(js, "fetch url must be a string");
    defer c.JS_FreeCString(js, url.raw);
    const method = stringArg(js, argv[1]) catch return fail(js, "fetch method must be a string");
    defer c.JS_FreeCString(js, method.raw);
    const headers_json = stringArg(js, argv[2]) catch return fail(js, "fetch headers must be JSON");
    defer c.JS_FreeCString(js, headers_json.raw);
    const body = stringArg(js, argv[3]) catch return fail(js, "fetch body must be a string");
    defer c.JS_FreeCString(js, body.raw);

    var resolving: [2]c.JSValue = undefined;
    const promise = c.JS_NewPromiseCapability(js, &resolving);
    if (c.JS_IsException(promise)) return promise;
    const parsed_url = network.parseHttpsUrl(url.bytes) catch {
        rejectPromise(js, resolving[1], "HttpsRequired: wfetch accepts only https:// URLs");
        c.JS_FreeValue(js, resolving[0]);
        c.JS_FreeValue(js, resolving[1]);
        return promise;
    };
    if (!network.originDeclared(state(js).origins, parsed_url.declared_host)) {
        var message_buffer: [320]u8 = undefined;
        const message = std.fmt.bufPrint(&message_buffer, "OriginNotDeclared: add \"{s}\" to origins in your widget config", .{parsed_url.declared_host}) catch "OriginNotDeclared";
        rejectPromise(js, resolving[1], message);
        c.JS_FreeValue(js, resolving[0]);
        c.JS_FreeValue(js, resolving[1]);
        return promise;
    }
    if (!network.requestWithinCap(url.bytes.len, headers_json.bytes.len, body.bytes.len)) {
        rejectPromise(js, resolving[1], "RequestTooLarge: wfetch request exceeds 5 MB");
        c.JS_FreeValue(js, resolving[0]);
        c.JS_FreeValue(js, resolving[1]);
        return promise;
    }
    const bridge_state = state(js);
    const slot = for (&bridge_state.fetches) |*candidate| {
        if (!candidate.active) break candidate;
    } else {
        rejectPromise(js, resolving[1], "FetchCapacityExceeded: at most 4 requests may run concurrently");
        c.JS_FreeValue(js, resolving[0]);
        c.JS_FreeValue(js, resolving[1]);
        return promise;
    };
    slot.* = .{ .active = true, .resolve = resolving[0], .reject = resolving[1] };
    slot.request.cancelled = &slot.cancelled;
    slot.request.method = if (std.ascii.eqlIgnoreCase(method.bytes, "GET")) .get else if (std.ascii.eqlIgnoreCase(method.bytes, "POST")) .post else {
        rejectAndResetFetch(js, slot, "wfetch method must be GET or POST");
        return promise;
    };
    slot.request.url = std.heap.page_allocator.dupe(u8, url.bytes) catch {
        rejectAndResetFetch(js, slot, "FetchFailed: request allocation failed");
        return promise;
    };
    slot.request.body = std.heap.page_allocator.dupe(u8, body.bytes) catch {
        rejectAndResetFetch(js, slot, "FetchFailed: request allocation failed");
        return promise;
    };
    slot.request.headers = copyHeadersJson(headers_json.bytes) orelse {
        rejectAndResetFetch(js, slot, "wfetch headers must be string values without CR/LF");
        return promise;
    };
    slot.thread = std.Thread.spawn(.{}, fetchWorker, .{slot}) catch {
        rejectAndResetFetch(js, slot, "FetchFailed: could not start request worker");
        return promise;
    };
    return promise;
}

fn copyHeadersJson(source: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, source, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.heap.page_allocator);
    var iterator = parsed.value.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .string) return null;
        const name = entry.key_ptr.*;
        const value = entry.value_ptr.string;
        if (name.len == 0 or std.mem.indexOfAny(u8, name, ":\r\n") != null or std.mem.indexOfAny(u8, value, "\r\n") != null) return null;
        const line = std.fmt.allocPrint(std.heap.page_allocator, "{s}: {s}\r\n", .{ name, value }) catch return null;
        defer std.heap.page_allocator.free(line);
        output.appendSlice(std.heap.page_allocator, line) catch return null;
    }
    return output.toOwnedSlice(std.heap.page_allocator) catch null;
}

fn fetchWorker(slot: *FetchSlot) void {
    slot.result = network.perform(&slot.request, std.heap.page_allocator);
    slot.done.store(true, .release);
}

fn rejectPromise(ctx: *c.JSContext, reject: c.JSValue, message: []const u8) void {
    const reason = c.JS_NewStringLen(ctx, message.ptr, message.len);
    defer c.JS_FreeValue(ctx, reason);
    var arguments = [_]c.JSValue{reason};
    const result = c.JS_Call(ctx, reject, qjs.undefinedValue(), 1, &arguments);
    c.JS_FreeValue(ctx, result);
}

fn rejectAndResetFetch(ctx: *c.JSContext, slot: *FetchSlot, message: []const u8) void {
    rejectPromise(ctx, slot.reject, message);
    c.JS_FreeValue(ctx, slot.resolve);
    c.JS_FreeValue(ctx, slot.reject);
    slot.request.deinit(std.heap.page_allocator);
    slot.* = .{};
}

pub fn hasActiveFetches(bridge_state: *const State) bool {
    for (&bridge_state.fetches) |*slot| if (slot.active) return true;
    return false;
}

/// Resolve completed worker slots on the QuickJS/main-loop thread. The SDK's
/// promise continuation enters the ordinary pending-job queue, so its state
/// update is batched by the same reconciler path as a timer or button event.
pub fn drainFetches(ctx: *c.JSContext, bridge_state: *State) void {
    for (&bridge_state.fetches) |*slot| {
        if (!slot.active or !slot.done.load(.acquire)) continue;
        if (slot.thread) |thread| thread.join();
        slot.thread = null;
        if (slot.result.failure == .none) {
            const response = c.JS_NewObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, response, "status", c.JS_NewUint32(ctx, slot.result.status));
            const body = slot.result.body orelse &.{};
            _ = c.JS_SetPropertyStr(ctx, response, "body", c.JS_NewStringLen(ctx, body.ptr, body.len));
            var arguments = [_]c.JSValue{response};
            const call_result = c.JS_Call(ctx, slot.resolve, qjs.undefinedValue(), 1, &arguments);
            c.JS_FreeValue(ctx, call_result);
            c.JS_FreeValue(ctx, response);
        } else {
            rejectPromise(ctx, slot.reject, switch (slot.result.failure) {
                .invalid_url => "HttpsRequired: wfetch accepts only https:// URLs",
                .timed_out => "FetchTimeout: request exceeded 15 seconds",
                .request_too_large => "RequestTooLarge: wfetch request exceeds 5 MB",
                .response_too_large => "ResponseTooLarge: wfetch response exceeds 5 MB",
                .cancelled => "FetchCancelled: request was cancelled",
                .request_failed => "FetchFailed: request failed",
                .none => unreachable,
            });
        }
        c.JS_FreeValue(ctx, slot.resolve);
        c.JS_FreeValue(ctx, slot.reject);
        slot.request.deinit(std.heap.page_allocator);
        slot.result.deinit(std.heap.page_allocator);
        slot.* = .{};
    }
}

pub const PressPayload = struct { x: f64, y: f64, width: f64, height: f64 };
pub const EventPayload = union(enum) { number: f64, press: PressPayload };

pub fn dispatchEvent(ctx: *c.JSContext, bridge_state: *State, node_id: tree_mod.NodeId, kind: []const u8, payload: ?EventPayload) bool {
    if (!c.JS_IsFunction(ctx, bridge_state.event_callback)) return true;
    const kind_value = c.JS_NewStringLen(ctx, kind.ptr, kind.len);
    defer c.JS_FreeValue(ctx, kind_value);
    const payload_value = if (payload) |value| switch (value) {
        .number => |number| c.JS_NewFloat64(ctx, number),
        .press => |press| block: {
            const object = c.JS_NewObject(ctx);
            if (c.JS_IsException(object)) return false;
            _ = c.JS_SetPropertyStr(ctx, object, "x", c.JS_NewFloat64(ctx, press.x));
            _ = c.JS_SetPropertyStr(ctx, object, "y", c.JS_NewFloat64(ctx, press.y));
            _ = c.JS_SetPropertyStr(ctx, object, "w", c.JS_NewFloat64(ctx, press.width));
            _ = c.JS_SetPropertyStr(ctx, object, "h", c.JS_NewFloat64(ctx, press.height));
            break :block object;
        },
    } else qjs.nullValue();
    defer c.JS_FreeValue(ctx, payload_value);
    var arguments = [_]c.JSValue{ c.JS_NewUint32(ctx, node_id), kind_value, payload_value };
    defer c.JS_FreeValue(ctx, arguments[0]);
    const result = c.JS_Call(ctx, bridge_state.event_callback, qjs.undefinedValue(), arguments.len, &arguments);
    const succeeded = !c.JS_IsException(result);
    c.JS_FreeValue(ctx, result);
    return succeeded;
}

fn isColorProperty(key: []const u8) bool {
    return std.mem.eql(u8, key, "background") or std.mem.eql(u8, key, "textColor") or std.mem.eql(u8, key, "borderColor") or
        std.mem.eql(u8, key, "hoverBackground") or std.mem.eql(u8, key, "hoverTextColor") or std.mem.eql(u8, key, "hoverBorderColor") or
        std.mem.eql(u8, key, "pressedBackground") or std.mem.eql(u8, key, "pressedTextColor") or std.mem.eql(u8, key, "pressedBorderColor");
}

pub fn dispatchProvider(ctx: *c.JSContext, bridge_state: *State, line: []const u8) bool {
    if (!c.JS_IsFunction(ctx, bridge_state.provider_callback)) return true;
    const value = c.JS_NewStringLen(ctx, line.ptr, line.len);
    defer c.JS_FreeValue(ctx, value);
    var arguments = [_]c.JSValue{value};
    const result = c.JS_Call(ctx, bridge_state.provider_callback, qjs.undefinedValue(), 1, &arguments);
    const succeeded = !c.JS_IsException(result);
    c.JS_FreeValue(ctx, result);
    return succeeded;
}

fn settleMedia(ctx: *c.JSContext, bridge_state: *State, index: usize, ok: ?bool, error_name: ?[]const u8) bool {
    const id = bridge_state.media_tracker.slots[index].id;
    if (id == 0) return true;
    bridge_state.provider.unregisterAck(id);
    bridge_state.media_tracker.remove(index);
    const callback = bridge_state.media_callbacks[index];
    bridge_state.media_callbacks[index] = qjs.undefinedValue();
    defer c.JS_FreeValue(ctx, callback);
    const ok_value = if (ok) |value| c.JS_NewBool(ctx, value) else qjs.nullValue();
    defer c.JS_FreeValue(ctx, ok_value);
    const error_value = if (error_name) |name| c.JS_NewStringLen(ctx, name.ptr, name.len) else qjs.nullValue();
    defer c.JS_FreeValue(ctx, error_value);
    var arguments = [_]c.JSValue{ ok_value, error_value };
    const result = c.JS_Call(ctx, callback, qjs.undefinedValue(), arguments.len, &arguments);
    const succeeded = !c.JS_IsException(result);
    c.JS_FreeValue(ctx, result);
    return succeeded;
}

fn settleAllMedia(ctx: *c.JSContext, bridge_state: *State, error_name: []const u8) void {
    for (0..max_media_pending) |index| _ = settleMedia(ctx, bridge_state, index, null, error_name);
}

/// Ack delivery shares the provider app-loop turn but never shares the
/// provider frame queue or installs another JS dispatcher.
pub fn dispatchMediaAcks(ctx: *c.JSContext, bridge_state: *State) bool {
    if (bridge_state.provider.protocolFailed()) {
        settleAllMedia(ctx, bridge_state, "MalformedMediaAck");
        return true;
    }
    while (bridge_state.provider.takeAck()) |ack| {
        const index = bridge_state.media_tracker.indexOf(ack.id) orelse continue;
        if (!settleMedia(ctx, bridge_state, index, ack.ok, null)) return false;
    }
    if (bridge_state.provider.isDisconnected()) {
        settleAllMedia(ctx, bridge_state, "MediaChannelDisconnected");
        return true;
    }
    const now_ms = bridge_state.provider.nowMilliseconds();
    for (0..max_media_pending) |index| {
        if (bridge_state.media_tracker.expired(index, now_ms) and
            !settleMedia(ctx, bridge_state, index, null, "MediaCommandTimeout")) return false;
    }
    return true;
}

pub fn nextMediaDeadlineMs(bridge_state: *const State) ?u64 {
    return bridge_state.media_tracker.nextDeadline();
}

fn log(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 1) return fail(js, "log expects one string");
    const value = stringArg(js, argv[0]) catch return fail(js, "log expects one string");
    defer c.JS_FreeCString(js, value.raw);
    std.log.info("widget: {s}", .{value.bytes});
    return qjs.undefinedValue();
}

fn consoleLog(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    return consoleWrite(ctx, argc, argv, .info);
}

fn consoleWarn(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    return consoleWrite(ctx, argc, argv, .warn);
}

fn consoleError(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    return consoleWrite(ctx, argc, argv, .err);
}

const ConsoleLevel = enum { info, warn, err };

fn consoleWrite(ctx: ?*c.JSContext, argc: c_int, argv: [*c]c.JSValueConst, level: ConsoleLevel) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    var buffer: [max_console_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    var index: usize = 0;
    while (index < @as(usize, @intCast(argc))) : (index += 1) {
        if (index > 0) writer.writeByte(' ') catch break;
        var len: usize = 0;
        const raw = c.JS_ToCStringLen2(js, &len, argv[index], false) orelse continue;
        defer c.JS_FreeCString(js, raw);
        writer.writeAll(raw[0..len]) catch break;
    }
    switch (level) {
        .info => std.log.info("widget console: {s}", .{writer.buffered()}),
        .warn => std.log.warn("widget console: {s}", .{writer.buffered()}),
        .err => std.log.err("widget console: {s}", .{writer.buffered()}),
    }
    return qjs.undefinedValue();
}

fn parseColor(value: []const u8) ?@import("native_sdk").canvas.Color {
    if (value.len != 9 or value[0] != '#') return null;
    const rgba = std.fmt.parseInt(u32, value[1..], 16) catch return null;
    return @import("native_sdk").canvas.Color.rgba8(@truncate(rgba >> 24), @truncate(rgba >> 16), @truncate(rgba >> 8), @truncate(rgba));
}

fn parseBoxShadow(value: []const u8) ?tree_mod.BoxShadow {
    var fields = std.mem.tokenizeScalar(u8, value, ' ');
    const x = parseShadowFloat(fields.next()) orelse return null;
    const y = parseShadowFloat(fields.next()) orelse return null;
    const blur = parseShadowFloat(fields.next()) orelse return null;
    const spread = parseShadowFloat(fields.next()) orelse return null;
    const color = parseColor(fields.next() orelse return null) orelse return null;
    if (fields.next() != null or blur < 0) return null;
    return .{ .offset = .{ .dx = x, .dy = y }, .blur = blur, .spread = spread, .color = color };
}

fn parseTextShadow(value: []const u8) ?@import("native_sdk").canvas.TextShadow {
    var fields = std.mem.tokenizeScalar(u8, value, ' ');
    const x = parseShadowFloat(fields.next()) orelse return null;
    const y = parseShadowFloat(fields.next()) orelse return null;
    const blur = parseShadowFloat(fields.next()) orelse return null;
    const color = parseColor(fields.next() orelse return null) orelse return null;
    if (fields.next() != null or blur < 0) return null;
    return .{ .offset = .{ .dx = x, .dy = y }, .blur = blur, .color = color };
}

fn parseShadowFloat(value: ?[]const u8) ?f32 {
    const number = std.fmt.parseFloat(f32, value orelse return null) catch return null;
    return if (std.math.isFinite(number)) number else null;
}

test "packed shadow properties accept bounded tuples and reject malformed values" {
    const box = parseBoxShadow("-2 3 8 -1 #11223344") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f32, -2), box.offset.dx);
    try std.testing.expectEqual(@as(f32, 8), box.blur);
    try std.testing.expectEqual(@as(f32, -1), box.spread);
    const text_shadow = parseTextShadow("1 2 4 #AABBCCDD") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f32, 2), text_shadow.offset.dy);
    try std.testing.expectEqual(@as(f32, 4), text_shadow.blur);
    try std.testing.expect(parseBoxShadow("0 2 -4 0 #000000FF") == null);
    try std.testing.expect(parseBoxShadow("0 2 4 #000000FF") == null);
    try std.testing.expect(parseTextShadow("0 2 4 1 #000000FF") == null);
}

test "native mediaCommand exists only for a declared runtime capability" {
    const Probe = struct {
        fn hasMediaCommand(enabled: bool) !bool {
            const runtime = c.JS_NewRuntime() orelse return error.OutOfMemory;
            defer c.JS_FreeRuntime(runtime);
            const context = c.JS_NewContext(runtime) orelse return error.OutOfMemory;
            defer c.JS_FreeContext(context);
            var bridge_state: State = .{
                .tree = undefined,
                .storage = undefined,
                .provider = undefined,
                .origins = &.{},
                .media_transport_enabled = enabled,
            };
            try install(context, &bridge_state);
            defer deinit(context, &bridge_state);
            const global = c.JS_GetGlobalObject(context);
            defer c.JS_FreeValue(context, global);
            const native = c.JS_GetPropertyStr(context, global, "native");
            defer c.JS_FreeValue(context, native);
            const command = c.JS_GetPropertyStr(context, native, "mediaCommand");
            defer c.JS_FreeValue(context, command);
            return c.JS_IsFunction(context, command);
        }
    };

    try std.testing.expect(!try Probe.hasMediaCommand(false));
    try std.testing.expect(try Probe.hasMediaCommand(true));
}

test "media callback is installed before send and rollback releases its slot" {
    const runtime = c.JS_NewRuntime() orelse return error.OutOfMemory;
    defer c.JS_FreeRuntime(runtime);
    const context = c.JS_NewContext(runtime) orelse return error.OutOfMemory;
    defer c.JS_FreeContext(context);
    var bridge_state: State = .{
        .tree = undefined,
        .storage = undefined,
        .provider = undefined,
        .origins = &.{},
    };
    const callback = c.JS_NewCFunction2(context, consoleLog, "callback", 1, c.JS_CFUNC_generic, 0);
    defer c.JS_FreeValue(context, callback);
    try std.testing.expect(c.JS_IsFunction(context, callback));

    installMediaCallback(context, &bridge_state, 0, callback);
    try std.testing.expect(c.JS_IsFunction(context, bridge_state.media_callbacks[0]));
    discardMediaCallback(context, &bridge_state, 0);
    try std.testing.expect(c.JS_IsUndefined(bridge_state.media_callbacks[0]));
}
