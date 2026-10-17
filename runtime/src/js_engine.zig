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
    /// The one realm every widget shares, when `shared_realm_enabled`.
    realm: ?*c.JSContext = null,
};

var shared: ?Shared = null;

/// Shared realm (the runtime's default; `--own-realms` turns it off): every widget
/// runs in one realm whose built-ins are frozen, with globals of its own
/// (`Globals`, swapped into the context for its turns) and only its own
/// promise jobs (`jobTag`). Set before the first engine is created: the
/// runtime's `main` sets it, and tests that want it set it themselves.
pub var shared_realm_enabled = false;

/// Makes the few prototype properties programs routinely shadow by
/// assignment (`this.name = ...` in an Error subclass) assignable on
/// instances, through accessors over the original values. `lockDown` then
/// freezes everything, those originals included.
const tame_source =
    \\(() => {
    \\  const tame = (proto, key) => {
    \\    const d = Object.getOwnPropertyDescriptor(proto, key);
    \\    if (!d || !("value" in d)) return;
    \\    const value = d.value;
    \\    Object.defineProperty(proto, key, {
    \\      get() { return value; },
    \\      set(next) {
    \\        if (this === proto) throw new TypeError("Cannot assign to read only property '" + String(key) + "' of a shared built-in");
    \\        Object.defineProperty(this, key, { value: next, writable: true, enumerable: true, configurable: true });
    \\      },
    \\      enumerable: d.enumerable,
    \\      configurable: false,
    \\    });
    \\  };
    \\  for (const key of ["constructor", "toString", "valueOf"]) tame(Object.prototype, key);
    \\  for (const E of [Error, TypeError, RangeError, SyntaxError, ReferenceError, EvalError, URIError, AggregateError]) {
    \\    for (const key of ["constructor", "name", "message", "toString"]) tame(E.prototype, key);
    \\  }
    \\  for (const key of ["constructor", "toString"]) tame(Function.prototype, key);
    \\})();
;

/// Lock a newly built shared realm: tame, then freeze every object alive in
/// the runtime (`JS_FreezeRealm`). No widget has made one yet, so each is a
/// built-in, and this reaches the ones no property leads to (functions only
/// a built-in's closure holds, prototypes only syntax or an engine class
/// reaches) as surely as the rest. Built-in methods QuickJS makes on first
/// use are not made now: each is frozen, and charged to the host, when a
/// widget first reaches it.
fn lockDown(realm: *c.JSContext) bool {
    const tamed = c.JS_Eval(realm, tame_source.ptr, tame_source.len, "tame.js", c.JS_EVAL_TYPE_GLOBAL);
    defer c.JS_FreeValue(realm, tamed);
    if (c.JS_IsException(tamed)) return false;
    return c.JS_FreezeRealm(realm) == 0;
}

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
        c.JS_SetJobTagFunc(runtime, jobTag);
        c.JS_SetChargeSharedFunc(runtime, chargeShared);
        c.JS_SetGCTriggerFunc(runtime, gcTrigger);
        if (shared_realm_enabled) {
            // Built once, in the host's range: no widget pays for it.
            const previous = shared.?.heap.current;
            shared.?.heap.current = shared.?.heap.hostOwner();
            defer shared.?.heap.current = previous;
            const realm = c.JS_NewContext(runtime) orelse {
                c.JS_FreeRuntime(runtime);
                shared.?.heap.deinit(std.heap.page_allocator);
                shared = null;
                return error.OutOfMemory;
            };
            if (!lockDown(realm)) {
                logExceptionFrom(realm, true);
                c.JS_FreeContext(realm);
                c.JS_FreeRuntime(runtime);
                shared.?.heap.deinit(std.heap.page_allocator);
                shared = null;
                return error.OutOfMemory;
            }
            shared.?.realm = realm;
        }
    }
    return &shared.?;
}

/// `JS_EnqueueJob` asks this around allocating a job, with the job's tag: a
/// collection in one widget's turn can queue another widget's
/// FinalizationRegistry callback, whose entry is that widget's. Null when the job is the running owner's;
/// otherwise the owner to restore, plus one so it is never null.
fn chargeJob(context: ?*c.JSContext, tag: usize, restore: ?*anyopaque) callconv(.c) ?*anyopaque {
    const js = context orelse {
        heap().current = @intCast(@intFromPtr(restore) - 1);
        return null;
    };
    // A job queued under an explicit tag is its tag's widget's
    // (`jobTagOf`): a registry's cleanup is its creator's, whoever's turn
    // collected. Any other job is its context's widget's.
    const owner: js_heap.Owner = if (tag != 0) @intCast(tag - 1) else (engineOf(js) orelse return null).owner;
    const previous = heap().current;
    if (owner == previous) return null;
    heap().current = owner;
    return @ptrFromInt(@as(usize, previous) + 1);
}

/// `JS_SetJobTagFunc`: a job belongs to the widget whose range is charged
/// when it is queued, in its turn or its teardown. In a shared realm every
/// widget's jobs share one queue, and a widget runs, and is charged for,
/// only its own (`Engine.pumpJobs`).
fn jobTag(_: ?*c.JSContext) callconv(.c) usize {
    return jobTagOf(heap().current);
}

