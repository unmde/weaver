const std = @import("std");
const native_sdk = @import("native_sdk");

// Retained-tree receipt (2026-07-30): executing every shipped TSX example
// measured 54 lowered nodes at worst (noro-shell). The Native SDK's realistic
// three-pane view measures about 500 nodes, so 1024 is the shared ~2x
// worst-good tripwire. @sizeOf(Node) is 1,928 bytes: one Tree reserves
// 1,974,272 bytes for slots, and the reusable transaction snapshot reserves a
// second arena (3,948,544 bytes total address space after first render).
// Slots/large fields are undefined until occupied and snapshots copy occupied
// slots only, so ~900 unused slots are neither zeroed nor copied; OS pages are
// touched as IDs become live. The Model's node-indexed slider mirror adds one
// eager 4 KiB array. Pinned by cli/src/index.ts nativeWidgetNodeLimit.
pub const max_nodes: usize = 1024;
// The examples measured 24 direct children (noro-shell and now-playing).
// 64 leaves 2.7x headroom for ordinary lists. The child array contributes 256
// bytes to each occupied 1,928-byte Node; unoccupied slots stay untouched.
// Pinned by cli/src/index.ts nativeWidgetChildLimit.
pub const max_children: usize = 64;
// The longest shipped text node is 122 UTF-8 bytes; provider metadata may be
// 512 bytes per field. 1024 is 2x that protocol-sized good case. Text storage
// contributes 1 KiB to each occupied Node; unoccupied slots stay untouched.
// Pinned by cli/src/index.ts nativeWidgetTextByteLimit.
pub const max_text_bytes: usize = 1024;
// Image-source receipt (2026-07-30): shipped relative asset paths peak at 24
// UTF-8 bytes and the provider wire admits 259-byte art paths. 1024 leaves
// almost 4x headroom over that cross-process good case. Sources allocate their
// exact length; even if all 1024 nodes were abused as images, retained source
// storage is bounded to 1 MiB plus 1 MiB in an in-flight transaction snapshot.
// Pinned by cli/src/index.ts nativeWidgetSourceByteLimit; release-audit.mjs
// enforces equality across the language boundary.
pub const max_source_bytes: usize = 1024;
// Lucide 1.26.0 measures 2,099 UTF-8 bytes for its largest normalized path
// ("puzzle"); shipped widgets measure 1,037 bytes. 8 KiB leaves 3.9x headroom.
// Paths allocate their exact length, so the unused allowance costs no memory.
// Pinned by cli/src/icon-paths.ts MAX_ICON_PATH_BYTES.
pub const max_icon_path_bytes: usize = 8 * 1024;
// Font discovery accepts 1..63-byte file stems and the longest shipped family
// is 17 bytes. This is a cross-boundary format bound (not an OS path limit);
// the inline bytes live only in lazily occupied Nodes. Pinned by
// cli/src/index.ts MAX_WIDGET_FONT_FAMILY_BYTES.
pub const max_font_family_bytes: usize = 63;
// The shipped examples use one canvas per view. Eight permits a dense good
// dashboard with four independently refreshed plots and leaves 2x headroom.
// Each CanvasState is 294,960 bytes (~2.25 MiB reserved across eight), but its
// command/point arrays stay undefined and pages are touched only as canvases
// draw. Pinned by cli/src/index.ts nativeWidgetCanvasLimit.
pub const max_canvases: usize = 8;
// Authored-canvas batch budgets, sized to the Native SDK's per-view
// display-list budget (`canvas_limits.max_canvas_commands_per_view` = 2048)
// so a single canvas can use the whole frame budget: a real meter widget
// needed 336 rects and hit the old 256/4096 caps in normal use. Wire values
// budget ~16 per command (a rect is opcode + packed color + geometry);
// points feed polylines. Memory is fixed capacity per canvas slot
// (commands ~64 B, points 8 B), ~1.5 MiB across the 8 canvas slots, pages
// touched only as canvases draw.
pub const max_canvas_commands: usize = 2048;
pub const max_canvas_points: usize = 8192;
pub const max_canvas_wire_values: usize = 32768;

pub const NodeId = u32;

pub const Kind = enum {
    column,
    row,
    stack,
    text,
    icon,
    panel,
    button,
    slider,
    image,
    canvas,

    pub fn parse(value: []const u8) ?Kind {
        inline for (@typeInfo(Kind).@"enum".fields) |field| {
            if (std.mem.eql(u8, value, field.name)) return @field(Kind, field.name);
        }
        return null;
    }
};

pub const FontWeight = enum { light, regular, medium, semibold, bold };
pub const TextAlign = enum { start, center, end };
pub const CrossAlign = enum { start, center, end, baseline, stretch };
pub const MainAlign = enum { start, center, end, between, around, evenly };
pub const SelfAlign = enum { auto, start, center, end, stretch };

pub const BoxShadow = struct {
    offset: native_sdk.geometry.OffsetF = .{},
    blur: f32 = 0,
    spread: f32 = 0,
    color: native_sdk.canvas.Color,
};

pub const InteractionStyle = struct {
    background: ?native_sdk.canvas.Color = null,
    text_color: ?native_sdk.canvas.Color = null,
    opacity: f32 = -1,
    border_color: ?native_sdk.canvas.Color = null,
    shadow: ?BoxShadow = null,
    shadow_set: bool = false,
    shadow_inset: bool = false,

    pub fn isEmpty(self: InteractionStyle) bool {
        return self.background == null and self.text_color == null and self.opacity < 0 and self.border_color == null and !self.shadow_set;
    }
};

/// One bounded retained node. JS ids index the tree's reserved table. Common
/// strings and child lists live inline; rare, independently-sized asset
/// strings are exact heap allocations.
pub const Node = struct {
    lifetime: u64 = 0,
    kind: Kind = .column,
    parent: ?NodeId = null,
    children: [max_children]NodeId = undefined,
    child_count: usize = 0,
    text: [max_text_bytes]u8 = undefined,
    text_len: usize = 0,
    padding: f32 = 0,
    padding_top: f32 = -1,
    padding_right: f32 = -1,
    padding_bottom: f32 = -1,
    padding_left: f32 = -1,
    margin_top: f32 = 0,
    margin_right: f32 = 0,
    margin_bottom: f32 = 0,
    margin_left: f32 = 0,
    gap: f32 = 0,
    radius: f32 = 0,
    radius_top_left: f32 = -1,
    radius_top_right: f32 = -1,
    radius_bottom_right: f32 = -1,
    radius_bottom_left: f32 = -1,
    border_width: f32 = 0,
    opacity: f32 = 1,
    background: ?native_sdk.canvas.Color = null,
    border_color: ?native_sdk.canvas.Color = null,
    text_color: ?native_sdk.canvas.Color = null,
    hover_style: InteractionStyle = .{},
    pressed_style: InteractionStyle = .{},
    shadow: ?BoxShadow = null,
    shadow_inset: bool = false,
    text_shadow: ?native_sdk.canvas.TextShadow = null,
    font_scale: f32 = 1,
    font_weight: FontWeight = .regular,
    font_family: [max_font_family_bytes]u8 = undefined,
    font_family_len: usize = 0,
    text_align: TextAlign = .start,
    line_height: f32 = 0,
    letter_spacing: f32 = 0,
    line_clamp: f32 = 0,
    tabular_nums: bool = false,
    cross_align: CrossAlign = .stretch,
    main_align: MainAlign = .start,
    grow: f32 = 0,
    shrink: f32 = 1,
    align_self: SelfAlign = .auto,
    flex_wrap: bool = false,
    /// -1 is unset; zero is an authored preferred size.
    width: f32 = -1,
    height: f32 = -1,
    min_width: f32 = 0,
    min_height: f32 = 0,
    /// -1 is unbounded; zero is an authored clamp.
    max_width: f32 = -1,
    max_height: f32 = -1,
    width_percent: f32 = 0,
    height_percent: f32 = 0,
    aspect_ratio: f32 = 0,
    truncate: bool = false,
    overflow_hidden: bool = false,
    handles_press: bool = false,
    handles_double_press: bool = false,
    handles_right_press: bool = false,
    handles_change: bool = false,
    value: f32 = 0,
    max: f32 = 1,
    /// Asset paths have no useful protocol bound. Allocate the authored value
    /// exactly instead of turning an arbitrary path length into a tree budget.
    source: []u8 = &.{},
    /// Rare, independently-budgeted icon geometry. Keeping this heap-owned
    /// avoids adding 8 KiB to every retained node.
    icon_path: []u8 = &.{},
    icon_view_box: native_sdk.geometry.RectF = native_sdk.geometry.RectF.init(0, 0, 24, 24),
    icon_stroke: f32 = 0,
    image_fit: native_sdk.canvas.ImageFit = .stretch,
    image_tile: bool = false,
    canvas_slot: u8 = 0,

    pub fn textSlice(self: *const Node) []const u8 {
        return self.text[0..self.text_len];
    }

    pub fn sourceSlice(self: *const Node) []const u8 {
        return self.source;
    }

    pub fn iconPathSlice(self: *const Node) []const u8 {
        return self.icon_path;
    }

    pub fn fontFamilySlice(self: *const Node) []const u8 {
        return self.font_family[0..self.font_family_len];
    }
};

