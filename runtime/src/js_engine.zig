const std = @import("std");
const bridge = @import("bridge.zig");
const platform = @import("platform/root.zig");
const qjs = @import("qjs.zig");
const provider_mod = @import("provider.zig");
const tree_mod = @import("tree.zig");
const storage_mod = @import("storage.zig");
const widget_diagnostic = @import("widget_diagnostic.zig");
const js_heap = @import("js_heap.zig");
const crash_record = @import("crash_record.zig");
const c = qjs.c;

// QuickJS receipt (2026-07-29): a synthetic worst-good retained view with
// 1,024 JS node records measured 629,335 allocator bytes (553,712 live).
// 32 MiB leaves >50x headroom. It is each engine's heap range (js_heap.zig):
// address space only, committed as the engine allocates.
pub const memory_limit_bytes: usize = 32 * 1024 * 1024;
/// Engines one process can hold at once, one heap range each: every hosted
/// widget, plus one more so a dev hot swap can build its candidate beside
/// the engine it replaces. A last range holds runtime-level allocations.
/// main.zig pins max_host_widgets against it.
pub const max_engines: usize = 33;
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

/// The one QuickJS runtime every engine in the process shares (ADR 0021):
/// atoms, shapes and the engine itself are paid once. Each widget keeps its
/// own realm (JSContext, built-ins, globals) and its own heap range, so its
/// memory cap stays exact. Created with the first engine, freed with the
/// last.
const Shared = struct {
    runtime: *c.JSRuntime,
    heap: js_heap.Heap,
    engines: usize = 0,
    /// Per widget range, the used bytes that start a collection (see
    /// `gcTrigger`). QuickJS's own threshold follows every widget's total, so
    /// one widget could reach its cap with garbage left uncollected.
    gc_thresholds: [max_engines + 1]usize = @splat(0),
    /// Ranges whose threshold is due a reset: every range after a
    /// collection, since it frees garbage in all of them.
    gc_settle: std.StaticBitSet(max_engines + 1) = .initFull(),
};

var shared: ?Shared = null;
/// The engine whose turn is running: the interrupt budget is its.
var executing_engine: ?*Engine = null;

/// The engine whose realm `context` is, through its opaque: the engine's
/// bridge state. Null once the engine is being destroyed.
fn engineOf(context: *c.JSContext) ?*Engine {
    const state: *bridge.State = @ptrCast(@alignCast(c.JS_GetContextOpaque(context) orelse return null));
    return @fieldParentPtr("bridge_state", state);
}

const heap_functions: c.JSMallocFunctions = .{
    .js_calloc = heapCalloc,
    .js_malloc = heapMalloc,
    .js_free = heapFree,
    .js_realloc = heapRealloc,
    .js_malloc_usable_size = heapUsableSize,
};

fn heap() *js_heap.Heap {
    return &shared.?.heap;
}

/// Tests only: how many more QuickJS allocations succeed before one fails.
var test_allocations_left: ?usize = null;

fn testAllocationFails() bool {
    if (!@import("builtin").is_test) return false;
    const left = test_allocations_left orelse return false;
    if (left == 0) {
        test_allocations_left = null;
        return true;
    }
    test_allocations_left = left - 1;
    return false;
}

fn heapCalloc(_: ?*anyopaque, count: usize, size: usize) callconv(.c) ?*anyopaque {
    if (testAllocationFails()) return null;
    const bytes = std.math.mul(usize, count, size) catch return null;
    const block = heap().alloc(bytes) orelse return null;
    @memset(@as([*]u8, @ptrCast(block))[0..bytes], 0);
    return block;
}

fn heapMalloc(_: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    if (testAllocationFails()) return null;
    return heap().alloc(size);
}

