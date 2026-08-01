const std = @import("std");
const bridge = @import("bridge.zig");
const platform = @import("platform/root.zig");
const qjs = @import("qjs.zig");
const provider_mod = @import("provider.zig");
const tree_mod = @import("tree.zig");
const storage_mod = @import("storage.zig");
const c = qjs.c;

// QuickJS receipt (2026-07-29): a synthetic worst-good retained view with
// 1,024 JS node records measured 629,335 allocator bytes (553,712 live).
// 32 MiB leaves >50x headroom. QuickJS allocates on demand, so the allowance
// reserves no resident memory.
pub const memory_limit_bytes: usize = 32 * 1024 * 1024;
// The same 1,024-record evaluation measured 8-11 ms in Debug on the Windows
// test runner. 100 ms leaves >9x measured headroom while still interrupting a
// runaway callback. This watchdog retains no memory.
pub const turn_budget_ms: u64 = 100;
// QuickJS's upstream 1 MiB default measured only 16 calls of a trivial
// recursive JS function. 4 MiB measured 70 calls, clearing the receipted
// 32-level widget-tree contract by >2x. runtime/build.zig reserves a 16 MiB
// process stack (4x this guard); stack pages commit only as recursion uses them.
pub const max_stack_bytes: usize = 4 * 1024 * 1024;
// Four simultaneous fetch slots can reject together; eight pending promise
// records leave 2x burst headroom. Each record is 32 bytes, so the fixed
// metadata costs 256 bytes; referenced JS values already live in QuickJS.
const max_pending_rejections: usize = 8;
// Exception detail ultimately enters widget_log's 8 KiB line buffer. 6,000
// bytes leaves >2 KiB for logger framing; this is one turn-lifetime stack
// buffer, not retained isolate memory. The visible first line is 150 bytes,
// enough for the longest current named budget diagnostic (<128 bytes).
const max_exception_detail_bytes: usize = 6000;
const max_visible_rejection_bytes: usize = 150;

pub const Error = error{
    OutOfMemory,
    QuickJs,
    ScriptException,
};

const PendingRejection = struct {
    promise: c.JSValue = qjs.undefinedValue(),
    reason: c.JSValue = qjs.undefinedValue(),
};