pub const Error = error{
    OutOfMemory,
    InvalidNode,
    NodeLimit,
    ChildLimit,
    TextTooLong,
    IconPathTooLong,
    Cycle,
    InvalidProperty,
    CanvasLimit,
    CanvasCommandLimit,
    CanvasPointLimit,
    InvalidCanvasBatch,
};

pub const CanvasState = struct {
    owner: NodeId = 0,
    layout_width: f32 = 0,
    layout_height: f32 = 0,
    command_layout_width: f32 = 0,
    command_layout_height: f32 = 0,
    commands: [max_canvas_commands]native_sdk.canvas.ImmediateCanvasCommand = undefined,
    command_count: usize = 0,
    points: [max_canvas_points]native_sdk.geometry.PointF = undefined,
    point_count: usize = 0,
    fingerprint: u64 = 0,

    pub fn slice(self: *const CanvasState) []const native_sdk.canvas.ImmediateCanvasCommand {
        return self.commands[0..self.command_count];
    }
};

/// JS mutates this tree; the Native SDK view is a pure derivation of it.
/// `generation` advances only for an effective retained-tree mutation.
/// Immediate canvas pixels have their own `canvas_generation`, so a draw-only
/// frame does not trigger unrelated authored-tree work such as image-source
/// synchronization.
pub const Tree = struct {
    allocator: std.mem.Allocator = std.heap.page_allocator,
    // Occupancy makes the large node arena a lazy reservation: never inspect
    // a slot unless its bit is set.
    occupied: std.StaticBitSet(max_nodes) = std.StaticBitSet(max_nodes).initEmpty(),
    nodes: [max_nodes]Node = undefined,
    canvas_occupied: std.StaticBitSet(max_canvases) = std.StaticBitSet(max_canvases).initEmpty(),
    canvases: [max_canvases]CanvasState = undefined,
    root: ?NodeId = null,
    generation: u64 = 0,
    canvas_generation: u64 = 0,
    next_node_lifetime: u64 = 1,
    batch_depth: u8 = 0,
    batch_changed: bool = false,
    transaction_snapshot: ?*Tree = null,
    snapshot_storage: ?*Tree = null,

    pub fn deinit(self: *Tree) void {
        self.destroySnapshots();
        self.deinitNodes();
    }

    fn deinitNodes(self: *Tree) void {
        const allocator = self.allocator;
        for (&self.nodes, 0..) |*entry, index| {
            if (!self.occupied.isSet(index)) continue;
            if (entry.source.len > 0) allocator.free(entry.source);
            if (entry.icon_path.len > 0) allocator.free(entry.icon_path);
        }
        self.occupied = std.StaticBitSet(max_nodes).initEmpty();
    }

    pub fn beginBatch(self: *Tree) Error!void {
        if (self.batch_depth == 0) {
            const snapshot = if (self.snapshot_storage) |storage| reuse: {
                self.snapshot_storage = null;
                break :reuse storage;
            } else try self.allocator.create(Tree);
            errdefer {
                snapshot.deinitNodes();
                resetEmpty(snapshot, self.allocator);
                self.snapshot_storage = snapshot;
            }
            try self.cloneInto(snapshot);
            self.transaction_snapshot = snapshot;
        }
        self.batch_depth +|= 1;
    }

    /// Close one authored batch level. The outermost close is deliberately
    /// split from commit so bridge validation can inspect only the complete
    /// generation and still roll it back if validation fails.
    pub fn prepareEndBatch(self: *Tree) bool {
        if (self.batch_depth == 0) return false;
        self.batch_depth -= 1;
        return self.batch_depth == 0;
    }

    pub fn commitBatch(self: *Tree) void {
        if (self.batch_depth != 0) return;
        if (self.batch_changed) {
            self.batch_changed = false;
            self.generation +%= 1;
        }
        self.recycleSnapshot();
    }

    pub fn endBatch(self: *Tree) void {
        if (!self.prepareEndBatch()) return;
        self.commitBatch();
    }

    /// Restore the exact tree that was visible before the outermost authored
    /// batch. A JavaScript exception may occur after arbitrary create/remove/
    /// prop operations; copying the bounded tree is deliberately boring and
    /// makes the renderer's contract absolute: a failed generation is never
    /// observable.
    pub fn abortBatch(self: *Tree) void {
        const snapshot = self.transaction_snapshot orelse {
            self.batch_depth = 0;
            self.batch_changed = false;
            return;
        };
        const allocator = self.allocator;
        self.transaction_snapshot = null;
        self.deinitNodes();
        self.* = snapshot.*;
        self.transaction_snapshot = null;
        self.snapshot_storage = snapshot;
        rebaseInternalSlices(snapshot, self);
        resetEmpty(snapshot, allocator);
    }

    pub fn moveFrom(self: *Tree, source: *Tree) void {
        self.deinit();
        const source_allocator = source.allocator;
        self.* = source.*;
        rebaseInternalSlices(source, self);
        resetEmpty(source, source_allocator);
    }

    pub fn nodeCount(self: *const Tree) usize {
        return self.occupied.count();
    }

    pub fn isNodeSlotOccupied(self: *const Tree, index: usize) bool {
        return index < max_nodes and self.occupied.isSet(index);
    }

    pub const CanvasAncestorViolation = struct {
        canvas_id: NodeId,
        ancestor_id: NodeId,
        reason: enum { clip, opacity },
    };

    pub fn canvasAncestorViolation(self: *const Tree) ?CanvasAncestorViolation {
        for (&self.nodes, 0..) |*node_value, index| {
            if (!self.occupied.isSet(index) or node_value.kind != .canvas) continue;
            const canvas_id: NodeId = @intCast(index + 1);
            var ancestor_id = node_value.parent;
            while (ancestor_id) |id| {
                const ancestor = self.nodeConst(id) catch break;
                if (ancestor.overflow_hidden) return .{ .canvas_id = canvas_id, .ancestor_id = id, .reason = .clip };
                if (ancestor.opacity < 1) return .{ .canvas_id = canvas_id, .ancestor_id = id, .reason = .opacity };
                ancestor_id = ancestor.parent;
            }
        }
        return null;
    }

    /// Replace an invalid authored generation with a deterministic retained
    /// error tree. This path has no fallible allocation, so even an OOM or
    /// exhausted authored budget cannot expose an uninitialized GPU surface.
    pub fn showError(self: *Tree, message: []const u8) void {
        self.recycleSnapshot();
        self.deinitNodes();
        const allocator = self.allocator;
        const snapshot_storage = self.snapshot_storage;
        const next_generation = self.generation +% 1;
        resetEmpty(self, allocator);
        self.generation = next_generation;
        self.snapshot_storage = snapshot_storage;

        const root_id: NodeId = 1;
        const text_id: NodeId = 2;
        self.nodes[0] = .{
            .lifetime = self.next_node_lifetime,
            .kind = .column,
            .children = block: {
                var children: [max_children]NodeId = @splat(0);
                children[0] = text_id;
                break :block children;
            },
            .child_count = 1,
            .padding = 12,
            .gap = 6,
            .grow = 1,
            .background = native_sdk.canvas.Color.rgba8(52, 12, 18, 255),
        };
        self.occupied.set(0);
        self.next_node_lifetime +%= 1;
        self.nodes[1] = .{
            .lifetime = self.next_node_lifetime,
            .kind = .text,
            .parent = root_id,
            .text_color = native_sdk.canvas.Color.rgba8(255, 226, 230, 255),
            .font_scale = 0.86,
            .font_weight = .semibold,
            .line_height = 1.25,
            .line_clamp = 6,
        };
        self.occupied.set(1);
        self.next_node_lifetime +%= 1;
        const safe_length = validUtf8Prefix(message, @min(message.len, max_text_bytes));
        @memcpy(self.nodes[1].text[0..safe_length], message[0..safe_length]);
        self.nodes[1].text_len = safe_length;
        self.root = root_id;
    }

    fn cloneInto(self: *const Tree, destination: *Tree) Error!void {
        resetEmpty(destination, self.allocator);
        destination.root = self.root;
        destination.generation = self.generation;
        destination.canvas_generation = self.canvas_generation;
        destination.next_node_lifetime = self.next_node_lifetime;
        destination.batch_depth = self.batch_depth;
        destination.batch_changed = self.batch_changed;
        errdefer destination.deinitNodes();
        for (&self.nodes, 0..) |*node_value, index| {
            if (!self.occupied.isSet(index)) continue;
            destination.nodes[index] = node_value.*;
            destination.nodes[index].source = &.{};
            destination.nodes[index].icon_path = &.{};
            destination.occupied.set(index);
            if (node_value.source.len > 0) {
                destination.nodes[index].source = try self.allocator.dupe(u8, node_value.source);
            }
            if (node_value.icon_path.len > 0) {
                destination.nodes[index].icon_path = try self.allocator.dupe(u8, node_value.icon_path);
            }
        }
        for (&self.canvases, 0..) |*canvas, index| {
            if (!self.canvas_occupied.isSet(index)) continue;
            const copy = &destination.canvases[index];
            resetCanvas(copy);
            copy.owner = canvas.owner;
            copy.layout_width = canvas.layout_width;
            copy.layout_height = canvas.layout_height;
            copy.command_layout_width = canvas.command_layout_width;
            copy.command_layout_height = canvas.command_layout_height;
            copy.command_count = canvas.command_count;
            copy.point_count = canvas.point_count;
            copy.fingerprint = canvas.fingerprint;
            @memcpy(copy.commands[0..canvas.command_count], canvas.commands[0..canvas.command_count]);
            @memcpy(copy.points[0..canvas.point_count], canvas.points[0..canvas.point_count]);
            destination.canvas_occupied.set(index);
        }
        rebaseInternalSlices(self, destination);
    }

    fn recycleSnapshot(self: *Tree) void {
        const snapshot = self.transaction_snapshot orelse return;
        self.transaction_snapshot = null;
        snapshot.transaction_snapshot = null;
        snapshot.snapshot_storage = null;
        snapshot.deinitNodes();
        resetEmpty(snapshot, self.allocator);
        std.debug.assert(self.snapshot_storage == null);
        self.snapshot_storage = snapshot;
    }

    fn destroySnapshots(self: *Tree) void {
        if (self.transaction_snapshot) |snapshot| {
            self.transaction_snapshot = null;
            snapshot.transaction_snapshot = null;
            snapshot.snapshot_storage = null;
            snapshot.deinitNodes();
            self.allocator.destroy(snapshot);
        }
        if (self.snapshot_storage) |snapshot| {
            self.snapshot_storage = null;
            snapshot.transaction_snapshot = null;
            snapshot.snapshot_storage = null;
            snapshot.deinitNodes();
            self.allocator.destroy(snapshot);
        }
    }

    pub fn createNode(self: *Tree, kind: Kind) Error!NodeId {
        for (&self.nodes, 0..) |*slot, index| {
            if (self.occupied.isSet(index)) continue;
            var canvas_index: ?usize = null;
            if (kind == .canvas) {
                canvas_index = for (&self.canvases, 0..) |*canvas, candidate| {
                    _ = canvas;
                    if (!self.canvas_occupied.isSet(candidate)) break candidate;
                } else return error.CanvasLimit;
            }
            slot.* = .{ .lifetime = self.next_node_lifetime, .kind = kind };
            self.occupied.set(index);
            self.next_node_lifetime +%= 1;
            if (self.next_node_lifetime == 0) self.next_node_lifetime = 1;
            if (canvas_index) |canvas_slot| {
                const id: NodeId = @intCast(index + 1);
                resetCanvas(&self.canvases[canvas_slot]);
                self.canvases[canvas_slot].owner = id;
                self.canvas_occupied.set(canvas_slot);
                slot.canvas_slot = @intCast(canvas_slot + 1);
            }
            self.changed();
            return @intCast(index + 1);
        }
        return error.NodeLimit;
    }

    pub fn node(self: *Tree, id: NodeId) Error!*Node {
        if (id == 0 or id > max_nodes) return error.InvalidNode;
        if (!self.occupied.isSet(id - 1)) return error.InvalidNode;
        const result = &self.nodes[id - 1];
        return result;
    }

    pub fn nodeConst(self: *const Tree, id: NodeId) Error!*const Node {
        if (id == 0 or id > max_nodes) return error.InvalidNode;
        if (!self.occupied.isSet(id - 1)) return error.InvalidNode;
        const result = &self.nodes[id - 1];
        return result;
    }

    pub fn setText(self: *Tree, id: NodeId, value: []const u8) Error!void {
        if (value.len > max_text_bytes) return error.TextTooLong;
        const target = try self.node(id);
        if (std.mem.eql(u8, target.textSlice(), value)) return;
        @memcpy(target.text[0..value.len], value);
        target.text_len = value.len;
        self.changed();
    }

    pub fn setNumberProp(self: *Tree, id: NodeId, key: []const u8, value: f32) Error!void {
        const target = try self.node(id);
        const slot: *f32 = if (std.mem.eql(u8, key, "padding"))
            &target.padding
        else if (std.mem.eql(u8, key, "paddingTop"))
            &target.padding_top
        else if (std.mem.eql(u8, key, "paddingRight"))
            &target.padding_right
        else if (std.mem.eql(u8, key, "paddingBottom"))
            &target.padding_bottom
        else if (std.mem.eql(u8, key, "paddingLeft"))
            &target.padding_left
        else if (std.mem.eql(u8, key, "marginTop"))
            &target.margin_top
        else if (std.mem.eql(u8, key, "marginRight"))
            &target.margin_right
        else if (std.mem.eql(u8, key, "marginBottom"))
            &target.margin_bottom
        else if (std.mem.eql(u8, key, "marginLeft"))
            &target.margin_left
        else if (std.mem.eql(u8, key, "gap"))
            &target.gap
        else if (std.mem.eql(u8, key, "radius"))
            &target.radius
        else if (std.mem.eql(u8, key, "radiusTopLeft"))
            &target.radius_top_left
        else if (std.mem.eql(u8, key, "radiusTopRight"))
            &target.radius_top_right
        else if (std.mem.eql(u8, key, "radiusBottomRight"))
            &target.radius_bottom_right
        else if (std.mem.eql(u8, key, "radiusBottomLeft"))
            &target.radius_bottom_left
        else if (std.mem.eql(u8, key, "borderWidth"))
            &target.border_width
        else if (std.mem.eql(u8, key, "opacity"))
            &target.opacity
        else if (std.mem.eql(u8, key, "hoverOpacity"))
            &target.hover_style.opacity
        else if (std.mem.eql(u8, key, "pressedOpacity"))
            &target.pressed_style.opacity
        else if (std.mem.eql(u8, key, "fontScale"))
            &target.font_scale
        else if (std.mem.eql(u8, key, "lineHeight"))
            &target.line_height
        else if (std.mem.eql(u8, key, "letterSpacing"))
            &target.letter_spacing
        else if (std.mem.eql(u8, key, "lineClamp"))
            &target.line_clamp
        else if (std.mem.eql(u8, key, "grow"))
            &target.grow
        else if (std.mem.eql(u8, key, "shrink"))
            &target.shrink
        else if (std.mem.eql(u8, key, "width"))
            &target.width
        else if (std.mem.eql(u8, key, "height"))
            &target.height
        else if (std.mem.eql(u8, key, "minWidth"))
            &target.min_width
        else if (std.mem.eql(u8, key, "minHeight"))
            &target.min_height
        else if (std.mem.eql(u8, key, "maxWidth"))
            &target.max_width
        else if (std.mem.eql(u8, key, "maxHeight"))
            &target.max_height
        else if (std.mem.eql(u8, key, "widthPercent"))
            &target.width_percent
        else if (std.mem.eql(u8, key, "heightPercent"))
            &target.height_percent
        else if (std.mem.eql(u8, key, "aspectRatio"))
            &target.aspect_ratio
        else if (std.mem.eql(u8, key, "iconStroke"))
            &target.icon_stroke
        else
            return error.InvalidProperty;
        const normalized = if (std.mem.eql(u8, key, "opacity"))
            std.math.clamp(value, 0, 1)
        else if (std.mem.eql(u8, key, "hoverOpacity") or std.mem.eql(u8, key, "pressedOpacity"))
            if (value < 0) -1 else std.math.clamp(value, 0, 1)
        else if (std.mem.startsWith(u8, key, "margin"))
            value
        else if (std.mem.eql(u8, key, "letterSpacing"))
            value
        else if ((std.mem.startsWith(u8, key, "padding") and !std.mem.eql(u8, key, "padding")) or std.mem.startsWith(u8, key, "radius"))
            @max(value, -1)
        else if (std.mem.eql(u8, key, "width") or std.mem.eql(u8, key, "height") or
            std.mem.eql(u8, key, "maxWidth") or std.mem.eql(u8, key, "maxHeight"))
            @max(value, -1)
        else
            @max(value, 0);
        if (slot.* == normalized) return;
        slot.* = normalized;
        self.changed();
    }

    pub fn setFontWeight(self: *Tree, id: NodeId, value: []const u8) Error!void {
        const weight: FontWeight = if (std.mem.eql(u8, value, "light")) .light else if (std.mem.eql(u8, value, "normal") or std.mem.eql(u8, value, "regular")) .regular else if (std.mem.eql(u8, value, "medium")) .medium else if (std.mem.eql(u8, value, "semibold")) .semibold else if (std.mem.eql(u8, value, "bold")) .bold else return error.InvalidProperty;
        const target = try self.node(id);
        if (target.font_weight == weight) return;
        target.font_weight = weight;
        self.changed();
    }

    pub fn setFontFamily(self: *Tree, id: NodeId, value: []const u8) Error!void {
        if (value.len > max_font_family_bytes) return error.TextTooLong;
        const target = try self.node(id);
        if (std.mem.eql(u8, target.fontFamilySlice(), value)) return;
        @memcpy(target.font_family[0..value.len], value);
        target.font_family_len = value.len;
        self.changed();
    }

    pub fn setTextAlign(self: *Tree, id: NodeId, value: []const u8) Error!void {
        const alignment: TextAlign = if (std.mem.eql(u8, value, "start")) .start else if (std.mem.eql(u8, value, "center")) .center else if (std.mem.eql(u8, value, "end")) .end else return error.InvalidProperty;
        const target = try self.node(id);
        if (target.text_align == alignment) return;
        target.text_align = alignment;
        self.changed();
    }

    pub fn setBackground(self: *Tree, id: NodeId, color: ?native_sdk.canvas.Color) Error!void {
        const target = try self.node(id);
        if (std.meta.eql(target.background, color)) return;
        target.background = color;
        self.changed();
    }

    pub fn setTextColor(self: *Tree, id: NodeId, color: ?native_sdk.canvas.Color) Error!void {
        const target = try self.node(id);
        if (std.meta.eql(target.text_color, color)) return;
        target.text_color = color;
        self.changed();
    }

    pub fn setBorderColor(self: *Tree, id: NodeId, color: ?native_sdk.canvas.Color) Error!void {
        const target = try self.node(id);
        if (std.meta.eql(target.border_color, color)) return;
        target.border_color = color;
        self.changed();
    }

    pub fn setInteractionColor(self: *Tree, id: NodeId, key: []const u8, color: ?native_sdk.canvas.Color) Error!void {
        const target = try self.node(id);
        const slot: *?native_sdk.canvas.Color = if (std.mem.eql(u8, key, "hoverBackground"))
            &target.hover_style.background
        else if (std.mem.eql(u8, key, "hoverTextColor"))
            &target.hover_style.text_color
        else if (std.mem.eql(u8, key, "hoverBorderColor"))
            &target.hover_style.border_color
        else if (std.mem.eql(u8, key, "pressedBackground"))
            &target.pressed_style.background
        else if (std.mem.eql(u8, key, "pressedTextColor"))
            &target.pressed_style.text_color
        else if (std.mem.eql(u8, key, "pressedBorderColor"))
            &target.pressed_style.border_color
        else
            return error.InvalidProperty;
        if (std.meta.eql(slot.*, color)) return;
        slot.* = color;
        self.changed();
    }

    pub fn setShadow(self: *Tree, id: NodeId, value: ?BoxShadow) Error!void {
        const target = try self.node(id);
        if (std.meta.eql(target.shadow, value)) return;
        target.shadow = value;
        self.changed();
    }

    pub fn setShadowInset(self: *Tree, id: NodeId, value: bool) Error!void {
        const target = try self.node(id);
        if (target.shadow_inset == value) return;
        target.shadow_inset = value;
        self.changed();
    }

    pub fn setInteractionShadow(self: *Tree, id: NodeId, key: []const u8, value: ?BoxShadow, is_set: bool) Error!void {
        const target = try self.node(id);
        const style: *InteractionStyle = if (std.mem.eql(u8, key, "hoverShadow"))
            &target.hover_style
        else if (std.mem.eql(u8, key, "pressedShadow"))
            &target.pressed_style
        else
            return error.InvalidProperty;
        if (style.shadow_set == is_set and std.meta.eql(style.shadow, value)) return;
        style.shadow = value;
        style.shadow_set = is_set;
        self.changed();
    }

    pub fn setInteractionShadowInset(self: *Tree, id: NodeId, key: []const u8, value: bool) Error!void {
        const target = try self.node(id);
        const style: *InteractionStyle = if (std.mem.eql(u8, key, "hoverShadowInset"))
            &target.hover_style
        else if (std.mem.eql(u8, key, "pressedShadowInset"))
            &target.pressed_style
        else
            return error.InvalidProperty;
        if (style.shadow_inset == value) return;
        style.shadow_inset = value;
        self.changed();
    }

    pub fn setTextShadow(self: *Tree, id: NodeId, value: ?native_sdk.canvas.TextShadow) Error!void {
        const target = try self.node(id);
        if (std.meta.eql(target.text_shadow, value)) return;
        target.text_shadow = value;
        self.changed();
    }

    pub fn setCrossAlign(self: *Tree, id: NodeId, value: []const u8) Error!void {
        const alignment: CrossAlign = if (std.mem.eql(u8, value, "start")) .start else if (std.mem.eql(u8, value, "center")) .center else if (std.mem.eql(u8, value, "end")) .end else if (std.mem.eql(u8, value, "baseline")) .baseline else if (std.mem.eql(u8, value, "stretch")) .stretch else return error.InvalidProperty;
        const target = try self.node(id);
        if (target.cross_align == alignment) return;
        target.cross_align = alignment;
        self.changed();
    }

    pub fn setMainAlign(self: *Tree, id: NodeId, value: []const u8) Error!void {
        const alignment: MainAlign = if (std.mem.eql(u8, value, "start")) .start else if (std.mem.eql(u8, value, "center")) .center else if (std.mem.eql(u8, value, "end")) .end else if (std.mem.eql(u8, value, "between")) .between else if (std.mem.eql(u8, value, "around")) .around else if (std.mem.eql(u8, value, "evenly")) .evenly else return error.InvalidProperty;
        const target = try self.node(id);
        if (target.main_align == alignment) return;
        target.main_align = alignment;
        self.changed();
    }

    pub fn setAlignSelf(self: *Tree, id: NodeId, value: []const u8) Error!void {
        const alignment: SelfAlign = if (std.mem.eql(u8, value, "auto")) .auto else if (std.mem.eql(u8, value, "start")) .start else if (std.mem.eql(u8, value, "center")) .center else if (std.mem.eql(u8, value, "end")) .end else if (std.mem.eql(u8, value, "stretch")) .stretch else return error.InvalidProperty;
        const target = try self.node(id);
        if (target.align_self == alignment) return;
        target.align_self = alignment;
        self.changed();
    }

    pub fn setFlexWrap(self: *Tree, id: NodeId, value: bool) Error!void {
        const target = try self.node(id);
        if (target.flex_wrap == value) return;
        target.flex_wrap = value;
        self.changed();
    }

    pub fn setTabularNums(self: *Tree, id: NodeId, value: bool) Error!void {
        const target = try self.node(id);
        if (target.tabular_nums == value) return;
        target.tabular_nums = value;
        self.changed();
    }

    pub fn setTruncate(self: *Tree, id: NodeId, value: bool) Error!void {
        const target = try self.node(id);
        if (target.truncate == value) return;
        target.truncate = value;
        self.changed();
    }

    pub fn setOverflowHidden(self: *Tree, id: NodeId, value: bool) Error!void {
        const target = try self.node(id);
        if (target.overflow_hidden == value) return;
        target.overflow_hidden = value;
        self.changed();
    }

    pub fn setHandler(self: *Tree, id: NodeId, kind: []const u8, enabled: bool) Error!void {
        const target = try self.node(id);
        const slot: *bool = if (std.mem.eql(u8, kind, "press"))
            &target.handles_press
        else if (std.mem.eql(u8, kind, "doublepress"))
            &target.handles_double_press
        else if (std.mem.eql(u8, kind, "rightpress"))
            &target.handles_right_press
        else if (std.mem.eql(u8, kind, "change"))
            &target.handles_change
        else
            return error.InvalidProperty;
        if (slot.* == enabled) return;
        slot.* = enabled;
        self.changed();
    }

    pub fn setControlValue(self: *Tree, id: NodeId, key: []const u8, value: f32) Error!void {
        const target = try self.node(id);
        const slot: *f32 = if (std.mem.eql(u8, key, "value")) &target.value else if (std.mem.eql(u8, key, "max")) &target.max else return error.InvalidProperty;
        const normalized = if (std.mem.eql(u8, key, "max")) @max(value, 0.000001) else @max(value, 0);
        if (slot.* == normalized) return;
        slot.* = normalized;
        self.changed();
    }

    pub fn setSource(self: *Tree, id: NodeId, value: []const u8) Error!void {
        if (value.len > max_source_bytes) return error.TextTooLong;
        const target = try self.node(id);
        if (std.mem.eql(u8, target.sourceSlice(), value)) return;
        const replacement = try self.allocator.dupe(u8, value);
        if (target.source.len > 0) self.allocator.free(target.source);
        target.source = replacement;
        self.changed();
    }

    pub fn setIconPath(self: *Tree, id: NodeId, value: []const u8) Error!void {
        if (value.len > max_icon_path_bytes) return error.IconPathTooLong;
        const target = try self.node(id);
        if (std.mem.eql(u8, target.iconPathSlice(), value)) return;
        const replacement = try self.allocator.dupe(u8, value);
        if (target.icon_path.len > 0) self.allocator.free(target.icon_path);
        target.icon_path = replacement;
        self.changed();
    }

    pub fn setIconViewBox(self: *Tree, id: NodeId, value: []const u8) Error!void {
        var values: [4]f32 = undefined;
        var tokens = std.mem.tokenizeAny(u8, value, " ,\t\r\n");
        for (&values) |*slot| {
            const token = tokens.next() orelse return error.InvalidProperty;
            slot.* = std.fmt.parseFloat(f32, token) catch return error.InvalidProperty;
            if (!std.math.isFinite(slot.*)) return error.InvalidProperty;
        }
        if (tokens.next() != null or values[2] <= 0 or values[3] <= 0) return error.InvalidProperty;
        const next = native_sdk.geometry.RectF.init(values[0], values[1], values[2], values[3]);
        const target = try self.node(id);
        if (std.meta.eql(target.icon_view_box, next)) return;
        target.icon_view_box = next;
        self.changed();
    }

    pub fn setImageFit(self: *Tree, id: NodeId, value: []const u8) Error!void {
        const fit: native_sdk.canvas.ImageFit = if (std.mem.eql(u8, value, "cover")) .cover else if (std.mem.eql(u8, value, "contain")) .contain else if (std.mem.eql(u8, value, "stretch")) .stretch else return error.InvalidProperty;
        const target = try self.node(id);
        if (target.image_fit == fit) return;
        target.image_fit = fit;
        self.changed();
    }

    pub fn setImageTile(self: *Tree, id: NodeId, value: bool) Error!void {
        const target = try self.node(id);
        if (target.image_tile == value) return;
        target.image_tile = value;
        self.changed();
    }

    pub fn canvasState(self: *Tree, id: NodeId) Error!*CanvasState {
        const target = try self.node(id);
        if (target.kind != .canvas or target.canvas_slot == 0) return error.InvalidNode;
        return &self.canvases[target.canvas_slot - 1];
    }

    pub fn canvasStateConst(self: *const Tree, id: NodeId) Error!*const CanvasState {
        const target = try self.nodeConst(id);
        if (target.kind != .canvas or target.canvas_slot == 0) return error.InvalidNode;
        return &self.canvases[target.canvas_slot - 1];
    }

    /// Layout feedback is runtime metadata, not an authored tree mutation.
    /// Keep it in the canvas side table so responsive canvases receive their
    /// actual content-box dimensions without growing every retained node.
    pub fn setCanvasLayout(self: *Tree, id: NodeId, width: f32, height: f32) Error!bool {
        const canvas = try self.canvasState(id);
        const next_width = @max(width, 0);
        const next_height = @max(height, 0);
        if (canvas.layout_width == next_width and canvas.layout_height == next_height) return false;
        canvas.layout_width = next_width;
        canvas.layout_height = next_height;
        return true;
    }

    /// Decode the SDK's bounded Float64 wire batch into fork-native drawing
    /// commands. Colors arrive as exact packed RGBA integers; geometry is
    /// narrowed once here, so the frame renderer never parses JS values.
    pub fn setCanvasCommands(self: *Tree, id: NodeId, wire: []const f64) Error!void {
        if (wire.len > max_canvas_wire_values) return error.InvalidCanvasBatch;
        const fingerprint = std.hash.Wyhash.hash(0x6361_6e76_6173, std.mem.sliceAsBytes(wire));
        const canvas = try self.canvasState(id);
        if (canvas.fingerprint == fingerprint and canvas.command_count > 0 and
            canvas.command_layout_width == canvas.layout_width and canvas.command_layout_height == canvas.layout_height) return;
        var commands_in_other_canvases: usize = 0;
        for (&self.canvases, 0..) |*other, index| {
            if (self.canvas_occupied.isSet(index) and other.owner != id) commands_in_other_canvases += other.command_count;
        }
        const command_limit = max_canvas_commands -| commands_in_other_canvases;
        // Validate the complete bounded batch before replacing the last good
        // frame. Decoding below is then a commit pass: malformed geometry,
        // points, or aggregate command pressure cannot leave a partial canvas
        // behind.
        try preflightCanvasWire(wire, command_limit);
        canvas.command_count = 0;
        canvas.point_count = 0;
        var cursor: usize = 0;
        while (cursor < wire.len) {
            const opcode = finiteInt(wire[cursor]) orelse return error.InvalidCanvasBatch;
            cursor += 1;
            switch (opcode) {
                0 => {
                    const color = try wireColor(wire, &cursor);
                    if (color.a > 0) {
                        const node_value = try self.nodeConst(id);
                        try appendCanvasCommand(canvas, command_limit, .{ .fill_rect = .{
                            .rect = native_sdk.geometry.RectF.init(
                                0,
                                0,
                                if (canvas.layout_width > 0) canvas.layout_width else @max(node_value.width, 0),
                                if (canvas.layout_height > 0) canvas.layout_height else @max(node_value.height, 0),
                            ),
                            .color = color,
                        } });
                    }
                },
                1 => try appendCanvasCommand(canvas, command_limit, .{ .fill_rect = .{
                    .rect = native_sdk.geometry.RectF.init(try wireFloat(wire, &cursor), try wireFloat(wire, &cursor), try wireFloat(wire, &cursor), try wireFloat(wire, &cursor)),
                    .color = try wireColor(wire, &cursor),
                } }),
                2 => try appendCanvasCommand(canvas, command_limit, .{ .fill_rounded_rect = .{
                    .rect = native_sdk.geometry.RectF.init(try wireFloat(wire, &cursor), try wireFloat(wire, &cursor), try wireFloat(wire, &cursor), try wireFloat(wire, &cursor)),
                    .radius = try wireFloat(wire, &cursor),
                    .color = try wireColor(wire, &cursor),
                } }),
                3 => try appendCanvasCommand(canvas, command_limit, .{ .fill_circle = .{
                    .center = native_sdk.geometry.PointF.init(try wireFloat(wire, &cursor), try wireFloat(wire, &cursor)),
                    .radius = try wireFloat(wire, &cursor),
                    .color = try wireColor(wire, &cursor),
                } }),
                4 => try appendCanvasCommand(canvas, command_limit, .{ .line = .{
                    .from = native_sdk.geometry.PointF.init(try wireFloat(wire, &cursor), try wireFloat(wire, &cursor)),
                    .to = native_sdk.geometry.PointF.init(try wireFloat(wire, &cursor), try wireFloat(wire, &cursor)),
                    .width = try wireFloat(wire, &cursor),
                    .color = try wireColor(wire, &cursor),
                } }),
                5 => {
                    const width = try wireFloat(wire, &cursor);
                    const color = try wireColor(wire, &cursor);
                    const count = finiteInt(if (cursor < wire.len) wire[cursor] else return error.InvalidCanvasBatch) orelse return error.InvalidCanvasBatch;
                    cursor += 1;
                    if (count < 2 or canvas.point_count + count > max_canvas_points) return error.CanvasPointLimit;
                    const start = canvas.point_count;
                    for (0..count) |_| {
                        canvas.points[canvas.point_count] = native_sdk.geometry.PointF.init(try wireFloat(wire, &cursor), try wireFloat(wire, &cursor));
                        canvas.point_count += 1;
                    }
                    try appendCanvasCommand(canvas, command_limit, .{ .polyline = .{ .points = canvas.points[start..canvas.point_count], .width = width, .color = color } });
                },
                else => return error.InvalidCanvasBatch,
            }
        }
        canvas.fingerprint = fingerprint;
        canvas.command_layout_width = canvas.layout_width;
        canvas.command_layout_height = canvas.layout_height;
        self.canvas_generation +%= 1;
    }

    pub fn appendChild(self: *Tree, parent_id: NodeId, child_id: NodeId) Error!void {
        if (parent_id == child_id or try self.isAncestor(child_id, parent_id)) return error.Cycle;
        const parent = try self.node(parent_id);
        _ = try self.node(child_id);
        for (parent.children[0..parent.child_count]) |existing| {
            if (existing == child_id) return;
        }
        if (parent.child_count == max_children) return error.ChildLimit;
        try self.detach(child_id);
        const live_parent = try self.node(parent_id);
        live_parent.children[live_parent.child_count] = child_id;
        live_parent.child_count += 1;
        (try self.node(child_id)).parent = parent_id;
        self.changed();
    }

    /// Move or attach `child_id` immediately before `before_id`. A zero
    /// `before_id` means append, matching the reconciler's end sentinel.
    pub fn insertBefore(self: *Tree, parent_id: NodeId, child_id: NodeId, before_id: NodeId) Error!void {
        if (parent_id == child_id or try self.isAncestor(child_id, parent_id)) return error.Cycle;
        _ = try self.node(parent_id);
        _ = try self.node(child_id);
        if (before_id != 0) {
            const before = try self.node(before_id);
            if (before.parent != parent_id or before_id == child_id) return error.InvalidNode;
        }
        const original_parent = (try self.node(child_id)).parent;
        const parent = try self.node(parent_id);
        var original_index: ?usize = null;
        if (original_parent == parent_id) {
            for (parent.children[0..parent.child_count], 0..) |candidate, index| {
                if (candidate == child_id) original_index = index;
            }
        }
        var target_index: usize = parent.child_count;
        if (before_id != 0) {
            for (parent.children[0..parent.child_count], 0..) |candidate, index| {
                if (candidate == before_id) target_index = index;
            }
        }
        if (original_index) |index| {
            const adjusted = if (index < target_index) target_index - 1 else target_index;
            if (index == adjusted) return;
        } else if (parent.child_count == max_children) return error.ChildLimit;
        try self.detach(child_id);
        const live_parent = try self.node(parent_id);
        target_index = live_parent.child_count;
        if (before_id != 0) {
            for (live_parent.children[0..live_parent.child_count], 0..) |candidate, index| {
                if (candidate == before_id) target_index = index;
            }
        }
        std.mem.copyBackwards(NodeId, live_parent.children[target_index + 1 .. live_parent.child_count + 1], live_parent.children[target_index..live_parent.child_count]);
        live_parent.children[target_index] = child_id;
        live_parent.child_count += 1;
        (try self.node(child_id)).parent = parent_id;
        self.changed();
    }

    pub fn removeNode(self: *Tree, id: NodeId) Error!void {
        _ = try self.node(id);
        try self.detach(id);
        self.removeSubtree(id);
        if (self.root == id) self.root = null;
        self.changed();
    }

    pub fn setRoot(self: *Tree, id: NodeId) Error!void {
        _ = try self.node(id);
        if (self.root == id) return;
        self.root = id;
        self.changed();
    }

    fn detach(self: *Tree, id: NodeId) Error!void {
        const child = try self.node(id);
        const parent_id = child.parent orelse return;
        const parent = try self.node(parent_id);
        for (parent.children[0..parent.child_count], 0..) |candidate, index| {
            if (candidate != id) continue;
            std.mem.copyForwards(NodeId, parent.children[index .. parent.child_count - 1], parent.children[index + 1 .. parent.child_count]);
            parent.child_count -= 1;
            child.parent = null;
            return;
        }
    }

    fn removeSubtree(self: *Tree, id: NodeId) void {
        const target = self.node(id) catch return;
        const count = target.child_count;
        var children: [max_children]NodeId = undefined;
        @memcpy(children[0..count], target.children[0..count]);
        for (children[0..count]) |child_id| self.removeSubtree(child_id);
        if (target.canvas_slot > 0) self.canvas_occupied.unset(target.canvas_slot - 1);
        if (target.source.len > 0) self.allocator.free(target.source);
        if (target.icon_path.len > 0) self.allocator.free(target.icon_path);
        self.occupied.unset(id - 1);
    }

    fn isAncestor(self: *Tree, ancestor: NodeId, descendant: NodeId) Error!bool {
        var cursor: ?NodeId = descendant;
        while (cursor) |id| {
            if (id == ancestor) return true;
            cursor = (try self.node(id)).parent;
        }
        return false;
    }

    fn changed(self: *Tree) void {
        if (self.batch_depth > 0) {
            self.batch_changed = true;
        } else {
            self.generation +%= 1;
        }
    }
};

