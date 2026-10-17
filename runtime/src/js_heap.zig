//! The QuickJS heap of the shared JS runtime. Every widget's allocations live
//! in its own reserved address range, so any pointer names its owner: frees
//! and usable sizes need no per-block header, a widget's memory cap is exact
//! (its range), and a widget's bytes are countable on their own. Runtime-
//! level allocations made outside any widget's turn go to a last, host
//! range.
//!
//! Inside a range, sizes up to 512 bytes come from 1 KiB granules carved
//! into one size class each (16-byte steps up to 128, then quarter steps);
//! larger blocks are runs of whole granules behind a 16-byte length header.
//! An 8-byte record per granule, at the start of the range, says what it
//! holds; a small-class granule keeps its own free list there, and goes
//! back to the range as soon as its last block is freed. Freed runs merge
//! with free neighbours, the run at the top of the range returns to it, and
//! pages wholly inside free space are decommitted, so freed memory leaves
//! the working set. QuickJS grows its parser and bytecode buffers by
//! repeated realloc; the newest block grows in place.
const std = @import("std");
const builtin = @import("builtin");

pub const Owner = u16;

const granule_bytes: usize = 1024;
const header_bytes: usize = 16;
const small_max: usize = 512;
const class_sizes = [_]u16{ 16, 32, 48, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512 };
const page_bytes: usize = std.heap.page_size_min;
const commit_step: usize = 64 * 1024;

/// What a granule holds: a small class index, or one of these. Only the
/// first and last granule of a run are marked; nothing looks inside one.
const run_start: u8 = 0xF0;
const run_end: u8 = 0xF1;
const free_start: u8 = 0xF2;
const free_end: u8 = 0xF3;

/// No granule, no block: granule indices and in-granule offsets are u16.
const none: u16 = std.math.maxInt(u16);

const Granule = extern struct {
    kind: u8,
    /// Small class: blocks handed out.
    live: u8 = 0,
    /// Small class: offset of the first free block; each free block starts
    /// with the offset of the next.
    free_head: u16 = none,
    /// Small class: neighbours among the class's granules with a free block.
    prev: u16 = none,
    next: u16 = none,
};

/// Head of a free run, in its first granule; its length is repeated in the
/// last 8 bytes of its last granule so the run after it can find its start.
const FreeRun = struct { prev: ?*FreeRun, next: ?*FreeRun, granules: usize };

const Range = struct {
    /// Granules handed out from the heap area so far; everything above is
    /// untouched.
    bump: usize = 0,
    /// Bytes of the granule map committed from its start: as far as the
    /// granules handed out need, not the whole map (256 KiB in a 32 MiB
    /// range, where a clock uses a few hundred granules).
    map_committed: usize = 0,
    /// Bytes of the heap area committed from its start for bump growth.
    committed: usize = 0,
    /// Usable bytes currently allocated.
    used: usize = 0,
    /// Per class, the first granule with a free block.
    open: [class_sizes.len]u16 = @splat(none),
    free_runs: ?*FreeRun = null,
    holder: Holder = .none,
};

/// Who a widget range belongs to. A released range that still holds
/// something the runtime shares (an atom or shape another widget uses) is
/// retired until its last block is freed: a new owner gets an empty range
/// while there is one, so its cap is exact.
const Holder = enum { none, owner, retired };

/// Sizes the heap: `owners` ranges of `range_bytes` each.
pub const Layout = struct {
    owners: usize,
    range_bytes: usize,

    fn granulesPerRange(self: Layout) usize {
        return (self.range_bytes - self.mapBytes()) / granule_bytes;
    }

    fn mapBytes(self: Layout) usize {
        // A record per granule of the whole range, rounded to a page; the
        // map's own granules are simply never handed out.
        return std.mem.alignForward(usize, self.range_bytes / granule_bytes * @sizeOf(Granule), page_bytes);
    }
};

