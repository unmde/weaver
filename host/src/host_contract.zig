//! What the Windows widget host and the CLI's client agree on (ADR 0022):
//! the named objects the CLI reaches the host through, the lifecycle lock
//! and stop marker that order starting and stopping it, the host's exit
//! codes, how Windows restarts it, and the layout of its record. Both sides
//! live in `weaver-widget.exe`: the host (`--host`, runtime/src/daemon.zig)
//! and the client verbs the CLI spawns it with (`--up`, `--down`,
//! `--status`, `--reload`, `--probe`; runtime/src/host_lifecycle.zig). The
//! runtime compiles this file as its `host_contract` module
//! (runtime/build.zig). macOS keeps its own `weaverd` and does not use it.
const std = @import("std");

const L = std.unicode.utf8ToUtf16LeStringLiteral;

/// Owned by the running host for its whole life: a second host that cannot
/// take it exits. Nothing else keeps a handle to it while no host runs, so
/// it exists exactly while a host does (`--probe`).
pub const singleton_mutex = L("Local\\WeaverHostSingletonV2");
/// Manual reset: `weaver down` sets it, and the host stops.
pub const shutdown_event = L("Local\\WeaverHostShutdownV2");
/// Auto reset: the registry changed; the host reconciles and answers on
/// one of the two events below.
pub const reload_event = L("Local\\WeaverHostReloadV2");
/// Serializes CLI processes that signal a reload (`--reload`).
pub const reload_signal_mutex = L("Local\\WeaverHostReloadSignalV2");
/// Manual reset: the reload took effect, and any widget it removed is gone
/// from the host, so the CLI may delete superseded install directories.
pub const reload_success_event = L("Local\\WeaverHostReloadSuccessV2");
/// Manual reset: the registry could not be read; nothing changed. Its
/// existence is also how the CLI tells the host can acknowledge reloads.
pub const reload_failure_event = L("Local\\WeaverHostReloadFailureV2");
/// Auto reset: the CLI wants status.json current (`--status`). The host
/// samples costs, writes it, and sets the manual-reset event below. The
/// host also writes it whenever something changes, and otherwise not at
/// all.
pub const status_request_event = L("Local\\WeaverHostStatusRequestV2");
pub const status_written_event = L("Local\\WeaverHostStatusWrittenV2");

/// Orders everything that starts or stops the host (ADR 0022, "Stopping
/// and the cap"): `--down` holds it while it writes the stop marker,
/// signals the host and waits for it to exit; `--up` while it clears the
/// marker and starts a host; a starting host, including one Windows
/// restarted, while it reads the marker and its record and publishes
/// control. So a pending restart cannot bring widgets back after `weaver
/// down`, and `weaver up` cannot race a host on its way out.
pub const lifecycle_mutex = L("Local\\WeaverHostLifecycle");
/// `%LOCALAPPDATA%\weaver\host.stop`: `weaver down` writes it and `weaver
/// up` deletes it. A starting host that finds it exits before publishing
/// control.
pub const stop_marker_name = "host.stop";

/// Exit and crash codes the host itself sets, in the customer range of
/// NTSTATUS so none collides with a real exception code, a Zig abort (3)
/// or a C exit.
///
/// A Zig panic, as the crash record names it (crash_record.notePanic), and
/// the code the host fails fast with after one.
pub const panic_code: u32 = 0xE057_0001;
/// The host exited because another host already owns the singleton.
pub const exit_already_running: u32 = 0xE057_0002;
/// The host's UI thread did not apply a widget's load or unload within the
/// management thread's deadline, and the host failed fast with this code,
/// so Windows restarts it. The record names the widget whose turn held the
/// UI thread, if one did.
pub const exit_wedged: u32 = 0xE057_0003;
/// The host found the stop marker as it started (`weaver down` ran since
/// whoever started it decided to), and exited before publishing control.
pub const exit_stopped: u32 = 0xE057_0004;
/// A host Windows restarted found that a newer host started since the
/// crash it was restarted for, and exited before publishing control.
pub const exit_superseded: u32 = 0xE057_0005;
/// The host could not take the lifecycle lock within `host_lock_wait_ms`.
pub const exit_lifecycle_busy: u32 = 0xE057_0006;
/// `weaver down` stopped a host that did not exit by itself in time
/// (host_lifecycle.down_grace_ms).
pub const exit_stopped_by_down: u32 = 0xE057_0007;
/// The host could not open its record within `record_open_wait_ms`, and
/// exited before loading any widget: without the record it could neither
/// quarantine the widget the last crash blames nor record its own.
pub const exit_record_unavailable: u32 = 0xE057_0008;

