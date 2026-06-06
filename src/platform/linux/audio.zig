/// Linux audio capture stub — PipeWire audio implementation placeholder.
const std = @import("std");
const types = @import("types");

pub fn listSources(allocator: std.mem.Allocator) ![]types.AudioSource {
    _ = allocator;
    return error.Unsupported;
}

pub fn startCapture(
    target: types.AudioTarget,
    config: types.AudioConfig,
    sample_cb: *const fn (types.AudioSamples) void,
) !types.CaptureHandle {
    _ = target;
    _ = config;
    _ = sample_cb;
    return error.Unsupported;
}

pub fn stopCapture(handle: types.CaptureHandle) void {
    _ = handle;
}
