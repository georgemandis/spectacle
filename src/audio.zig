/// Cross-platform audio capture interface.
/// Selects the platform implementation at comptime and re-exports its API.
const builtin = @import("builtin");
const types = @import("types");

pub const AudioSource = types.AudioSource;
pub const AudioTarget = types.AudioTarget;
pub const AudioConfig = types.AudioConfig;
pub const CaptureHandle = types.CaptureHandle;
pub const AudioSamples = types.AudioSamples;

const platform = switch (builtin.os.tag) {
    .macos => @import("platform/macos/audio.zig"),
    .windows => @import("platform/windows/audio.zig"),
    .linux => @import("platform/linux/audio.zig"),
    else => @compileError("Unsupported platform"),
};

pub fn listSources(allocator: @import("std").mem.Allocator) ![]AudioSource {
    return platform.listSources(allocator);
}

pub fn startCapture(
    target: AudioTarget,
    config: AudioConfig,
    sample_cb: *const fn (AudioSamples) void,
) !CaptureHandle {
    return platform.startCapture(target, config, sample_cb);
}

pub fn stopCapture(handle: CaptureHandle) void {
    platform.stopCapture(handle);
}
