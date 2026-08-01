const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");

const windows_monitor = if (builtin.os.tag == .windows) @import("platform/windows_monitor.zig") else struct {};

// Manifest receipt (2026-07-29): the largest shipped widget.json is 570
// bytes (noro-shell). 64 KiB leaves >100x format-growth headroom. Reads
// allocate actual file length; unused allowance costs no resident memory.
pub const max_manifest_bytes: usize = 64 * 1024;
// Bundle receipt: the largest shipped bundle.js is 45,818 bytes (noro-shell).
// 1 MiB leaves >22x headroom. Initial and hot-reload reads allocate actual
// length; unused allowance costs no memory. Pinned by main.zig hot reload.
pub const max_bundle_bytes: usize = 1024 * 1024;

pub const MonitorGeometry = struct {
    work_area_px: native_sdk.geometry.RectI,
    effective_dpi: u32,

    pub fn scale(self: MonitorGeometry) f32 {
        return @as(f32, @floatFromInt(self.effective_dpi)) / 96.0;
    }
};

pub const Anchor = struct {
    monitor: []const u8 = "primary",
    corner: []const u8,
    offset: [2]f32 = .{ 24, 24 },
};

pub const FontWeight = enum { light, regular, medium, semibold, bold };

pub const Font = struct {
    id: u64,
    name: []const u8,
    stem: []const u8,
    family: []const u8,
    weight: FontWeight,
    file: []const u8,
};

pub const Manifest = struct {
    name: []const u8,
    size: [2]f32,
    anchor: ?Anchor = null,
    layer: []const u8 = "desktop",
    clickThrough: bool = false,
    transparent: bool = true,
    origins: []const []const u8 = &.{},
    subscribe: []const []const u8 = &.{},
    capabilities: []const []const u8 = &.{},
    renderBackend: []const u8 = "software",
    fonts: []const Font = &.{},
};

pub const Loaded = struct {
    manifest: Manifest,
    bundle: []const u8,
};

fn resolvedAnchor(value: Manifest) Anchor {
    return value.anchor orelse .{
        .monitor = "primary",
        .corner = "top-right",
        .offset = .{ 24, 24 },
    };
}

/// Load the two-file widget contract into the process-lifetime arena. M0 is
/// intentionally strict: unknown JSON fields and unsupported placement fail
/// at launch instead of quietly changing the desktop behavior.
pub fn load(io: std.Io, allocator: std.mem.Allocator, directory: []const u8) !Loaded {
    const manifest_path = try std.fs.path.join(allocator, &.{ directory, "widget.json" });
    const bundle_path = try std.fs.path.join(allocator, &.{ directory, "bundle.js" });
    const manifest_bytes = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(max_manifest_bytes));
    const bundle = try std.Io.Dir.cwd().readFileAlloc(io, bundle_path, allocator, .limited(max_bundle_bytes));
    const parsed = try std.json.parseFromSliceLeaky(Manifest, allocator, manifest_bytes, .{ .ignore_unknown_fields = false });
    if (!std.math.isFinite(parsed.size[0]) or !std.math.isFinite(parsed.size[1]) or
        parsed.size[0] <= 0 or parsed.size[1] <= 0) return error.InvalidWidgetSize;
    if (parsed.anchor) |anchor| {
        if (!std.mem.eql(u8, anchor.monitor, "primary")) return error.UnsupportedMonitor;
        if (!std.mem.eql(u8, anchor.corner, "top-left") and !std.mem.eql(u8, anchor.corner, "top-right") and !std.mem.eql(u8, anchor.corner, "bottom-left") and !std.mem.eql(u8, anchor.corner, "bottom-right")) return error.UnsupportedAnchor;
        if (!std.math.isFinite(anchor.offset[0]) or !std.math.isFinite(anchor.offset[1]) or
            anchor.offset[0] < 0 or anchor.offset[1] < 0) return error.InvalidAnchorOffset;
    }
    if (!std.mem.eql(u8, parsed.layer, "desktop") and !std.mem.eql(u8, parsed.layer, "normal") and !std.mem.eql(u8, parsed.layer, "topmost")) return error.UnsupportedLayer;
    if (!parsed.transparent) return error.UnsupportedOpaqueWidget;
    if (!std.mem.eql(u8, parsed.renderBackend, "gpu") and !std.mem.eql(u8, parsed.renderBackend, "software")) return error.InvalidRenderBackend;
    for (parsed.origins) |origin| {
        if (origin.len == 0 or std.mem.indexOf(u8, origin, "://") != null or std.mem.indexOfAny(u8, origin, "/?#@") != null) return error.InvalidOrigin;
    }
    for (parsed.subscribe) |provider| {
        if (!std.mem.eql(u8, provider, "time") and !std.mem.eql(u8, provider, "cpu") and !std.mem.eql(u8, provider, "memory") and !std.mem.eql(u8, provider, "audio") and !std.mem.eql(u8, provider, "media")) return error.InvalidProvider;
    }
    for (parsed.capabilities) |capability| {
        if (!std.mem.eql(u8, capability, "media-transport")) return error.InvalidCapability;
    }
    if (parsed.fonts.len > native_sdk.runtime.max_registered_canvas_fonts) return error.TooManyFonts;
    for (parsed.fonts) |font| {
        if (font.id < native_sdk.canvas.min_registered_font_id or font.name.len == 0 or font.stem.len == 0 or font.family.len == 0 or !isLocalFontFile(font.file)) return error.InvalidFont;
    }
    return .{ .manifest = parsed, .bundle = bundle };
}