fn resetCanvas(canvas: *CanvasState) void {
    canvas.owner = 0;
    canvas.layout_width = 0;
    canvas.layout_height = 0;
    canvas.command_layout_width = 0;
    canvas.command_layout_height = 0;
    canvas.command_count = 0;
    canvas.point_count = 0;
    canvas.fingerprint = 0;
}

fn resetEmpty(tree: *Tree, allocator: std.mem.Allocator) void {
    tree.allocator = allocator;
    tree.occupied = std.StaticBitSet(max_nodes).initEmpty();
    tree.canvas_occupied = std.StaticBitSet(max_canvases).initEmpty();
    tree.root = null;
    tree.generation = 0;
    tree.canvas_generation = 0;
    tree.next_node_lifetime = 1;
    tree.batch_depth = 0;
    tree.batch_changed = false;
    tree.transaction_snapshot = null;
    tree.snapshot_storage = null;
}

fn rebaseInternalSlices(source: *const Tree, destination: *Tree) void {
    for (&destination.canvases, 0..) |*canvas, canvas_index| {
        if (!destination.canvas_occupied.isSet(canvas_index)) continue;
        const source_canvas = &source.canvases[canvas_index];
        for (canvas.commands[0..canvas.command_count]) |*command| {
            switch (command.*) {
                .polyline => |polyline| {
                    const byte_offset = @intFromPtr(polyline.points.ptr) - @intFromPtr(&source_canvas.points);
                    const point_offset = byte_offset / @sizeOf(native_sdk.geometry.PointF);
                    command.polyline.points = canvas.points[point_offset .. point_offset + polyline.points.len];
                },
                else => {},
            }
        }
    }
}