/// A single-widget QuickJS isolate. It runs only when the Native SDK main loop
/// enters `fireTimer`; no JS thread, OS timer, or hidden render loop exists.
pub const Engine = struct {
    runtime: *c.JSRuntime,
    context: *c.JSContext,
    bridge_state: bridge.State,
    provider: *provider_mod.Client,
    deadline_ms: u64 = 0,
    executing: bool = false,
    pending_rejections: [max_pending_rejections]PendingRejection = [_]PendingRejection{.{}} ** max_pending_rejections,

    pub fn create(
        allocator: std.mem.Allocator,
        tree: *tree_mod.Tree,
        storage: *storage_mod.Store,
        origins: []const []const u8,
        provider: *provider_mod.Client,
        media_transport_enabled: bool,
    ) !*Engine {
        const self = allocator.create(Engine) catch return error.OutOfMemory;
        errdefer allocator.destroy(self);
        const runtime = c.JS_NewRuntime() orelse return error.OutOfMemory;
        errdefer c.JS_FreeRuntime(runtime);
        const context = c.JS_NewContext(runtime) orelse return error.OutOfMemory;
        errdefer c.JS_FreeContext(context);
        self.* = .{
            .runtime = runtime,
            .context = context,
            .bridge_state = undefined,
            .provider = provider,
        };
        self.bridge_state = .{
            .tree = tree,
            .storage = storage,
            .provider = provider,
            .origins = origins,
            .media_transport_enabled = media_transport_enabled,
        };
        c.JS_SetMemoryLimit(runtime, memory_limit_bytes);
        c.JS_SetMaxStackSize(runtime, max_stack_bytes);
        c.JS_SetInterruptHandler(runtime, interruptHandler, self);
        c.JS_SetHostPromiseRejectionTracker(runtime, promiseRejectionTracker, self);
        bridge.install(context, &self.bridge_state) catch return error.QuickJs;
        return self;
    }

    pub fn destroy(self: *Engine, allocator: std.mem.Allocator) void {
        self.flushStorage();
        for (&self.pending_rejections) |*pending| {
            c.JS_FreeValue(self.context, pending.promise);
            c.JS_FreeValue(self.context, pending.reason);
            pending.* = .{};
        }
        bridge.deinit(self.context, &self.bridge_state);
        c.JS_FreeContext(self.context);
        c.JS_FreeRuntime(self.runtime);
        allocator.destroy(self);
    }

    pub fn evaluate(self: *Engine, source: []const u8, file_name: [*:0]const u8) Error!void {
        // The parser accepts a length but still uses one sentinel byte for
        // its end token. Widget files come from readFileAlloc, whose spare
        // capacity is not initialized, so make that byte explicit.
        const terminated = std.heap.page_allocator.dupeZ(u8, source) catch return error.OutOfMemory;
        defer std.heap.page_allocator.free(terminated);
        self.beginTurn();
        defer self.endTurn();
        const result = c.JS_Eval(self.context, terminated.ptr, source.len, file_name, c.JS_EVAL_TYPE_GLOBAL);
        defer c.JS_FreeValue(self.context, result);
        if (c.JS_IsException(result)) return self.reportException();
        try self.pumpJobs();
    }

    pub fn timers(self: *const Engine) []const bridge.TimerSlot {
        return &self.bridge_state.timers;
    }

    pub fn memoryUsage(self: *const Engine) c.JSMemoryUsage {
        var usage: c.JSMemoryUsage = undefined;
        c.JS_ComputeMemoryUsage(self.runtime, &usage);
        return usage;
    }

    pub fn setTree(self: *Engine, tree: *tree_mod.Tree) void {
        self.bridge_state.tree = tree;
    }

    pub fn setHotSwapSeed(self: *Engine, seed: []const u8) Error!void {
        const global = c.JS_GetGlobalObject(self.context);
        defer c.JS_FreeValue(self.context, global);
        const value = c.JS_NewStringLen(self.context, seed.ptr, seed.len);
        if (c.JS_IsException(value) or c.JS_SetPropertyStr(self.context, global, "__weaverHotSwapSeed", value) < 0) return error.QuickJs;
    }

    pub fn captureHotSwap(self: *Engine, allocator: std.mem.Allocator) ?[]u8 {
        const result = self.callGlobal("__weaverCaptureHotSwap") catch |err| {
            std.log.warn("dev hot swap state capture failed; candidate will use fresh state: {s}", .{@errorName(err)});
            return null;
        };
        defer c.JS_FreeValue(self.context, result);
        if (!c.JS_IsString(result)) return null;
        var len: usize = 0;
        const raw = c.JS_ToCStringLen2(self.context, &len, result, false) orelse {
            std.log.warn("dev hot swap state capture could not be converted to UTF-8; candidate will use fresh state", .{});
            return null;
        };
        defer c.JS_FreeCString(self.context, raw);
        return allocator.dupe(u8, raw[0..len]) catch |err| {
            std.log.warn("dev hot swap state capture allocation failed; candidate will use fresh state: {s}", .{@errorName(err)});
            return null;
        };
    }

    pub fn hotSwapAccepted(self: *Engine) bool {
        const result = self.callGlobal("__weaverHotSwapAccepted") catch |err| {
            std.log.warn("dev hot swap state acceptance check failed; candidate will use fresh state: {s}", .{@errorName(err)});
            return false;
        };
        defer c.JS_FreeValue(self.context, result);
        return c.JS_ToBool(self.context, result) == 1;
    }

    pub fn fireTimer(self: *Engine, timer_id: u64, timestamp_ns: u64) Error!void {
        const timer = for (&self.bridge_state.timers) |*candidate| {
            if (candidate.active and candidate.id == timer_id) break candidate;
        } else return;
        if (!c.JS_IsFunction(self.context, timer.callback)) return;
        self.beginTurn();
        defer self.endTurn();
        const timestamp = c.JS_NewFloat64(self.context, @as(f64, @floatFromInt(timestamp_ns)) / @as(f64, std.time.ns_per_s));
        defer c.JS_FreeValue(self.context, timestamp);
        var arguments = [_]c.JSValue{timestamp};
        const result = c.JS_Call(self.context, timer.callback, qjs.undefinedValue(), arguments.len, &arguments);
        defer c.JS_FreeValue(self.context, result);
        if (c.JS_IsException(result)) return self.reportException();
        try self.pumpJobs();
    }

    pub fn fireEvent(self: *Engine, node_id: tree_mod.NodeId, kind: []const u8, payload: ?bridge.EventPayload) Error!void {
        self.beginTurn();
        defer self.endTurn();
        if (!bridge.dispatchEvent(self.context, &self.bridge_state, node_id, kind, payload)) return self.reportException();
        try self.pumpJobs();
    }

    pub fn hasCanvasFrames(self: *const Engine) bool {
        return bridge.hasCanvasFrames(&self.bridge_state);
    }

    pub fn fireCanvasFrames(self: *Engine, timestamp_ns: u64) Error!void {
        self.beginTurn();
        defer self.endTurn();
        if (!bridge.dispatchCanvasFrames(self.context, &self.bridge_state, timestamp_ns)) return self.reportException();
        try self.pumpJobs();
    }

    pub fn fireCanvasResize(self: *Engine, node_id: tree_mod.NodeId, width: f32, height: f32) Error!void {
        self.beginTurn();
        defer self.endTurn();
        if (!bridge.dispatchCanvasResize(self.context, &self.bridge_state, node_id, width, height)) return self.reportException();
        try self.pumpJobs();
    }

    pub fn hasActiveFetches(self: *const Engine) bool {
        return bridge.hasActiveFetches(&self.bridge_state);
    }

    pub fn renderFailed(self: *const Engine) bool {
        return bridge.renderFailed(&self.bridge_state);
    }

    pub fn drainFetches(self: *Engine) Error!void {
        self.beginTurn();
        defer self.endTurn();
        bridge.drainFetches(self.context, &self.bridge_state);
        try self.pumpJobs();
    }

    pub fn hasHostProvider(self: *const Engine) bool {
        return self.provider.isAvailable();
    }

    pub fn nextMediaDeadlineMs(self: *const Engine) ?u64 {
        return bridge.nextMediaDeadlineMs(&self.bridge_state);
    }

    pub fn drainProviders(self: *Engine) Error!usize {
        self.beginTurn();
        defer self.endTurn();
        var line_buffer: [provider_mod.max_line_bytes]u8 = undefined;
        var count: usize = 0;
        while (self.provider.take(&line_buffer)) |line| {
            if (!bridge.dispatchProvider(self.context, &self.bridge_state, line)) return self.reportException();
            count += 1;
        }
        if (!bridge.dispatchMediaAcks(self.context, &self.bridge_state)) return self.reportException();
        try self.pumpJobs();
        return count;
    }

    fn pumpJobs(self: *Engine) Error!void {
        while (true) {
            var job_context: ?*c.JSContext = null;
            const result = c.JS_ExecutePendingJob(self.runtime, &job_context);
            if (result == 0) {
                self.flushUnhandledRejections();
                return;
            }
            if (result < 0) return self.reportExceptionFrom(job_context orelse self.context);
        }
    }

    fn callGlobal(self: *Engine, name: [*:0]const u8) Error!c.JSValue {
        self.beginTurn();
        defer self.endTurn();
        const global = c.JS_GetGlobalObject(self.context);
        defer c.JS_FreeValue(self.context, global);
        const callback = c.JS_GetPropertyStr(self.context, global, name);
        defer c.JS_FreeValue(self.context, callback);
        if (!c.JS_IsFunction(self.context, callback)) return error.QuickJs;
        const result = c.JS_Call(self.context, callback, qjs.undefinedValue(), 0, null);
        if (c.JS_IsException(result)) {
            c.JS_FreeValue(self.context, result);
            return self.reportException();
        }
        return result;
    }

    fn beginTurn(self: *Engine) void {
        // QuickJS records its C-stack top when the runtime is created, but
        // platform callbacks can enter from a materially deeper native
        // dispatch path (notably canvas resize during a near-cap rebuild).
        // A turn starts with no live JS frames, so refresh the reference
        // point before applying the receipted recursion guard above.
        if (!self.executing) c.JS_UpdateStackTop(self.runtime);
        self.deadline_ms = platform.monotonicMilliseconds() + turn_budget_ms;
        self.executing = true;
    }

    fn endTurn(self: *Engine) void {
        self.executing = false;
    }

    /// SDK storage normally flushes on its 200 ms native debounce. A clean
    /// window close gets one final synchronous hook. weaverd posts WM_CLOSE
    /// before its bounded termination fallback, so ordinary dev restarts,
    /// uninstall, and host shutdown all take this path; only a crashed or
    /// externally force-killed widget relies on the completed debounce.
    fn flushStorage(self: *Engine) void {
        const global = c.JS_GetGlobalObject(self.context);
        defer c.JS_FreeValue(self.context, global);
        const callback = c.JS_GetPropertyStr(self.context, global, "__weaverFlushStorage");
        defer c.JS_FreeValue(self.context, callback);
        if (!c.JS_IsFunction(self.context, callback)) return;
        const result = c.JS_Call(self.context, callback, qjs.undefinedValue(), 0, null);
        defer c.JS_FreeValue(self.context, result);
        if (c.JS_IsException(result)) logExceptionFrom(self.context);
    }

    fn reportException(self: *Engine) Error {
        return self.reportExceptionFrom(self.context);
    }

    fn reportExceptionFrom(_: *Engine, context: *c.JSContext) Error {
        logExceptionFrom(context);
        return error.ScriptException;
    }

    fn flushUnhandledRejections(self: *Engine) void {
        for (&self.pending_rejections) |*pending| {
            if (c.JS_IsUndefined(pending.promise)) continue;
            var detail_buffer: [max_exception_detail_bytes]u8 = undefined;
            const details = valueDetails(self.context, pending.reason, &detail_buffer);
            if (self.bridge_state.emit_error_logs) std.log.err("widget unhandled promise rejection:\n{s}", .{details});
            self.bridge_state.render_failed = true;
            var visible_buffer: [tree_mod.max_text_bytes]u8 = undefined;
            const first_line_length = std.mem.indexOfScalar(u8, details, '\n') orelse details.len;
            const first_line = validUtf8Prefix(details[0..first_line_length], max_visible_rejection_bytes);
            const visible = std.fmt.bufPrint(
                &visible_buffer,
                "unhandled promise rejection\n{s}",
                .{first_line},
            ) catch "Unhandled promise rejection; see the per-widget log";
            self.bridge_state.tree.showError(visible);
            c.JS_FreeValue(self.context, pending.promise);
            c.JS_FreeValue(self.context, pending.reason);
            pending.* = .{};
        }
    }
};

