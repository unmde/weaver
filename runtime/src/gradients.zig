const std = @import("std");
const native_sdk = @import("native_sdk");

pub const max_layers: usize = 8;
pub const max_stops: usize = 64;
pub const max_mesh_patches: usize = native_sdk.runtime.max_canvas_mesh_patches_per_view;
pub const max_wire_bytes: usize = 16 * 1024;
const max_coordinate: f32 = 1_000_000;

const WireStop = struct {
    offset: f32,
    color: []const u8,
};

const WirePatch = struct {
    points: [16][2]f32,
    colors: [4][]const u8,
};

const WireLayer = struct {
    kind: []const u8,
    start: ?[2]f32 = null,
    end: ?[2]f32 = null,
    center: ?[2]f32 = null,
    radii: ?[2]f32 = null,
    from_degrees: ?f32 = null,
    stops: []const WireStop = &.{},
    spread: []const u8 = "pad",
    interpolation: []const u8 = "srgb_linear",
    patches: []const WirePatch = &.{},
};

const WireDocument = struct {
    v: u8,
    layers: []const WireLayer,
};

pub fn validate(bytes: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    _ = try decode(arena_state.allocator(), bytes);
}

/// Decode the canonical SDK wire document into frame-arena retained metadata.
/// Coordinates stay normalized until Native lays out the widget.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) ![]const native_sdk.canvas.ImmediateCanvasCommand {
    if (bytes.len == 0) return &.{};
    if (bytes.len > max_wire_bytes) return error.GradientTooLong;
    const document = try std.json.parseFromSliceLeaky(WireDocument, allocator, bytes, .{ .ignore_unknown_fields = false });
    if (document.v != 1 or document.layers.len == 0 or document.layers.len > max_layers) return error.InvalidGradient;

    const commands = try allocator.alloc(native_sdk.canvas.ImmediateCanvasCommand, document.layers.len);
    var stop_count: usize = 0;
    var mesh_patch_count: usize = 0;
    for (document.layers, commands, 0..) |layer, *command, layer_index| {
        const interpolation = parseInterpolation(layer.interpolation) orelse return error.InvalidGradient;
        if (std.mem.eql(u8, layer.kind, "mesh")) {
            if (layer.patches.len == 0 or mesh_patch_count + layer.patches.len > max_mesh_patches) return error.InvalidGradient;
            mesh_patch_count += layer.patches.len;
            const patches = try allocator.alloc(native_sdk.canvas.WidgetMeshPatch, layer.patches.len);
            for (layer.patches, patches) |source, *destination| {
                for (source.points, 0..) |source_point, point_index| {
                    destination.points[point_index] = try parsePoint(source_point);
                }
                for (source.colors, 0..) |source_color, color_index| {
                    destination.colors[color_index] = parseColor(source_color) orelse return error.InvalidGradient;
                }
            }
            command.* = .{ .background_mesh_gradient = .{
                .patches = patches,
                .interpolation = interpolation,
            } };
            continue;
        }

        if (layer.stops.len < 2 or stop_count + layer.stops.len > max_stops) return error.InvalidGradient;
        stop_count += layer.stops.len;
        const stops = try allocator.alloc(native_sdk.canvas.GradientStop, layer.stops.len);
        for (layer.stops, stops) |source, *destination| {
            if (!finite(source.offset)) return error.InvalidGradient;
            destination.* = .{
                .offset = source.offset,
                .color = parseColor(source.color) orelse return error.InvalidGradient,
            };
        }
        const spread = parseSpread(layer.spread) orelse return error.InvalidGradient;
        if (std.mem.eql(u8, layer.kind, "linear")) {
            command.* = .{ .background_gradient = .{ .linear = .{
                .start = try parsePoint(layer.start orelse return error.InvalidGradient),
                .end = try parsePoint(layer.end orelse return error.InvalidGradient),
                .stops = stops,
                .spread = spread,
                .interpolation = interpolation,
            } } };
        } else if (std.mem.eql(u8, layer.kind, "radial")) {
            const radii = try parsePoint(layer.radii orelse return error.InvalidGradient);
            if (radii.x <= 0 or radii.y <= 0) return error.InvalidGradient;
            command.* = .{ .background_gradient = .{ .radial = .{
                .center = try parsePoint(layer.center orelse return error.InvalidGradient),
                .radii = .{ .width = radii.x, .height = radii.y },
                .stops = stops,
                .spread = spread,
                .interpolation = interpolation,
            } } };
        } else if (std.mem.eql(u8, layer.kind, "conic")) {
            const degrees = layer.from_degrees orelse return error.InvalidGradient;
            if (!finite(degrees)) return error.InvalidGradient;
            command.* = .{
                .background_gradient = .{
                    .conic = .{
                        .center = try parsePoint(layer.center orelse return error.InvalidGradient),
                        // SDK authoring follows CSS: zero at twelve o'clock and
                        // positive clockwise. Native is zero at +x in y-down space.
                        .start_angle_radians = degrees * @as(f32, std.math.pi) / 180.0 - @as(f32, std.math.pi) / 2.0,
                        .stops = stops,
                        .spread = spread,
                        .interpolation = interpolation,
                    },
                },
            };
        } else {
            std.log.err("gradient layer {d} has unknown kind '{s}'", .{ layer_index, layer.kind });
            return error.InvalidGradient;
        }
    }
    return commands;
}

