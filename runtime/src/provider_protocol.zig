const std = @import("std");
const media_pending = @import("media_pending.zig");
const media_protocol = @import("media_protocol.zig");

// The largest possible media publication is derived and receipted in
// media_protocol.zig; aliasing it prevents a second frame-size budget.
pub const frame_line_capacity: usize = media_protocol.max_media_frame_bytes;
// One host publication cycle can contain CPU, memory, audio, and media: four
// frames. Four slots preserve that complete measured protocol shape; entries
// reserve 4 * 12,502 = 50,008 bytes, with pages touched as frames arrive.
pub const frame_queue_capacity: usize = 4;
// One acknowledgement slot per live media command. Derivation makes a queue/
// tracker mismatch impossible; four slots cost only fixed AckSlot metadata.
pub const ack_queue_capacity: usize = media_pending.capacity;
// The longest legal seek command (u64 seek, JS-safe id, newline) measures 86
// UTF-8 bytes. 256 leaves almost 3x protocol-format headroom and costs one
// fixed stack buffer while a command is sent.
pub const command_line_capacity: usize = 256;
// IEEE-754's largest exactly representable integer. This is a JS/wire
// invariant, not a capacity budget; larger IDs cannot round-trip exactly.
pub const max_safe_id: u64 = 9_007_199_254_740_991;

pub const Ack = struct {
    id: u64,
    ok: bool,
};

const AckSlot = struct {
    id: u64 = 0,
    value: ?Ack = null,
    delivered: bool = false,
};

const AckWire = struct {
    ack: u64,
    ok: bool,
};

const FrameEntry = struct {
    bytes: [frame_line_capacity]u8 = undefined,
    len: usize = 0,
};

const SpinMutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    pub fn lock(self: *SpinMutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *SpinMutex) void {
        self.inner.unlock();
    }
};

/// The platform reader thread calls `routeLine`; the app loop calls `take*`.
/// Provider frames retain their established drop-oldest semantics. Acks have
/// their own structurally non-lossy lane sized to the four-pending command cap.
pub const Queues = struct {
    mutex: SpinMutex = .{},
    frames: [frame_queue_capacity]FrameEntry = [_]FrameEntry{.{}} ** frame_queue_capacity,
    frame_head: usize = 0,
    frame_count: usize = 0,
    acks: [ack_queue_capacity]AckSlot = [_]AckSlot{.{}} ** ack_queue_capacity,
    ack_protocol_failed: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    unknown_ack_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    wake_generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Registration happens on the app loop before the command is written.
    /// One slot per live command makes the lane structurally non-lossy: with
    /// the frozen four-pending cap, a known acknowledgement always has exactly
    /// one reserved destination.
    pub fn registerAck(self: *Queues, id: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.acks) |*slot| {
            if (slot.id == id) return false;
            if (slot.id == 0) {
                slot.* = .{ .id = id };
                return true;
            }
        }
        return false;
    }

    pub fn unregisterAck(self: *Queues, id: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.acks) |*slot| {
            if (slot.id != id) continue;
            slot.* = .{};
            return;
        }
    }

    pub fn routeLine(self: *Queues, line: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.routeLineLocked(line);
    }

    fn routeLineLocked(self: *Queues, line: []const u8) void {
        const envelope = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, line, .{}) catch {
            if (std.mem.indexOf(u8, line, "\"ack\"") != null) {
                self.ack_protocol_failed.store(1, .release);
                _ = self.wake_generation.fetchAdd(1, .release);
            }
            return self.pushFrameLocked(line);
        };
        defer envelope.deinit();
        const is_ack = switch (envelope.value) {
            .object => |object| object.contains("ack"),
            else => false,
        };
        if (is_ack) {
            // Reader threads wake the app loop for acknowledgement/protocol
            // events only. Provider frames retain their established timer
            // drain and batching behavior.
            _ = self.wake_generation.fetchAdd(1, .release);
            const parsed = std.json.parseFromSlice(AckWire, std.heap.page_allocator, line, .{
                .ignore_unknown_fields = false,
            }) catch {
                self.ack_protocol_failed.store(1, .release);
                return;
            };
            defer parsed.deinit();
            if (parsed.value.ack == 0 or parsed.value.ack > max_safe_id) {
                self.ack_protocol_failed.store(1, .release);
                return;
            }
            for (&self.acks) |*slot| {
                if (slot.id != parsed.value.ack) continue;
                if (slot.value != null or slot.delivered) {
                    _ = self.unknown_ack_count.fetchAdd(1, .monotonic);
                    return;
                }
                slot.value = .{ .id = parsed.value.ack, .ok = parsed.value.ok };
                return;
            }
            _ = self.unknown_ack_count.fetchAdd(1, .monotonic);
            return;
        }
        self.pushFrameLocked(line);
    }

    pub fn wakeGeneration(self: *const Queues) u64 {
        return self.wake_generation.load(.acquire);
    }

    fn pushFrameLocked(self: *Queues, line: []const u8) void {
        if (line.len == 0 or line.len > frame_line_capacity) return;
        if (self.frame_count == self.frames.len) {
            self.frame_head = (self.frame_head + 1) % self.frames.len;
            self.frame_count -= 1;
        }
        const index = (self.frame_head + self.frame_count) % self.frames.len;
        @memcpy(self.frames[index].bytes[0..line.len], line);
        self.frames[index].len = line.len;
        self.frame_count += 1;
    }

    pub fn takeFrame(self: *Queues, output: []u8) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.frame_count == 0) return null;
        const entry = &self.frames[self.frame_head];
        if (entry.len > output.len) return null;
        @memcpy(output[0..entry.len], entry.bytes[0..entry.len]);
        self.frame_head = (self.frame_head + 1) % self.frames.len;
        self.frame_count -= 1;
        return output[0..entry.len];
    }

    pub fn takeAck(self: *Queues) ?Ack {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.acks) |*slot| {
            const result = slot.value orelse continue;
            slot.value = null;
            slot.delivered = true;
            return result;
        }
        return null;
    }
};