fn logExceptionFrom(context: *c.JSContext) void {
    const exception = c.JS_GetException(context);
    defer c.JS_FreeValue(context, exception);
    var buffer: [max_exception_detail_bytes]u8 = undefined;
    std.log.err("widget JavaScript exception:\n{s}", .{valueDetails(context, exception, &buffer)});
}

fn valueDetails(context: *c.JSContext, value: c.JSValueConst, buffer: []u8) []const u8 {
    if (c.JS_IsError(value)) return errorValueDetails(context, value, buffer);
    var len: usize = 0;
    const raw = c.JS_ToCStringLen2(context, &len, value, false) orelse return "JavaScript value could not be formatted";
    defer c.JS_FreeCString(context, raw);
    const source = validUtf8Prefix(raw[0..len], buffer.len);
    @memcpy(buffer[0..source.len], source);
    return buffer[0..source.len];
}

fn errorValueDetails(context: *c.JSContext, value: c.JSValueConst, buffer: []u8) []const u8 {
    const name_value = c.JS_GetPropertyStr(context, value, "name");
    defer c.JS_FreeValue(context, name_value);
    const message_value = c.JS_GetPropertyStr(context, value, "message");
    defer c.JS_FreeValue(context, message_value);
    const stack_value = c.JS_GetPropertyStr(context, value, "stack");
    defer c.JS_FreeValue(context, stack_value);

    var name_len: usize = 0;
    const name_raw = c.JS_ToCStringLen2(context, &name_len, name_value, false);
    defer if (name_raw) |raw| c.JS_FreeCString(context, raw);
    var message_len: usize = 0;
    const message_raw = c.JS_ToCStringLen2(context, &message_len, message_value, false);
    defer if (message_raw) |raw| c.JS_FreeCString(context, raw);
    var stack_len: usize = 0;
    const stack_raw = c.JS_ToCStringLen2(context, &stack_len, stack_value, false);
    defer if (stack_raw) |raw| c.JS_FreeCString(context, raw);

    const name = if (name_raw) |raw| raw[0..name_len] else "Error";
    const message = if (message_raw) |raw| raw[0..message_len] else "";
    const stack = if (stack_raw) |raw| raw[0..stack_len] else "";
    if (message.len == 0 or std.mem.indexOf(u8, stack, message) != null) {
        const source = if (stack.len > 0) stack else name;
        const copied = validUtf8Prefix(source, buffer.len);
        @memcpy(buffer[0..copied.len], copied);
        return buffer[0..copied.len];
    }

    var cursor: usize = 0;
    appendDetail(buffer, &cursor, name);
    appendDetail(buffer, &cursor, ": ");
    appendDetail(buffer, &cursor, message);
    if (stack.len > 0) {
        appendDetail(buffer, &cursor, "\n");
        appendDetail(buffer, &cursor, stack);
    }
    return buffer[0..cursor];
}

