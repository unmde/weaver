//! How the daemon host's management thread (daemon.zig) has the UI thread
//! load or unload a widget (ADR 0022 step 4). The management thread reads
//! the registry, prepares each widget off the UI thread, then posts one
//! command and waits for the UI thread to apply it between widget turns
//! (main.zig `applyControl`):
//!
//!     add    { id, dir, backend }   load the bundle in `dir` into slot `id`
//!     remove { id }                 unload the widget in slot `id`
//!
//! An `add` id is the widget's slot in the host: it runs in that slot, and
//! the crash record names it as `id + 1`.
const std = @import("std");

pub const Add = struct {
    id: u16,
    /// Its bundle directory (`dist`).
    dir: []const u8,
    /// Where it reports its renderer, or why it did not load.
    backend: ?[]const u8 = null,
};

pub const Command = union(enum) {
    add: Add,
    remove: struct { id: u16 },
};

/// One command handed to the UI thread, and its outcome handed back.
pub const Pending = struct {
    command: Command,
    /// Set by the UI thread: null when it took effect, else why not.
    failure: ?anyerror = null,
    done: std.Io.Event = .unset,
};

/// The command waiting for the UI thread. The management thread posts one
/// and waits for it to be done, so there is never more than one.
pub const Mailbox = struct {
    pending: std.atomic.Value(?*Pending) = .init(null),

    pub fn post(self: *Mailbox, pending: *Pending) void {
        const previous = self.pending.swap(pending, .acq_rel);
        std.debug.assert(previous == null);
    }

    pub fn take(self: *Mailbox) ?*Pending {
        return self.pending.swap(null, .acq_rel);
    }

    pub fn waiting(self: *Mailbox) bool {
        return self.pending.load(.acquire) != null;
    }
};

/// Splits a byte stream into lines no longer than its buffer (a dev
/// widget's provider pipe, dev_widgets.zig).
pub const LineReader = struct {
    buffer: []u8,
    start: usize = 0,
    end: usize = 0,

    /// The next complete line, without its newline; null when the buffered
    /// bytes hold none yet.
    pub fn next(self: *LineReader) ?[]const u8 {
        const newline = std.mem.indexOfScalar(u8, self.buffer[self.start..self.end], '\n') orelse return null;
        const line = self.buffer[self.start .. self.start + newline];
        self.start += newline + 1;
        return std.mem.trimEnd(u8, line, "\r");
    }

    /// Room to read into, after moving unread bytes to the front; empty when
    /// a line has outgrown the buffer.
    pub fn space(self: *LineReader) []u8 {
        if (self.start > 0) {
            std.mem.copyForwards(u8, self.buffer[0 .. self.end - self.start], self.buffer[self.start..self.end]);
            self.end -= self.start;
            self.start = 0;
        }
        return self.buffer[self.end..];
    }

    pub fn filled(self: *LineReader, count: usize) void {
        self.end += count;
    }
};

test "the mailbox holds one command until it is taken" {
    var mailbox: Mailbox = .{};
    try std.testing.expect(!mailbox.waiting());
    var pending: Pending = .{ .command = .{ .remove = .{ .id = 1 } } };
    mailbox.post(&pending);
    try std.testing.expect(mailbox.waiting());
    try std.testing.expectEqual(&pending, mailbox.take().?);
    try std.testing.expect(mailbox.take() == null);
}

test "lines split across reads come out whole" {
    var storage: [64]u8 = undefined;
    var reader: LineReader = .{ .buffer = &storage };
    const parts = [_][]const u8{ "{\"a\":1}\n{\"b\"", ":2}\r\n" };
    const expected = [_][]const u8{ "{\"a\":1}", "{\"b\":2}" };
    var count: usize = 0;
    for (parts) |part| {
        const room = reader.space();
        @memcpy(room[0..part.len], part);
        reader.filled(part.len);
        // A line is valid until the next `space`.
        while (reader.next()) |line| : (count += 1) try std.testing.expectEqualStrings(expected[count], line);
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}