pub const Heap = struct {
    layout: Layout,
    base: [*]u8,
    ranges: []Range,
    /// The owner new allocations are charged to.
    current: Owner,

    pub fn init(allocator: std.mem.Allocator, layout: Layout) !Heap {
        std.debug.assert(layout.granulesPerRange() < none);
        const base = try reserve(layout.owners * layout.range_bytes);
        errdefer release(base, layout.owners * layout.range_bytes);
        const ranges = try allocator.alloc(Range, layout.owners);
        for (ranges) |*range| range.* = .{};
        return .{ .layout = layout, .base = base, .ranges = ranges, .current = @intCast(layout.owners - 1) };
    }

    pub fn deinit(self: *Heap, allocator: std.mem.Allocator) void {
        release(self.base, self.layout.owners * self.layout.range_bytes);
        allocator.free(self.ranges);
        self.* = undefined;
    }

    /// The owner of runtime-level allocations made outside widget turns.
    pub fn hostOwner(self: *const Heap) Owner {
        return @intCast(self.layout.owners - 1);
    }

    /// Usable bytes `owner` holds now.
    pub fn usedBytes(self: *const Heap, owner: Owner) usize {
        return self.ranges[owner].used;
    }

    /// A widget range for a new owner: an empty one, or else the retired
    /// one holding least (shared blocks every widget's reloads leave, such
    /// as atoms for common names, would otherwise use up the ranges). What a
    /// retired range still holds counts against its new owner's cap.
    pub fn acquireOwner(self: *Heap) ?Owner {
        var least: ?usize = null;
        for (self.ranges[0 .. self.ranges.len - 1], 0..) |*range, owner| {
            switch (range.holder) {
                .none => {
                    range.holder = .owner;
                    return @intCast(owner);
                },
                .retired => if (least == null or range.used < self.ranges[least.?].used) {
                    least = owner;
                },
                .owner => {},
            }
        }
        const owner = least orelse return null;
        self.ranges[owner].holder = .owner;
        return @intCast(owner);
    }

    /// The owner is gone. An empty range is reset for the next owner; one
    /// that still holds shared blocks is retired until they are freed.
    pub fn releaseOwner(self: *Heap, owner: Owner) void {
        if (self.ranges[owner].used == 0) self.resetRange(owner) else self.ranges[owner].holder = .retired;
    }

    /// Give an empty range back whole: the empty granules its size classes
    /// keep for reuse would otherwise sit scattered through it, and the next
    /// owner could not get one run as long as the range allows.
    fn resetRange(self: *Heap, owner: Owner) void {
        const range = &self.ranges[owner];
        std.debug.assert(range.used == 0);
        if (range.map_committed > 0) decommit(self.rangeBase(owner), range.map_committed);
        if (range.committed > 0) decommit(self.granuleAddress(owner, 0), range.committed);
        range.* = .{};
    }

    /// A retired range whose last shared block was just freed is free again.
    fn settle(self: *Heap, owner: Owner) void {
        const range = &self.ranges[owner];
        if (range.holder == .retired and range.used == 0) self.resetRange(owner);
    }

    /// Bytes of `owner`'s heap area below its top: the most that can be
    /// resident (free runs inside it are mostly decommitted).
    pub fn grownBytes(self: *const Heap, owner: Owner) usize {
        return self.ranges[owner].bump * granule_bytes;
    }

    fn rangeBase(self: *const Heap, owner: Owner) [*]u8 {
        return self.base + @as(usize, owner) * self.layout.range_bytes;
    }

    fn granules(self: *const Heap, owner: Owner) [*]Granule {
        return @ptrCast(@alignCast(self.rangeBase(owner)));
    }

    fn granuleAddress(self: *const Heap, owner: Owner, granule: usize) [*]u8 {
        return self.rangeBase(owner) + self.layout.mapBytes() + granule * granule_bytes;
    }

    fn ownerOf(self: *const Heap, ptr: *const anyopaque) Owner {
        return @intCast((@intFromPtr(ptr) - @intFromPtr(self.base)) / self.layout.range_bytes);
    }

    fn granuleOf(self: *const Heap, owner: Owner, ptr: *const anyopaque) usize {
        return (@intFromPtr(ptr) - @intFromPtr(self.granuleAddress(owner, 0))) / granule_bytes;
    }

    fn runHead(self: *const Heap, owner: Owner, start: usize) *FreeRun {
        return @ptrCast(@alignCast(self.granuleAddress(owner, start)));
    }

    fn runFooter(self: *const Heap, owner: Owner, last: usize) *usize {
        return @ptrCast(@alignCast(self.granuleAddress(owner, last) + granule_bytes - @sizeOf(usize)));
    }

    /// Mark the first and last granule of a run of `count`.
    fn markEnds(self: *Heap, owner: Owner, start: usize, count: usize, first: u8, last: u8) void {
        const map = self.granules(owner);
        map[start + count - 1] = .{ .kind = last };
        map[start] = .{ .kind = first };
    }

    /// Commit the granule map's records and the heap area for granules
    /// [0, end): what bump growth to `end` touches.
    fn ensureCommitted(self: *Heap, owner: Owner, end: usize) bool {
        const range = &self.ranges[owner];
        const map_end = std.mem.alignForward(usize, end * @sizeOf(Granule), page_bytes);
        if (map_end > range.map_committed) {
            if (!commit(self.rangeBase(owner) + range.map_committed, map_end - range.map_committed)) return false;
            range.map_committed = map_end;
        }
        const area_end = end * granule_bytes;
        if (area_end <= range.committed) return true;
        const area_bytes = self.layout.range_bytes - self.layout.mapBytes();
        const target = @min(std.mem.alignForward(usize, area_end, commit_step), area_bytes);
        if (!commit(self.granuleAddress(owner, 0) + range.committed, target - range.committed)) return false;
        range.committed = target;
        return true;
    }

    fn commitGranules(self: *Heap, owner: Owner, start: usize, count: usize) bool {
        const first = std.mem.alignBackward(usize, @intFromPtr(self.granuleAddress(owner, start)), page_bytes);
        const end = std.mem.alignForward(usize, @intFromPtr(self.granuleAddress(owner, start + count)), page_bytes);
        return commit(@ptrFromInt(first), end - first);
    }

    /// Decommit the pages wholly inside free granules [start, start+count),
    /// keeping the head and footer pages.
    fn decommitInterior(self: *Heap, owner: Owner, start: usize, count: usize) void {
        const head_end = @intFromPtr(self.granuleAddress(owner, start)) + @sizeOf(FreeRun);
        const footer = @intFromPtr(self.runFooter(owner, start + count - 1));
        const first = std.mem.alignForward(usize, head_end, page_bytes);
        const end = std.mem.alignBackward(usize, footer, page_bytes);
        if (end > first) decommit(@ptrFromInt(first), end - first);
    }

    fn unlink(self: *Heap, owner: Owner, run: *FreeRun) void {
        if (run.prev) |prev| prev.next = run.next else self.ranges[owner].free_runs = run.next;
        if (run.next) |next| next.prev = run.prev;
    }

    /// Record granules [start, start+count) as one free run, merging with
    /// free neighbours, or hand them back to the top of the range.
    fn freeGranules(self: *Heap, owner: Owner, first_granule: usize, first_count: usize) void {
        const range = &self.ranges[owner];
        const map = self.granules(owner);
        var start = first_granule;
        var count = first_count;
        const after = start + count;
        if (after < range.bump and map[after].kind == free_start) {
            const next = self.runHead(owner, after);
            self.unlink(owner, next);
            count += next.granules;
        }
        if (start > 0 and (map[start - 1].kind == free_start or map[start - 1].kind == free_end)) {
            const previous_count = self.runFooter(owner, start - 1).*;
            start -= previous_count;
            self.unlink(owner, self.runHead(owner, start));
            count += previous_count;
        }
        if (start + count == range.bump) {
            // The top of the range: give it back to the bump region and
            // decommit what is no longer reachable from below.
            range.bump = start;
            // The map keeps its pages: 8 bytes a granule, a page per 512 KiB.
            const keep = std.mem.alignForward(usize, start * granule_bytes, page_bytes);
            if (range.committed > keep) {
                decommit(self.granuleAddress(owner, 0) + keep, range.committed - keep);
                range.committed = keep;
            }
            return;
        }
        self.markEnds(owner, start, count, free_start, free_end);
        const run = self.runHead(owner, start);
        run.* = .{ .prev = null, .next = range.free_runs, .granules = count };
        if (range.free_runs) |head| head.prev = run;
        range.free_runs = run;
        self.runFooter(owner, start + count - 1).* = count;
        self.decommitInterior(owner, start, count);
    }

    /// `count` contiguous committed granules: a free run that fits, else
    /// fresh ones from the top of the range.
    fn takeGranules(self: *Heap, owner: Owner, count: usize) ?usize {
        const range = &self.ranges[owner];
        var cursor = range.free_runs;
        while (cursor) |run| : (cursor = run.next) {
            if (run.granules < count) continue;
            const start = self.granuleOf(owner, run);
            const remaining = run.granules - count;
            // Commit before touching the run's bookkeeping, so a failed
            // commit leaves the run as it was. The remainder's head granule
            // is written below, so it is committed too.
            if (!self.commitGranules(owner, start, count + @intFromBool(remaining > 0))) return null;
            self.unlink(owner, run);
            if (remaining > 0) {
                // Taken before the remainder is freed, so its merge check
                // does not see these granules as a free neighbour.
                self.granules(owner)[start + count - 1] = .{ .kind = run_end };
                self.freeGranules(owner, start + count, remaining);
            }
            return start;
        }
        if (range.bump + count > self.layout.granulesPerRange()) return null;
        const start = range.bump;
        if (!self.ensureCommitted(owner, start + count)) return null;
        range.bump += count;
        return start;
    }

    pub fn alloc(self: *Heap, size: usize) ?*anyopaque {
        return self.allocFor(self.current, size);
    }

    fn allocFor(self: *Heap, owner: Owner, size: usize) ?*anyopaque {
        if (size == 0 or size > self.layout.range_bytes) return null;
        const range = &self.ranges[owner];
        if (size <= small_max) {
            const class = classFor(size);
            const granule = if (range.open[class] != none) range.open[class] else self.carve(owner, class) orelse return null;
            const record = &self.granules(owner)[granule];
            const block = self.granuleAddress(owner, granule) + record.free_head;
            record.free_head = @as(*const u16, @ptrCast(@alignCast(block))).*;
            record.live += 1;
            if (record.free_head == none) self.close(owner, class, granule);
            range.used += class_sizes[class];
            return block;
        }
        const count = runGranules(size);
        const start = self.takeGranules(owner, count) orelse return null;
        self.markRun(owner, start, count);
        range.used += count * granule_bytes - header_bytes;
        return self.granuleAddress(owner, start) + header_bytes;
    }

    /// A fresh granule of `class` blocks, all free, opened for allocation.
    fn carve(self: *Heap, owner: Owner, class: usize) ?u16 {
        const granule = self.takeGranules(owner, 1) orelse return null;
        const block_size: usize = class_sizes[class];
        const first = self.granuleAddress(owner, granule);
        var next: u16 = none;
        var offset: usize = granule_bytes - granule_bytes % block_size;
        while (offset >= block_size) {
            offset -= block_size;
            @as(*u16, @ptrCast(@alignCast(first + offset))).* = next;
            next = @intCast(offset);
        }
        self.granules(owner)[granule] = .{ .kind = @intCast(class), .free_head = 0 };
        self.open(owner, class, @intCast(granule));
        return @intCast(granule);
    }

    fn open(self: *Heap, owner: Owner, class: usize, granule: u16) void {
        const range = &self.ranges[owner];
        const map = self.granules(owner);
        map[granule].prev = none;
        map[granule].next = range.open[class];
        if (range.open[class] != none) map[range.open[class]].prev = granule;
        range.open[class] = granule;
    }

    fn close(self: *Heap, owner: Owner, class: usize, granule: u16) void {
        const map = self.granules(owner);
        const record = map[granule];
        if (record.prev != none) map[record.prev].next = record.next else self.ranges[owner].open[class] = record.next;
        if (record.next != none) map[record.next].prev = record.prev;
    }

    fn markRun(self: *Heap, owner: Owner, start: usize, count: usize) void {
        self.markEnds(owner, start, count, run_start, if (count == 1) run_start else run_end);
        const header: *usize = @ptrCast(@alignCast(self.granuleAddress(owner, start)));
        header.* = count;
    }

    fn runCount(ptr: *const anyopaque) usize {
        return @as(*const usize, @ptrCast(@alignCast(@as([*]const u8, @ptrCast(ptr)) - header_bytes))).*;
    }

    pub fn usableSize(self: *const Heap, ptr: *const anyopaque) usize {
        const owner = self.ownerOf(ptr);
        const kind = self.granules(owner)[self.granuleOf(owner, ptr)].kind;
        if (kind < class_sizes.len) return class_sizes[kind];
        return runCount(ptr) * granule_bytes - header_bytes;
    }

    pub fn free(self: *Heap, ptr: *anyopaque) void {
        const owner = self.ownerOf(ptr);
        const range = &self.ranges[owner];
        const granule: u16 = @intCast(self.granuleOf(owner, ptr));
        const record = &self.granules(owner)[granule];
        const kind = record.kind;
        if (kind < class_sizes.len) {
            range.used -= class_sizes[kind];
            const was_full = record.free_head == none;
            @as(*u16, @ptrCast(@alignCast(ptr))).* = record.free_head;
            record.free_head = @intCast(@intFromPtr(ptr) - @intFromPtr(self.granuleAddress(owner, granule)));
            record.live -= 1;
            if (was_full) self.open(owner, kind, granule);
            // An empty granule goes back, unless it is the class's last one
            // with room: then an alloc/free pair at the edge cannot make
            // every call take and return a granule.
            if (record.live == 0 and (range.open[kind] != granule or record.next != none)) {
                self.close(owner, kind, granule);
                self.freeGranules(owner, granule, 1);
            }
            self.settle(owner);
            return;
        }
        std.debug.assert(kind == run_start);
        const count = runCount(ptr);
        range.used -= count * granule_bytes - header_bytes;
        self.freeGranules(owner, granule, count);
        self.settle(owner);
    }

    /// Grow or shrink in the block's own range, so an object stays with the
    /// widget that made it. The block at the top of its range grows in place.
    pub fn realloc(self: *Heap, ptr: ?*anyopaque, size: usize) ?*anyopaque {
        const old = ptr orelse return self.alloc(size);
        if (size == 0) {
            self.free(old);
            return null;
        }
        if (size > self.layout.range_bytes) return null;
        const usable = self.usableSize(old);
        if (size <= usable) return old;
        const owner = self.ownerOf(old);
        // A block another widget grows is one they share (an atom or a
        // shape): it moves to the widget growing it, which pays for the
        // growth, instead of growing in a range whose owner may since have
        // gone and been replaced.
        const target = if (self.current != owner and self.current != self.hostOwner()) self.current else owner;
        const range = &self.ranges[owner];
        const granule = self.granuleOf(owner, old);
        if (target == owner and size > small_max and self.granules(owner)[granule].kind == run_start) {
            const count = runCount(old);
            const wanted = runGranules(size);
            if (granule + count == range.bump and granule + wanted <= self.layout.granulesPerRange() and
                self.ensureCommitted(owner, granule + wanted))
            {
                range.bump = granule + wanted;
                self.markRun(owner, granule, wanted);
                range.used += (wanted - count) * granule_bytes;
                return old;
            }
        }
        const moved = self.allocFor(target, size) orelse return null;
        @memcpy(@as([*]u8, @ptrCast(moved))[0..usable], @as([*]const u8, @ptrCast(old))[0..usable]);
        self.free(old);
        return moved;
    }
};

