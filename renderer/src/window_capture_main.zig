const std = @import("std");

extern fn weaver_window_capture_run() callconv(.c) c_int;

pub fn main() !void {
    if (weaver_window_capture_run() != 0) {
        return error.WindowCaptureFailed;
    }
}