/// How long a starting host waits for the lifecycle lock. The longest
/// holder is `weaver down`, which waits `down_grace_ms` (4 s) for the host
/// to exit and up to 1 s more after it stops it; 30 s is 6x that.
pub const host_lock_wait_ms: u32 = 30_000;

/// How long a host Windows restarted waits for the crashed host to be gone.
/// Windows can start the restart before the crashed process has exited
/// (receipt, 2026-10-17, weaver-step5-scratch/gt-ui: 0.24 s before), and
/// until then that process owns the singleton. 30 s leaves room for a slow
/// crash report.
pub const predecessor_wait_ms: u32 = 30_000;
/// How long any starting host retries opening its record while it is in
/// use. It stays in use for a moment after a crashed host has exited:
/// 203-250 ms in seven restarts (2026-10-17, weaver-step5-scratch/gt-*).
/// 2 s is 8x that, and well inside the 5 s `weaver up` waits for a host. A
/// host that still cannot open it exits (`exit_record_unavailable`), and
/// `weaver up` and `weaver status` name the file.
pub const record_open_wait_ms: u32 = 2_000;

/// The arguments Windows restarts a crashed host with, after the
/// executable's own path: `--host --restart-of <generation> --localappdata
/// "<path>"`. Windows restarts a process with the user's default
/// environment, not the crashed process's (receipt, 2026-10-17,
/// weaver-step5-scratch/envspike: a process started with LOCALAPPDATA and a
/// marker variable set came back with the user's LOCALAPPDATA and no
/// marker; working directory and the registered arguments came back
/// unchanged). So the profile the host ran against rides the command line,
/// or a host started against a scratch profile would come back on the
/// user's own. The generation is the crashed host's: a restarted host whose
/// record holds another one exits (`exit_superseded`).
pub const restart_of_flag = "--restart-of";
pub const local_app_data_flag = "--localappdata";
/// RegisterApplicationRestart flags: restart after a crash only. Not after
/// a hang (the host's own apply deadline handles a stuck UI thread), and not
/// after an update or a reboot, which would be a login start Weaver does not
/// have (ADR 0022, "What this gives up").
pub const restart_flags: u32 = 0x2 | 0x4 | 0x8; // RESTART_NO_HANG | RESTART_NO_PATCH | RESTART_NO_REBOOT
/// RegisterApplicationRestart's limit on its command line, in UTF-16 units
/// with the terminator (RESTART_MAX_CMD_LINE, winbase.h).
pub const restart_max_command_line: usize = 1024;
/// Windows restarts only a process that ran this long before it crashed
/// (RegisterApplicationRestart's documentation; spike receipt, 2026-10-16,
/// rm-bench/restart-spike: a crash 10 s after start was not restarted within
/// 120 s, crashes after 62-70 s were). A host that crashes sooner stays down
/// until `weaver up`.
pub const os_restart_min_run_ms: u64 = 60_000;
/// The slowest restart measured: Windows restarted crashed processes 5-37 s
/// after the crash (spike, 2026-10-16, rm-bench/restart-spike).
pub const os_restart_measured_max_ms: u64 = 37_000;
/// How long after a crash `weaver status` keeps saying a restart is on its
/// way: about 3x the slowest measured.
pub const os_restart_wait_ms: u64 = 120_000;

/// The restart cap (ADR 0022, Dara's policy): a host Windows restarted that
/// finds `restart_cap - 1` other automatic restarts within
/// `restart_window_ms` does not ask to be restarted again. So Windows
/// restarts the host at most three times in ten minutes; after the fourth
/// crash it stays down, and `weaver up` starts a fresh count.
pub const restart_cap: usize = 3;
pub const restart_window_ms: u64 = 10 * 60 * 1000;