/// Granules for a block of `size` bytes; callers cap `size` at a range first.
fn runGranules(size: usize) usize {
    return (size + header_bytes + granule_bytes - 1) / granule_bytes;
}

fn classFor(size: usize) usize {
    for (class_sizes, 0..) |class_size, index| {
        if (size <= class_size) return index;
    }
    unreachable;
}

extern "kernel32" fn VirtualAlloc(address: ?*anyopaque, size: usize, kind: u32, protect: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn VirtualFree(address: ?*anyopaque, size: usize, kind: u32) callconv(.winapi) std.os.windows.BOOL;
const mem_commit: u32 = 0x1000;
const mem_reserve: u32 = 0x2000;
const mem_decommit: u32 = 0x4000;
const mem_release: u32 = 0x8000;
const page_noaccess: u32 = 0x01;
const page_readwrite: u32 = 0x04;

/// Address space only: nothing commits until a range grows into it.
fn reserve(bytes: usize) ![*]u8 {
    if (builtin.os.tag == .windows) {
        const address = VirtualAlloc(null, bytes, mem_reserve, page_noaccess) orelse return error.OutOfMemory;
        return @ptrCast(address);
    }
    const mapped = std.posix.mmap(null, bytes, .{}, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = builtin.os.tag == .linux }, -1, 0) catch return error.OutOfMemory;
    return mapped.ptr;
}