fn validUtf8Prefix(value: []const u8, maximum: usize) usize {
    var length = maximum;
    while (length > 0 and !std.unicode.utf8ValidateSlice(value[0..length])) : (length -= 1) {}
    return length;
}

test "node lifetime changes when a removed image id is reused" {
    var tree: Tree = .{};
    const first = try tree.createNode(.image);
    const first_lifetime = (try tree.nodeConst(first)).lifetime;
    try tree.removeNode(first);
    const second = try tree.createNode(.image);
    try std.testing.expectEqual(first, second);
    try std.testing.expect((try tree.nodeConst(second)).lifetime != first_lifetime);
}

fn appendCanvasCommand(canvas: *CanvasState, command_limit: usize, command: native_sdk.canvas.ImmediateCanvasCommand) Error!void {
    if (canvas.command_count == command_limit) return error.CanvasCommandLimit;
    canvas.commands[canvas.command_count] = command;
    canvas.command_count += 1;
}

fn preflightCanvasWire(wire: []const f64, command_limit: usize) Error!void {
    var cursor: usize = 0;
    var command_count: usize = 0;
    var point_count: usize = 0;
    while (cursor < wire.len) {
        const opcode = finiteInt(wire[cursor]) orelse return error.InvalidCanvasBatch;
        cursor += 1;
        var emits_command = true;
        switch (opcode) {
            0 => {
                const color = try wireColor(wire, &cursor);
                emits_command = color.a > 0;
            },
            1 => {
                for (0..4) |_| _ = try wireFloat(wire, &cursor);
                _ = try wireColor(wire, &cursor);
            },
            2 => {
                for (0..5) |_| _ = try wireFloat(wire, &cursor);
                _ = try wireColor(wire, &cursor);
            },
            3 => {
                for (0..3) |_| _ = try wireFloat(wire, &cursor);
                _ = try wireColor(wire, &cursor);
            },
            4 => {
                for (0..5) |_| _ = try wireFloat(wire, &cursor);
                _ = try wireColor(wire, &cursor);
            },
            5 => {
                _ = try wireFloat(wire, &cursor);
                _ = try wireColor(wire, &cursor);
                const count = finiteInt(if (cursor < wire.len) wire[cursor] else return error.InvalidCanvasBatch) orelse return error.InvalidCanvasBatch;
                cursor += 1;
                if (count < 2 or point_count + count > max_canvas_points) return error.CanvasPointLimit;
                for (0..count) |_| {
                    _ = try wireFloat(wire, &cursor);
                    _ = try wireFloat(wire, &cursor);
                }
                point_count += count;
            },
            else => return error.InvalidCanvasBatch,
        }
        if (emits_command) {
            if (command_count == command_limit) return error.CanvasCommandLimit;
            command_count += 1;
        }
    }
}