fn isLocalFontFile(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfAny(u8, path, "/\\") != null) return false;
    if (path.len < 4) return false;
    const extension = path[path.len - 4 ..];
    return std.ascii.eqlIgnoreCase(extension, ".ttf") or std.ascii.eqlIgnoreCase(extension, ".otf");
}

fn roundPhysicalEdge(logical_edge: f32, scale: f32) i32 {
    return @intFromFloat(@round(logical_edge * scale));
}

/// Resolve a widget anchor against one monitor. Work-area edges are physical
/// virtual-desktop pixels; widget extents and offsets are DIPs. The monitor's
/// physical origin is never scaled, so negative-coordinate monitors remain
/// truthful and taskbar exclusions stay exactly those reported by Win32.
pub fn anchoredPhysicalFrame(value: Manifest, monitor: MonitorGeometry) native_sdk.geometry.RectI {
    const work_area = monitor.work_area_px;
    const scale = monitor.scale();
    const anchor = resolvedAnchor(value);
    const on_right = std.mem.endsWith(u8, anchor.corner, "right");
    const on_bottom = std.mem.startsWith(u8, anchor.corner, "bottom");
    const width_px = roundPhysicalEdge(value.size[0], scale);
    const height_px = roundPhysicalEdge(value.size[1], scale);
    const offset_x_px = roundPhysicalEdge(anchor.offset[0], scale);
    const offset_y_px = roundPhysicalEdge(anchor.offset[1], scale);
    const x = if (on_right)
        work_area.x + work_area.width - width_px - offset_x_px
    else
        work_area.x + offset_x_px;
    const y = if (on_bottom)
        work_area.y + work_area.height - height_px - offset_y_px
    else
        work_area.y + offset_y_px;
    return native_sdk.geometry.RectI.init(x, y, width_px, height_px);
}

fn primaryMonitorGeometry() MonitorGeometry {
    const native = windows_monitor.primary() orelse {
        return .{
            .work_area_px = native_sdk.geometry.RectI.init(0, 0, 1920, 1080),
            .effective_dpi = 96,
        };
    };
    return .{
        .work_area_px = native_sdk.geometry.RectI.init(
            native.work_left_px,
            native.work_top_px,
            native.work_right_px - native.work_left_px,
            native.work_bottom_px - native.work_top_px,
        ),
        .effective_dpi = native.effective_dpi,
    };
}

/// Native SDK top-level frames are DIPs. Convert the already-resolved
/// physical anchor position back once at the target monitor's scale; the
/// Native SDK converts it to physical pixels once during HWND creation.
pub fn desktopFrame(value: Manifest) native_sdk.geometry.RectF {
    if (builtin.os.tag == .macos) {
        // AppKit resolves `primaryDisplayAnchor` against the live primary
        // visible frame. This frame contributes size only; keeping the
        // placeholder origin out of the placement math prevents a second
        // platform coordinate conversion from appearing here.
        return native_sdk.geometry.RectF.init(0, 0, value.size[0], value.size[1]);
    }
    const monitor = primaryMonitorGeometry();
    const physical = anchoredPhysicalFrame(value, monitor);
    const scale = monitor.scale();
    return native_sdk.geometry.RectF.init(
        @as(f32, @floatFromInt(physical.x)) / scale,
        @as(f32, @floatFromInt(physical.y)) / scale,
        value.size[0],
        value.size[1],
    );
}

pub fn primaryDisplayAnchor(value: Manifest) native_sdk.PrimaryDisplayAnchor {
    const anchor = resolvedAnchor(value);
    const corner: native_sdk.PrimaryDisplayAnchorCorner = if (std.mem.eql(u8, anchor.corner, "top-left"))
        .top_left
    else if (std.mem.eql(u8, anchor.corner, "top-right"))
        .top_right
    else if (std.mem.eql(u8, anchor.corner, "bottom-left"))
        .bottom_left
    else
        .bottom_right;
    return .{
        .corner = corner,
        .offset = native_sdk.geometry.PointF.init(anchor.offset[0], anchor.offset[1]),
    };
}

