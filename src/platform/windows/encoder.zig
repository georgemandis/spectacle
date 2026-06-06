/// Windows encoder stub — raw frames + WAV implementation placeholder.
const std = @import("std");
const types = @import("types");

pub const Encoder = struct {
    _unused: u8 = 0,
};

pub fn init(format: []const u8, path: []const u8, config: types.CaptureConfig) !Encoder {
    _ = format;
    _ = path;
    _ = config;
    return error.Unsupported;
}

pub fn writeVideoFrame(encoder: *Encoder, frame: types.VideoFrame) !void {
    _ = encoder;
    _ = frame;
    return error.Unsupported;
}

pub fn writeAudioSamples(encoder: *Encoder, samples: types.AudioSamples) !void {
    _ = encoder;
    _ = samples;
    return error.Unsupported;
}

pub fn finalize(encoder: *Encoder) !void {
    _ = encoder;
    return error.Unsupported;
}