fn commit(address: [*]u8, bytes: usize) bool {
    if (bytes == 0) return true;
    if (builtin.os.tag == .windows) return VirtualAlloc(address, bytes, mem_commit, page_readwrite) != null;
    return std.c.mprotect(@ptrCast(@alignCast(address)), bytes, .{ .READ = true, .WRITE = true }) == 0;
}

/// Give pages back: their contents are gone and they leave the working set.
fn decommit(address: [*]u8, bytes: usize) void {
    if (builtin.os.tag == .windows) {
        _ = VirtualFree(address, bytes, mem_decommit);
        return;
    }
    const pages: []align(page_bytes) u8 = @alignCast(address[0..bytes]);
    std.posix.madvise(pages.ptr, pages.len, std.posix.MADV.DONTNEED) catch {};
    _ = std.c.mprotect(pages.ptr, pages.len, .{});
}

fn release(address: [*]u8, bytes: usize) void {
    if (builtin.os.tag == .windows) {
        _ = VirtualFree(address, 0, mem_release);
        return;
    }
    const pages: []align(page_bytes) u8 = @alignCast(address[0..bytes]);
    std.posix.munmap(pages);
}

test "allocations stay in their owner's range and free by address" {
    var heap = try Heap.init(std.testing.allocator, .{ .owners = 3, .range_bytes = 1024 * 1024 });
    defer heap.deinit(std.testing.allocator);

    heap.current = 0;
    const a = heap.alloc(24).?;
    const big = heap.alloc(5000).?;
    const pin = heap.alloc(5000).?;
    heap.current = 1;
    const b = heap.alloc(24).?;
    try std.testing.expectEqual(@as(Owner, 0), heap.ownerOf(a));
    try std.testing.expectEqual(@as(Owner, 0), heap.ownerOf(big));
    try std.testing.expectEqual(@as(Owner, 1), heap.ownerOf(b));
    try std.testing.expectEqual(@as(usize, 32), heap.usableSize(a));
    try std.testing.expect(heap.usableSize(big) >= 5000);
    try std.testing.expectEqual(@as(usize, 32) + 2 * heap.usableSize(big), heap.usedBytes(0));
    try std.testing.expectEqual(@as(usize, 32), heap.usedBytes(1));

    // Freed in another owner's turn, still credited to its own range; the
    // same class block and the freed run come back.
    heap.free(a);
    heap.free(big);
    try std.testing.expectEqual(heap.usableSize(pin), heap.usedBytes(0));
    heap.current = 0;
    try std.testing.expectEqual(a, heap.alloc(20).?);
    try std.testing.expectEqual(big, heap.alloc(4000).?);
}