fn parsePoint(value: [2]f32) !native_sdk.geometry.PointF {
    if (!finite(value[0]) or !finite(value[1])) return error.InvalidGradient;
    return native_sdk.geometry.PointF.init(value[0], value[1]);
}

fn finite(value: f32) bool {
    return std.math.isFinite(value) and @abs(value) <= max_coordinate;
}

fn parseSpread(value: []const u8) ?native_sdk.canvas.GradientSpread {
    if (std.mem.eql(u8, value, "pad")) return .pad;
    if (std.mem.eql(u8, value, "repeat")) return .repeat;
    if (std.mem.eql(u8, value, "reflect")) return .reflect;
    return null;
}

fn parseInterpolation(value: []const u8) ?native_sdk.canvas.GradientInterpolation {
    if (std.mem.eql(u8, value, "srgb")) return .srgb;
    if (std.mem.eql(u8, value, "srgb_linear")) return .srgb_linear;
    if (std.mem.eql(u8, value, "oklab")) return .oklab;
    return null;
}

fn parseColor(value: []const u8) ?native_sdk.canvas.Color {
    if (value.len != 9 or value[0] != '#') return null;
    const red = std.fmt.parseInt(u8, value[1..3], 16) catch return null;
    const green = std.fmt.parseInt(u8, value[3..5], 16) catch return null;
    const blue = std.fmt.parseInt(u8, value[5..7], 16) catch return null;
    const alpha = std.fmt.parseInt(u8, value[7..9], 16) catch return null;
    return native_sdk.canvas.Color.rgba8(red, green, blue, alpha);
}

test "decodes layered conic and mesh backgrounds into retained metadata" {
    const source =
        \\{"v":1,"layers":[{"kind":"conic","center":[0.5,0.5],"from_degrees":90,"stops":[{"offset":0,"color":"#FF0000FF"},{"offset":1,"color":"#0000FFFF"}],"spread":"repeat","interpolation":"oklab"},{"kind":"mesh","patches":[{"points":[[0,0],[0.33,0],[0.66,0],[1,0],[0,0.33],[0.33,0.33],[0.66,0.33],[1,0.33],[0,0.66],[0.33,0.66],[0.66,0.66],[1,0.66],[0,1],[0.33,1],[0.66,1],[1,1]],"colors":["#FF0000FF","#00FF00FF","#0000FFFF","#FFFFFFFF"]}],"interpolation":"srgb_linear"}]}
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const commands = try decode(arena_state.allocator(), source);
    try std.testing.expectEqual(@as(usize, 2), commands.len);
    switch (commands[0]) {
        .background_gradient => |gradient| switch (gradient) {
            .conic => |conic| {
                try std.testing.expectApproxEqAbs(@as(f32, 0), conic.start_angle_radians, 0.0001);
                try std.testing.expectEqual(native_sdk.canvas.GradientSpread.repeat, conic.spread);
                try std.testing.expectEqual(native_sdk.canvas.GradientInterpolation.oklab, conic.interpolation);
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
    switch (commands[1]) {
        .background_mesh_gradient => |mesh| try std.testing.expectEqual(@as(usize, 1), mesh.patches.len),
        else => return error.TestUnexpectedResult,
    }
}

test "rejects non-positive radial radii before retained mutation" {
    const invalid_documents = [_][]const u8{
        \\{"v":1,"layers":[{"kind":"radial","center":[0.5,0.5],"radii":[0,1],"stops":[{"offset":0,"color":"#FF0000FF"},{"offset":1,"color":"#0000FFFF"}]}]}
        ,
        \\{"v":1,"layers":[{"kind":"radial","center":[0.5,0.5],"radii":[1,-1],"stops":[{"offset":0,"color":"#FF0000FF"},{"offset":1,"color":"#0000FFFF"}]}]}
        ,
    };
    for (invalid_documents) |source| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        try std.testing.expectError(error.InvalidGradient, decode(arena_state.allocator(), source));
    }
}