test "clock manifest shape parses" {
    const source =
        \\{"name":"Clock","size":[240,110],"anchor":{"corner":"top-right","offset":[24,24]},"layer":"desktop","transparent":true}
    ;
    const parsed = try std.json.parseFromSlice(Manifest, std.testing.allocator, source, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(f32, 240), parsed.value.size[0]);
}

test "media transport is the only runtime capability" {
    const accepted =
        \\{"name":"Transport","size":[240,110],"capabilities":["media-transport"]}
    ;
    const parsed = try std.json.parseFromSlice(Manifest, std.testing.allocator, accepted, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("media-transport", parsed.value.capabilities[0]);
}

test "font manifest paths stay root-adjacent and use supported extensions" {
    try std.testing.expect(isLocalFontFile("Cozette.ttf"));
    try std.testing.expect(isLocalFontFile("Pixel.otf"));
    try std.testing.expect(isLocalFontFile("Display.TTF"));
    try std.testing.expect(isLocalFontFile("Display.OTF"));
    try std.testing.expect(!isLocalFontFile("fonts/Cozette.ttf"));
    try std.testing.expect(!isLocalFontFile("..\\Cozette.ttf"));
    try std.testing.expect(!isLocalFontFile("Cozette.woff2"));
}

test "anchors use target monitor DPI and preserve negative work-area coordinates" {
    const monitor = MonitorGeometry{
        .work_area_px = native_sdk.geometry.RectI.init(-1920, -120, 1920, 1080),
        .effective_dpi = 120,
    };
    const corners = [_]struct { name: []const u8, expected: native_sdk.geometry.RectI }{
        .{ .name = "top-left", .expected = native_sdk.geometry.RectI.init(-1890, -90, 300, 138) },
        .{ .name = "top-right", .expected = native_sdk.geometry.RectI.init(-330, -90, 300, 138) },
        .{ .name = "bottom-left", .expected = native_sdk.geometry.RectI.init(-1890, 792, 300, 138) },
        .{ .name = "bottom-right", .expected = native_sdk.geometry.RectI.init(-330, 792, 300, 138) },
    };
    for (corners) |corner| {
        const manifest = Manifest{
            .name = "dpi",
            .size = .{ 240, 110 },
            .anchor = .{ .corner = corner.name, .offset = .{ 24, 24 } },
        };
        try std.testing.expectEqualDeep(corner.expected, anchoredPhysicalFrame(manifest, monitor));
    }
}

test "anchor physical extents follow the five supported scale factors" {
    for ([_]u32{ 96, 120, 144, 168, 192 }) |dpi| {
        const manifest = Manifest{
            .name = "dpi",
            .size = .{ 241.25, 109.5 },
            .anchor = .{ .corner = "bottom-right", .offset = .{ 13.5, 7.25 } },
        };
        const monitor = MonitorGeometry{
            .work_area_px = native_sdk.geometry.RectI.init(0, 0, 2560, 1400),
            .effective_dpi = dpi,
        };
        const frame = anchoredPhysicalFrame(manifest, monitor);
        const scale = monitor.scale();
        try std.testing.expectEqual(roundPhysicalEdge(manifest.size[0], scale), frame.width);
        try std.testing.expectEqual(roundPhysicalEdge(manifest.size[1], scale), frame.height);
        try std.testing.expectEqual(2560 - roundPhysicalEdge(manifest.anchor.?.offset[0], scale), frame.x + frame.width);
        try std.testing.expectEqual(1400 - roundPhysicalEdge(manifest.anchor.?.offset[1], scale), frame.y + frame.height);
    }
}

test "manifest anchors map to the primary-display logical contract" {
    const manifest = Manifest{
        .name = "logical",
        .size = .{ 240, 110 },
        .anchor = .{ .corner = "bottom-left", .offset = .{ 13, 17 } },
    };
    const anchor = primaryDisplayAnchor(manifest);
    try std.testing.expectEqual(native_sdk.PrimaryDisplayAnchorCorner.bottom_left, anchor.corner);
    try std.testing.expectEqualDeep(native_sdk.geometry.PointF.init(13, 17), anchor.offset);
    const default_anchor = primaryDisplayAnchor(.{ .name = "default", .size = .{ 240, 110 } });
    try std.testing.expectEqual(native_sdk.PrimaryDisplayAnchorCorner.top_right, default_anchor.corner);
    try std.testing.expectEqualDeep(native_sdk.geometry.PointF.init(24, 24), default_anchor.offset);
}
