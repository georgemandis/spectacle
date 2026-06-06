/// C ABI exports for the spectacle shared/static library.
/// Enables FFI consumers (Bun, Node, Rust, Python) to use spectacle
/// for real-time screen and audio capture with callback delivery.
const std = @import("std");
const capture = @import("capture");
const audio = @import("audio");
const encoder = @import("encoder");
const types = @import("types");

const c_allocator = std.heap.c_allocator;

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

/// List available displays. Returns null on error.
/// Caller must free with spectacle_free_displays(ptr, count).
pub export fn spectacle_list_displays(out_count: *u32) ?[*]types.Display {
    const displays = capture.listDisplays(c_allocator) catch return null;
    out_count.* = @intCast(displays.len);
    return displays.ptr;
}

pub export fn spectacle_free_displays(ptr: ?[*]types.Display, count: u32) void {
    if (ptr) |p| {
        c_allocator.free(p[0..count]);
    }
}

/// List available windows. Returns null on error.
/// Caller must free with spectacle_free_windows(ptr, count).
pub export fn spectacle_list_windows(out_count: *u32) ?[*]types.Window {
    const windows = capture.listWindows(c_allocator) catch return null;
    out_count.* = @intCast(windows.len);
    return windows.ptr;
}

pub export fn spectacle_free_windows(ptr: ?[*]types.Window, count: u32) void {
    if (ptr) |p| {
        c_allocator.free(p[0..count]);
    }
}

/// List available audio sources. Returns null on error.
/// Caller must free with spectacle_free_audio_sources(ptr, count).
pub export fn spectacle_list_audio_sources(out_count: *u32) ?[*]types.AudioSource {
    const sources = audio.listSources(c_allocator) catch return null;
    out_count.* = @intCast(sources.len);
    return sources.ptr;
}

pub export fn spectacle_free_audio_sources(ptr: ?[*]types.AudioSource, count: u32) void {
    if (ptr) |p| {
        c_allocator.free(p[0..count]);
    }
}

// ---------------------------------------------------------------------------
// Screen capture — opaque handle type
// ---------------------------------------------------------------------------

/// Opaque heap-allocated handle for active screen captures.
const ScreenCaptureState = struct {
    handle: types.CaptureHandle,
};

/// Start screen capture. Returns an opaque handle, or null on error.
/// target_tag: 0=display, 1=window_id, 2=window_title, 3=window_pid, 4=region
/// Stop with spectacle_capture_stop(handle).
pub export fn spectacle_capture_start(
    display_index: u32,
    fps: u32,
    scale: f32,
    capture_audio_flag: bool,
    frame_callback: *const fn (types.VideoFrame) callconv(.c) void,
    audio_callback: ?*const fn (types.AudioSamples) callconv(.c) void,
) ?*ScreenCaptureState {
    const target = types.CaptureTarget{ .display = display_index };
    const config = types.CaptureConfig{
        .fps = fps,
        .scale = scale,
        .capture_audio = capture_audio_flag,
    };
    // Wrap C callbacks — calling convention already matches for simple cases
    const frame_cb: *const fn (types.VideoFrame) void = @ptrCast(frame_callback);
    const audio_cb: ?*const fn (types.AudioSamples) void = if (audio_callback) |cb| @ptrCast(cb) else null;

    const handle = capture.startCapture(target, config, frame_cb, audio_cb) catch return null;
    const state = c_allocator.create(ScreenCaptureState) catch return null;
    state.* = .{ .handle = handle };
    return state;
}

pub export fn spectacle_capture_stop(state: ?*ScreenCaptureState) void {
    if (state) |s| {
        capture.stopCapture(s.handle);
        c_allocator.destroy(s);
    }
}

// ---------------------------------------------------------------------------
// Audio capture
// ---------------------------------------------------------------------------

const AudioCaptureState = struct {
    handle: types.CaptureHandle,
};

pub export fn spectacle_audio_start(
    sample_rate: u32,
    channels: u32,
    sample_callback: *const fn (types.AudioSamples) callconv(.c) void,
) ?*AudioCaptureState {
    const target = types.AudioTarget{ .system = {} };
    const config = types.AudioConfig{
        .sample_rate = sample_rate,
        .channels = channels,
    };
    const sample_cb: *const fn (types.AudioSamples) void = @ptrCast(sample_callback);
    const handle = audio.startCapture(target, config, sample_cb) catch return null;
    const state = c_allocator.create(AudioCaptureState) catch return null;
    state.* = .{ .handle = handle };
    return state;
}

pub export fn spectacle_audio_stop(state: ?*AudioCaptureState) void {
    if (state) |s| {
        audio.stopCapture(s.handle);
        c_allocator.destroy(s);
    }
}

// ---------------------------------------------------------------------------
// Encoder
// ---------------------------------------------------------------------------

const EncoderState = struct {
    enc: encoder.Encoder,
};

/// Create an encoder. format and path are null-terminated C strings.
/// Returns null on error. Free with spectacle_encoder_finalize.
pub export fn spectacle_encoder_create(
    format: [*:0]const u8,
    path: [*:0]const u8,
    fps: u32,
    scale: f32,
) ?*EncoderState {
    const fmt_slice = std.mem.sliceTo(format, 0);
    const path_slice = std.mem.sliceTo(path, 0);
    const config = types.CaptureConfig{ .fps = fps, .scale = scale };
    const enc = encoder.init(fmt_slice, path_slice, config) catch return null;
    const state = c_allocator.create(EncoderState) catch return null;
    state.* = .{ .enc = enc };
    return state;
}

/// Write a video frame. Returns 0 on success, -1 on error.
pub export fn spectacle_encoder_write_video(state: ?*EncoderState, frame: *const types.VideoFrame) i32 {
    const s = state orelse return -1;
    encoder.writeVideoFrame(&s.enc, frame.*) catch return -1;
    return 0;
}

/// Write audio samples. Returns 0 on success, -1 on error.
pub export fn spectacle_encoder_write_audio(state: ?*EncoderState, samples: *const types.AudioSamples) i32 {
    const s = state orelse return -1;
    encoder.writeAudioSamples(&s.enc, samples.*) catch return -1;
    return 0;
}

/// Finalize the encoder and free the handle. Returns 0 on success, -1 on error.
pub export fn spectacle_encoder_finalize(state: ?*EncoderState) i32 {
    const s = state orelse return -1;
    defer c_allocator.destroy(s);
    encoder.finalize(&s.enc) catch return -1;
    return 0;
}