/// Incremental newline framing for platform readers. A disconnected partial
/// line is a protocol failure because it could be a truncated acknowledgement.
pub const Framer = struct {
    pending: [frame_line_capacity * 2]u8 = undefined,
    pending_len: usize = 0,

    pub fn feed(self: *Framer, queues: *Queues, bytes: []const u8) bool {
        if (bytes.len > self.pending.len - self.pending_len) {
            queues.ack_protocol_failed.store(1, .release);
            _ = queues.wake_generation.fetchAdd(1, .release);
            return false;
        }
        @memcpy(self.pending[self.pending_len..][0..bytes.len], bytes);
        self.pending_len += bytes.len;
        // One stream read is one publication boundary. The host deliberately
        // writes related newline-delimited frames (for example CPU + memory)
        // in one bounded send, so keep every complete line from that read
        // indivisible with respect to the app-loop drain.
        queues.mutex.lock();
        defer queues.mutex.unlock();
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, self.pending[0..self.pending_len], start, '\n')) |end| {
            queues.routeLineLocked(self.pending[start..end]);
            start = end + 1;
        }
        if (start > 0) {
            std.mem.copyForwards(u8, self.pending[0 .. self.pending_len - start], self.pending[start..self.pending_len]);
            self.pending_len -= start;
        }
        return true;
    }

    pub fn finish(self: *Framer, queues: *Queues) void {
        if (self.pending_len != 0) queues.ack_protocol_failed.store(1, .release);
        self.pending_len = 0;
    }
};

