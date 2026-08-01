const std = @import("std");

// Media-wire text fields are fixed protocol bounds mirrored by host/src/
// media.zig. Shipped widget text peaks at 122 UTF-8 bytes; 512 per metadata
// field leaves >4x that measured good text shape (at least 128 four-byte
// codepoints). The queue reserves the derived worst-case frames below and
// touches pages only as publications arrive.
pub const max_text_bytes: usize = 512;
// Source-app identity is protocol metadata, not an authored tree budget.
// 256 bytes is half the metadata-field bound and far beyond shipped labels;
// it contributes only to the fixed derived frame storage below.
pub const max_source_app_bytes: usize = 256;
// Host art paths obey the ordinary Windows MAX_PATH wire shape: 259 payload
// bytes plus the host's terminating NUL. This is an OS/protocol invariant,
// not an image or asset budget. It must match host/src/media.zig.
pub const max_art_path_bytes: usize = 259;
// JSON's longest single-byte escape spelling is six bytes (`\u00XX`). This is
// a grammar invariant, not a budget.
pub const max_json_escape_bytes: usize = 6;

const max_media_frame_fixed =
    "{\"provider\":\"media\",\"value\":{\"title\":\"\",\"artist\":\"\",\"album\":\"\",\"playing\":false,\"status\":\"stopped\",\"sourceApp\":\"\",\"artPath\":\"\",\"positionMs\":18446744073709551615,\"durationMs\":18446744073709551615}}\n";

/// Must match host/src/media.zig. It is the complete newline-terminated v2
/// media-frame bound, including the optional artPath field. The 12,502-byte
/// result is derived from every field at its protocol maximum; no separate
/// headroom is needed because this is wire framing rather than authored data.
pub const max_media_frame_bytes: usize = max_media_frame_fixed.len +
    max_json_escape_bytes * (3 * max_text_bytes + max_source_app_bytes + max_art_path_bytes);

test "runtime media line bound matches the frozen worst-case formula" {
    try std.testing.expectEqual(@as(usize, 12_502), max_media_frame_bytes);
    try std.testing.expect(max_media_frame_bytes > 8192);
}