test "a range commits its granule map as far as its granules reach" {
    var heap = try Heap.init(std.testing.allocator, .{ .owners = 2, .range_bytes = 32 * 1024 * 1024 });
    defer heap.deinit(std.testing.allocator);
    heap.current = 0;
    _ = heap.alloc(24).?;
    // One granule: one page of a 256 KiB map.
    try std.testing.expectEqual(page_bytes, heap.ranges[0].map_committed);
    try std.testing.expectEqual(commit_step, heap.ranges[0].committed);
    // 600 more granules reach a second map page (8 bytes each), no further.
    const run = heap.alloc(600 * granule_bytes - header_bytes).?;
    try std.testing.expectEqual(2 * page_bytes, heap.ranges[0].map_committed);
    @memset(@as([*]u8, @ptrCast(run))[0 .. 600 * granule_bytes - header_bytes], 0xAB);
    // The run at the top comes back; the heap area decommits, the map stays.
    heap.free(run);
    try std.testing.expectEqual(2 * page_bytes, heap.ranges[0].map_committed);
    try std.testing.expect(heap.ranges[0].committed <= commit_step);
}

test "free runs merge and the top of the range comes back" {
    var heap = try Heap.init(std.testing.allocator, .{ .owners = 2, .range_bytes = 1024 * 1024 });
    defer heap.deinit(std.testing.allocator);
    heap.current = 0;
    const first = heap.alloc(3000).?;
    const second = heap.alloc(3000).?;
    const third = heap.alloc(3000).?;
    const grown = heap.grownBytes(0);
    heap.free(first);
    heap.free(second);
    // Two neighbouring 3-granule runs merged: a 6-granule block fits where they were.
    try std.testing.expectEqual(first, heap.alloc(6000).?);
    heap.free(third);
    try std.testing.expect(heap.grownBytes(0) < grown);
}