pub const record_magic: u32 = 0x5248_5657; // "WVHR"
pub const record_version: u32 = 3;

pub const RecordState = enum(u32) { none = 0, running = 1, stopped = 2, _ };

pub const CrashKind = enum(u32) {
    none = 0,
    /// The thread was running a widget's turn: `Crash.slot` names it.
    widget_turn = 1,
    /// The UI thread, outside any widget's turn.
    ui = 2,
    /// Any other thread outside a widget's turn: a provider's worker, the
    /// management thread.
    other = 3,
    _,
};

/// Whether this host asked Windows to restart it after a crash.
pub const RestartRequest = enum(u32) {
    /// Not a daemon host, or it has not got that far.
    none = 0,
    registered = 1,
    /// A restart it would have asked for passes the cap (`restart_cap`).
    capped = 2,
    /// RegisterApplicationRestart refused: `Record.restart_error` says why.
    failed = 3,
    _,
};

/// The widget whose turn is running, and on which thread.
pub const Turn = extern struct {
    /// Its slot in the host plus one; zero between turns.
    slot: u32 = 0,
    thread: u32 = 0,
    /// Wyhash of its bundle.js, as loaded.
    bundle: u64 = 0,
};

pub const Crash = extern struct {
    kind: CrashKind = .none,
    /// The exception code, or the runtime's panic code.
    code: u32 = 0,
    thread: u32 = 0,
    /// For `widget_turn`: the widget's slot plus one and its bundle.
    slot: u32 = 0,
    bundle: u64 = 0,
    /// When it happened, as a Windows FILETIME.
    time: u64 = 0,
};

/// Which widget a host slot holds, written when the host adds it: the next
/// host turns a crash's slot into a widget to quarantine with this.
pub const SlotIdentity = extern struct {
    /// Wyhash (seed 0) of its registered name, with the low bit set; zero
    /// for an empty slot.
    name_hash: u64 = 0,
    /// Its bundle.js modification time when it was added, in nanoseconds
    /// since the Unix epoch: the bundle the quarantine holds.
    artifact: i64 = 0,
};

/// The name identity a host slot records (`SlotIdentity.name_hash`), and
/// what `weaver status` matches a crash's slot against. Never zero, which
/// marks an empty slot.
pub fn nameHash(name: []const u8) u64 {
    return std.hash.Wyhash.hash(0, name) | 1;
}

/// Host slots the record names: the runtime's `max_host_widgets`, which
/// pins it (runtime/src/main.zig).
pub const record_slots: usize = 32;
/// A startup error's name, as `@errorName` gives it. The longest error name
/// in the runtime, Native and host sources is 40 bytes
/// (CaptureProviderFixtureCapabilityRequired, 2026-10-17); 48 holds it, and
/// a longer one is cut, not lost.
pub const stop_reason_bytes: usize = 48;

/// `%LOCALAPPDATA%\weaver\host.record`, which the host keeps mapped
/// (runtime/src/crash_record.zig), the next host reads to quarantine a
/// widget, and `weaver status` reads (through `--status`) while no host
/// runs.
pub const Record = extern struct {
    magic: u32,
    version: u32,
    /// One more than the previous host's: tells a reader which start a
    /// record belongs to.
    generation: u64,
    pid: u32,
    state: RecordState,
    /// Process creation time (FILETIME): with `pid`, tells this process
    /// from a later one that reused its PID.
    start_time: u64,
    turn: Turn,
    crash: Crash,
    slots: [record_slots]SlotIdentity,
    /// The automatic restarts that count toward the cap, as FILETIMEs of
    /// their starts, oldest first; this start's own when Windows restarted
    /// it. `weaver up` starts with none.
    restarts: [restart_cap]u64,
    restart_count: u32,
    restart: RestartRequest,
    /// For `restart == .failed`: RegisterApplicationRestart's HRESULT.
    restart_error: u32,
    /// The restart command line's length in UTF-16 units, without the
    /// terminator, against `restart_max_command_line`.
    restart_line_len: u32,
    stop_reason_len: u32,
    /// Why a host that returned an error from main stopped.
    stop_reason: [stop_reason_bytes]u8,
};