fn wireFloat(wire: []const f64, cursor: *usize) Error!f32 {
    if (cursor.* >= wire.len or !std.math.isFinite(wire[cursor.*])) return error.InvalidCanvasBatch;
    const value: f32 = @floatCast(wire[cursor.*]);
    cursor.* += 1;
    return value;
}

fn wireColor(wire: []const f64, cursor: *usize) Error!native_sdk.canvas.Color {
    if (cursor.* >= wire.len) return error.InvalidCanvasBatch;
    const packed_value = finiteInt(wire[cursor.*]) orelse return error.InvalidCanvasBatch;
    cursor.* += 1;
    if (packed_value > std.math.maxInt(u32)) return error.InvalidCanvasBatch;
    const rgba: u32 = @intCast(packed_value);
    return native_sdk.canvas.Color.rgba8(@truncate(rgba >> 24), @truncate(rgba >> 16), @truncate(rgba >> 8), @truncate(rgba));
}

fn finiteInt(value: f64) ?usize {
    if (!std.math.isFinite(value) or value < 0 or @floor(value) != value or value > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return null;
    return @intFromFloat(value);
}

test "tree owns a bounded hierarchy" {
    var tree: Tree = .{};
    const root = try tree.createNode(.column);
    const label = try tree.createNode(.text);
    try tree.setText(label, "clock");
    try tree.appendChild(root, label);
    try tree.setRoot(root);
    try std.testing.expectEqualStrings("clock", (try tree.nodeConst(label)).textSlice());
    try std.testing.expectError(error.Cycle, tree.appendChild(label, root));
    try tree.removeNode(label);
    try std.testing.expectError(error.InvalidNode, tree.node(label));
}

test "aborting a render batch restores the exact committed tree" {
    var tree: Tree = .{ .allocator = std.testing.allocator };
    defer tree.deinit();
    const root = try tree.createNode(.column);
    const label = try tree.createNode(.text);
    const icon = try tree.createNode(.icon);
    const canvas = try tree.createNode(.canvas);
    try tree.setText(label, "committed");
    try tree.setIconPath(icon, "M 0 0 L 1 1");
    try tree.setCanvasCommands(canvas, &.{ 5, 1, 0xffffffff, 2, 1, 2, 3, 4 });
    try tree.appendChild(root, label);
    try tree.appendChild(root, icon);
    try tree.appendChild(root, canvas);
    try tree.setRoot(root);
    const committed_generation = tree.generation;
    const committed_canvas_generation = tree.canvas_generation;

    try tree.beginBatch();
    try tree.setText(label, "partial");
    try tree.setIconPath(icon, "M 20 20 L 30 30");
    try tree.setCanvasCommands(canvas, &.{ 5, 2, 0xff0000ff, 3, 10, 11, 12, 13, 14, 15 });
    const partial = try tree.createNode(.panel);
    try tree.appendChild(root, partial);
    try std.testing.expectEqual(committed_canvas_generation +% 1, tree.canvas_generation);
    tree.abortBatch();

    try std.testing.expectEqual(committed_generation, tree.generation);
    try std.testing.expectEqual(committed_canvas_generation, tree.canvas_generation);
    try std.testing.expectEqual(@as(usize, 4), tree.nodeCount());
    try std.testing.expectEqualStrings("committed", (try tree.nodeConst(label)).textSlice());
    try std.testing.expectEqualStrings("M 0 0 L 1 1", (try tree.nodeConst(icon)).iconPathSlice());
    try std.testing.expectError(error.InvalidNode, tree.nodeConst(partial));
    const restored_canvas = try tree.canvasStateConst(canvas);
    try std.testing.expectEqual(@as(usize, 2), restored_canvas.commands[0].polyline.points.len);
    try std.testing.expectEqual(@as(f32, 1), restored_canvas.commands[0].polyline.points[0].x);
    try std.testing.expectEqual(@as(f32, 4), restored_canvas.commands[0].polyline.points[1].y);
}

test "a committed render batch advances one generation" {
    var tree: Tree = .{ .allocator = std.testing.allocator };
    defer tree.deinit();
    const root = try tree.createNode(.column);
    try tree.setRoot(root);
    const before = tree.generation;
    try tree.beginBatch();
    const label = try tree.createNode(.text);
    try tree.setText(label, "committed");
    try tree.appendChild(root, label);
    tree.endBatch();
    try std.testing.expectEqual(before +% 1, tree.generation);
    try std.testing.expectEqualStrings("committed", (try tree.nodeConst(label)).textSlice());
}

test "render transactions reuse snapshot storage and validate only the outer close" {
    var tree: Tree = .{ .allocator = std.testing.allocator };
    defer tree.deinit();
    const root = try tree.createNode(.column);
    try tree.setRoot(root);

    try tree.beginBatch();
    try tree.beginBatch();
    const canvas = try tree.createNode(.canvas);
    try tree.setOverflowHidden(root, true);
    try tree.appendChild(root, canvas);
    try std.testing.expect(!tree.prepareEndBatch());
    try tree.setOverflowHidden(root, false);
    try std.testing.expect(tree.prepareEndBatch());
    try std.testing.expect(tree.canvasAncestorViolation() == null);
    tree.commitBatch();

    const storage = tree.snapshot_storage.?;
    try tree.beginBatch();
    try std.testing.expect(tree.transaction_snapshot.? == storage);
    tree.abortBatch();
    try std.testing.expect(tree.snapshot_storage.? == storage);
}

test "error surface is deterministic and replaces authored content" {
    var tree: Tree = .{ .allocator = std.testing.allocator };
    defer tree.deinit();
    _ = try tree.createNode(.canvas);
    tree.showError("render failed\nnode capacity exhausted: max_nodes=1024, asked for 1025");
    try std.testing.expectEqual(@as(usize, 2), tree.nodeCount());
    try std.testing.expectEqual(@as(NodeId, 1), tree.root.?);
    try std.testing.expectEqual(Kind.column, (try tree.nodeConst(1)).kind);
    try std.testing.expectEqual(Kind.text, (try tree.nodeConst(2)).kind);
    try std.testing.expectEqualStrings(
        "render failed\nnode capacity exhausted: max_nodes=1024, asked for 1025",
        (try tree.nodeConst(2)).textSlice(),
    );
}

test "canvas ancestor violations name clipping and opacity separately" {
    var tree: Tree = .{};
    const root = try tree.createNode(.column);
    const opacity = try tree.createNode(.panel);
    const canvas = try tree.createNode(.canvas);
    try tree.setOverflowHidden(root, true);
    try tree.appendChild(root, opacity);
    try tree.appendChild(opacity, canvas);
    const clipped = tree.canvasAncestorViolation().?;
    try std.testing.expectEqual(canvas, clipped.canvas_id);
    try std.testing.expectEqual(root, clipped.ancestor_id);
    try std.testing.expectEqual(.clip, clipped.reason);
    try tree.setOverflowHidden(root, false);
    try tree.setNumberProp(opacity, "opacity", 0.5);
    const faded = tree.canvasAncestorViolation().?;
    try std.testing.expectEqual(opacity, faded.ancestor_id);
    try std.testing.expectEqual(.opacity, faded.reason);
}

test "interaction style storage stays fixed per occupied node" {
    try std.testing.expectEqual(@as(usize, 104), @sizeOf(InteractionStyle));
    try std.testing.expectEqual(@as(usize, 208), @sizeOf(InteractionStyle) * 2);
}

test "tree stores styling breadth layout wire properties" {
    var tree: Tree = .{};
    const id = try tree.createNode(.stack);
    try std.testing.expectEqual(CrossAlign.stretch, (try tree.nodeConst(id)).cross_align);
    try tree.setNumberProp(id, "paddingTop", 0);
    try tree.setNumberProp(id, "paddingRight", 12);
    try tree.setNumberProp(id, "marginLeft", -8);
    try tree.setNumberProp(id, "minWidth", 40);
    try tree.setNumberProp(id, "maxHeight", 120);
    try tree.setNumberProp(id, "widthPercent", 50);
    try tree.setNumberProp(id, "aspectRatio", 4.0 / 3.0);
    try tree.setNumberProp(id, "width", 0);
    try tree.setNumberProp(id, "maxWidth", 0);
    try tree.setNumberProp(id, "shrink", 0);
    try tree.setNumberProp(id, "radiusTopLeft", 14);
    try tree.setNumberProp(id, "radiusBottomRight", 2);
    try tree.setNumberProp(id, "borderWidth", 1);
    try tree.setNumberProp(id, "lineHeight", 1.25);
    try tree.setNumberProp(id, "letterSpacing", -0.5);
    try tree.setNumberProp(id, "lineClamp", 3);
    const border = native_sdk.canvas.Color.rgba8(229, 231, 235, 255);
    try tree.setBorderColor(id, border);
    try tree.setInteractionColor(id, "hoverBackground", native_sdk.canvas.Color.rgba8(10, 20, 30, 255));
    try tree.setInteractionColor(id, "hoverTextColor", native_sdk.canvas.Color.rgba8(240, 240, 240, 255));
    try tree.setNumberProp(id, "hoverOpacity", 0.75);
    try tree.setInteractionColor(id, "pressedBorderColor", native_sdk.canvas.Color.rgba8(1, 2, 3, 255));
    try tree.setNumberProp(id, "pressedOpacity", 0.5);
    try tree.setHandler(id, "doublepress", true);
    try tree.setHandler(id, "rightpress", true);
    try tree.setMainAlign(id, "evenly");
    try tree.setAlignSelf(id, "stretch");
    try tree.setFlexWrap(id, true);
    try tree.setTextAlign(id, "center");
    try tree.setFontFamily(id, "CozetteVector");
    try tree.setTabularNums(id, true);
    const shadow_color = native_sdk.canvas.Color.rgba8(1, 2, 3, 64);
    try tree.setShadow(id, .{ .offset = .{ .dx = 2, .dy = 3 }, .blur = 8, .spread = -1, .color = shadow_color });
    try tree.setShadowInset(id, true);
    try tree.setInteractionShadow(id, "hoverShadow", .{ .offset = .{ .dy = 2 }, .blur = 4, .color = shadow_color }, true);
    try tree.setInteractionShadowInset(id, "hoverShadowInset", true);
    try tree.setInteractionShadow(id, "pressedShadow", null, true);
    try tree.setTextShadow(id, .{ .offset = .{ .dx = 1, .dy = 2 }, .blur = 4, .color = shadow_color });
    try tree.setOverflowHidden(id, true);
    const node = try tree.nodeConst(id);
    try std.testing.expectEqual(Kind.stack, node.kind);
    try std.testing.expectEqual(@as(f32, 0), node.padding_top);
    try std.testing.expectEqual(@as(f32, 12), node.padding_right);
    try std.testing.expectEqual(@as(f32, -8), node.margin_left);
    try std.testing.expectEqual(@as(f32, 40), node.min_width);
    try std.testing.expectEqual(@as(f32, 120), node.max_height);
    try std.testing.expectEqual(@as(f32, 50), node.width_percent);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0 / 3.0), node.aspect_ratio, 0.0001);
    try std.testing.expectEqual(@as(f32, 0), node.width);
    try std.testing.expectEqual(@as(f32, 0), node.max_width);
    try std.testing.expectEqual(@as(f32, 0), node.shrink);
    try std.testing.expectEqual(@as(f32, 14), node.radius_top_left);
    try std.testing.expectEqual(@as(f32, 2), node.radius_bottom_right);
    try std.testing.expectEqual(@as(f32, 1), node.border_width);
    try std.testing.expectEqual(@as(f32, 1.25), node.line_height);
    try std.testing.expectEqual(@as(f32, -0.5), node.letter_spacing);
    try std.testing.expectEqual(@as(f32, 3), node.line_clamp);
    try std.testing.expectEqualDeep(border, node.border_color.?);
    try std.testing.expectEqual(@as(f32, 0.75), node.hover_style.opacity);
    try std.testing.expectEqual(@as(f32, 0.5), node.pressed_style.opacity);
    try std.testing.expect(!node.hover_style.isEmpty());
    try std.testing.expect(node.handles_double_press);
    try std.testing.expect(node.handles_right_press);
    try std.testing.expectEqual(MainAlign.evenly, node.main_align);
    try std.testing.expectEqual(SelfAlign.stretch, node.align_self);
    try std.testing.expect(node.flex_wrap);
    try std.testing.expectEqual(TextAlign.center, node.text_align);
    try std.testing.expectEqualStrings("CozetteVector", node.fontFamilySlice());
    try std.testing.expect(node.tabular_nums);
    try std.testing.expectEqual(@as(f32, 2), node.shadow.?.offset.dx);
    try std.testing.expectEqual(@as(f32, -1), node.shadow.?.spread);
    try std.testing.expect(node.shadow_inset);
    try std.testing.expect(node.hover_style.shadow_set);
    try std.testing.expectEqual(@as(f32, 4), node.hover_style.shadow.?.blur);
    try std.testing.expect(node.hover_style.shadow_inset);
    try std.testing.expect(node.pressed_style.shadow_set);
    try std.testing.expect(node.pressed_style.shadow == null);
    try std.testing.expectEqual(@as(f32, 4), node.text_shadow.?.blur);
    try std.testing.expect(node.overflow_hidden);
    try tree.setNumberProp(id, "paddingTop", -1);
    try std.testing.expectEqual(@as(f32, -1), (try tree.nodeConst(id)).padding_top);
}