test "interleaved frames coalesce while four acks never drop" {
    var queues: Queues = .{};
    for (1..5) |id| try std.testing.expect(queues.registerAck(id));
    queues.routeLine("{\"provider\":\"cpu\",\"value\":{\"percent\":1}}");
    queues.routeLine("{\"ack\":1,\"ok\":true}");
    queues.routeLine("{\"provider\":\"cpu\",\"value\":{\"percent\":2}}");
    queues.routeLine("{\"ack\":2,\"ok\":false}");
    queues.routeLine("{\"provider\":\"cpu\",\"value\":{\"percent\":3}}");
    queues.routeLine("{\"provider\":\"cpu\",\"value\":{\"percent\":4}}");
    queues.routeLine("{\"provider\":\"cpu\",\"value\":{\"percent\":5}}");
    queues.routeLine("{\"ack\":3,\"ok\":true}");
    queues.routeLine("{\"ack\":4,\"ok\":true}");

    var output: [frame_line_capacity]u8 = undefined;
    try std.testing.expectEqualStrings("{\"provider\":\"cpu\",\"value\":{\"percent\":2}}", queues.takeFrame(&output).?);
    try std.testing.expectEqualStrings("{\"provider\":\"cpu\",\"value\":{\"percent\":3}}", queues.takeFrame(&output).?);
    try std.testing.expectEqualStrings("{\"provider\":\"cpu\",\"value\":{\"percent\":4}}", queues.takeFrame(&output).?);
    try std.testing.expectEqualStrings("{\"provider\":\"cpu\",\"value\":{\"percent\":5}}", queues.takeFrame(&output).?);
    for ([_]Ack{
        .{ .id = 1, .ok = true },
        .{ .id = 2, .ok = false },
        .{ .id = 3, .ok = true },
        .{ .id = 4, .ok = true },
    }) |expected| try std.testing.expectEqualDeep(expected, queues.takeAck().?);
}

test "reader wake generation advances for acknowledgements but not provider frames" {
    var queues: Queues = .{};
    const initial = queues.wakeGeneration();
    queues.routeLine("{\"provider\":\"cpu\",\"value\":{\"percent\":1}}");
    try std.testing.expectEqual(initial, queues.wakeGeneration());
    try std.testing.expect(queues.registerAck(1));
    queues.routeLine("{\"ack\":1,\"ok\":true}");
    try std.testing.expectEqual(initial + 1, queues.wakeGeneration());
}

test "late acknowledgements cannot crowd out replacement command IDs" {
    var queues: Queues = .{};
    for (1..5) |id| try std.testing.expect(queues.registerAck(id));
    for (1..5) |id| queues.unregisterAck(id);
    for (5..9) |id| try std.testing.expect(queues.registerAck(id));
    for (1..5) |id| {
        var line: [64]u8 = undefined;
        queues.routeLine(try std.fmt.bufPrint(&line, "{{\"ack\":{d},\"ok\":true}}", .{id}));
    }
    for (5..9) |id| {
        var line: [64]u8 = undefined;
        queues.routeLine(try std.fmt.bufPrint(&line, "{{\"ack\":{d},\"ok\":true}}", .{id}));
    }
    try std.testing.expectEqual(@as(u64, 4), queues.unknown_ack_count.load(.acquire));
    for (5..9) |id| {
        const ack = queues.takeAck().?;
        try std.testing.expectEqual(@as(u64, id), ack.id);
        queues.unregisterAck(ack.id);
    }
    try std.testing.expect(queues.takeAck() == null);
    try std.testing.expectEqual(@as(u8, 0), queues.ack_protocol_failed.load(.acquire));
}

test "partial framing stays outside demux and malformed ack poisons only ack lane" {
    var queues: Queues = .{};
    queues.routeLine("{\"ack\":1}");
    try std.testing.expectEqual(@as(u8, 1), queues.ack_protocol_failed.load(.acquire));
    try std.testing.expect(queues.takeAck() == null);
    var output: [frame_line_capacity]u8 = undefined;
    try std.testing.expect(queues.takeFrame(&output) == null);
}

test "runtime framing demuxes interleaved lines split across reads" {
    var queues: Queues = .{};
    try std.testing.expect(queues.registerAck(9));
    var framer: Framer = .{};
    try std.testing.expect(framer.feed(&queues, "{\"provider\":\"media\",\"value\":{}}\n{\"ack\":"));
    try std.testing.expect(framer.feed(&queues, "9,\"ok\":true}\n"));
    var output: [frame_line_capacity]u8 = undefined;
    try std.testing.expectEqualStrings("{\"provider\":\"media\",\"value\":{}}", queues.takeFrame(&output).?);
    try std.testing.expectEqualDeep(Ack{ .id = 9, .ok = true }, queues.takeAck().?);
    try std.testing.expect(framer.feed(&queues, "{\"ack\":10"));
    framer.finish(&queues);
    try std.testing.expectEqual(@as(u8, 1), queues.ack_protocol_failed.load(.acquire));
}