fn jobTagOf(owner: js_heap.Owner) usize {
    return @as(usize, owner) + 1;
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

fn releaseShared(owner: js_heap.Owner) void {
    const state = &shared.?;
    state.heap.releaseOwner(owner);
    state.engines -= 1;
    if (state.engines != 0) return;
    state.heap.current = state.heap.hostOwner();
    if (state.realm) |realm| c.JS_FreeContext(realm);
    c.JS_FreeRuntime(state.runtime);
    state.heap.deinit(std.heap.page_allocator);
    shared = null;
}

/// A single-widget QuickJS realm in the shared runtime. It runs only when the
/// Native SDK main loop enters `fireTimer`; no JS thread, OS timer, or hidden
/// render loop exists.
/// A widget's own state in the shared realm (`Engine.globals`): its global
/// object and global lexical scope, its Error stack settings and its
/// Math.random state (`JS_SwapProgramState`).
const Globals = struct {
    state: c.JSProgramState,

    fn deinit(self: *Globals, context: *c.JSContext) void {
        c.JS_FreeValue(context, self.state.global);
        c.JS_FreeValue(context, self.state.lexical);
        c.JS_FreeValue(context, self.state.prepare_stack);
        c.JS_FreeValue(context, self.state.stack_trace_limit);
    }
};

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
    /// Shared realm only: this widget's global object and global lexical
    /// scope while they are out of the context; the realm's own while they
    /// are in (`enterRealm` and `leaveRealm` exchange them). Null in a realm
    /// of its own.
    globals: ?Globals = null,
    in_realm: bool = false,
    entered_for_turn: bool = false,
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
        const context = state.realm orelse c.JS_NewContext(runtime) orelse {
            // Building the realm can throw (out of memory) into the shared
            // exception slot with no context left to take it from.
            c.JS_DropRuntimeException(runtime);
            return error.OutOfMemory;
        };
        errdefer if (state.realm == null) c.JS_FreeContext(context);
        // Building the realm can run out of memory part way and still return
        // a context, its exception left in the shared slot: that realm is
        // not whole, and the exception is not the next widget's.
        if (c.JS_HasException(context)) {
            c.JS_FreeValue(context, c.JS_GetException(context));
            return error.OutOfMemory;
        }
        // In the shared realm, globals of its own: an object whose
        // prototype is the realm's frozen global, so the built-ins are found
        // through it, with its own `globalThis`, and its own scope for
        // top-level `let`, `const` and `class`.
        var globals: ?Globals = if (state.realm != null) globals: {
            const shared_global = c.JS_GetGlobalObject(context);
            defer c.JS_FreeValue(context, shared_global);
            const global = c.JS_NewObjectProto(context, shared_global);
            if (c.JS_IsException(global)) return error.OutOfMemory;
            errdefer c.JS_FreeValue(context, global);
            if (c.JS_DefinePropertyValueStr(context, global, "globalThis", c.JS_DupValue(context, global), c.JS_PROP_WRITABLE | c.JS_PROP_CONFIGURABLE) < 0) return error.OutOfMemory;
            const lexical = c.JS_NewObjectProto(context, qjs.nullValue());
            if (c.JS_IsException(lexical)) return error.OutOfMemory;
            // A seed of its own: Math.random's state otherwise lets one
            // widget predict another's numbers. Never zero (xorshift).
            var seed: u64 = 0;
            while (seed == 0) {
                var bytes: [8]u8 = undefined;
                std.Io.Threaded.global_single_threaded.io().random(&bytes);
                seed = std.mem.readInt(u64, &bytes, .little);
            }
            var program: c.JSProgramState = undefined;
            c.JS_InitProgramState(context, &program);
            program.global = global;
            program.lexical = lexical;
            program.random_state = seed;
            break :globals .{ .state = program };
        } else null;
        errdefer if (globals) |*pair| pair.deinit(context);
        errdefer if (c.JS_HasException(context)) c.JS_FreeValue(context, c.JS_GetException(context));
        self.* = .{
            .runtime = runtime,
            .context = context,
            .owner = owner,
            .bridge_state = undefined,
            .provider = provider,
            .globals = globals,
        };
        // Owned by the engine from here; its errdefer must not free them too.
        globals = null;
        self.bridge_state = .{
            .tree = tree,
            .storage = storage,
            .provider = provider,
            .origins = origins,
            .media_transport_enabled = media_transport_enabled,
            .capture_mode = capture_mode,
        };
        errdefer if (self.globals) |*pair| pair.deinit(context);
        const entered = self.enterRealm();
        defer if (entered) self.leaveRealm();
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
        // Teardown runs its code, so in a shared realm with its globals.
        const entered = self.enterRealm();
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
        if (self.globals) |*pair| {
            // Its queued jobs hold its objects; in a shared realm they would
            // otherwise wait forever in the one queue.
            c.JS_FreeTaggedJobs(self.context, jobTagOf(self.owner));
            if (entered) self.leaveRealm();
            pair.deinit(self.context);
            self.globals = null;
        } else {
            c.JS_SetContextOpaque(self.context, null);
            c.JS_FreeContext(self.context);
        }
        if (self.crash_slot != null) crash_record.endTurn();
        // The realm's cycles, its queued jobs among them (the context owns
        // its job queue), go now, not at some later widget's GC, so the
        // range is empty before another engine takes it.
        if (state.engines > 1 or state.realm != null) c.JS_RunGC(state.runtime);
        if (state.realm) |realm| {
            // That collection can queue cleanups of its own registries (a
            // target dying just before its registry), under its tag. They
            // go too, and what they held, until none is left: its range is
            // the next widget's, and so would its jobs be.
            const tag = jobTagOf(self.owner);
            while (c.JS_IsTaggedJobPending(realm, tag)) {
                c.JS_FreeTaggedJobs(realm, tag);
                c.JS_RunGC(state.runtime);
            }
        }
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
        const entered = self.enterRealm();
        defer if (entered) self.leaveRealm();
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
            const result = if (self.globals != null)
                c.JS_ExecuteTaggedJob(self.context, jobTagOf(self.owner))
            else
                c.JS_ExecuteContextJob(self.context);
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

    /// In the shared realm, put this widget's globals in the context, and
    /// its bridge state as the context's opaque, so its code sees its own
    /// globals and its bridge calls find it. False when there was nothing
    /// to do (its own realm, or already in): only a true caller leaves.
    fn enterRealm(self: *Engine) bool {
        if (self.globals == null or self.in_realm) return false;
        c.JS_SwapProgramState(self.context, &self.globals.?.state);
        c.JS_SetContextOpaque(self.context, &self.bridge_state);
        self.in_realm = true;
        return true;
    }

    fn leaveRealm(self: *Engine) void {
        if (!self.in_realm) return;
        c.JS_SwapProgramState(self.context, &self.globals.?.state);
        c.JS_SetContextOpaque(self.context, null);
        self.in_realm = false;
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
        self.entered_for_turn = self.enterRealm();
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
        if (self.entered_for_turn) self.leaveRealm();
        self.entered_for_turn = false;
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
    const details = valueDetails(context, exception, &buffer);
    widget_diagnostic.report("widget JavaScript exception:\n{s}{s}", .{ details, frozenBuiltInHint(details) });
}

/// In the shared realm, built-ins are frozen, and QuickJS's message for
/// changing one ("object is not extensible", "'x' is read-only") does not
/// say why.
fn frozenBuiltInHint(details: []const u8) []const u8 {
    if (!shared_realm_enabled) return "";
    const frozen = std.mem.indexOf(u8, details, "object is not extensible") != null or std.mem.indexOf(u8, details, "' is read-only") != null;
    if (!frozen) return "";
    return "\nIf this changed a built-in (Array.prototype, Object.prototype, Math, ...): widgets share one set of built-ins, frozen so no widget can change another's. Keep helpers on your own objects or modules instead.";
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

test "the Error stack settings keep no value they no longer hold" {
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
    const engine = try createTestEngine(&tree, &store, &provider);
    defer engine.destroy(std.testing.allocator);

    const before = engine.memoryUsage().malloc_size;
    // Each assignment used to keep the value it replaced alive for good.
    try engine.evaluate(
        \\Error.stackTraceLimit = new ArrayBuffer(4 * 1024 * 1024);
        \\Error.stackTraceLimit = 10;
        \\// A formatter that is not a function is ignored, and each error
        \\// built while it was set used to keep a reference to it.
        \\Error.prepareStackTrace = new ArrayBuffer(4 * 1024 * 1024);
        \\new Error("m");
        \\Error.captureStackTrace({});
        \\Error.prepareStackTrace = undefined;
    , "stack-trace-limit.js");
    c.JS_RunGC(engine.runtime);
    const after = engine.memoryUsage().malloc_size;
    try std.testing.expect(after < before + 1024 * 1024);
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

test "in the shared realm each widget keeps its own globals" {
    shared_realm_enabled = true;
    defer shared_realm_enabled = false;
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const first = try widgets.engine(0);
    defer first.destroy(std.testing.allocator);
    const second = try widgets.engine(1);
    defer second.destroy(std.testing.allocator);
    try std.testing.expect(first.context == second.context);
    try first.evaluate(
        \\var declared = 1;
        \\let lexical = 2;
        \\globalThis.assigned = 3;
        \\function declaredFunction() { return 4; }
        \\undeclared = 5;
        \\Object.defineProperty(globalThis, "sdkGlobal", { value: () => 6 });
        \\var Math = "shadowed";
    , "first.js");
    // Nothing of the first widget's is visible to the second, which can
    // declare the same names, and still has the built-ins.
    try second.evaluate(
        \\for (const name of ["declared", "lexical", "assigned", "declaredFunction", "undeclared", "sdkGlobal"]) {
        \\  if (eval("typeof " + name) !== "undefined") throw new Error(name + " leaked");
        \\}
    , "second-looks.js");
    try second.evaluate(
        \\var declared = "second";
        \\let lexical = "second";
        \\if (Math.max(1, 2) !== 2) throw new Error("Math was shadowed for the second widget too");
        \\if (globalThis !== this || globalThis.globalThis !== globalThis) throw new Error("globalThis");
    , "second.js");
    // The first widget's names resolve, bare, as in a realm of its own.
    try first.evaluate(
        \\if (declared !== 1 || lexical !== 2 || assigned !== 3 || declaredFunction() !== 4 || undeclared !== 5 || sdkGlobal() !== 6) throw new Error("own globals lost");
        \\if (Math !== "shadowed") throw new Error("own shadowing lost");
        \\if (new Function("return this")() !== globalThis) throw new Error("Function sees another global");
        \\if ((0, eval)("declared") !== 1) throw new Error("indirect eval sees another global");
    , "first-again.js");
}

test "in the shared realm a widget cannot change the built-ins another widget sees" {
    shared_realm_enabled = true;
    defer shared_realm_enabled = false;
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const attacker = try widgets.engine(0);
    defer attacker.destroy(std.testing.allocator);
    const victim = try widgets.engine(1);
    defer victim.destroy(std.testing.allocator);
    try attacker.evaluate(
        \\"use strict";
        \\const shared = Object.getPrototypeOf(globalThis);
        \\const attempts = [
        \\  () => { Array.prototype.extra = 1; },
        \\  () => { Object.prototype.polluted = 1; },
        \\  () => { Object.prototype.toString = () => "owned"; },
        \\  () => { Math.max = () => 0; },
        \\  () => { JSON.parse = null; },
        \\  () => { delete Array.prototype.map; },
        \\  () => { shared.Array = null; },
        \\  () => { shared.injected = 1; },
        \\  () => { Object.setPrototypeOf(Array.prototype, null); },
        \\  () => { Promise.prototype.then = () => {}; },
        \\  () => { (function* () {}).constructor.prototype.extra = 1; },
        \\  () => { [][Symbol.iterator]().__proto__.next = () => ({ done: true }); },
        \\];
        \\const changed = attempts.filter((attempt) => { try { attempt(); return true; } catch { return false; } });
        \\if (changed.length > 0) throw new Error(changed.length + " changes went through");
    , "attacker.js");
    try victim.evaluate(
        \\if ([].extra !== undefined || ({}).polluted !== undefined) throw new Error("prototype polluted");
        \\if (({}).toString() !== "[object Object]" || Math.max(1, 2) !== 2 || JSON.parse("1") !== 1) throw new Error("built-in replaced");
        \\if ([1].map((x) => x + 1)[0] !== 2 || [...[1, 2]].length !== 2) throw new Error("built-in removed");
    , "victim.js");
}

test "in the shared realm an Error subclass can still name itself" {
    shared_realm_enabled = true;
    defer shared_realm_enabled = false;
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const widget = try widgets.engine(0);
    defer widget.destroy(std.testing.allocator);
    try widget.evaluate(
        \\class WidgetError extends Error { constructor() { super("m"); this.name = "WidgetError"; } }
        \\const error = new WidgetError();
        \\if (error.name !== "WidgetError" || String(error) !== "WidgetError: m") throw new Error("name lost: " + String(error));
        \\if (Error.prototype.name !== "Error") throw new Error("shared prototype changed");
    , "errors.js");
}

test "in the shared realm a widget's promise jobs run only in its turns and go with it" {
    shared_realm_enabled = true;
    defer shared_realm_enabled = false;
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    // The bystander first: in a shared realm the second widget's objects
    // reuse the shapes the first one's created (same prototypes), and those
    // stay charged to the first. Here they are the bystander's, so the
    // owner's range shows only what the owner made.
    const bystander = try widgets.engine(1);
    defer bystander.destroy(std.testing.allocator);
    const owner = try widgets.engine(0);
    owner.bridge_state.emit_error_logs = false;
    const tag = jobTagOf(owner.owner);
    // After a job throws, the rest wait for the widget's next turn.
    try std.testing.expectError(error.ScriptException, owner.evaluate(
        \\queueMicrotask(() => { throw new Error("first job"); });
        \\queueMicrotask(() => { globalThis.second = true; });
    , "jobs.js"));
    try std.testing.expect(c.JS_IsTaggedJobPending(owner.context, tag));
    try bystander.evaluate("if (globalThis.second !== undefined) throw new Error('ran in the wrong widget');", "bystander.js");
    try std.testing.expect(c.JS_IsTaggedJobPending(owner.context, tag));
    try owner.evaluate("globalThis.next = true;", "next.js");
    try std.testing.expect(!c.JS_IsTaggedJobPending(owner.context, tag));
    try owner.evaluate("if (globalThis.second !== true) throw new Error('second job did not run');", "check.js");
    // Jobs still queued when it goes are freed with it, and its range comes
    // back empty.
    try std.testing.expectError(error.ScriptException, owner.evaluate(
        \\const kept = new Array(1000).fill("x");
        \\queueMicrotask(() => { throw new Error("first job"); });
        \\queueMicrotask(() => { globalThis.kept = kept; });
    , "leftover.js"));
    try std.testing.expect(c.JS_IsTaggedJobPending(owner.context, tag));
    const range = owner.owner;
    owner.destroy(std.testing.allocator);
    try std.testing.expect(!c.JS_IsTaggedJobPending(bystander.context, tag));
    try std.testing.expectEqual(@as(usize, 0), heap().usedBytes(range));
}

test "in the shared realm a widget cannot leave anything on a built-in for another to find" {
    shared_realm_enabled = true;
    defer shared_realm_enabled = false;
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const first = try widgets.engine(0);
    defer first.destroy(std.testing.allocator);
    const second = try widgets.engine(1);
    defer second.destroy(std.testing.allocator);
    // Every built-in object is frozen, the ones only syntax or an engine
    // class reaches and the originals behind the assignable prototype
    // properties among them: nothing one widget puts there is anything
    // another can read.
    try first.evaluate(
        \\"use strict";
        \\const original = (proto, key) => Object.getOwnPropertyDescriptor(proto, key).get();
        \\const accessor = (proto, key) => Object.getOwnPropertyDescriptor(proto, key);
        \\Error.prepareStackTrace = (_, sites) => sites;
        \\const callSite = Object.getPrototypeOf(new Error().stack[0]);
        \\Error.prepareStackTrace = undefined;
        \\const reached = [
        \\  Array.prototype.push,
        \\  Promise.prototype.then,
        \\  original(Object.prototype, "toString"),
        \\  original(Error.prototype, "toString"),
        \\  original(Function.prototype, "toString"),
        \\  accessor(Error.prototype, "name").get,
        \\  accessor(Error.prototype, "name").set,
        \\  Object.getPrototypeOf([1].values().map((x) => x)),
        \\  Object.getPrototypeOf(Iterator.from({ next() { return { done: true }; } })),
        \\  Object.getPrototypeOf(Iterator.concat([1], [2])),
        \\  callSite,
        \\];
        \\const open = reached.filter((value) => !Object.isFrozen(value));
        \\if (open.length > 0) throw new Error(open.length + " built-ins are not frozen");
        \\const changed = reached.filter((value) => { try { value.mailbox = 1; return true; } catch { return false; } });
        \\if (changed.length > 0) throw new Error(changed.length + " changes went through");
    , "first.js");
    try second.evaluate(
        \\if (Array.prototype.push.mailbox !== undefined) throw new Error("found something on push");
        \\if ([1].values().map((x) => x).next().value !== 1) throw new Error("iterator helper changed");
        \\if (Iterator.concat([3], [4]).next().value !== 3) throw new Error("concat changed");
    , "second.js");
}

test "in the shared realm each widget has its own Error stack settings" {
    shared_realm_enabled = true;
    defer shared_realm_enabled = false;
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const first = try widgets.engine(0);
    defer first.destroy(std.testing.allocator);
    const second = try widgets.engine(1);
    defer second.destroy(std.testing.allocator);
    // Error.prepareStackTrace and Error.stackTraceLimit are stored on the
    // context, not on the frozen Error: each widget's turn has its own.
    try first.evaluate(
        \\Error.prepareStackTrace = () => "first's format";
        \\Error.stackTraceLimit = 3;
    , "first.js");
    try second.evaluate(
        \\if (Error.prepareStackTrace !== undefined || Error.stackTraceLimit !== 10) throw new Error("first's settings leaked");
        \\if (typeof new Error("m").stack !== "string" || new Error("m").stack === "first's format") throw new Error("first's format ran");
        \\Error.stackTraceLimit = 5;
    , "second.js");
    try first.evaluate(
        \\if (new Error("m").stack !== "first's format" || Error.stackTraceLimit !== 3) throw new Error("own settings lost");
    , "first-again.js");
}

fn readNumberGlobal(engine: *Engine, name: [*:0]const u8) !f64 {
    engine.beginTurn();
    defer engine.endTurn();
    const global = c.JS_GetGlobalObject(engine.context);
    defer c.JS_FreeValue(engine.context, global);
    const value = c.JS_GetPropertyStr(engine.context, global, name);
    defer c.JS_FreeValue(engine.context, value);
    var number: f64 = undefined;
    try std.testing.expect(c.JS_ToFloat64(engine.context, &number, value) == 0);
    return number;
}

/// QuickJS's Math.random step (xorshift64*).
fn randomStep(state: *u64) u64 {
    var x = state.*;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    state.* = x;
    return x *% 0x2545F4914F6CDD1D;
}

test "in the shared realm one widget's Math.random says nothing of another's" {
    shared_realm_enabled = true;
    defer shared_realm_enabled = false;
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const first = try widgets.engine(0);
    defer first.destroy(std.testing.allocator);
    const second = try widgets.engine(1);
    defer second.destroy(std.testing.allocator);
    try first.evaluate("globalThis.r1 = Math.random(); globalThis.r2 = Math.random();", "first.js");
    const r1: u64 = @intFromFloat((try readNumberGlobal(first, "r1")) * 4503599627370496.0);
    const r2: u64 = @intFromFloat((try readNumberGlobal(first, "r2")) * 4503599627370496.0);
    // Two outputs give the state back: undo the multiplier, try the 12 bits
    // each output drops, and keep the state whose next output is r2.
    const multiplier: u64 = 0x2545F4914F6CDD1D;
    var inverse: u64 = 1;
    for (0..6) |_| inverse = inverse *% (2 -% (multiplier *% inverse));
    var predicted: ?u64 = null;
    for (0..4096) |low| {
        var state = ((r1 << 12) | @as(u64, @intCast(low))) *% inverse;
        if (randomStep(&state) >> 12 == r2) predicted = randomStep(&state) >> 12;
    }
    try std.testing.expect(predicted != null);
    // That state is the first widget's alone: it predicts its own next
    // number and not the second widget's.
    try second.evaluate("globalThis.r3 = Math.random();", "second.js");
    const theirs: u64 = @intFromFloat((try readNumberGlobal(second, "r3")) * 4503599627370496.0);
    try std.testing.expect(predicted.? != theirs);
    try first.evaluate("globalThis.r3 = Math.random();", "first-again.js");
    const own: u64 = @intFromFloat((try readNumberGlobal(first, "r3")) * 4503599627370496.0);
    try std.testing.expectEqual(predicted.?, own);
}

test "in the shared realm a finalizer runs in the turns of the widget that made it" {
    shared_realm_enabled = true;
    defer shared_realm_enabled = false;
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const owner = try widgets.engine(0);
    defer owner.destroy(std.testing.allocator);
    const bystander = try widgets.engine(1);
    defer bystander.destroy(std.testing.allocator);
    try owner.evaluate(
        \\globalThis.registry = new FinalizationRegistry((held) => { globalThis.cleaned = held; });
        \\(() => { const target = {}; target.self = target; registry.register(target, "token"); })();
    , "owner.js");
    // Collected in another widget's turn, the cleanup is still the owner's.
    bystander.beginTurn();
    c.JS_RunGC(owner.runtime);
    bystander.endTurn();
    try std.testing.expect(c.JS_IsTaggedJobPending(owner.context, jobTagOf(owner.owner)));
    try std.testing.expect(!c.JS_IsTaggedJobPending(owner.context, jobTagOf(bystander.owner)));
    try bystander.evaluate("if (globalThis.cleaned !== undefined) throw new Error('ran in the wrong widget');", "bystander.js");
    try owner.evaluate("globalThis.next = true;", "owner-next.js");
    try owner.evaluate("if (globalThis.cleaned !== 'token') throw new Error('cleanup did not run');", "owner-check.js");
}

test "in the shared realm a finalizer still queued when its widget goes goes with it" {
    shared_realm_enabled = true;
    defer shared_realm_enabled = false;
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const survivor = try widgets.engine(1);
    defer survivor.destroy(std.testing.allocator);
    const owner = try widgets.engine(0);
    var alive = true;
    defer if (alive) owner.destroy(std.testing.allocator);
    try owner.evaluate(
        \\globalThis.registry = new FinalizationRegistry((held) => { globalThis.kept = held; });
        \\(() => { const target = {}; target.self = target; registry.register(target, new ArrayBuffer(1024 * 1024)); })();
    , "owner.js");
    // A collection outside any turn (the host's) queues it under the owner.
    c.JS_RunGC(owner.runtime);
    const tag = jobTagOf(owner.owner);
    try std.testing.expect(c.JS_IsTaggedJobPending(owner.context, tag));
    try std.testing.expect(!c.JS_IsTaggedJobPending(owner.context, jobTagOf(heap().hostOwner())));
    const range = owner.owner;
    owner.destroy(std.testing.allocator);
    alive = false;
    try std.testing.expect(!c.JS_IsTaggedJobPending(survivor.context, tag));
    try std.testing.expectEqual(@as(usize, 0), heap().usedBytes(range));
    // A target that dies only with its widget dies with its registry, in
    // the collection its teardown runs: no cleanup is queued then.
    const late = try widgets.engine(0);
    var late_alive = true;
    defer if (late_alive) late.destroy(std.testing.allocator);
    try late.evaluate(
        \\globalThis.registry = new FinalizationRegistry((held) => { globalThis.kept = held; });
        \\globalThis.target = {}; target.self = target;
        \\registry.register(target, new ArrayBuffer(1024 * 1024));
    , "late.js");
    const late_range = late.owner;
    late.destroy(std.testing.allocator);
    late_alive = false;
    try std.testing.expect(!c.JS_IsTaggedJobPending(survivor.context, jobTagOf(late_range)));
    try std.testing.expectEqual(@as(usize, 0), heap().usedBytes(late_range));
}

test "in the shared realm a widget that goes mid-error leaves nothing behind" {
    shared_realm_enabled = true;
    defer shared_realm_enabled = false;
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const survivor = try widgets.engine(1);
    defer survivor.destroy(std.testing.allocator);
    const leaving = try widgets.engine(0);
    var alive = true;
    defer if (alive) leaving.destroy(std.testing.allocator);
    leaving.bridge_state.emit_error_logs = false;
    try std.testing.expectError(error.ScriptException, leaving.evaluate(
        \\globalThis.cycle = { bytes: new ArrayBuffer(1024 * 1024) }; cycle.self = cycle;
        \\Error.prepareStackTrace = () => new ArrayBuffer(1024 * 1024);
        \\Promise.reject(new ArrayBuffer(1024 * 1024));
        \\queueMicrotask(() => { globalThis.leftover = true; });
        \\throw new Error("leaving");
    , "leaving.js"));
    const range = leaving.owner;
    leaving.destroy(std.testing.allocator);
    alive = false;
    try std.testing.expectEqual(@as(usize, 0), heap().usedBytes(range));
    try std.testing.expect(!c.JS_IsTaggedJobPending(survivor.context, jobTagOf(range)));
    try std.testing.expect(c.JS_GetContextOpaque(survivor.context) == null);
    try survivor.evaluate("if (typeof cycle !== 'undefined' || typeof leftover !== 'undefined' || Error.prepareStackTrace !== undefined) throw 1;", "survivor.js");
}

test "in the shared realm a function only a built-in's closure holds is frozen too" {
    shared_realm_enabled = true;
    defer shared_realm_enabled = false;
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const second = try widgets.engine(1);
    defer second.destroy(std.testing.allocator);
    const first = try widgets.engine(0);
    var alive = true;
    defer if (alive) first.destroy(std.testing.allocator);
    // Iterator.zip's argument check is a function of its own, reachable
    // only through a stack frame (CallSite.getFunction), not a property.
    const reach =
        \\Error.prepareStackTrace = (_, sites) => sites;
        \\globalThis.check = null;
        \\try { Iterator.zip(null); } catch (e) {
        \\  check = e.stack.map((site) => site.getFunction()).find((f) => f && f.name === "check");
        \\}
        \\Error.prepareStackTrace = undefined;
        \\if (typeof check !== "function") throw new Error("no hidden function to check");
    ;
    try first.evaluate(reach, "first.js");
    try first.evaluate(
        \\"use strict";
        \\if (!Object.isFrozen(check)) throw new Error("hidden function not frozen");
        \\try { check.mailbox = new ArrayBuffer(1024 * 1024); } catch {}
    , "first-write.js");
    const range = first.owner;
    first.destroy(std.testing.allocator);
    alive = false;
    try std.testing.expectEqual(@as(usize, 0), heap().usedBytes(range));
    try second.evaluate(reach, "second.js");
    try second.evaluate("if (check.mailbox !== undefined) throw new Error('found something on it');", "second-read.js");
}

test "in the shared realm a finalizer's job is charged to its creator, not the collector" {
    shared_realm_enabled = true;
    defer shared_realm_enabled = false;
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const owner = try widgets.engine(0);
    defer owner.destroy(std.testing.allocator);
    const collector = try widgets.engine(1);
    try owner.evaluate(
        \\globalThis.registry = new FinalizationRegistry((held) => { globalThis.cleaned = held; });
        \\(() => { const target = {}; target.self = target; registry.register(target, "owner's"); })();
    , "owner.js");
    // The collector's teardown collects the owner's target.
    const range = collector.owner;
    collector.destroy(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), heap().usedBytes(range));
    try std.testing.expect(c.JS_IsTaggedJobPending(owner.context, jobTagOf(owner.owner)));
    try owner.evaluate("globalThis.next = true;", "owner-next.js");
    try owner.evaluate("if (cleaned !== \"owner's\") throw new Error('cleanup did not run');", "owner-check.js");
}

test "in the shared realm a cleanup queued by a widget's own teardown goes with it" {
    shared_realm_enabled = true;
    defer shared_realm_enabled = false;
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const survivor = try widgets.engine(1);
    defer survivor.destroy(std.testing.allocator);
    const leaving = try widgets.engine(0);
    // The target is made before its registry, so in the teardown's
    // collection it dies first, while the registry still lives, and its
    // cleanup is queued then.
    try leaving.evaluate(
        \\globalThis.target = {}; target.self = target;
        \\globalThis.registry = new FinalizationRegistry(eval);
        \\registry.register(target, "globalThis.fromDepartedWidget = true;");
    , "leaving.js");
    const range = leaving.owner;
    leaving.destroy(std.testing.allocator);
    try std.testing.expect(!c.JS_IsTaggedJobPending(survivor.context, jobTagOf(range)));
    try std.testing.expectEqual(@as(usize, 0), heap().usedBytes(range));
    // The next widget in that range runs nothing of the last one's.
    const next = try widgets.engine(0);
    defer next.destroy(std.testing.allocator);
    try next.evaluate("globalThis.ran = true;", "next.js");
    try next.evaluate("if (globalThis.fromDepartedWidget !== undefined) throw new Error('ran the departed widget\\'s cleanup');", "next-check.js");
}

test "in the shared realm each widget has its own performance time origin" {
    shared_realm_enabled = true;
    defer shared_realm_enabled = false;
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const first = try widgets.engine(0);
    defer first.destroy(std.testing.allocator);
    try first.evaluate("globalThis.origin = performance.timeOrigin; globalThis.now = performance.now();", "first.js");
    // Long enough that a shared origin could not pass for a new one.
    try first.evaluate("const start = performance.now(); while (performance.now() - start < 25) {}", "wait.js");
    const second = try widgets.engine(1);
    defer second.destroy(std.testing.allocator);
    try second.evaluate("globalThis.origin = performance.timeOrigin; globalThis.now = performance.now();", "second.js");
    const first_origin = try readNumberGlobal(first, "origin");
    const second_origin = try readNumberGlobal(second, "origin");
    try std.testing.expect(second_origin >= first_origin + 20);
    // performance.now() counts from the widget's own origin.
    try std.testing.expect(try readNumberGlobal(second, "now") < 20);
}

fn noopJob(_: ?*c.JSContext, _: c_int, _: [*c]c.JSValue) callconv(.c) c.JSValue {
    return qjs.undefinedValue();
}

test "in a realm of its own a job queued outside a turn is its widget's memory" {
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const widget = try widgets.engine(0);
    defer widget.destroy(std.testing.allocator);
    try std.testing.expectEqual(heap().hostOwner(), heap().current);
    const before = widget.heapBytes();
    const host_before = heap().usedBytes(heap().hostOwner());
    try std.testing.expectEqual(@as(c_int, 0), c.JS_EnqueueJob(widget.context, noopJob, 0, null));
    try std.testing.expect(widget.heapBytes() > before);
    try std.testing.expectEqual(host_before, heap().usedBytes(heap().hostOwner()));
    try widget.evaluate("globalThis.tick = 1;", "tick.js");
}

test "in the shared realm a built-in first used after lockdown is frozen, and the host's" {
    shared_realm_enabled = true;
    defer shared_realm_enabled = false;
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const second = try widgets.engine(1);
    defer second.destroy(std.testing.allocator);
    const first = try widgets.engine(0);
    var alive = true;
    defer if (alive) first.destroy(std.testing.allocator);
    // Built-in methods QuickJS makes on first use are not made at lockdown:
    // the first widget to reach one makes it, frozen, in the host's memory.
    const reach =
        \\globalThis.lazy = [String.prototype.localeCompare, Array.prototype.copyWithin, Math.hypot, Reflect.ownKeys];
    ;
    const host_before = heap().usedBytes(heap().hostOwner());
    try first.evaluate(reach, "first.js");
    try first.evaluate(
        \\"use strict";
        \\if (!lazy.every((f) => Object.isFrozen(f))) throw new Error("a built-in made after lockdown is not frozen");
        \\for (const f of lazy) { try { f.mailbox = 1; } catch {} }
    , "first-write.js");
    try std.testing.expect(heap().usedBytes(heap().hostOwner()) > host_before);
    const range = first.owner;
    first.destroy(std.testing.allocator);
    alive = false;
    try std.testing.expectEqual(@as(usize, 0), heap().usedBytes(range));
    try second.evaluate(reach, "second.js");
    try second.evaluate("if (lazy.some((f) => f.mailbox !== undefined)) throw new Error('found something on it');", "second-read.js");
}

test "in the shared realm lockdown makes the built-ins it can leave for later" {
    shared_realm_enabled = true;
    defer shared_realm_enabled = false;
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const widget = try widgets.engine(0);
    defer widget.destroy(std.testing.allocator);
    // Freezing every object at once used to make every built-in method:
    // 276 KB in the host's range against 125 KB for the realm unfrozen.
    // Made on first use instead, the frozen realm stays near the latter.
    const host = heap().usedBytes(heap().hostOwner());
    std.debug.print("shared realm in the host's range: {d} bytes\n", .{host});
    try std.testing.expect(host < 180 * 1024);
}

test "a widget in the shared realm costs far less than a realm of its own" {
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const own_bytes = own: {
        const keeper = try widgets.engine(1);
        defer keeper.destroy(std.testing.allocator);
        const widget = try widgets.engine(0);
        defer widget.destroy(std.testing.allocator);
        break :own widget.heapBytes();
    };
    // The last engine is gone, so the next one starts a new shared runtime.
    shared_realm_enabled = true;
    defer shared_realm_enabled = false;
    const keeper = try widgets.engine(1);
    defer keeper.destroy(std.testing.allocator);
    const widget = try widgets.engine(0);
    defer widget.destroy(std.testing.allocator);
    const shared_bytes = widget.heapBytes();
    std.debug.print("realm of its own: {d} bytes; in the shared realm: {d} bytes\n", .{ own_bytes, shared_bytes });
    try std.testing.expect(shared_bytes + 40 * 1024 < own_bytes);
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
    // point where this widget would collect inside a turn. Small turns: 2,000
    // shapes in one Debug turn came close enough to `turn_budget_ms` that a
    // busy machine interrupted it.
    for (0..100) |_| try leaving.evaluate("for (let i = 0; i < 500; i += 1) kept.push(Object.create({}));", "shapes.js");
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
