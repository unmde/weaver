const std = @import("std");

extern fn native_sdk_d3d_presenter_tests() callconv(.c) c_int;

test "D3D presenter decodes bounded gradients and compiles both shaders" {
    try std.testing.expectEqual(@as(c_int, 0), native_sdk_d3d_presenter_tests());
}