fn appendDetail(buffer: []u8, cursor: *usize, value: []const u8) void {
    const copied = validUtf8Prefix(value, buffer.len -| cursor.*);
    @memcpy(buffer[cursor.* .. cursor.* + copied.len], copied);
    cursor.* += copied.len;
}

fn validUtf8Prefix(value: []const u8, maximum: usize) []const u8 {
    var length = @min(value.len, maximum);
    while (length > 0 and !std.unicode.utf8ValidateSlice(value[0..length])) length -= 1;
    return value[0..length];
}

fn promiseRejectionTracker(
    context: ?*c.JSContext,
    promise: c.JSValueConst,
    reason: c.JSValueConst,
    is_handled: bool,
    opaque_context: ?*anyopaque,
) callconv(.c) void {
    const js = context orelse return;
    const self: *Engine = @ptrCast(@alignCast(opaque_context orelse return));
    const promise_pointer = c.JS_VALUE_GET_PTR(promise);
    for (&self.pending_rejections) |*pending| {
        if (c.JS_IsUndefined(pending.promise) or c.JS_VALUE_GET_PTR(pending.promise) != promise_pointer) continue;
        if (is_handled) {
            c.JS_FreeValue(js, pending.promise);
            c.JS_FreeValue(js, pending.reason);
            pending.* = .{};
        }
        return;
    }
    if (is_handled) return;
    for (&self.pending_rejections) |*pending| {
        if (!c.JS_IsUndefined(pending.promise)) continue;
        pending.* = .{
            .promise = c.JS_DupValue(js, promise),
            .reason = c.JS_DupValue(js, reason),
        };
        return;
    }
    var buffer: [tree_mod.max_text_bytes]u8 = undefined;
    std.log.err("widget unhandled promise rejection queue exhausted; newest rejection:\n{s}", .{valueDetails(js, reason, &buffer)});
}

