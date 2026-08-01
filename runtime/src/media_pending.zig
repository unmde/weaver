const std = @import("std");

// A good transport interaction can issue a rapid previous/play/seek/next
// sequence before acknowledgements return. Four slots hold that modeled burst
// and pin provider_protocol.ack_queue_capacity; Slot is 16 bytes, so the
// tracker costs 64 bytes fixed.
pub const capacity: usize = 4;
// Host execution is bounded at 2,500 ms. The runtime's 3,000 ms deadline
// leaves 500 ms for pipe delivery/ack handling and retains no extra memory.
pub const timeout_ms: u64 = 3000;
// IEEE-754's largest exactly representable integer. This is a JS/wire
// invariant, not a capacity budget; it mirrors provider_protocol.max_safe_id.
pub const max_safe_id: u64 = 9_007_199_254_740_991;

pub const Slot = struct {
    id: u64 = 0,
    deadline_ms: u64 = 0,
};

pub const Tracker = struct {
    slots: [capacity]Slot = [_]Slot{.{}} ** capacity,

    pub fn add(self: *Tracker, id: u64, now_ms: u64) !usize {
        if (id == 0 or id > max_safe_id) return error.InvalidCommandId;
        var free: ?usize = null;
        for (&self.slots, 0..) |*slot, index| {
            if (slot.id == id) return error.DuplicateCommandId;
            if (slot.id == 0 and free == null) free = index;
        }
        const index = free orelse return error.PendingLimit;
        self.slots[index] = .{ .id = id, .deadline_ms = now_ms +| timeout_ms };
        return index;
    }

    pub fn indexOf(self: *const Tracker, id: u64) ?usize {
        for (self.slots, 0..) |slot, index| if (slot.id == id) return index;
        return null;
    }

    pub fn expired(self: *const Tracker, index: usize, now_ms: u64) bool {
        const slot = self.slots[index];
        return slot.id != 0 and now_ms >= slot.deadline_ms;
    }

    pub fn remove(self: *Tracker, index: usize) void {
        self.slots[index] = .{};
    }

    pub fn nextDeadline(self: *const Tracker) ?u64 {
        var earliest: ?u64 = null;
        for (self.slots) |slot| {
            if (slot.id == 0) continue;
            if (earliest == null or slot.deadline_ms < earliest.?) earliest = slot.deadline_ms;
        }
        return earliest;
    }
};

test "pending tracker caps at four and never reuses a live id" {
    var tracker: Tracker = .{};
    for (1..capacity + 1) |id| _ = try tracker.add(id, 10);
    try std.testing.expectError(error.PendingLimit, tracker.add(5, 10));
    try std.testing.expectError(error.DuplicateCommandId, tracker.add(2, 10));
    tracker.remove(tracker.indexOf(2).?);
    const index = try tracker.add(5, 20);
    try std.testing.expectEqual(@as(u64, 5), tracker.slots[index].id);
}

test "ack lookup timeout and fail-all removal settle every slot exactly once" {
    var tracker: Tracker = .{};
    const first = try tracker.add(11, 100);
    const second = try tracker.add(12, 100);
    try std.testing.expectEqual(@as(u64, 3100), tracker.nextDeadline().?);
    try std.testing.expectEqual(first, tracker.indexOf(11).?);
    try std.testing.expect(!tracker.expired(first, 3099));
    try std.testing.expect(tracker.expired(first, 3100));
    tracker.remove(first);
    try std.testing.expect(tracker.indexOf(11) == null);
    tracker.remove(second);
    for (tracker.slots) |slot| try std.testing.expectEqual(@as(u64, 0), slot.id);
}