test "the newest block grows in place" {
    var heap = try Heap.init(std.testing.allocator, .{ .owners = 2, .range_bytes = 1024 * 1024 });
    defer heap.deinit(std.testing.allocator);
    heap.current = 0;
    var buffer: [*]u8 = @ptrCast(heap.alloc(1000).?);
    @memcpy(buffer[0..5], "hello");
    var size: usize = 1000;
    while (size < 64 * 1024) : (size *= 2) {
        const next: [*]u8 = @ptrCast(heap.realloc(buffer, size * 2).?);
        try std.testing.expectEqual(buffer, next);
        buffer = next;
    }
    try std.testing.expectEqualStrings("hello", buffer[0..5]);
    try std.testing.expect(heap.grownBytes(0) <= 130 * 1024);
}

test "realloc keeps contents and the block's owner" {
    var heap = try Heap.init(std.testing.allocator, .{ .owners = 2, .range_bytes = 1024 * 1024 });
    defer heap.deinit(std.testing.allocator);
    heap.current = 0;
    const small: [*]u8 = @ptrCast(heap.alloc(10).?);
    @memcpy(small[0..10], "abcdefghij");
    heap.current = 1;
    const grown: [*]u8 = @ptrCast(heap.realloc(small, 3000).?);
    try std.testing.expectEqualStrings("abcdefghij", grown[0..10]);
    try std.testing.expectEqual(@as(Owner, 0), heap.ownerOf(grown));
    try std.testing.expectEqual(@as(usize, 0), heap.usedBytes(1));
}