fn interruptHandler(_: ?*c.JSRuntime, context: ?*anyopaque) callconv(.c) c_int {
    const self: *Engine = @ptrCast(@alignCast(context orelse return 1));
    return if (self.executing and platform.monotonicMilliseconds() >= self.deadline_ms) 1 else 0;
}

fn createTestEngine(tree: *tree_mod.Tree, store: *storage_mod.Store, provider: *provider_mod.Client) !*Engine {
    return Engine.create(std.testing.allocator, tree, store, &.{}, provider, false);
}

test "diagnostic truncation preserves UTF-8 boundaries" {
    const details = "failure 💥";
    try std.testing.expectEqualStrings("failure ", validUtf8Prefix(details, details.len - 1));
    try std.testing.expectEqualStrings(details, validUtf8Prefix(details, details.len));
}

test "a forced max_nodes failure is rolled back, named, and replaced by an error surface" {
    var tree: tree_mod.Tree = .{ .allocator = std.testing.allocator };
    defer tree.deinit();
    const committed = try tree.createNode(.text);
    try tree.setText(committed, "healthy");
    try tree.setRoot(committed);

    var provider: provider_mod.Client = .{};
    try provider.init(std.testing.io, null);
    defer provider.deinit();
    var store: storage_mod.Store = .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .directory = ".",
        .path = "weaver-js-engine-test-storage.json",
        .temporary_path = "weaver-js-engine-test-storage.tmp",
    };
    const engine = try createTestEngine(&tree, &store, &provider);
    defer engine.destroy(std.testing.allocator);
    engine.bridge_state.emit_error_logs = false;

    var requested_buffer: [32]u8 = undefined;
    const requested = try std.fmt.bufPrint(&requested_buffer, "{d}", .{tree_mod.max_nodes + 1});
    const script = try std.mem.concat(std.testing.allocator, u8, &.{
        \\native.beginBatch();
        \\try {
        \\  for (let index = 0; index <
        ,
        requested,
        \\; index += 1) native.createNode("panel");
        \\  native.endBatch();
        \\} catch (error) {
        \\  native.abortBatch();
        \\  native.reportError("render", String(error) + "\n" + (error.stack || ""));
        \\}
    });
    defer std.testing.allocator.free(script);
    try engine.evaluate(script, "budget-test.js");

    try std.testing.expect(engine.renderFailed());
    try std.testing.expectEqual(@as(usize, 2), tree.nodeCount());
    try std.testing.expectEqual(tree_mod.Kind.column, (try tree.nodeConst(tree.root.?)).kind);
    const expected = try std.fmt.allocPrint(
        std.testing.allocator,
        "node capacity exhausted: max_nodes={d}, asked for {d}",
        .{ tree_mod.max_nodes, tree_mod.max_nodes + 1 },
    );
    defer std.testing.allocator.free(expected);
    try std.testing.expect(std.mem.indexOf(u8, (try tree.nodeConst(2)).textSlice(), expected) != null);
}

