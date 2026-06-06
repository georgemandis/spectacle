/// Cross-platform encoding/muxing interface.
/// Selects the platform implementation at comptime and re-exports its API.
const builtin = @import("builtin");
const types = @import("types");

pub const VideoFrame = types.VideoFrame;
pub const AudioSamples = types.AudioSamples;
pub const CaptureConfig = types.CaptureConfig;

const platform = switch (builtin.os.tag) {
    .macos => @import("platform/macos/encoder.zig"),
    .windows => @import("platform/windows/encoder.zig"),
    .linux => @import("platform/linux/encoder.zig"),
    else => @compileError("Unsupported platform"),
};

/// Re-export the platform's Encoder type.
pub const Encoder = platform.Encoder;

pub fn init(format: []const u8, path: []const u8, config: CaptureConfig) !Encoder {
    return platform.init(format, path, config);
}

pub fn writeVideoFrame(encoder: *Encoder, frame: VideoFrame) !void {
    return platform.writeVideoFrame(encoder, frame);
}

pub fn writeAudioSamples(encoder: *Encoder, samples: AudioSamples) !void {
    return platform.writeAudioSamples(encoder, samples);
}

pub fn finalize(encoder: *Encoder) !void {
    return platform.finalize(encoder);
}
