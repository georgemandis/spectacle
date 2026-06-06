pub const version = "0.1.0";

// ---------------------------------------------------------------------------
// Discovery result types
// ---------------------------------------------------------------------------

pub const Display = struct {
    index: u32, // ordinal (0 = primary)
    name: ?[*:0]const u8, // display name if available
    width: u32,
    height: u32,
    platform_id: u64, // opaque platform display ID
};

pub const Window = struct {
    title: ?[*:0]const u8,
    app_name: ?[*:0]const u8,
    pid: u32,
    window_id: u64, // opaque platform window ID
    display_index: u32,
};

pub const AudioSource = struct {
    name: ?[*:0]const u8, // e.g. "Spotify", "System Audio"
    pid: u32, // 0 for system-wide
    source_id: u64, // opaque platform source ID
};

// ---------------------------------------------------------------------------
// Target types
// ---------------------------------------------------------------------------

pub const CaptureTarget = union(enum) {
    display: u32, // display index
    window_id: u64, // from Window.window_id
    window_title: [*:0]const u8, // substring match
    window_pid: u32, // by PID
    region: struct { x: u32, y: u32, w: u32, h: u32, display: u32 },
};

pub const AudioTarget = union(enum) {
    system: void, // all system audio
    app_name: [*:0]const u8,
    pid: u32,
};

// ---------------------------------------------------------------------------
// Configuration structs
// ---------------------------------------------------------------------------

pub const CaptureConfig = struct {
    fps: u32 = 30,
    scale: f32 = 1.0,
    capture_audio: bool = true,
    show_cursor: bool = true,
    sample_rate: u32 = 48000,
    channels: u32 = 2,
};

pub const AudioConfig = struct {
    sample_rate: u32 = 48000,
    channels: u32 = 2,
};

// ---------------------------------------------------------------------------
// Handle / frame / samples
// ---------------------------------------------------------------------------

/// Opaque handle returned by startCapture. Platform-specific internals.
pub const CaptureHandle = struct {
    platform_handle: *anyopaque,
};

/// Cross-platform video frame delivered via callback.
/// Platforms convert their native format (CMSampleBuffer, DXGI texture,
/// PipeWire buffer) into this common representation before invoking the callback.
pub const VideoFrame = struct {
    data: [*]const u8, // pixel data (BGRA, 8 bits per channel)
    len: usize, // byte length of data
    width: u32,
    height: u32,
    bytes_per_row: u32, // stride (may include padding)
    timestamp_ns: u64, // presentation timestamp in nanoseconds
};

/// Cross-platform audio samples delivered via callback.
pub const AudioSamples = struct {
    data: [*]const f32, // interleaved float32 PCM
    frame_count: u32, // number of frames (samples per channel)
    channels: u32,
    sample_rate: u32,
    timestamp_ns: u64,
};

// ---------------------------------------------------------------------------
// Error set
// ---------------------------------------------------------------------------

pub const CaptureError = error{
    PermissionDenied,
    TargetNotFound,
    BackendInitFailed,
    EncoderFailed,
    WriteFailed,
    Unsupported,
};

// ---------------------------------------------------------------------------
// Exit codes
// ---------------------------------------------------------------------------

pub const ExitCode = enum(u8) {
    success = 0,
    invalid_args = 1,
    target_not_found = 2,
    permission_denied = 3,
    runtime_error = 4,
    unsupported_format = 5,
};