test "a small-class granule goes back once its blocks are all free" {
    var heap = try Heap.init(std.testing.allocator, .{ .owners = 2, .range_bytes = 1024 * 1024 });
    defer heap.deinit(std.testing.allocator);
    heap.current = 0;
    // Eight full granules of 64-byte blocks, then a large block above them.
    var blocks: [128]*anyopaque = undefined;
    for (&blocks) |*block| block.* = heap.alloc(64).?;
    const keep = heap.alloc(5000).?;
    for (blocks) |block| heap.free(block);
    try std.testing.expectEqual(heap.usableSize(keep), heap.usedBytes(0));
    // The class keeps one empty granule; the other seven merged into one
    // free run below `keep`, where a 7-granule block now fits.
    const reused = heap.alloc(7000).?;
    try std.testing.expect(@intFromPtr(reused) < @intFromPtr(keep));
    heap.free(reused);
    heap.free(keep);
    try std.testing.expect(heap.grownBytes(0) <= 1024);
}

test "sizes past a range fail instead of wrapping" {
    var heap = try Heap.init(std.testing.allocator, .{ .owners = 2, .range_bytes = 1024 * 1024 });
    defer heap.deinit(std.testing.allocator);
    heap.current = 0;
    try std.testing.expectEqual(@as(?*anyopaque, null), heap.alloc(std.math.maxInt(usize)));
    const small: [*]u8 = @ptrCast(heap.alloc(10).?);
    @memcpy(small[0..3], "abc");
    try std.testing.expectEqual(@as(?*anyopaque, null), heap.realloc(small, std.math.maxInt(usize)));
    try std.testing.expectEqualStrings("abc", small[0..3]);
}