comptime {
    // The first 80 bytes kept their version-1 layout, and the slots their
    // version-2 place.
    std.debug.assert(@offsetOf(Record, "slots") == 80);
    std.debug.assert(@offsetOf(Record, "restarts") == 80 + record_slots * 16);
    // Five u32s after the restarts, then the reason, padded to 8 bytes.
    std.debug.assert(@sizeOf(Record) == std.mem.alignForward(usize, 80 + record_slots * 16 + restart_cap * 8 + 20 + stop_reason_bytes, 8));
}

/// The record in `bytes`, if it is one this version wrote.
pub fn parseRecord(bytes: []const u8) ?Record {
    if (bytes.len != @sizeOf(Record)) return null;
    const record = std.mem.bytesToValue(Record, bytes[0..@sizeOf(Record)]);
    if (record.magic != record_magic or record.version != record_version) return null;
    return record;
}

/// The automatic restarts a host counts toward the cap, and whether it may
/// ask Windows for another: a host started by `weaver up` (`restart_of ==
/// null`) counts none and may; one Windows restarted keeps the previous
/// host's restarts that fall within `restart_window_ms` of `now`, adds its
/// own, and may ask again only while fewer than `restart_cap` are counted.
pub const RestartPlan = struct {
    restarts: [restart_cap]u64 = @splat(0),
    count: u32 = 0,
    register: bool = true,

    /// `now` and the stored times are FILETIMEs (100 ns units).
    pub fn of(previous: ?Record, restarted: bool, now: u64) RestartPlan {
        var plan: RestartPlan = .{};
        if (!restarted) return plan;
        const window = restart_window_ms * 10_000;
        if (previous) |record| {
            const kept = @min(record.restart_count, restart_cap);
            for (record.restarts[0..kept]) |time| {
                if (now -| time >= window) continue;
                // Room for this start's own: the oldest one goes.
                if (plan.count == restart_cap - 1) {
                    std.mem.copyForwards(u64, plan.restarts[0 .. restart_cap - 2], plan.restarts[1 .. restart_cap - 1]);
                    plan.count -= 1;
                }
                plan.restarts[plan.count] = time;
                plan.count += 1;
            }
        }
        plan.restarts[plan.count] = now;
        plan.count += 1;
        plan.register = plan.count < restart_cap;
        return plan;
    }
};

test "the record reads back only at this version and size" {
    var record = std.mem.zeroes(Record);
    record.magic = record_magic;
    record.version = record_version;
    record.pid = 7;
    record.crash.kind = .widget_turn;
    try std.testing.expectEqual(@as(u32, 7), parseRecord(std.mem.asBytes(&record)).?.pid);
    try std.testing.expect(parseRecord(std.mem.asBytes(&record)[0..80]) == null);
    record.version = 2;
    try std.testing.expect(parseRecord(std.mem.asBytes(&record)) == null);
}

test "Windows restarts the host three times in ten minutes, then not again" {
    const minute: u64 = 60 * 10_000_000;
    // `weaver up`: nothing counted, and it asks.
    var plan = RestartPlan.of(null, false, 100 * minute);
    try std.testing.expectEqual(@as(u32, 0), plan.count);
    try std.testing.expect(plan.register);
    var record = std.mem.zeroes(Record);
    var now: u64 = 100 * minute;
    for (1..restart_cap + 1) |restart| {
        now += minute;
        plan = RestartPlan.of(record, true, now);
        try std.testing.expectEqual(@as(u32, @intCast(@min(restart, restart_cap))), plan.count);
        // The first two restarts ask again; the third finds two others in
        // the window, so a fourth crash stays down.
        try std.testing.expectEqual(restart < restart_cap, plan.register);
        record.restarts = plan.restarts;
        record.restart_count = plan.count;
    }
    // Restarts older than the window are forgotten.
    plan = RestartPlan.of(record, true, now + restart_window_ms * 10_000);
    try std.testing.expectEqual(@as(u32, 1), plan.count);
    try std.testing.expect(plan.register);
    // `weaver up` starts a fresh count, whatever the record held.
    plan = RestartPlan.of(record, false, now);
    try std.testing.expectEqual(@as(u32, 0), plan.count);
    try std.testing.expect(plan.register);
}
