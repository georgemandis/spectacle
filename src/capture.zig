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