fn heapFree(_: ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void {
    heap().free(ptr orelse return);
}

fn heapRealloc(_: ?*anyopaque, ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    if (testAllocationFails()) return null;
    return heap().realloc(ptr, size);
}

fn heapUsableSize(ptr: ?*const anyopaque) callconv(.c) usize {
    return heap().usableSize(ptr orelse return 0);
}

fn acquireShared() !*Shared {
    if (shared == null) {
        // The heap must be in place first: creating the runtime allocates.
        shared = .{
            .runtime = undefined,
            .heap = try js_heap.Heap.init(std.heap.page_allocator, .{ .owners = max_engines + 1, .range_bytes = memory_limit_bytes }),
        };
        const runtime = c.JS_NewRuntime2(&heap_functions, null) orelse {
            shared.?.heap.deinit(std.heap.page_allocator);
            shared = null;
            return error.OutOfMemory;
        };
        shared.?.runtime = runtime;
        c.JS_SetMaxStackSize(runtime, max_stack_bytes);
        c.JS_SetInterruptHandler(runtime, interruptHandler, null);
        c.JS_SetHostPromiseRejectionTracker(runtime, promiseRejectionTracker, null);
        c.JS_SetChargeJobFunc(runtime, chargeJob);
        c.JS_SetChargeSharedFunc(runtime, chargeShared);
        c.JS_SetGCTriggerFunc(runtime, gcTrigger);
    }
    return &shared.?;
}

/// `JS_EnqueueJob` asks this around allocating a job: a collection in one
/// widget's turn can queue another widget's FinalizationRegistry callback,
/// whose entry is that widget's. Null when the job is the running owner's;
/// otherwise the owner to restore, plus one so it is never null.
fn chargeJob(context: ?*c.JSContext, restore: ?*anyopaque) callconv(.c) ?*anyopaque {
    const js = context orelse {
        heap().current = @intCast(@intFromPtr(restore) - 1);
        return null;
    };
    const engine = engineOf(js) orelse return null;
    const previous = heap().current;
    if (engine.owner == previous) return null;
    heap().current = engine.owner;
    return @ptrFromInt(@as(usize, previous) + 1);
}

/// `JS_SetChargeSharedFunc`: the runtime's own tables (atoms, shapes) grow
/// in the host range whichever widget's turn grew them, so a widget's range
/// is empty once the widget is gone. Returns the owner to restore, plus one,
/// or null when no switch was needed.
fn chargeShared(_: ?*c.JSRuntime, restore: ?*anyopaque) callconv(.c) ?*anyopaque {
    if (restore) |token| {
        heap().current = @intCast(@intFromPtr(token) - 1);
        return null;
    }
    const previous = heap().current;
    if (previous == heap().hostOwner()) return null;
    heap().current = heap().hostOwner();
    return @ptrFromInt(@as(usize, previous) + 1);
}

/// `JS_SetGCTriggerFunc`: a safety net under a widget's cap, not a pacing
/// rule (QuickJS's runtime-wide threshold keeps pacing collections). A
/// widget collects once its range passes halfway from what it held after
/// the last collection to its cap; a clock never gets near, and one holding
/// most of its cap collects ever more often only as it closes in. Each
/// collection walks every widget's heap, so a tighter rule cost CPU for
/// everyone.
fn gcTrigger(_: ?*c.JSRuntime, size: usize) callconv(.c) bool {
    const state = &shared.?;
    const owner = state.heap.current;
    if (owner == state.heap.hostOwner()) return false;
    const used = state.heap.usedBytes(owner);
    if (state.gc_settle.isSet(owner)) {
        state.gc_thresholds[owner] = used + (memory_limit_bytes -| used) / 2;
        state.gc_settle.unset(owner);
    }
    if (used + size <= state.gc_thresholds[owner]) return false;
    state.gc_settle = .initFull();
    return true;
}

/// A widget's realm: what `JS_NewContext` builds, except that the typed
/// array family (ArrayBuffer, the typed arrays, DataView, Atomics) and the
/// base64 one (atob, btoa, DOMException) are built the first time widget
/// code touches one of their globals. Most widgets use neither, and they
/// are about 18 KiB of every realm (measured 2026-10-16, see
/// "a widget realm builds typed arrays and base64 only when used").
/// QuickJS keeps each of their globals as a lazily initialized property,
/// which JavaScript sees as an ordinary data property (see VENDOR.md).
/// Every other family stays eager: RegExp because a literal needs its class
/// without reading a global.
fn newWidgetContext(runtime: *c.JSRuntime) ?*c.JSContext {
    const context = c.JS_NewContextRaw(runtime) orelse return null;
    // `JS_NewContext`'s order, so the globals keep its order too.
    const steps = [_]*const fn (?*c.JSContext) callconv(.c) c_int{
        c.JS_AddIntrinsicBaseObjects,
        c.JS_AddIntrinsicDate,
        c.JS_AddIntrinsicEval,
        c.JS_AddIntrinsicRegExp,
        c.JS_AddIntrinsicJSON,
        c.JS_AddIntrinsicProxy,
        c.JS_AddIntrinsicMapSet,
        c.JS_AddLazyIntrinsicTypedArrays,
        c.JS_AddIntrinsicPromise,
        c.JS_AddIntrinsicWeakRef,
        c.JS_AddLazyIntrinsicAToB,
        c.JS_AddPerformance,
    };
    for (steps) |add| {
        if (add(context) < 0) {
            c.JS_FreeContext(context);
            return null;
        }
    }
    return context;
}

fn releaseShared(owner: js_heap.Owner) void {
    const state = &shared.?;
    state.heap.releaseOwner(owner);
    state.engines -= 1;
    if (state.engines != 0) return;
    state.heap.current = state.heap.hostOwner();
    c.JS_FreeRuntime(state.runtime);
    state.heap.deinit(std.heap.page_allocator);
    shared = null;
}

/// A single-widget QuickJS realm in the shared runtime. It runs only when the
/// Native SDK main loop enters `fireTimer`; no JS thread, OS timer, or hidden
/// render loop exists.
pub const Engine = struct {
    runtime: *c.JSRuntime,
    context: *c.JSContext,
    /// This engine's heap range: what it allocates, and its memory cap.
    owner: js_heap.Owner,
    bridge_state: bridge.State,
    provider: *provider_mod.Client,
    deadline_ms: u64 = 0,
    executing: bool = false,
    /// The widget's slot in the host, for the crash record: a crash during
    /// one of its turns names it (`crash_record`). Null outside a host.
    crash_slot: ?u16 = null,
    /// Wyhash of the widget's bundle, recorded with its turns.
    crash_bundle: u64 = 0,
    capture_clock_ms: ?u64 = null,
    pending_rejections: [max_pending_rejections]PendingRejection = [_]PendingRejection{.{}} ** max_pending_rejections,

    pub fn create(
        allocator: std.mem.Allocator,
        tree: *tree_mod.Tree,
        storage: *storage_mod.Store,
        origins: []const []const u8,
        provider: *provider_mod.Client,
        media_transport_enabled: bool,
        capture_mode: bool,
    ) !*Engine {
        const self = allocator.create(Engine) catch return error.OutOfMemory;
        errdefer allocator.destroy(self);
        const state = acquireShared() catch return error.OutOfMemory;
        // Building the realm and installing the bridge run QuickJS code
        // outside a turn, possibly on a thread other than the last turn's
        // (a widget the daemon adds loads on its own thread): measure the
        // recursion guard from here, as `beginTurn` does.
        if (executing_engine == null) c.JS_UpdateStackTop(state.runtime);
        const owner = state.heap.acquireOwner() orelse return error.OutOfMemory;
        state.gc_settle.set(owner);
        state.engines += 1;
        errdefer releaseShared(owner);
        const previous_owner = state.heap.current;
        state.heap.current = owner;
        defer state.heap.current = previous_owner;
        const runtime = state.runtime;
        const context = newWidgetContext(runtime) orelse {
            // Building the realm can throw (out of memory) into the shared
            // exception slot with no context left to take it from.
            c.JS_DropRuntimeException(runtime);
            return error.OutOfMemory;
        };
        errdefer c.JS_FreeContext(context);
        // Building the realm can run out of memory part way and still return
        // a context, its exception left in the shared slot: that realm is
        // not whole, and the exception is not the next widget's.
        if (c.JS_HasException(context)) {
            c.JS_FreeValue(context, c.JS_GetException(context));
            return error.OutOfMemory;
        }
        errdefer if (c.JS_HasException(context)) c.JS_FreeValue(context, c.JS_GetException(context));
        self.* = .{
            .runtime = runtime,
            .context = context,
            .owner = owner,
            .bridge_state = undefined,
            .provider = provider,
        };
        self.bridge_state = .{
            .tree = tree,
            .storage = storage,
            .provider = provider,
            .origins = origins,
            .media_transport_enabled = media_transport_enabled,
            .capture_mode = capture_mode,
        };
        bridge.install(context, &self.bridge_state) catch return error.QuickJs;
        return self;
    }

    pub fn destroy(self: *Engine, allocator: std.mem.Allocator) void {
        const state = &shared.?;
        // Teardown runs widget code outside a turn, maybe on another thread
        // than the last turn (see `create`).
        if (executing_engine == null) c.JS_UpdateStackTop(state.runtime);
        const previous_owner = state.heap.current;
        state.heap.current = self.owner;
        // Teardown runs its code (a storage flush can call its toJSON): a
        // crash here is this widget's, as in a turn.
        if (self.crash_slot) |slot| crash_record.beginTurn(slot, self.crash_bundle);
        self.flushStorage();
        // Settling the bridge's outstanding callbacks can reject promises,
        // so its teardown comes before the rejections are released.
        bridge.deinit(self.context, &self.bridge_state);
        for (&self.pending_rejections) |*pending| {
            c.JS_FreeValue(self.context, pending.promise);
            c.JS_FreeValue(self.context, pending.reason);
            pending.* = .{};
        }
        // Teardown ran widget code outside a turn; the shared exception slot
        // must not keep this realm alive.
        self.drainExceptions();
        c.JS_SetContextOpaque(self.context, null);
        c.JS_FreeContext(self.context);
        if (self.crash_slot != null) crash_record.endTurn();
        // The realm's cycles, its queued jobs among them (the context owns
        // its job queue), go now, not at some later widget's GC, so the
        // range is empty before another engine takes it.
        if (state.engines > 1) c.JS_RunGC(state.runtime);
        state.heap.current = if (previous_owner == self.owner) state.heap.hostOwner() else previous_owner;
        releaseShared(self.owner);
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
        const function = try self.compile(terminated, file_name);
        const result = c.JS_EvalFunction(self.context, function);
        defer c.JS_FreeValue(self.context, result);
        if (c.JS_IsException(result)) return self.reportException();
        try self.pumpJobs();
    }

    /// Compile `source` into a function owned by this engine's heap range,
    /// holding only the bytecode. The parser's working memory is many
    /// short-lived blocks; made in the widget's range, they would stay
    /// resident between its long-lived ones. So compile in the shared host
    /// range, which every compile reuses, and copy the finished bytecode
    /// across. The copy leaves out each function's source text, which
    /// QuickJS keeps only for `Function.prototype.toString` and repeats in
    /// every enclosing function: 54 KiB of a clock widget's 347 KiB
    /// (2026-10-15). Stack traces keep their lines and columns.
    fn compile(self: *Engine, source: [:0]const u8, file_name: [*:0]const u8) Error!c.JSValue {
        var size: usize = 0;
        const written = written: {
            heap().current = heap().hostOwner();
            defer heap().current = self.owner;
            const compiled = c.JS_Eval(self.context, source.ptr, source.len, file_name, c.JS_EVAL_TYPE_GLOBAL | c.JS_EVAL_FLAG_COMPILE_ONLY);
            if (c.JS_IsException(compiled)) break :written null;
            defer c.JS_FreeValue(self.context, compiled);
            break :written c.JS_WriteObject(self.context, &size, compiled, c.JS_WRITE_OBJ_BYTECODE | c.JS_WRITE_OBJ_STRIP_SOURCE);
        } orelse return self.reportException();
        defer c.js_free(self.context, written);
        const function = c.JS_ReadObject(self.context, written, size, c.JS_READ_OBJ_BYTECODE);
        if (c.JS_IsException(function)) return self.reportException();
        return function;
    }

    /// Feed an explicit capture fixture through the same provider callback
    /// installed by `native.onProvider`. The capture bootstrap owns when this
    /// is called; ordinary desktop provider frames still arrive from Client.
    pub fn dispatchProviderFixture(self: *Engine, line: []const u8) Error!void {
        self.beginTurn();
        defer self.endTurn();
        if (!bridge.dispatchProvider(self.context, &self.bridge_state, line)) return self.reportException();
        try self.pumpJobs();
    }

    pub fn setCaptureClock(self: *Engine, epoch_ms: u64) !void {
        // JavaScript numbers preserve every integer only through 2^53 - 1;
        // the capture clock must remain byte-exact when it crosses into JS.
        const max_safe_integer: u64 = 9_007_199_254_740_991;
        if (epoch_ms > max_safe_integer) return error.CaptureClockOutOfRange;
        const script = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "Object.defineProperty(globalThis, '__weaverCaptureNowMs', {{ value: {d}, writable: true, configurable: false }});",
            .{epoch_ms},
        );
        defer std.heap.page_allocator.free(script);
        try self.evaluate(script, "weaver-capture-clock.js");
        self.capture_clock_ms = epoch_ms;
    }

    pub fn advanceCaptureClock(self: *Engine, milliseconds: u64) !void {
        const current = self.capture_clock_ms orelse return;
        const max_safe_integer: u64 = 9_007_199_254_740_991;
        if (milliseconds > max_safe_integer - current) return error.CaptureClockOutOfRange;
        const next = current + milliseconds;
        const script = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "globalThis.__weaverCaptureNowMs = {d};",
            .{next},
        );
        defer std.heap.page_allocator.free(script);
        try self.evaluate(script, "weaver-capture-clock-advance.js");
        self.capture_clock_ms = next;
    }

    pub fn timers(self: *const Engine) []const bridge.TimerSlot {
        return &self.bridge_state.timers;
    }

    /// The shared runtime's totals, every engine included.
    pub fn memoryUsage(self: *const Engine) c.JSMemoryUsage {
        var usage: c.JSMemoryUsage = undefined;
        c.JS_ComputeMemoryUsage(self.runtime, &usage);
        return usage;
    }

    /// Bytes this engine's own heap range holds.
    pub fn heapBytes(self: *const Engine) usize {
        return heap().usedBytes(self.owner);
    }

    pub fn heapGrownBytes(self: *const Engine) usize {
        return heap().grownBytes(self.owner);
    }

    pub fn setTree(self: *Engine, tree: *tree_mod.Tree) void {
        self.bridge_state.tree = tree;
    }

    pub fn setHotSwapSeed(self: *Engine, seed: []const u8) Error!void {
        const previous_owner = self.chargeHeap();
        defer heap().current = previous_owner;
        defer self.drainExceptions();
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
        const previous_owner = self.chargeHeap();
        defer heap().current = previous_owner;
        defer self.drainExceptions();
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

    pub fn activeFetchCount(self: *const Engine) usize {
        return bridge.activeFetchCount(&self.bridge_state);
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

    /// Run this realm's queued jobs. Each realm keeps its own queue (a
    /// change to the vendored QuickJS), so a widget's jobs run only in its
    /// own turns, as they did with a runtime each. After a job throws, the
    /// rest wait for the widget's next turn.
    fn pumpJobs(self: *Engine) Error!void {
        while (true) {
            const result = c.JS_ExecuteContextJob(self.context);
            if (result == 0) {
                self.flushUnhandledRejections();
                return;
            }
            if (result < 0) return self.reportException();
        }
    }

    /// Empty the runtime's shared exception slot, logging what this widget
    /// left there. Releasing a logged exception can run a finalizer whose
    /// cleanup fails to queue and throws again, so this repeats until the
    /// slot stays empty, logging the first few.
    fn drainExceptions(self: *Engine) void {
        var drained: usize = 0;
        while (c.JS_HasException(self.context)) : (drained += 1) {
            if (drained < 4) {
                logExceptionFrom(self.context, self.bridge_state.emit_error_logs);
            } else {
                c.JS_FreeValue(self.context, c.JS_GetException(self.context));
            }
        }
    }

    /// Charge QuickJS allocations to this engine outside a turn; returns
    /// the owner to restore.
    fn chargeHeap(self: *const Engine) js_heap.Owner {
        const previous = heap().current;
        heap().current = self.owner;
        return previous;
    }

    fn callGlobal(self: *Engine, name: [*:0]const u8) Error!c.JSValue {
        self.beginTurn();
        defer self.endTurn();
        const global = c.JS_GetGlobalObject(self.context);
        defer c.JS_FreeValue(self.context, global);
        const callback = c.JS_GetPropertyStr(self.context, global, name);
        defer c.JS_FreeValue(self.context, callback);
        if (c.JS_IsException(callback)) return self.reportException();
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
        executing_engine = self;
        heap().current = self.owner;
        if (self.crash_slot) |slot| crash_record.beginTurn(slot, self.crash_bundle);
    }

    fn endTurn(self: *Engine) void {
        // The runtime's pending-exception slot is shared by every widget:
        // nothing of this turn may be left in it for the next one.
        self.drainExceptions();
        crash_record.endTurn();
        self.executing = false;
        executing_engine = null;
        heap().current = heap().hostOwner();
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
        if (c.JS_IsException(callback)) return logExceptionFrom(self.context, self.bridge_state.emit_error_logs);
        if (!c.JS_IsFunction(self.context, callback)) return;
        const result = c.JS_Call(self.context, callback, qjs.undefinedValue(), 0, null);
        defer c.JS_FreeValue(self.context, result);
        if (c.JS_IsException(result)) logExceptionFrom(self.context, self.bridge_state.emit_error_logs);
    }

    fn reportException(self: *Engine) Error {
        return self.reportExceptionFrom(self.context);
    }

    fn reportExceptionFrom(self: *Engine, context: *c.JSContext) Error {
        logExceptionFrom(context, self.bridge_state.emit_error_logs);
        return error.ScriptException;
    }

    fn flushUnhandledRejections(self: *Engine) void {
        for (&self.pending_rejections) |*pending| {
            if (c.JS_IsUndefined(pending.promise)) continue;
            var detail_buffer: [max_exception_detail_bytes]u8 = undefined;
            const details = valueDetails(self.context, pending.reason, &detail_buffer);
            if (self.bridge_state.emit_error_logs) widget_diagnostic.report("widget unhandled promise rejection:\n{s}", .{details});
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

/// Takes the pending exception off `context`; logs it unless a test has
/// silenced the engine's error logs.
fn logExceptionFrom(context: *c.JSContext, emit: bool) void {
    const exception = c.JS_GetException(context);
    defer c.JS_FreeValue(context, exception);
    if (!emit) return;
    var buffer: [max_exception_detail_bytes]u8 = undefined;
    widget_diagnostic.report("widget JavaScript exception:\n{s}", .{valueDetails(context, exception, &buffer)});
}

/// Format `value` for a diagnostic without running widget code: no
/// `toString`, no getters, no Proxy traps. Diagnostics run at turn ends and
/// in teardown, where widget code could throw again, reject promises nobody
/// will release, or recurse through the rejection tracker. An Error shows
/// its name, message and stack; a primitive shows itself; any other thrown
/// object is named by kind only.
fn valueDetails(context: *c.JSContext, value: c.JSValueConst, buffer: []u8) []const u8 {
    const details = formatValue(context, value, buffer);
    // Converting a string can still fail to allocate.
    if (c.JS_HasException(context)) c.JS_FreeValue(context, c.JS_GetException(context));
    return details;
}

fn formatValue(context: *c.JSContext, value: c.JSValueConst, buffer: []u8) []const u8 {
    if (c.JS_IsError(value)) return errorValueDetails(context, value, buffer);
    var dom_name: c.JSValue = undefined;
    var dom_message: c.JSValue = undefined;
    if (c.JS_GetDOMExceptionFields(context, value, &dom_name, &dom_message)) {
        // Built-ins such as atob throw these; their name and message live
        // in the object, not in properties.
        defer c.JS_FreeValue(context, dom_name);
        defer c.JS_FreeValue(context, dom_message);
        return errorFields(context, dom_name, dom_message, value, buffer);
    }
    if (c.JS_IsSymbol(value)) return "a thrown Symbol";
    if (c.JS_IsObject(value)) return "a thrown object that is not an Error (throw new Error(...) to see its message and stack)";
    var len: usize = 0;
    const raw = c.JS_ToCStringLen2(context, &len, value, false) orelse return "JavaScript value could not be formatted";
    defer c.JS_FreeCString(context, raw);
    const source = validUtf8Prefix(raw[0..len], buffer.len);
    @memcpy(buffer[0..source.len], source);
    return buffer[0..source.len];
}

/// The string data property `name` of `object` or its prototypes, as a
/// value the caller frees; null when it is absent, an accessor, not a
/// string, or behind a Proxy. (A module namespace on the chain could still
/// throw for an uninitialized export; widgets load as global scripts, so
/// none reaches here.)
fn stringDataProperty(context: *c.JSContext, object: c.JSValueConst, name: [*:0]const u8) ?c.JSValue {
    const atom = c.JS_NewAtom(context, name);
    defer c.JS_FreeAtom(context, atom);
    var current = c.JS_DupValue(context, object);
    defer c.JS_FreeValue(context, current);
    for (0..8) |_| {
        if (!c.JS_IsObject(current) or c.JS_IsProxy(current)) return null;
        var descriptor: c.JSPropertyDescriptor = undefined;
        const found = c.JS_GetOwnProperty(context, &descriptor, current, atom);
        if (found < 0) return null;
        if (found > 0) {
            c.JS_FreeValue(context, descriptor.getter);
            c.JS_FreeValue(context, descriptor.setter);
            if (c.JS_IsString(descriptor.value)) return descriptor.value;
            c.JS_FreeValue(context, descriptor.value);
            return null;
        }
        const next = c.JS_GetPrototype(context, current);
        c.JS_FreeValue(context, current);
        current = next;
    }
    return null;
}

fn errorValueDetails(context: *c.JSContext, value: c.JSValueConst, buffer: []u8) []const u8 {
    const name_value = stringDataProperty(context, value, "name") orelse qjs.undefinedValue();
    defer c.JS_FreeValue(context, name_value);
    const message_value = stringDataProperty(context, value, "message") orelse qjs.undefinedValue();
    defer c.JS_FreeValue(context, message_value);
    return errorFields(context, name_value, message_value, value, buffer);
}

/// "name: message" and the stack of an error-like `value`, from string
/// values already read without running widget code.
fn errorFields(context: *c.JSContext, name_value: c.JSValueConst, message_value: c.JSValueConst, value: c.JSValueConst, buffer: []u8) []const u8 {
    const stack_value = stringDataProperty(context, value, "stack") orelse qjs.undefinedValue();
    defer c.JS_FreeValue(context, stack_value);

    var name_len: usize = 0;
    const name_raw = if (c.JS_IsString(name_value)) c.JS_ToCStringLen2(context, &name_len, name_value, false) else null;
    defer if (name_raw) |raw| c.JS_FreeCString(context, raw);
    var message_len: usize = 0;
    const message_raw = if (c.JS_IsString(message_value)) c.JS_ToCStringLen2(context, &message_len, message_value, false) else null;
    defer if (message_raw) |raw| c.JS_FreeCString(context, raw);
    var stack_len: usize = 0;
    const stack_raw = if (c.JS_IsString(stack_value)) c.JS_ToCStringLen2(context, &stack_len, stack_value, false) else null;
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
    _ = opaque_context;
    const js = context orelse return;
    const self = engineOf(js) orelse return;
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

fn interruptHandler(_: ?*c.JSRuntime, _: ?*anyopaque) callconv(.c) c_int {
    const self = executing_engine orelse return 0;
    return if (self.executing and platform.monotonicMilliseconds() >= self.deadline_ms) 1 else 0;
}

fn createTestEngine(tree: *tree_mod.Tree, store: *storage_mod.Store, provider: *provider_mod.Client) !*Engine {
    return Engine.create(std.testing.allocator, tree, store, &.{}, provider, false, false);
}

test "diagnostic truncation preserves UTF-8 boundaries" {
    const details = "failure 💥";
    try std.testing.expectEqualStrings("failure ", validUtf8Prefix(details, details.len - 1));
    try std.testing.expectEqualStrings(details, validUtf8Prefix(details, details.len));
}

test "capture mode bridge capability is runtime-owned" {
    var tree: tree_mod.Tree = .{ .allocator = std.testing.allocator };
    defer tree.deinit();
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
    const engine = try Engine.create(std.testing.allocator, &tree, &store, &.{}, &provider, false, true);
    defer engine.destroy(std.testing.allocator);

    try engine.evaluate(
        \\try { globalThis.native = { captureMode: false }; } catch {}
        \\try { native.captureMode = false; } catch {}
        \\if (native.captureMode !== true) throw new Error("captureMode was replaced by widget code");
    , "capture-mode-test.js");
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

test "a widget unloads at once while a request of its waits on a server that never answers" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    // Accepts the connection and never answers the TLS handshake.
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    const Silent = struct {
        fn run(listener: *std.Io.net.Server, stream: *?std.Io.net.Stream, accepted: *std.atomic.Value(bool)) void {
            stream.* = listener.accept(std.testing.io) catch null;
            accepted.store(true, .release);
        }
    };
    var held: ?std.Io.net.Stream = null;
    var accepted = std.atomic.Value(bool).init(false);
    const acceptor = try std.Thread.spawn(.{}, Silent.run, .{ &server, &held, &accepted });
    defer {
        acceptor.join();
        // Closing the connection lets the orphaned request finish and free
        // itself on its own thread.
        if (held) |stream| stream.close(io);
    }
    const port = server.socket.address.getPort();
    var origin_buffer: [32]u8 = undefined;
    const origin = try std.fmt.bufPrint(&origin_buffer, "127.0.0.1:{d}", .{port});
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const origins = [_][]const u8{origin};
    const engine = try Engine.create(std.testing.allocator, &widgets.trees[0], &widgets.store, &origins, &widgets.provider, false, false);
    var script_buffer: [160]u8 = undefined;
    const script = try std.fmt.bufPrint(&script_buffer, "native.fetch(\"https://127.0.0.1:{d}/\", \"GET\", \"{{}}\", \"\");", .{port});
    try engine.evaluate(script, "fetch.js");
    const deadline = platform.monotonicMilliseconds() + 5_000;
    while (!accepted.load(.acquire) and platform.monotonicMilliseconds() < deadline) std.Thread.yield() catch {};
    try std.testing.expect(accepted.load(.acquire));
    const started = platform.monotonicMilliseconds();
    engine.destroy(std.testing.allocator);
    // It did not wait for WinHTTP's timeout, or for the server.
    try std.testing.expect(platform.monotonicMilliseconds() - started < 1_000);
}

test "a widget at its memory cap leaves its neighbour's realm untouched" {
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
    var neighbour_tree: tree_mod.Tree = .{ .allocator = std.testing.allocator };
    defer neighbour_tree.deinit();
    const neighbour = try createTestEngine(&neighbour_tree, &store, &provider);
    defer neighbour.destroy(std.testing.allocator);
    try neighbour.evaluate("globalThis.kept = new Array(1000).fill(7);", "neighbour.js");
    const neighbour_bytes = neighbour.heapBytes();

    var hog_tree: tree_mod.Tree = .{ .allocator = std.testing.allocator };
    defer hog_tree.deinit();
    const hog = try createTestEngine(&hog_tree, &store, &provider);
    try hog.evaluate(
        \\globalThis.hog = [];
        \\let message = "";
        \\try { for (;;) hog.push(new ArrayBuffer(4 * 1024 * 1024)); } catch (error) { message = String(error); }
        \\if (!message.includes("out of memory")) throw new Error("expected out of memory, got " + message);
    , "hog.js");
    try std.testing.expect(hog.heapBytes() > memory_limit_bytes / 2);
    try std.testing.expect(hog.heapBytes() <= memory_limit_bytes);
    hog.destroy(std.testing.allocator);

    try std.testing.expectEqual(neighbour_bytes, neighbour.heapBytes());
    try neighbour.evaluate("if (kept.length !== 1000 || kept[999] !== 7) throw new Error('neighbour lost its state');", "neighbour-check.js");
}

const TestWidgets = struct {
    provider: provider_mod.Client = .{},
    store: storage_mod.Store = undefined,
    trees: [2]tree_mod.Tree = undefined,

    fn init(self: *TestWidgets) !void {
        try self.provider.init(std.testing.io, null);
        self.store = .{
            .io = std.testing.io,
            .allocator = std.testing.allocator,
            .directory = ".",
            .path = "weaver-js-engine-test-storage.json",
            .temporary_path = "weaver-js-engine-test-storage.tmp",
        };
        for (&self.trees) |*tree| tree.* = .{ .allocator = std.testing.allocator };
    }

    fn deinit(self: *TestWidgets) void {
        for (&self.trees) |*tree| tree.deinit();
        self.provider.deinit();
    }

    fn engine(self: *TestWidgets, index: usize) !*Engine {
        return createTestEngine(&self.trees[index], &self.store, &self.provider);
    }
};

test "a widget's queued jobs run only in its own turns" {
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const owner = try widgets.engine(0);
    defer owner.destroy(std.testing.allocator);
    owner.bridge_state.emit_error_logs = false;
    const bystander = try widgets.engine(1);
    defer bystander.destroy(std.testing.allocator);

    // After a job throws, the rest wait for the widget's next turn.
    try std.testing.expectError(error.ScriptException, owner.evaluate(
        \\queueMicrotask(() => { throw new Error("first job"); });
        \\queueMicrotask(() => { globalThis.second = true; });
    , "jobs.js"));
    try std.testing.expect(c.JS_IsContextJobPending(owner.context));
    try bystander.evaluate("globalThis.ran = true;", "bystander.js");
    try std.testing.expect(c.JS_IsContextJobPending(owner.context));
    try owner.evaluate("globalThis.next = true;", "next.js");
    try std.testing.expect(!c.JS_IsContextJobPending(owner.context));
    try owner.evaluate("if (globalThis.second !== true) throw new Error('second job did not run');", "jobs-check.js");
}

test "another widget's collection queues a cleanup that waits for its owner" {
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const owner = try widgets.engine(0);
    defer owner.destroy(std.testing.allocator);
    const bystander = try widgets.engine(1);
    defer bystander.destroy(std.testing.allocator);

    try owner.evaluate(
        \\globalThis.registry = new FinalizationRegistry(() => { globalThis.cleaned = new ArrayBuffer(1024 * 1024); });
        \\// A cycle: only the collector frees it, not its last reference.
        \\(() => { const target = {}; target.self = target; registry.register(target, "token"); })();
    , "owner.js");
    c.JS_RunGC(owner.runtime);
    try std.testing.expect(c.JS_IsContextJobPending(owner.context));
    const bystander_bytes = bystander.heapBytes();
    try bystander.evaluate("globalThis.ran = true;", "bystander.js");
    try std.testing.expect(c.JS_IsContextJobPending(owner.context));
    try std.testing.expect(bystander.heapBytes() < bystander_bytes + 64 * 1024);
    const owner_bytes = owner.heapBytes();
    try owner.evaluate("globalThis.next = true;", "next.js");
    try std.testing.expect(owner.heapBytes() >= owner_bytes + 1024 * 1024);
    try owner.evaluate("if (!(globalThis.cleaned instanceof ArrayBuffer)) throw new Error('cleanup did not run');", "owner-check.js");
}

test "cleanups another widget's collection queues are charged to their owner" {
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const owner = try widgets.engine(0);
    defer owner.destroy(std.testing.allocator);
    const bystander = try widgets.engine(1);
    defer bystander.destroy(std.testing.allocator);

    try owner.evaluate("globalThis.registry = new FinalizationRegistry(() => {}); globalThis.targets = [];", "owner.js");
    for (0..10) |_| try owner.evaluate(
        \\for (let index = 0; index < 1000; index += 1) {
        \\  const target = {}; target.self = target; registry.register(target, index); targets.push(target);
        \\}
    , "register.js");
    // Unreachable now, but cycles: only a collection frees them.
    try owner.evaluate("globalThis.targets = null;", "drop.js");
    // The collection runs in the bystander's turn, as a GC its own
    // allocations triggered would.
    const bystander_bytes = bystander.heapBytes();
    heap().current = bystander.owner;
    c.JS_RunGC(owner.runtime);
    heap().current = heap().hostOwner();
    try std.testing.expect(c.JS_IsContextJobPending(owner.context));
    try std.testing.expect(bystander.heapBytes() < bystander_bytes + 16 * 1024);
}

test "a media callback that throws while its widget unloads takes nothing with it" {
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const survivor = try widgets.engine(1);
    defer survivor.destroy(std.testing.allocator);
    const leaving = try widgets.engine(0);
    try leaving.evaluate("globalThis.callback = () => { throw new ArrayBuffer(20 * 1024 * 1024); };", "leaving.js");
    // A media command still waiting for its acknowledgement: unloading
    // settles it, and its callback throws.
    const global = c.JS_GetGlobalObject(leaving.context);
    defer c.JS_FreeValue(leaving.context, global);
    const index = try leaving.bridge_state.media_tracker.add(1, 0);
    leaving.bridge_state.media_callbacks[index] = c.JS_GetPropertyStr(leaving.context, global, "callback");
    leaving.destroy(std.testing.allocator);

    // The runtime's exception slot is shared; the thrown 20 MiB went with
    // the widget, so its range is whole for the next one.
    const next = try widgets.engine(0);
    defer next.destroy(std.testing.allocator);
    try next.evaluate("globalThis.big = new ArrayBuffer(28 * 1024 * 1024);", "next.js");
}

test "widget code that throws while the runtime handles its error leaves nothing behind" {
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const survivor = try widgets.engine(1);
    defer survivor.destroy(std.testing.allocator);
    const leaving = try widgets.engine(0);
    leaving.bridge_state.emit_error_logs = false;
    // Formatting the unhandled rejection's reason throws 10 MiB, and so
    // does reading the hot-swap hook.
    try leaving.evaluate(
        \\Promise.reject({ toString() { throw new ArrayBuffer(10 * 1024 * 1024); } });
        \\Object.defineProperty(globalThis, "__weaverCaptureHotSwap", { get() { throw new ArrayBuffer(10 * 1024 * 1024); } });
    , "leaving.js");
    try std.testing.expect(leaving.renderFailed());
    try std.testing.expectEqual(@as(?[]u8, null), leaving.captureHotSwap(std.testing.allocator));
    try std.testing.expect(!c.JS_HasException(survivor.context));
    leaving.destroy(std.testing.allocator);

    const next = try widgets.engine(0);
    defer next.destroy(std.testing.allocator);
    try next.evaluate("globalThis.big = new ArrayBuffer(28 * 1024 * 1024);", "next.js");
}

test "diagnostics format thrown values without running widget code" {
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const engine = try widgets.engine(0);
    defer engine.destroy(std.testing.allocator);
    // Turn ends and teardown format errors; widget code run there could
    // throw again or reject a promise nothing will release.
    try engine.evaluate(
        \\globalThis.ran = [];
        \\globalThis.thrownObject = { toString() { ran.push("toString"); return "custom"; } };
        \\globalThis.thrownError = new TypeError("plain message");
        \\Object.defineProperty(thrownError, "stack", { get() { ran.push("stack getter"); return "x"; } });
        \\globalThis.proxied = new Error("behind a proxy");
        \\Object.setPrototypeOf(proxied, new Proxy({}, { get() { ran.push("proxy trap"); return "x"; } }));
    , "diagnostics.js");
    const global = c.JS_GetGlobalObject(engine.context);
    defer c.JS_FreeValue(engine.context, global);
    var buffer: [max_exception_detail_bytes]u8 = undefined;
    for ([_][*:0]const u8{ "thrownObject", "thrownError", "proxied" }) |name| {
        const value = c.JS_GetPropertyStr(engine.context, global, name);
        defer c.JS_FreeValue(engine.context, value);
        _ = valueDetails(engine.context, value, &buffer);
    }
    const error_value = c.JS_GetPropertyStr(engine.context, global, "thrownError");
    defer c.JS_FreeValue(engine.context, error_value);
    try std.testing.expectEqualStrings("TypeError: plain message", valueDetails(engine.context, error_value, &buffer));
    try engine.evaluate("if (ran.length !== 0) throw new Error('diagnostics ran widget code: ' + ran.join(', '));", "check.js");
}

test "a built-in's DOMException keeps its name and message in diagnostics" {
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const engine = try widgets.engine(0);
    defer engine.destroy(std.testing.allocator);
    try engine.evaluate("try { atob('!'); } catch (error) { globalThis.thrown = error; }", "dom.js");
    const global = c.JS_GetGlobalObject(engine.context);
    defer c.JS_FreeValue(engine.context, global);
    const thrown = c.JS_GetPropertyStr(engine.context, global, "thrown");
    defer c.JS_FreeValue(engine.context, thrown);
    var buffer: [max_exception_detail_bytes]u8 = undefined;
    const details = valueDetails(engine.context, thrown, &buffer);
    try std.testing.expect(std.mem.startsWith(u8, details, "InvalidCharacterError: "));
}

test "a hot-swap capture too big to convert leaves the exception slot empty" {
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const engine = try widgets.engine(0);
    defer engine.destroy(std.testing.allocator);
    engine.bridge_state.emit_error_logs = false;
    // The string fits the widget's heap; its UTF-8 copy does not.
    try engine.evaluate(
        \\globalThis.__weaverCaptureHotSwap = () => "é".repeat(12 * 1024 * 1024);
    , "capture.js");
    try std.testing.expectEqual(@as(?[]u8, null), engine.captureHotSwap(std.testing.allocator));
    try std.testing.expect(!c.JS_HasException(engine.context));
}

test "an endless microtask chain stops at its own widget's budget" {
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const spinner = try widgets.engine(0);
    defer spinner.destroy(std.testing.allocator);
    spinner.bridge_state.emit_error_logs = false;
    const bystander = try widgets.engine(1);
    defer bystander.destroy(std.testing.allocator);

    const started = platform.monotonicMilliseconds();
    try std.testing.expectError(error.ScriptException, spinner.evaluate(
        \\function again() { queueMicrotask(again); for (;;) {} }
        \\queueMicrotask(again);
    , "spin.js"));
    try std.testing.expect(platform.monotonicMilliseconds() - started < 4 * turn_budget_ms);
    // The next job waits in the spinner's own queue, never in a neighbour's
    // turn.
    const before_bystander = platform.monotonicMilliseconds();
    try bystander.evaluate("globalThis.ran = true;", "bystander.js");
    try std.testing.expect(platform.monotonicMilliseconds() - before_bystander < turn_budget_ms);
    try std.testing.expect(c.JS_IsContextJobPending(spinner.context));
}

test "freed small blocks give their capacity back to the widget" {
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const engine = try widgets.engine(0);
    defer engine.destroy(std.testing.allocator);
    // 100,000 short strings, in turns far inside the turn budget even in a
    // Debug build on a slow runner.
    try engine.evaluate("globalThis.strings = [];", "churn.js");
    for (0..100) |_| try engine.evaluate("for (let index = 0; index < 1000; index += 1) strings.push('x'.repeat(100) + strings.length);", "churn.js");
    try engine.evaluate("globalThis.strings = null;", "churn.js");
    c.JS_RunGC(engine.runtime);
    try engine.evaluate("globalThis.big = new ArrayBuffer(24 * 1024 * 1024);", "big.js");
}

test "the runtime's own tables leave nothing in a destroyed widget's range" {
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const survivor = try widgets.engine(1);
    defer survivor.destroy(std.testing.allocator);
    const leaving = try widgets.engine(0);
    const owner = leaving.owner;
    // Each object gets a shape of its own, so the runtime's shape table
    // grows during this widget's turns.
    try leaving.evaluate("globalThis.kept = [];", "kept.js");
    // 50,000 shapes grow the table well past its start, and stay below the
    // point where this widget would collect inside a turn.
    for (0..25) |_| try leaving.evaluate("for (let i = 0; i < 2000; i += 1) kept.push(Object.create({}));", "shapes.js");
    leaving.destroy(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), heap().usedBytes(owner));

    const next = try widgets.engine(0);
    defer next.destroy(std.testing.allocator);
    try std.testing.expectEqual(owner, next.owner);
    try next.evaluate("globalThis.big = new ArrayBuffer(30 * 1024 * 1024);", "next.js");
}

test "a realm that runs out of memory while it is built leaves no exception behind" {
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const survivor = try widgets.engine(1);
    defer survivor.destroy(std.testing.allocator);
    for ([_]usize{ 100, 200, 400, 800 }) |allocations| {
        test_allocations_left = allocations;
        const created = widgets.engine(0);
        test_allocations_left = null;
        // The failure surfaces from whichever step ran out: building the
        // realm (OutOfMemory) or installing the bridge (QuickJs).
        if (created) |engine| engine.destroy(std.testing.allocator) else |err| try std.testing.expect(err == error.OutOfMemory or err == error.QuickJs);
        try std.testing.expect(!c.JS_HasException(survivor.context));
    }
}

test "a range holding an atom another widget uses goes to a new widget only once freed" {
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const survivor = try widgets.engine(1);
    defer survivor.destroy(std.testing.allocator);
    const leaving = try widgets.engine(0);
    const leaving_owner = leaving.owner;
    // The same 4 MiB property name in both realms is one runtime atom, made
    // in the leaving widget's range.
    const make = "globalThis.name = 'k'.repeat(4 * 1024 * 1024); globalThis.held = { [name]: 1 };";
    try leaving.evaluate(make, "leaving.js");
    try survivor.evaluate(make, "survivor.js");
    leaving.destroy(std.testing.allocator);
    try std.testing.expect(heap().usedBytes(leaving_owner) > 0);

    const next = try widgets.engine(0);
    try std.testing.expect(next.owner != leaving_owner);
    try next.evaluate("globalThis.big = new ArrayBuffer(30 * 1024 * 1024);", "next.js");
    next.destroy(std.testing.allocator);

    try survivor.evaluate("delete globalThis.held; delete globalThis.name;", "drop.js");
    c.JS_RunGC(survivor.runtime);
    try std.testing.expectEqual(@as(usize, 0), heap().usedBytes(leaving_owner));
    const reused = try widgets.engine(0);
    defer reused.destroy(std.testing.allocator);
    try std.testing.expectEqual(leaving_owner, reused.owner);
}

test "a realm whose class table cannot be allocated leaves the collector intact" {
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const survivor = try widgets.engine(1);
    defer survivor.destroy(std.testing.allocator);
    test_allocations_left = 1;
    const created = widgets.engine(0);
    test_allocations_left = null;
    if (created) |engine| engine.destroy(std.testing.allocator) else |err| try std.testing.expectEqual(error.OutOfMemory, err);
    c.JS_RunGC(survivor.runtime);
    try survivor.evaluate("globalThis.ok = true;", "after.js");
}

test "a shape a widget grows after its maker is gone moves to that widget" {
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const keeper = try widgets.engine(1);
    defer keeper.destroy(std.testing.allocator);
    const maker = try widgets.engine(0);
    const maker_owner = maker.owner;
    // The same property sequence on a null prototype is one runtime shape,
    // made in the first widget's range.
    const make = "globalThis.o = Object.create(null); o.a = 1; o.b = 2; o.c = 3;";
    try maker.evaluate(make, "maker.js");
    try keeper.evaluate(make, "keeper.js");
    maker.destroy(std.testing.allocator);
    const retired = heap().usedBytes(maker_owner);
    try std.testing.expect(retired > 0);
    // One more property grows the shape in place (its hash size holds):
    // that must not grow the retired range.
    try keeper.evaluate("o.d = 4;", "grow.js");
    try std.testing.expect(heap().usedBytes(maker_owner) < retired);
}

test "a widget's garbage is collected before it reaches its own cap" {
    // Four trees are too big for the test stack.
    const trees = try std.testing.allocator.alloc(tree_mod.Tree, 4);
    defer std.testing.allocator.free(trees);
    for (trees) |*tree| tree.* = .{ .allocator = std.testing.allocator };
    defer for (trees) |*tree| tree.deinit();
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    // Three neighbours each hold 24 MiB, so the runtime-wide threshold
    // sits far above any one widget's cap.
    var neighbours: [3]*Engine = undefined;
    for (&neighbours, 0..) |*neighbour, index| {
        neighbour.* = try createTestEngine(&trees[index], &widgets.store, &widgets.provider);
        try neighbour.*.evaluate("globalThis.held = new ArrayBuffer(24 * 1024 * 1024);", "held.js");
    }
    defer for (neighbours) |neighbour| neighbour.destroy(std.testing.allocator);
    const churner = try createTestEngine(&trees[3], &widgets.store, &widgets.provider);
    defer churner.destroy(std.testing.allocator);
    // Each round leaves a 4 MiB cycle that only a collection frees.
    for (0..12) |_| try churner.evaluate("{ const node = { pad: new ArrayBuffer(4 * 1024 * 1024) }; node.self = node; }", "churn.js");
}

test "a widget realm has every built-in a full realm has, the lazy ones on first use" {
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const engine = try widgets.engine(0);
    defer engine.destroy(std.testing.allocator);
    // The globals of a realm built with every family at once, each with
    // what its property descriptor says.
    const full = c.JS_NewContext(engine.runtime).?;
    defer c.JS_FreeContext(full);
    const describe = "const describe = (d) => d === undefined ? 'missing' : JSON.stringify([typeof d.value, typeof d.get, d.writable, d.enumerable, d.configurable]);";
    const keys_source = describe ++ "JSON.stringify(Reflect.ownKeys(globalThis).filter((k) => typeof k === 'string').map((k) => [k, describe(Object.getOwnPropertyDescriptor(globalThis, k))]))";
    const names = c.JS_Eval(full, keys_source, keys_source.len, "keys.js", c.JS_EVAL_TYPE_GLOBAL);
    defer c.JS_FreeValue(full, names);
    const text = c.JS_ToCString(full, names).?;
    defer c.JS_FreeCString(full, text);
    // Each of them exists here, the lazy ones not enumerable (as the built-ins
    // they stand in for are not), described as in the full realm (a data
    // property, even before first use), and works.
    var check: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer check.deinit();
    try check.writer.print(describe ++
        \\const full = {s};
        \\const missing = full.filter(([name]) => !Object.prototype.hasOwnProperty.call(globalThis, name)).map(([name]) => name);
        \\if (missing.length > 0) throw new Error("missing " + missing.join(","));
        \\const shown = Object.keys(globalThis).filter((name) => ["ArrayBuffer", "Uint8Array", "Atomics", "atob", "DOMException"].includes(name));
        \\if (shown.length > 0) throw new Error("enumerable " + shown.join(","));
        \\const differ = full.filter(([name, expected]) => describe(Object.getOwnPropertyDescriptor(globalThis, name)) !== expected).map(([name]) => name);
        \\if (differ.length > 0) throw new Error("described unlike a full realm: " + differ.join(","));
        \\if (new Uint8Array([1, 2, 3]).length !== 3 || new DataView(new ArrayBuffer(4)).byteLength !== 4) throw new Error("typed arrays");
        \\if (atob(btoa("weaver")) !== "weaver") throw new Error("base64");
        \\if (!("value" in Object.getOwnPropertyDescriptor(globalThis, "Float64Array"))) throw new Error("still an accessor");
    , .{std.mem.span(text)});
    try engine.evaluate(check.written(), "lazy.js");
}

test "every realm, not just the first, throws a real DOMException from atob" {
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const first = try widgets.engine(0);
    defer first.destroy(std.testing.allocator);
    const second = try widgets.engine(1);
    defer second.destroy(std.testing.allocator);
    const check = "try { atob('!'); throw new Error('no throw'); } catch (error) { if (!(error instanceof DOMException) || error.name !== 'InvalidCharacterError') throw error; }";
    try first.evaluate(check, "first.js");
    try second.evaluate(check, "second.js");
}

test "assigning a lazy global before reading it keeps the assignment" {
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const engine = try widgets.engine(0);
    defer engine.destroy(std.testing.allocator);
    try engine.evaluate(
        \\globalThis.atob = () => "mine";
        \\if (atob("x") !== "mine" || typeof btoa !== "function") throw new Error("assignment lost");
    , "assign.js");
}

test "a lazy global made non-configurable before first use still builds its family" {
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const engine = try widgets.engine(0);
    defer engine.destroy(std.testing.allocator);
    try engine.evaluate(
        \\Object.defineProperty(globalThis, "Uint8Array", { configurable: false });
        \\if (new Uint8Array(2).length !== 2) throw new Error("Uint8Array");
        \\const described = Object.getOwnPropertyDescriptor(globalThis, "Uint8Array");
        \\if (described.configurable || typeof described.value !== "function") throw new Error("descriptor");
    , "sealed.js");
}

test "building a family keeps what the widget did to its other globals" {
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const engine = try widgets.engine(0);
    defer engine.destroy(std.testing.allocator);
    try engine.evaluate(
        \\delete globalThis.Uint8Array;
        \\if (typeof Float64Array !== "function" || "Uint8Array" in globalThis) throw new Error("a deleted Uint8Array came back");
        \\if (Object.getPrototypeOf(Int8Array) !== Object.getPrototypeOf(Float64Array)) throw new Error("the family was built twice");
        \\const mine = () => "mine";
        \\Object.defineProperty(globalThis, "atob", { value: mine, writable: true, configurable: true });
        \\if (typeof btoa !== "function" || globalThis.atob !== mine) throw new Error("the widget's atob was replaced");
    , "siblings.js");
}

test "typed arrays built late share the realm's own Array.prototype.toString" {
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const engine = try widgets.engine(0);
    defer engine.destroy(std.testing.allocator);
    try engine.evaluate(
        \\const original = Array.prototype.toString;
        \\Array.prototype.toString = () => "patched";
        \\if (Uint8Array.prototype.toString !== original) throw new Error("typed arrays took the patched toString");
    , "to-string.js");
}

/// Fails each allocation in turn of the first read of the lazy global
/// `name` in a fresh widget realm, until a read fails none. A read that
/// fails must throw and leave nothing pending, and the realm must then
/// build the family on its next use and pass `check`. Returns how many
/// allocations the sweep failed.
fn expectFirstUseSurvivesOutOfMemory(name: [:0]const u8, check: [:0]const u8) !usize {
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const engine = try widgets.engine(0);
    defer engine.destroy(std.testing.allocator);
    const previous_owner = engine.chargeHeap();
    defer heap().current = previous_owner;
    var failures: usize = 0;
    while (true) : (failures += 1) {
        const context = newWidgetContext(engine.runtime) orelse return error.OutOfMemory;
        defer c.JS_RunGC(engine.runtime);
        defer c.JS_FreeContext(context);
        const global = c.JS_GetGlobalObject(context);
        defer c.JS_FreeValue(context, global);
        test_allocations_left = failures;
        const value = c.JS_GetPropertyStr(context, global, name.ptr);
        const failed = test_allocations_left == null;
        test_allocations_left = null;
        if (c.JS_IsException(value)) {
            try std.testing.expect(failed);
            c.JS_FreeValue(context, c.JS_GetException(context));
        } else {
            c.JS_FreeValue(context, value);
        }
        try std.testing.expect(!c.JS_HasException(context));
        const result = c.JS_Eval(context, check.ptr, check.len, "recovered.js", c.JS_EVAL_TYPE_GLOBAL);
        defer c.JS_FreeValue(context, result);
        if (c.JS_IsException(result)) return engine.reportExceptionFrom(context);
        if (!failed) return failures;
    }
}

test "a typed array family that runs out of memory while it is built is built again on next use" {
    const failures = try expectFirstUseSurvivesOutOfMemory("Uint8Array",
        \\if (typeof Uint8Array !== "function" || new Uint8Array([1, 2]).length !== 2) throw new Error("Uint8Array");
        \\if (typeof Atomics !== "object" || new Float64Array(1).length !== 1) throw new Error("the rest of the family");
    );
    // The sweep reached past the whole build, not just its first steps.
    try std.testing.expect(failures > 100);
}

test "base64 that runs out of memory while it is built throws, leaves nothing pending, and builds later" {
    const failures = try expectFirstUseSurvivesOutOfMemory("atob",
        \\if (atob(btoa("weaver")) !== "weaver") throw new Error("base64");
        \\try { atob("!"); throw new Error("no throw"); } catch (error) { if (!(error instanceof DOMException)) throw error; }
    );
    try std.testing.expect(failures > 20);
}

test "a widget realm builds typed arrays and base64 only when used" {
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const engine = try widgets.engine(0);
    defer engine.destroy(std.testing.allocator);
    const previous_owner = engine.chargeHeap();
    defer heap().current = previous_owner;
    c.JS_RunGC(engine.runtime);
    const before_full = engine.heapBytes();
    const full = c.JS_NewContext(engine.runtime) orelse return error.OutOfMemory;
    const full_bytes = engine.heapBytes() - before_full;
    c.JS_FreeContext(full);
    c.JS_RunGC(engine.runtime);
    const before_widget = engine.heapBytes();
    const widget = newWidgetContext(engine.runtime) orelse return error.OutOfMemory;
    const widget_bytes = engine.heapBytes() - before_widget;
    c.JS_FreeContext(widget);
    c.JS_RunGC(engine.runtime);
    // Receipt (2026-10-16, Windows, Debug): a full realm 66,000 bytes, a
    // widget realm 43,872. The floor sits under that 22,128-byte gap so a
    // build that turns a family eager again fails here.
    try std.testing.expect(full_bytes >= widget_bytes + 16 * 1024);
}

test "a destroyed widget's range comes back whole, queued jobs and all" {
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const survivor = try widgets.engine(1);
    defer survivor.destroy(std.testing.allocator);
    const leaving = try widgets.engine(0);
    leaving.bridge_state.emit_error_logs = false;
    // A queued job holds 20 MiB, and registered targets hold each other
    // through held values.
    try std.testing.expectError(error.ScriptException, leaving.evaluate(
        \\globalThis.registry = new FinalizationRegistry(() => {});
        \\const links = [0, 1, 2, 3].map(() => ({ pad: new ArrayBuffer(1024 * 1024) }));
        \\for (let index = 0; index < 3; index += 1) registry.register(links[index], links[index + 1]);
        \\globalThis.first = links[0];
        \\const held = new ArrayBuffer(20 * 1024 * 1024);
        \\queueMicrotask(() => { throw new Error("stops the pump"); });
        \\queueMicrotask(() => held.byteLength);
    , "leaving.js"));
    try std.testing.expect(c.JS_IsContextJobPending(leaving.context));
    leaving.destroy(std.testing.allocator);

    const next = try widgets.engine(0);
    defer next.destroy(std.testing.allocator);
    try next.evaluate("globalThis.big = new ArrayBuffer(28 * 1024 * 1024);", "next.js");
}

test "widget functions keep no source text, and stacks keep their lines" {
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const engine = try widgets.engine(0);
    defer engine.destroy(std.testing.allocator);
    try engine.evaluate(
        \\function named() { return "body text"; }
        \\if (String(named).includes("body text")) throw new Error("function source was kept");
        \\let stack = "";
        \\try { null.missing; } catch (error) { stack = error.stack; }
        \\if (!/strip\.js:4:\d+/.test(stack)) throw new Error("stack lost its line: " + stack);
    , "strip.js");
}
