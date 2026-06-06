/// Windows screen capture stub — DXGI Desktop Duplication implementation placeholder.
const std = @import("std");
const types = @import("types");

pub fn listDisplays(allocator: std.mem.Allocator) ![]types.Display {
    _ = allocator;
    return error.Unsupported;
}

pub fn listWindows(allocator: std.mem.Allocator) ![]types.Window {
    _ = allocator;
    return error.Unsupported;
}

pub fn startCapture(
    target: types.CaptureTarget,
    config: types.CaptureConfig,
    frame_cb: *const fn (types.VideoFrame) void,
    audio_cb: ?*const fn (types.AudioSamples) void,
) !types.CaptureHandle {
    _ = target;
    _ = config;
    _ = frame_cb;
    _ = audio_cb;
    return error.Unsupported;
}

pub fn stopCapture(handle: types.CaptureHandle) void {
    _ = handle;
}
