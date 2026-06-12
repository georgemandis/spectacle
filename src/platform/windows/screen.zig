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

pub fn listMicDevices(allocator: @import("std").mem.Allocator) ![]types.MicDevice {
    _ = allocator;
    return error.Unsupported;
}

pub fn startMicCapture(sample_cb: *const fn (types.AudioSamples) void, device_name: ?[*:0]const u8) !void {
    _ = sample_cb;
    _ = device_name;
    return error.Unsupported;
}

pub fn stopMicCapture() void {}

pub fn captureScreenshot(
    target: types.CaptureTarget,
    config: types.CaptureConfig,
    output_path: [*:0]const u8,
    format: types.ImageFormat,
) !void {
    _ = target;
    _ = config;
    _ = output_path;
    _ = format;
    return error.Unsupported;
}