test "icon path has an independent 8192-byte budget and parsed viewBox" {
    var tree: Tree = .{ .allocator = std.testing.allocator };
    defer tree.deinit();
    const id = try tree.createNode(.icon);
    const at_limit = [_]u8{'M'} ** max_icon_path_bytes;
    try tree.setIconPath(id, &at_limit);
    try std.testing.expectEqual(max_icon_path_bytes, (try tree.nodeConst(id)).iconPathSlice().len);
    const over_limit = [_]u8{'M'} ** (max_icon_path_bytes + 1);
    try std.testing.expectError(error.IconPathTooLong, tree.setIconPath(id, &over_limit));
    try tree.setIconViewBox(id, "-2.5 1 32 16");
    try std.testing.expectEqual(native_sdk.geometry.RectF.init(-2.5, 1, 32, 16), (try tree.nodeConst(id)).icon_view_box);
    try std.testing.expectError(error.InvalidProperty, tree.setIconViewBox(id, "0 0 24 0"));
}

test "rare icon paths do not grow every retained node" {
    // Later styling layers may add compact common fields, but restoring the
    // 8 KiB inline path buffer must always trip this bound.
    try std.testing.expect(@sizeOf(Node) < max_icon_path_bytes / 2);

    var tree: Tree = .{ .allocator = std.testing.allocator };
    defer tree.deinit();
    const first = try tree.createNode(.icon);
    const second = try tree.createNode(.icon);
    try tree.setIconPath(first, "M 0 0 L 24 24");
    try tree.setIconPath(second, "M 24 0 L 0 24");
    try tree.removeNode(first);
    try std.testing.expectEqualStrings("M 24 0 L 0 24", (try tree.nodeConst(second)).iconPathSlice());
}