test "unhandled promise rejection is visible while a handled rejection stays healthy" {
    var rejected_tree: tree_mod.Tree = .{ .allocator = std.testing.allocator };
    defer rejected_tree.deinit();
    var provider: provider_mod.Client = .{};
    try provider.init(std.testing.io, null);
    defer provider.deinit();
    var store: storage_mod.Store = .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .directory = ".",
        .path = "weaver-js-engine-test-storage.json",
        .temporary_path = "weaver-js-engine-test-storage.tmp",
    };
    const rejected = try createTestEngine(&rejected_tree, &store, &provider);
    defer rejected.destroy(std.testing.allocator);
    rejected.bridge_state.emit_error_logs = false;
    try rejected.evaluate("Promise.resolve().then(() => { throw new Error('async exploded'); });", "promise-test.js");
    try std.testing.expect(rejected.renderFailed());
    try std.testing.expect(std.mem.indexOf(u8, (try rejected_tree.nodeConst(2)).textSlice(), "async exploded") != null);

    var handled_tree: tree_mod.Tree = .{ .allocator = std.testing.allocator };
    defer handled_tree.deinit();
    const handled = try createTestEngine(&handled_tree, &store, &provider);
    defer handled.destroy(std.testing.allocator);
    try handled.evaluate("Promise.reject(new Error('expected')).catch(() => {});", "handled-promise-test.js");
    try std.testing.expect(!handled.renderFailed());
}
