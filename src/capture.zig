/// Cross-platform screen capture interface.
/// Selects the platform implementation at comptime and re-exports its API.
const builtin = @import("builtin");
const types = @import("types");

pub const Display = types.Display;
pub const Window = types.Window;
pub const CaptureTarget = types.CaptureTarget;
pub const CaptureConfig = types.CaptureConfig;
pub const CaptureHandle = types.CaptureHandle;
pub const VideoFrame = types.VideoFrame;
pub const AudioSamples = types.AudioSamples;

const platform = switch (builtin.os.tag) {
    .macos => @import("platform/macos/screen.zig"),
    .windows => @import("platform/windows/screen.zig"),
    .linux => @import("platform/linux/screen.zig"),
    else => @compileError("Unsupported platform"),
};

pub fn listDisplays(allocator: @import("std").mem.Allocator) ![]Display {
    return platform.listDisplays(allocator);
}

pub fn listWindows(allocator: @import("std").mem.Allocator) ![]Window {
    return platform.listWindows(allocator);
}

pub fn startCapture(
    target: CaptureTarget,
    config: CaptureConfig,
    frame_cb: *const fn (VideoFrame) void,
    audio_cb: ?*const fn (AudioSamples) void,
) !CaptureHandle {
    return platform.startCapture(target, config, frame_cb, audio_cb);
}

pub fn stopCapture(handle: CaptureHandle) void {
    platform.stopCapture(handle);
}

pub fn listMicDevices(allocator: @import("std").mem.Allocator) ![]@import("types").MicDevice {
    return platform.listMicDevices(allocator);
}

pub fn startMicCapture(sample_cb: *const fn (AudioSamples) void, device_name: ?[*:0]const u8) !void {
    return platform.startMicCapture(sample_cb, device_name);
}

pub fn stopMicCapture() void {
    platform.stopMicCapture();
}

pub const ImageFormat = types.ImageFormat;

pub fn captureScreenshot(
    target: CaptureTarget,
    config: CaptureConfig,
    output_path: [*:0]const u8,
    format: ImageFormat,
) !void {
    return platform.captureScreenshot(target, config, output_path, format);
}