test "canvas wire decodes packed colors and polyline points" {
    var tree: Tree = .{};
    const id = try tree.createNode(.canvas);
    try tree.setNumberProp(id, "width", 64);
    try tree.setNumberProp(id, "height", 32);
    const wire = [_]f64{
        0,          0x11223344,
        1,          1,
        2,          3,
        4,          0xff00ffff,
        5,          2,
        0xffffffff, 3,
        0,          0,
        4,          8,
        9,          3,
    };
    const retained_generation = tree.generation;
    const canvas_generation = tree.canvas_generation;
    try tree.setCanvasCommands(id, &wire);
    try std.testing.expectEqual(retained_generation, tree.generation);
    try std.testing.expectEqual(canvas_generation +% 1, tree.canvas_generation);
    try tree.setCanvasCommands(id, &wire);
    try std.testing.expectEqual(canvas_generation +% 1, tree.canvas_generation);
    const canvas = try tree.canvasStateConst(id);
    try std.testing.expectEqual(@as(usize, 3), canvas.command_count);
    try std.testing.expectEqual(@as(usize, 3), canvas.point_count);
    try std.testing.expectEqual(@as(f32, 64), canvas.commands[0].fill_rect.rect.width);
    try std.testing.expectApproxEqAbs(@as(f32, 0x11) / 255, canvas.commands[0].fill_rect.color.r, 0.0001);
    try std.testing.expectEqual(@as(usize, 3), canvas.commands[2].polyline.points.len);
    try std.testing.expect(try tree.setCanvasLayout(id, 96, 48));
    try std.testing.expect(!(try tree.setCanvasLayout(id, 96, 48)));
    try std.testing.expectEqual(@as(f32, 96), (try tree.canvasStateConst(id)).layout_width);
    try std.testing.expectEqual(@as(f32, 48), (try tree.canvasStateConst(id)).layout_height);
    try tree.setCanvasCommands(id, &wire);
    try std.testing.expectEqual(canvas_generation +% 2, tree.canvas_generation);
    try std.testing.expectEqual(@as(f32, 96), (try tree.canvasStateConst(id)).commands[0].fill_rect.rect.width);
    try std.testing.expectEqual(@as(f32, 48), (try tree.canvasStateConst(id)).commands[0].fill_rect.rect.height);
}