test "a range refuses past its capacity, the cap" {
    var heap = try Heap.init(std.testing.allocator, .{ .owners = 2, .range_bytes = 256 * 1024 });
    defer heap.deinit(std.testing.allocator);
    heap.current = 0;
    var count: usize = 0;
    while (heap.alloc(4096) != null) count += 1;
    // The range less its granule map (a page or more), 5 granules per
    // 4 KiB block.
    try std.testing.expectEqual(heap.layout.granulesPerRange() / 5, count);
    // The other range is untouched by the first one's exhaustion.
    heap.current = 1;
    try std.testing.expect(heap.alloc(4096) != null);
}

test "random allocations keep their contents and their accounting" {
    var heap = try Heap.init(std.testing.allocator, .{ .owners = 2, .range_bytes = 8 * 1024 * 1024 });
    defer heap.deinit(std.testing.allocator);
    heap.current = 0;
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    const Live = struct { ptr: [*]u8, size: usize, tag: u8 };
    var live: [256]?Live = @splat(null);
    var expected_used: usize = 0;
    for (0..20_000) |step| {
        const index = random.uintLessThan(usize, live.len);
        if (live[index]) |block| {
            for (block.ptr[0..block.size]) |byte| try std.testing.expectEqual(block.tag, byte);
            expected_used -= heap.usableSize(block.ptr);
            if (random.boolean()) {
                heap.free(block.ptr);
                live[index] = null;
                continue;
            }
            const size = 1 + random.uintLessThan(usize, if (random.uintLessThan(u8, 8) == 0) 40_000 else 600);
            const moved: [*]u8 = @ptrCast(heap.realloc(block.ptr, size).?);
            const kept = @min(size, block.size);
            for (moved[0..kept]) |byte| try std.testing.expectEqual(block.tag, byte);
            @memset(moved[0..size], block.tag);
            live[index] = .{ .ptr = moved, .size = size, .tag = block.tag };
            expected_used += heap.usableSize(moved);
        } else {
            const size = 1 + random.uintLessThan(usize, if (random.uintLessThan(u8, 8) == 0) 40_000 else 600);
            const ptr: [*]u8 = @ptrCast(heap.alloc(size).?);
            const tag: u8 = @truncate(step);
            @memset(ptr[0..size], tag);
            live[index] = .{ .ptr = ptr, .size = size, .tag = tag };
            expected_used += heap.usableSize(ptr);
        }
        try std.testing.expectEqual(expected_used, heap.usedBytes(0));
    }
    for (&live) |*slot| if (slot.*) |block| heap.free(block.ptr);
    try std.testing.expectEqual(@as(usize, 0), heap.usedBytes(0));
}