test "canvas command budget is shared across every canvas in the view" {
    var tree: Tree = .{};
    const first = try tree.createNode(.canvas);
    const second = try tree.createNode(.canvas);
    const values_per_rect = 6;
    const wire = try std.testing.allocator.alloc(f64, max_canvas_commands * values_per_rect);
    defer std.testing.allocator.free(wire);
    for (0..max_canvas_commands) |index| {
        const command = wire[index * values_per_rect ..][0..values_per_rect];
        command.* = .{ 1, 0, 0, 1, 1, 0xffffffff };
    }
    try tree.setCanvasCommands(first, wire);
    try std.testing.expectError(
        error.CanvasCommandLimit,
        tree.setCanvasCommands(second, &.{ 1, 0, 0, 1, 1, 0xffffffff }),
    );
}

test "a failed canvas batch preserves the last good frame and shared budget" {
    var tree: Tree = .{};
    const first = try tree.createNode(.canvas);
    const second = try tree.createNode(.canvas);
    try tree.setCanvasCommands(first, &.{ 1, 7, 8, 9, 10, 0xffffffff });
    const original_fingerprint = (try tree.canvasStateConst(first)).fingerprint;

    // The first command is valid, but the following polyline declares three
    // points and supplies only one. The old single-command frame must remain
    // intact rather than becoming this partial prefix.
    try std.testing.expectError(
        error.InvalidCanvasBatch,
        tree.setCanvasCommands(first, &.{ 1, 99, 98, 97, 96, 0xff0000ff, 5, 1, 0xffffffff, 3, 0, 0 }),
    );
    const preserved = try tree.canvasStateConst(first);
    try std.testing.expectEqual(@as(usize, 1), preserved.command_count);
    try std.testing.expectEqual(@as(usize, 0), preserved.point_count);
    try std.testing.expectEqual(original_fingerprint, preserved.fingerprint);
    try std.testing.expectEqual(@as(f32, 7), preserved.commands[0].fill_rect.rect.x);

    // Failed work contributes nothing to the per-view budget.
    try tree.setCanvasCommands(second, &.{ 1, 0, 0, 1, 1, 0xffffffff });
    try std.testing.expectEqual(@as(usize, 1), (try tree.canvasStateConst(second)).command_count);
}

test "asset source paths are bounded, allocate exactly, and survive transaction snapshots" {
    var tree: Tree = .{ .allocator = std.testing.allocator };
    defer tree.deinit();
    const image = try tree.createNode(.image);
    const long_source = [_]u8{'a'} ** max_source_bytes;
    try tree.setSource(image, &long_source);
    try tree.beginBatch();
    try tree.setSource(image, "replacement.png");
    tree.abortBatch();
    try std.testing.expectEqualStrings(&long_source, (try tree.nodeConst(image)).sourceSlice());
    const over_limit = [_]u8{'b'} ** (max_source_bytes + 1);
    try std.testing.expectError(error.TextTooLong, tree.setSource(image, &over_limit));
}
