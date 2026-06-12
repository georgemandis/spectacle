const std = @import("std");
const builtin = @import("builtin");
const types = @import("types");
const capture = @import("capture");
const audio_mod = @import("audio");
const encoder_mod = @import("encoder");

const version = types.version;

// C time() for timestamps (Zig 0.16 doesn't have std.time.timestamp)
extern "c" fn time(tloc: ?*isize) isize;
fn cTime(tloc: ?*isize) isize {
    return time(tloc);
}

// C access() for checking file existence
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
fn cAccess(path: [*:0]const u8, mode: c_int) c_int {
    return access(path, mode);
}

// C file I/O for WAV writing
const CFile = opaque {};
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*CFile;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, stream: *CFile) usize;
extern "c" fn fseek(stream: *CFile, offset: c_long, whence: c_int) c_int;
extern "c" fn fclose(stream: *CFile) c_int;

fn printUsage(writer: *std.Io.Writer) !void {
    try writer.print(
        \\Usage: spectacle <command> [options]
        \\
        \\Cross-platform screen and system audio capture CLI.
        \\Version {s} ({s})
        \\
        \\Commands:
        \\  record             Record screen video (and system audio by default)
        \\  audio              Capture system audio only
        \\  screenshot          Take a screenshot (PNG or JPEG)
        \\  list <target>      List displays, windows, or audio-sources
        \\  help               Show this help message
        \\
        \\Options:
        \\  --output FILE      Output file path (format inferred from extension)
        \\  --window NAME      Capture a specific window by title (substring match)
        \\  --pid PID          Capture a specific window by process ID
        \\  --region X,Y,W,H   Capture a screen region
        \\  --display N        Which display to capture (default: 0)
        \\  --no-audio         Video only, suppress audio capture
        \\  --no-cursor        Hide the cursor in the recording
        \\  --mic              Include microphone audio in the recording
        \\  --mic-device NAME  Use a specific microphone (substring match)
        \\  --app NAME         Capture a specific app by name (video + audio)
        \\  --fps N            Frame rate for video capture (default: 30)
        \\  --scale F          Resolution scale factor (default: 1.0)
        \\  --sample-rate N    Audio sample rate in Hz (default: 48000)
        \\  --channels N       Audio channel count (default: 2)
        \\  --json             Structured JSON output
        \\  --help, -h         Show this help message
        \\  --version, -v      Show version
        \\
        \\Examples:
        \\  spectacle record --output demo.mp4
        \\  spectacle record --window "Google Chrome" --output tutorial.mp4
        \\  spectacle record --no-audio --output silent.mp4
        \\  spectacle audio --output meeting.wav
        \\  spectacle audio --app "Spotify" --output music.wav
        \\  spectacle screenshot --output shot.png
        \\  spectacle screenshot --window "Chrome" --output page.png
        \\  spectacle list displays
        \\  spectacle list windows
        \\  spectacle list audio-sources
        \\
        \\Created by George Mandis <george@mand.is>
        \\
    , .{ version, @tagName(builtin.os.tag) });
}

// ---------------------------------------------------------------------------
// Human-readable output formatters
// ---------------------------------------------------------------------------

fn printDisplaysHuman(writer: *std.Io.Writer, displays: []const types.Display) !void {
    try writer.print("Displays:\n", .{});
    if (displays.len == 0) {
        try writer.print("  (none found)\n", .{});
        return;
    }
    for (displays) |d| {
        if (d.name) |name| {
            try writer.print("  [{d}] {s} ({d}x{d})\n", .{ d.index, name, d.width, d.height });
        } else {
            try writer.print("  [{d}] Display {d} ({d}x{d})\n", .{ d.index, d.index, d.width, d.height });
        }
    }
}

fn printWindowsHuman(writer: *std.Io.Writer, windows: []const types.Window) !void {
    try writer.print("Windows:\n", .{});
    if (windows.len == 0) {
        try writer.print("  (none found)\n", .{});
        return;
    }
    for (windows) |w| {
        const title = w.title orelse "(untitled)";
        const app = w.app_name orelse "(unknown)";
        try writer.print("  [{d}] {s} — {s} (pid {d})\n", .{ w.window_id, title, app, w.pid });
    }
}

fn printAudioSourcesHuman(writer: *std.Io.Writer, sources: []const types.AudioSource, mic_devices: []const types.MicDevice) !void {
    try writer.print("Audio Sources:\n", .{});
    if (sources.len == 0) {
        try writer.print("  (none found)\n", .{});
    } else {
        for (sources) |s| {
            const name = s.name orelse "(unnamed)";
            if (s.pid == 0) {
                try writer.print("  [system] {s}\n", .{name});
            } else {
                try writer.print("  [pid {d}] {s}\n", .{ s.pid, name });
            }
        }
    }
    try writer.print("\nMicrophone Devices:\n", .{});
    if (mic_devices.len == 0) {
        try writer.print("  (none found)\n", .{});
    } else {
        for (mic_devices) |dev| {
            const name = if (dev.name) |n| std.mem.sliceTo(n, 0) else "Unknown";
            const marker: []const u8 = if (dev.is_default) " (default)" else "";
            try writer.print("  {s}{s}\n", .{ name, marker });
        }
    }
}

// ---------------------------------------------------------------------------
// JSON output formatters
// ---------------------------------------------------------------------------

fn escapeJsonString(writer: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.print("\\\"", .{}),
            '\\' => try writer.print("\\\\", .{}),
            '\n' => try writer.print("\\n", .{}),
            '\t' => try writer.print("\\t", .{}),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{@as(u16, c)});
                } else {
                    try writer.print("{c}", .{c});
                }
            },
        }
    }
}

fn writeJsonString(writer: *std.Io.Writer, s: ?[*:0]const u8) !void {
    if (s) |str| {
        try writer.print("\"", .{});
        const slice = std.mem.sliceTo(str, 0);
        try escapeJsonString(writer, slice);
        try writer.print("\"", .{});
    } else {
        try writer.print("null", .{});
    }
}

fn printDisplaysJson(writer: *std.Io.Writer, displays: []const types.Display) !void {
    try writer.print("[", .{});
    for (displays, 0..) |d, i| {
        if (i > 0) try writer.print(",", .{});
        try writer.print("{{\"index\":{d},\"name\":", .{d.index});
        try writeJsonString(writer, d.name);
        try writer.print(",\"width\":{d},\"height\":{d},\"platform_id\":{d}}}", .{ d.width, d.height, d.platform_id });
    }
    try writer.print("]\n", .{});
}

fn printWindowsJson(writer: *std.Io.Writer, windows: []const types.Window) !void {
    try writer.print("[", .{});
    for (windows, 0..) |w, i| {
        if (i > 0) try writer.print(",", .{});
        try writer.print("{{\"window_id\":{d},\"title\":", .{w.window_id});
        try writeJsonString(writer, w.title);
        try writer.print(",\"app_name\":", .{});
        try writeJsonString(writer, w.app_name);
        try writer.print(",\"pid\":{d},\"display_index\":{d}}}", .{ w.pid, w.display_index });
    }
    try writer.print("]\n", .{});
}

fn printAudioSourcesJson(writer: *std.Io.Writer, sources: []const types.AudioSource, mic_devices: []const types.MicDevice) !void {
    try writer.print("{{\"audio_sources\":[", .{});
    for (sources, 0..) |s, i| {
        if (i > 0) try writer.print(",", .{});
        try writer.print("{{\"name\":", .{});
        try writeJsonString(writer, s.name);
        try writer.print(",\"pid\":{d},\"source_id\":{d}}}", .{ s.pid, s.source_id });
    }
    try writer.print("],\"mic_devices\":[", .{});
    for (mic_devices, 0..) |dev, i| {
        if (i > 0) try writer.print(",", .{});
        try writer.print("{{\"name\":", .{});
        try writeJsonString(writer, dev.name);
        try writer.print(",\"uid\":", .{});
        try writeJsonString(writer, dev.uid);
        try writer.print(",\"default\":{s}}}", .{if (dev.is_default) "true" else "false"});
    }
    try writer.print("]}}\n", .{});
}

// ---------------------------------------------------------------------------
// Signal handling for graceful Ctrl+C stop
// ---------------------------------------------------------------------------

var should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn installSignalHandler() void {
    // Use C signal() which is simpler and avoids Zig's type-checking on sigaction handler
    _ = cSignal(2, &sigintHandlerC); // SIGINT = 2
    _ = cSignal(15, &sigintHandlerC); // SIGTERM = 15
}

extern "c" fn signal(sig: c_int, handler: *const fn (c_int) callconv(.c) void) ?*const fn (c_int) callconv(.c) void;
fn cSignal(sig: c_int, handler: *const fn (c_int) callconv(.c) void) ?*const fn (c_int) callconv(.c) void {
    return signal(sig, handler);
}

fn sigintHandlerC(_: c_int) callconv(.c) void {
    should_stop.store(true, .release);
}

// ---------------------------------------------------------------------------
// Global encoder pointer for capture callbacks
// ---------------------------------------------------------------------------

var global_encoder: ?*encoder_mod.Encoder = null;
var global_frame_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

fn frameCallback(frame: types.VideoFrame) void {
    if (global_encoder) |enc| {
        encoder_mod.writeVideoFrame(enc, frame) catch {};
        _ = global_frame_count.fetchAdd(1, .monotonic);
    }
}

fn audioCallback(samples: types.AudioSamples) void {
    if (global_encoder) |enc| {
        encoder_mod.writeAudioSamples(enc, samples) catch {};
    }
}

fn micCallback(samples: types.AudioSamples) void {
    if (global_encoder) |enc| {
        encoder_mod.writeMicSamples(enc, samples) catch {};
    }
}

// ---------------------------------------------------------------------------
// WAV audio-only capture globals and callbacks
// ---------------------------------------------------------------------------

var wav_file: ?*CFile = null;
var wav_data_bytes: u64 = 0;
var wav_sample_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

fn noopFrameCallback(_: types.VideoFrame) void {
    // Intentionally discard video frames for audio-only capture
}

fn wavAudioCallback(samples: types.AudioSamples) void {
    const file = wav_file orelse return;
    const total_samples = @as(usize, samples.frame_count) * @as(usize, samples.channels);
    if (total_samples == 0) return;

    // Convert f32 interleaved samples to i16 PCM and write
    // Use a stack buffer; 8192 samples * 2 bytes = 16KB per chunk
    const chunk_size = 8192;
    var pcm_buf: [chunk_size * 2]u8 = undefined;

    var offset: usize = 0;
    while (offset < total_samples) {
        const remaining = total_samples - offset;
        const batch = @min(remaining, chunk_size);

        for (0..batch) |i| {
            const s = samples.data[offset + i];
            const clamped = std.math.clamp(s, -1.0, 1.0);
            const pcm: i16 = @intFromFloat(clamped * 32767.0);
            std.mem.writeInt(i16, pcm_buf[i * 2 ..][0..2], pcm, .little);
        }

        const bytes_to_write = batch * 2;
        const written = fwrite(@ptrCast(&pcm_buf), 1, bytes_to_write, file);
        wav_data_bytes += @intCast(written);
        offset += batch;
    }

    _ = wav_sample_count.fetchAdd(@intCast(samples.frame_count), .monotonic);
}

/// Write a 44-byte WAV header (placeholder sizes) to the open file.
fn writeWavHeader(file: *CFile, sample_rate: u32, channels: u32) void {
    var header: [44]u8 = undefined;

    const byte_rate: u32 = sample_rate * channels * 2; // 16-bit = 2 bytes per sample
    const block_align: u16 = @intCast(channels * 2);

    // RIFF chunk descriptor
    @memcpy(header[0..4], "RIFF");
    std.mem.writeInt(u32, header[4..8], 0, .little); // placeholder RIFF size
    @memcpy(header[8..12], "WAVE");

    // fmt sub-chunk
    @memcpy(header[12..16], "fmt ");
    std.mem.writeInt(u32, header[16..20], 16, .little); // sub-chunk size
    std.mem.writeInt(u16, header[20..22], 1, .little); // PCM format
    std.mem.writeInt(u16, header[22..24], @intCast(channels), .little);
    std.mem.writeInt(u32, header[24..28], sample_rate, .little);
    std.mem.writeInt(u32, header[28..32], byte_rate, .little);
    std.mem.writeInt(u16, header[32..34], block_align, .little);
    std.mem.writeInt(u16, header[34..36], 16, .little); // bits per sample

    // data sub-chunk header
    @memcpy(header[36..40], "data");
    std.mem.writeInt(u32, header[40..44], 0, .little); // placeholder data size

    _ = fwrite(@ptrCast(&header), 1, 44, file);
}

/// Patch the WAV header with final sizes and close the file.
fn finalizeWavFile(file: *CFile, data_bytes: u64) void {
    const data_size: u32 = @intCast(@min(data_bytes, 0xFFFFFFFF));
    const riff_size: u32 = data_size +% 36;

    var size_buf: [4]u8 = undefined;

    // Patch RIFF chunk size at byte 4
    _ = fseek(file, 4, 0); // SEEK_SET = 0
    std.mem.writeInt(u32, &size_buf, riff_size, .little);
    _ = fwrite(@ptrCast(&size_buf), 1, 4, file);

    // Patch data chunk size at byte 40
    _ = fseek(file, 40, 0);
    std.mem.writeInt(u32, &size_buf, data_size, .little);
    _ = fwrite(@ptrCast(&size_buf), 1, 4, file);

    _ = fclose(file);
}

// ---------------------------------------------------------------------------
// CFRunLoop extern for macOS run loop
// ---------------------------------------------------------------------------

extern "c" fn CFRunLoopRunInMode(mode: *const anyopaque, seconds: f64, returnAfterSourceHandled: u8) i32;
// kCFRunLoopDefaultMode is a global CFStringRef variable - we need to load its value
const kCFRunLoopDefaultMode_ptr = @extern(*const *const anyopaque, .{ .name = "kCFRunLoopDefaultMode" });

// ---------------------------------------------------------------------------
// Record command implementation
// ---------------------------------------------------------------------------

fn runRecord(
    args_iter: anytype,
    stderr_writer: *std.Io.Writer,
) !void {
    // Parse arguments
    var output_path: ?[]const u8 = null;
    var window_name: ?[*:0]const u8 = null;
    var pid_arg: ?u32 = null;
    var region_arg: ?struct { x: u32, y: u32, w: u32, h: u32 } = null;
    var display_index: u32 = 0;
    var no_audio = false;
    var no_cursor = false;
    var use_mic = false;
    var mic_device: ?[*:0]const u8 = null;
    var fps: u32 = 30;
    var scale: f32 = 1.0;
    var sample_rate: u32 = 48000;
    var channels: u32 = 2;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--output")) {
            output_path = args_iter.next() orelse {
                try stderr_writer.print("Error: --output requires a file path\n", .{});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                unreachable;
            };
        } else if (std.mem.eql(u8, arg, "--window")) {
            const name = args_iter.next() orelse {
                try stderr_writer.print("Error: --window requires a name\n", .{});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                unreachable;
            };
            // We need a null-terminated string; the arg from iterator is already a slice
            // that's backed by stable memory (from process args)
            window_name = @ptrCast(name.ptr);
        } else if (std.mem.eql(u8, arg, "--pid")) {
            const pid_str = args_iter.next() orelse {
                try stderr_writer.print("Error: --pid requires a process ID\n", .{});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                unreachable;
            };
            pid_arg = std.fmt.parseInt(u32, pid_str, 10) catch {
                try stderr_writer.print("Error: invalid PID '{s}'\n", .{pid_str});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                unreachable;
            };
        } else if (std.mem.eql(u8, arg, "--display")) {
            const d_str = args_iter.next() orelse {
                try stderr_writer.print("Error: --display requires an index\n", .{});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                unreachable;
            };
            display_index = std.fmt.parseInt(u32, d_str, 10) catch {
                try stderr_writer.print("Error: invalid display index '{s}'\n", .{d_str});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                unreachable;
            };
        } else if (std.mem.eql(u8, arg, "--region")) {
            const region_str = args_iter.next() orelse {
                try stderr_writer.print("Error: --region requires X,Y,W,H\n", .{});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                unreachable;
            };
            // Parse "X,Y,W,H"
            var parts: [4]u32 = undefined;
            var part_idx: usize = 0;
            var iter = std.mem.splitScalar(u8, region_str, ',');
            while (iter.next()) |part| {
                if (part_idx >= 4) break;
                parts[part_idx] = std.fmt.parseInt(u32, part, 10) catch {
                    try stderr_writer.print("Error: invalid --region value '{s}'. Expected X,Y,W,H (e.g. 0,0,1920,1080)\n", .{region_str});
                    try stderr_writer.flush();
                    std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                    unreachable;
                };
                part_idx += 1;
            }
            if (part_idx != 4) {
                try stderr_writer.print("Error: --region requires exactly 4 values: X,Y,W,H (e.g. 0,0,1920,1080)\n", .{});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                unreachable;
            }
            region_arg = .{ .x = parts[0], .y = parts[1], .w = parts[2], .h = parts[3] };
        } else if (std.mem.eql(u8, arg, "--no-audio")) {
            no_audio = true;
        } else if (std.mem.eql(u8, arg, "--no-cursor")) {
            no_cursor = true;
        } else if (std.mem.eql(u8, arg, "--mic")) {
            use_mic = true;
        } else if (std.mem.eql(u8, arg, "--mic-device")) {
            use_mic = true;
            const name = args_iter.next() orelse {
                try stderr_writer.print("Error: --mic-device requires a device name\n", .{});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                unreachable;
            };
            mic_device = @ptrCast(name.ptr);
        } else if (std.mem.eql(u8, arg, "--fps")) {
            const fps_str = args_iter.next() orelse {
                try stderr_writer.print("Error: --fps requires a number\n", .{});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                unreachable;
            };
            fps = std.fmt.parseInt(u32, fps_str, 10) catch {
                try stderr_writer.print("Error: invalid fps '{s}'\n", .{fps_str});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                unreachable;
            };
        } else if (std.mem.eql(u8, arg, "--scale")) {
            const scale_str = args_iter.next() orelse {
                try stderr_writer.print("Error: --scale requires a number\n", .{});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                unreachable;
            };
            scale = std.fmt.parseFloat(f32, scale_str) catch {
                try stderr_writer.print("Error: invalid scale '{s}'\n", .{scale_str});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                unreachable;
            };
        } else if (std.mem.eql(u8, arg, "--sample-rate")) {
            const sr_str = args_iter.next() orelse {
                try stderr_writer.print("Error: --sample-rate requires a number\n", .{});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                unreachable;
            };
            sample_rate = std.fmt.parseInt(u32, sr_str, 10) catch {
                try stderr_writer.print("Error: invalid sample rate '{s}'\n", .{sr_str});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                unreachable;
            };
        } else if (std.mem.eql(u8, arg, "--app")) {
            const name = args_iter.next() orelse {
                try stderr_writer.print("Error: --app requires an application name\n", .{});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                unreachable;
            };
            // --app uses window_title target which also matches owning app names
            window_name = @ptrCast(name.ptr);
        } else if (std.mem.eql(u8, arg, "--channels")) {
            const ch_str = args_iter.next() orelse {
                try stderr_writer.print("Error: --channels requires a number\n", .{});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                unreachable;
            };
            channels = std.fmt.parseInt(u32, ch_str, 10) catch {
                try stderr_writer.print("Error: invalid channels '{s}'\n", .{ch_str});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                unreachable;
            };
        } else {
            try stderr_writer.print("Error: unknown option '{s}'\n", .{arg});
            try stderr_writer.flush();
            std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
            unreachable;
        }
    }

    // Auto-generate output path if not provided
    var auto_name_buf: [64]u8 = undefined;
    if (output_path == null) {
        const timestamp = cTime(null);
        const auto_name = std.fmt.bufPrint(&auto_name_buf, "spectacle_{d}.mp4", .{timestamp}) catch "spectacle_recording.mp4";
        output_path = auto_name;
    }

    const path = output_path.?;

    // Determine format from extension
    var format: []const u8 = "mp4";
    if (std.mem.endsWith(u8, path, ".mov")) {
        format = "mov";
    } else if (std.mem.endsWith(u8, path, ".mp4")) {
        format = "mp4";
    } else {
        try stderr_writer.print("Error: unsupported output format. Use .mp4 or .mov\n", .{});
        try stderr_writer.flush();
        std.process.exit(@intFromEnum(types.ExitCode.unsupported_format));
        unreachable;
    }

    // Check if output file already exists using C access()
    // We need a null-terminated path for access()
    var path_z_buf: [4096]u8 = undefined;
    if (path.len < path_z_buf.len) {
        @memcpy(path_z_buf[0..path.len], path);
        path_z_buf[path.len] = 0;
        const path_z: [*:0]const u8 = path_z_buf[0..path.len :0];
        if (cAccess(path_z, 0) == 0) {
            try stderr_writer.print("Error: output file already exists: {s}\n", .{path});
            try stderr_writer.flush();
            std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
            unreachable;
        }
    }

    // Build capture target
    var target: types.CaptureTarget = .{ .display = display_index };
    if (window_name) |name| {
        target = .{ .window_title = name };
    } else if (pid_arg) |pid| {
        target = .{ .window_pid = pid };
    } else if (region_arg) |r| {
        target = .{ .region = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h, .display = display_index } };
    }

    // Build capture config
    const config = types.CaptureConfig{
        .fps = fps,
        .scale = scale,
        .capture_audio = !no_audio,
        .show_cursor = !no_cursor,
        .capture_mic = use_mic,
        .sample_rate = sample_rate,
        .channels = channels,
    };

    // Install signal handler
    installSignalHandler();

    // Initialize encoder
    var enc = encoder_mod.init(format, path, config) catch {
        try stderr_writer.print("Error: failed to initialize encoder\n", .{});
        try stderr_writer.flush();
        std.process.exit(@intFromEnum(types.ExitCode.runtime_error));
        unreachable;
    };

    // Set global encoder pointer for callbacks
    global_encoder = &enc;
    global_frame_count.store(0, .release);

    try stderr_writer.print("Recording to {s} ({s}, {d} fps", .{ path, format, fps });
    if (no_audio) {
        try stderr_writer.print(", no audio", .{});
    }
    if (use_mic) {
        try stderr_writer.print(", mic", .{});
    }
    try stderr_writer.print(")\n", .{});
    try stderr_writer.print("Press Ctrl+C to stop...\n", .{});
    try stderr_writer.flush();

    // Start capture
    const audio_cb: ?*const fn (types.AudioSamples) void = if (no_audio) null else &audioCallback;

    const handle = capture.startCapture(target, config, &frameCallback, audio_cb) catch |err| {
        switch (err) {
            error.PermissionDenied => {
                try stderr_writer.print("Error: Screen recording permission denied.\nGrant access in System Settings > Privacy & Security > Screen Recording.\n", .{});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.permission_denied));
            },
            error.TargetNotFound => {
                try stderr_writer.print("Error: capture target not found\n", .{});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.target_not_found));
            },
            else => {
                try stderr_writer.print("Error: failed to start capture\n", .{});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.runtime_error));
            },
        }
        unreachable;
    };

    // Start mic capture if requested
    if (use_mic) {
        capture.startMicCapture(&micCallback, mic_device) catch {
            try stderr_writer.print("Warning: failed to start mic capture\n", .{});
            try stderr_writer.flush();
        };
    }

    // Record start time
    const start_time = cTime(null);
    var last_progress_time = start_time;

    // Main run loop - on macOS we need to pump CFRunLoop for ScreenCaptureKit
    while (!should_stop.load(.acquire)) {
        if (builtin.os.tag == .macos) {
            _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode_ptr.*, 0.1, 0);
        } else {
            std.time.sleep(100_000_000); // 100ms
        }

        // Print progress every ~2 seconds
        const now = cTime(null);
        if (now - last_progress_time >= 2) {
            const elapsed = now - start_time;
            const frames = global_frame_count.load(.acquire);
            try stderr_writer.print("\rRecording... {d}s, {d} frames captured", .{ elapsed, frames });
            try stderr_writer.flush();
            last_progress_time = now;
        }
    }

    // Stop capture
    try stderr_writer.print("\nStopping capture...\n", .{});
    try stderr_writer.flush();

    if (use_mic) {
        capture.stopMicCapture();
    }
    capture.stopCapture(handle);

    // Clear global encoder before finalizing
    global_encoder = null;

    // Finalize encoder
    encoder_mod.finalize(&enc) catch {
        try stderr_writer.print("Error: failed to finalize recording\n", .{});
        try stderr_writer.flush();
        std.process.exit(@intFromEnum(types.ExitCode.runtime_error));
        unreachable;
    };

    // Print summary
    const elapsed = cTime(null) - start_time;
    const frames = global_frame_count.load(.acquire);
    try stderr_writer.print("Recording saved: {s} ({d}s, {d} frames)\n", .{ path, elapsed, frames });
    try stderr_writer.flush();
}

// ---------------------------------------------------------------------------
// Audio command implementation
// ---------------------------------------------------------------------------

fn runAudio(
    args_iter: anytype,
    stderr_writer: *std.Io.Writer,
) !void {
    // Parse arguments
    var output_path: ?[]const u8 = null;
    var app_name: ?[]const u8 = null;
    var sample_rate: u32 = 48000;
    var channels: u32 = 2;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--output")) {
            output_path = args_iter.next() orelse {
                try stderr_writer.print("Error: --output requires a file path\n", .{});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                unreachable;
            };
        } else if (std.mem.eql(u8, arg, "--app")) {
            app_name = args_iter.next() orelse {
                try stderr_writer.print("Error: --app requires an application name\n", .{});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                unreachable;
            };
        } else if (std.mem.eql(u8, arg, "--sample-rate")) {
            const sr_str = args_iter.next() orelse {
                try stderr_writer.print("Error: --sample-rate requires a number\n", .{});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                unreachable;
            };
            sample_rate = std.fmt.parseInt(u32, sr_str, 10) catch {
                try stderr_writer.print("Error: invalid sample rate '{s}'\n", .{sr_str});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                unreachable;
            };
        } else if (std.mem.eql(u8, arg, "--channels")) {
            const ch_str = args_iter.next() orelse {
                try stderr_writer.print("Error: --channels requires a number\n", .{});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                unreachable;
            };
            channels = std.fmt.parseInt(u32, ch_str, 10) catch {
                try stderr_writer.print("Error: invalid channels '{s}'\n", .{ch_str});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                unreachable;
            };
        } else {
            try stderr_writer.print("Error: unknown option '{s}'\n", .{arg});
            try stderr_writer.flush();
            std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
            unreachable;
        }
    }

    // Auto-generate output path if not provided
    var auto_name_buf: [64]u8 = undefined;
    if (output_path == null) {
        const timestamp = cTime(null);
        const auto_name = std.fmt.bufPrint(&auto_name_buf, "spectacle_{d}.wav", .{timestamp}) catch "spectacle_recording.wav";
        output_path = auto_name;
    }

    const path = output_path.?;

    // Validate .wav extension
    if (!std.mem.endsWith(u8, path, ".wav")) {
        try stderr_writer.print("Error: audio output must be a .wav file\n", .{});
        try stderr_writer.flush();
        std.process.exit(@intFromEnum(types.ExitCode.unsupported_format));
        unreachable;
    }

    // Check if output file already exists
    var path_z_buf: [4096]u8 = undefined;
    if (path.len < path_z_buf.len) {
        @memcpy(path_z_buf[0..path.len], path);
        path_z_buf[path.len] = 0;
        const path_z: [*:0]const u8 = path_z_buf[0..path.len :0];
        if (cAccess(path_z, 0) == 0) {
            try stderr_writer.print("Error: output file already exists: {s}\n", .{path});
            try stderr_writer.flush();
            std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
            unreachable;
        }
    }

    // Open WAV file
    var file_path_z: [4096]u8 = undefined;
    @memcpy(file_path_z[0..path.len], path);
    file_path_z[path.len] = 0;
    const file_path_sentinel: [*:0]const u8 = file_path_z[0..path.len :0];

    const file = fopen(file_path_sentinel, "wb") orelse {
        try stderr_writer.print("Error: could not open output file: {s}\n", .{path});
        try stderr_writer.flush();
        std.process.exit(@intFromEnum(types.ExitCode.runtime_error));
        unreachable;
    };

    // Write WAV header (placeholder sizes)
    writeWavHeader(file, sample_rate, channels);

    // Set up global WAV state
    wav_file = file;
    wav_data_bytes = 0;
    wav_sample_count.store(0, .release);

    // Install signal handler
    installSignalHandler();

    // Use Core Audio Taps for all audio-only capture (both system and per-app)
    const use_audio_taps = true;

    if (app_name) |an| {
        try stderr_writer.print("Recording audio from \"{s}\" to {s} ({d} Hz, {d} channels)\n", .{ an, path, sample_rate, channels });
    } else {
        try stderr_writer.print("Recording system audio to {s} ({d} Hz, {d} channels)\n", .{ path, sample_rate, channels });
    }
    try stderr_writer.print("Press Ctrl+C to stop...\n", .{});
    try stderr_writer.flush();

    // We store the handle as a tagged value to know which stop function to call
    var audio_tap_handle: ?types.CaptureHandle = null;
    var screen_capture_handle: ?types.CaptureHandle = null;

    if (use_audio_taps) {
        // Build AudioTarget
        var audio_target: types.AudioTarget = .{ .system = {} };
        var app_name_z_buf: [256]u8 = undefined;
        if (app_name) |an| {
            if (an.len >= app_name_z_buf.len) {
                try stderr_writer.print("Error: app name too long\n", .{});
                try stderr_writer.flush();
                _ = fclose(file);
                wav_file = null;
                std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                unreachable;
            }
            @memcpy(app_name_z_buf[0..an.len], an);
            app_name_z_buf[an.len] = 0;
            audio_target = .{ .app_name = app_name_z_buf[0..an.len :0] };
        }

        const audio_config = types.AudioConfig{
            .sample_rate = sample_rate,
            .channels = channels,
        };

        audio_tap_handle = audio_mod.startCapture(audio_target, audio_config, &wavAudioCallback) catch |err| {
            _ = fclose(file);
            wav_file = null;
            switch (err) {
                error.TargetNotFound => {
                    if (app_name) |an| {
                        try stderr_writer.print("Error: No audio source matching \"{s}\" found. Use 'spectacle list audio-sources' to see available sources.\n", .{an});
                    } else {
                        try stderr_writer.print("Error: failed to start audio capture\n", .{});
                    }
                    try stderr_writer.flush();
                    std.process.exit(@intFromEnum(types.ExitCode.target_not_found));
                },
                else => {
                    try stderr_writer.print("Error: failed to start audio capture\n", .{});
                    try stderr_writer.flush();
                    std.process.exit(@intFromEnum(types.ExitCode.runtime_error));
                },
            }
            unreachable;
        };
    } else {
        // System audio via ScreenCaptureKit (discard video frames)
        const config = types.CaptureConfig{
            .fps = 1,
            .scale = 0.25,
            .capture_audio = true,
            .sample_rate = sample_rate,
            .channels = channels,
        };

        screen_capture_handle = capture.startCapture(.{ .display = 0 }, config, &noopFrameCallback, &wavAudioCallback) catch |err| {
            _ = fclose(file);
            wav_file = null;
            switch (err) {
                error.PermissionDenied => {
                    try stderr_writer.print("Error: Screen recording permission denied.\nGrant access in System Settings > Privacy & Security > Screen Recording.\n", .{});
                    try stderr_writer.flush();
                    std.process.exit(@intFromEnum(types.ExitCode.permission_denied));
                },
                else => {
                    try stderr_writer.print("Error: failed to start audio capture\n", .{});
                    try stderr_writer.flush();
                    std.process.exit(@intFromEnum(types.ExitCode.runtime_error));
                },
            }
            unreachable;
        };
    }

    // Record start time
    const start_time = cTime(null);
    var last_progress_time = start_time;

    // Main run loop
    while (!should_stop.load(.acquire)) {
        if (builtin.os.tag == .macos) {
            _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode_ptr.*, 0.1, 0);
        } else {
            std.time.sleep(100_000_000); // 100ms
        }

        // Print progress every ~2 seconds
        const now = cTime(null);
        if (now - last_progress_time >= 2) {
            const elapsed = now - start_time;
            const frames = wav_sample_count.load(.acquire);
            const seconds_recorded = if (sample_rate > 0) frames / sample_rate else 0;
            try stderr_writer.print("\rRecording audio... {d}s elapsed, ~{d}s of audio captured", .{ elapsed, seconds_recorded });
            try stderr_writer.flush();
            last_progress_time = now;
        }
    }

    // Stop capture
    try stderr_writer.print("\nStopping audio capture...\n", .{});
    try stderr_writer.flush();

    if (audio_tap_handle) |h| {
        audio_mod.stopCapture(h);
    } else if (screen_capture_handle) |h| {
        capture.stopCapture(h);
    }

    // Finalize WAV file — patch header with actual sizes
    const final_data_bytes = wav_data_bytes;
    finalizeWavFile(file, final_data_bytes);
    wav_file = null;

    // Print summary
    const elapsed = cTime(null) - start_time;
    const total_frames = wav_sample_count.load(.acquire);
    const duration_secs = if (sample_rate > 0) total_frames / sample_rate else 0;
    try stderr_writer.print("Audio saved: {s} ({d}s, {d} bytes)\n", .{ path, if (elapsed > 0) elapsed else @as(isize, @intCast(duration_secs)), final_data_bytes + 44 });
    try stderr_writer.flush();
}

// ---------------------------------------------------------------------------
// Screenshot command implementation
// ---------------------------------------------------------------------------

fn runScreenshot(
    args_iter: anytype,
    stderr_writer: *std.Io.Writer,
) !void {
    // Parse arguments
    var output_path: ?[]const u8 = null;
    var window_name: ?[*:0]const u8 = null;
    var pid_arg: ?u32 = null;
    var region_arg: ?struct { x: u32, y: u32, w: u32, h: u32 } = null;
    var display_index: u32 = 0;
    var no_cursor = false;
    var scale: f32 = 1.0;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--output")) {
            output_path = args_iter.next() orelse {
                try stderr_writer.print("Error: --output requires a file path\n", .{});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                unreachable;
            };
        } else if (std.mem.eql(u8, arg, "--window")) {
            const name = args_iter.next() orelse {
                try stderr_writer.print("Error: --window requires a name\n", .{});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                unreachable;
            };
            window_name = @ptrCast(name.ptr);
        } else if (std.mem.eql(u8, arg, "--pid")) {
            const pid_str = args_iter.next() orelse {
                try stderr_writer.print("Error: --pid requires a process ID\n", .{});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                unreachable;
            };
            pid_arg = std.fmt.parseInt(u32, pid_str, 10) catch {
                try stderr_writer.print("Error: invalid PID '{s}'\n", .{pid_str});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                unreachable;
            };
        } else if (std.mem.eql(u8, arg, "--app")) {
            const name = args_iter.next() orelse {
                try stderr_writer.print("Error: --app requires an application name\n", .{});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                unreachable;
            };
            window_name = @ptrCast(name.ptr);
        } else if (std.mem.eql(u8, arg, "--display")) {
            const d_str = args_iter.next() orelse {
                try stderr_writer.print("Error: --display requires an index\n", .{});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                unreachable;
            };
            display_index = std.fmt.parseInt(u32, d_str, 10) catch {
                try stderr_writer.print("Error: invalid display index '{s}'\n", .{d_str});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                unreachable;
            };
        } else if (std.mem.eql(u8, arg, "--region")) {
            const region_str = args_iter.next() orelse {
                try stderr_writer.print("Error: --region requires X,Y,W,H\n", .{});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                unreachable;
            };
            var parts: [4]u32 = undefined;
            var part_idx: usize = 0;
            var iter = std.mem.splitScalar(u8, region_str, ',');
            while (iter.next()) |part| {
                if (part_idx >= 4) break;
                parts[part_idx] = std.fmt.parseInt(u32, part, 10) catch {
                    try stderr_writer.print("Error: invalid --region value '{s}'. Expected X,Y,W,H (e.g. 0,0,1920,1080)\n", .{region_str});
                    try stderr_writer.flush();
                    std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                    unreachable;
                };
                part_idx += 1;
            }
            if (part_idx != 4) {
                try stderr_writer.print("Error: --region requires exactly 4 values: X,Y,W,H (e.g. 0,0,1920,1080)\n", .{});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                unreachable;
            }
            region_arg = .{ .x = parts[0], .y = parts[1], .w = parts[2], .h = parts[3] };
        } else if (std.mem.eql(u8, arg, "--no-cursor")) {
            no_cursor = true;
        } else if (std.mem.eql(u8, arg, "--scale")) {
            const scale_str = args_iter.next() orelse {
                try stderr_writer.print("Error: --scale requires a number\n", .{});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                unreachable;
            };
            scale = std.fmt.parseFloat(f32, scale_str) catch {
                try stderr_writer.print("Error: invalid scale '{s}'\n", .{scale_str});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
                unreachable;
            };
        } else {
            try stderr_writer.print("Error: unknown option '{s}'\n", .{arg});
            try stderr_writer.flush();
            std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
            unreachable;
        }
    }

    // Auto-generate output path if not provided
    var auto_name_buf: [64]u8 = undefined;
    if (output_path == null) {
        const auto_name = std.fmt.bufPrint(&auto_name_buf, "screenshot.png", .{}) catch "screenshot.png";
        output_path = auto_name;
    }

    const path = output_path.?;

    // Determine format from extension
    var format: types.ImageFormat = .png;
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) {
        format = .jpeg;
    } else if (std.mem.endsWith(u8, path, ".png")) {
        format = .png;
    } else {
        try stderr_writer.print("Error: unsupported screenshot format. Use .png or .jpg/.jpeg\n", .{});
        try stderr_writer.flush();
        std.process.exit(@intFromEnum(types.ExitCode.unsupported_format));
        unreachable;
    }

    // Check if output file already exists
    var path_z_buf: [4096]u8 = undefined;
    if (path.len < path_z_buf.len) {
        @memcpy(path_z_buf[0..path.len], path);
        path_z_buf[path.len] = 0;
        const path_z: [*:0]const u8 = path_z_buf[0..path.len :0];
        if (cAccess(path_z, 0) == 0) {
            try stderr_writer.print("Error: output file already exists: {s}\n", .{path});
            try stderr_writer.flush();
            std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
            unreachable;
        }
    }

    // Build capture target
    var target: types.CaptureTarget = .{ .display = display_index };
    if (window_name) |name| {
        target = .{ .window_title = name };
    } else if (pid_arg) |pid| {
        target = .{ .window_pid = pid };
    } else if (region_arg) |r| {
        target = .{ .region = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h, .display = display_index } };
    }

    // Build capture config (1 fps, no audio — just need one frame)
    const config = types.CaptureConfig{
        .fps = 1,
        .scale = scale,
        .capture_audio = false,
        .show_cursor = !no_cursor,
    };

    // Need a null-terminated path for captureScreenshot
    var out_z_buf: [4096]u8 = undefined;
    if (path.len >= out_z_buf.len) {
        try stderr_writer.print("Error: output path too long\n", .{});
        try stderr_writer.flush();
        std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
        unreachable;
    }
    @memcpy(out_z_buf[0..path.len], path);
    out_z_buf[path.len] = 0;
    const out_path_z: [*:0]const u8 = out_z_buf[0..path.len :0];

    // Capture screenshot
    capture.captureScreenshot(target, config, out_path_z, format) catch |err| {
        switch (err) {
            error.PermissionDenied => {
                try stderr_writer.print("Error: Screen recording permission denied.\nGrant access in System Settings > Privacy & Security > Screen Recording.\n", .{});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.permission_denied));
            },
            error.TargetNotFound => {
                try stderr_writer.print("Error: capture target not found\n", .{});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.target_not_found));
            },
            error.WriteFailed => {
                try stderr_writer.print("Error: failed to write image file\n", .{});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.runtime_error));
            },
            else => {
                try stderr_writer.print("Error: screenshot capture failed\n", .{});
                try stderr_writer.flush();
                std.process.exit(@intFromEnum(types.ExitCode.runtime_error));
            },
        }
        unreachable;
    };

    try stderr_writer.print("Screenshot saved: {s}\n", .{path});
    try stderr_writer.flush();
}

// ---------------------------------------------------------------------------
// Main entry point
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const stdout_file = std.Io.File.stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout = stdout_file.writerStreaming(init.io, &stdout_buf);

    const stderr_file = std.Io.File.stderr();
    var stderr_buf: [4096]u8 = undefined;
    var stderr = stderr_file.writerStreaming(init.io, &stderr_buf);

    const allocator = init.gpa;

    var args_iter = try init.minimal.args.iterateAllocator(allocator);
    defer args_iter.deinit();
    _ = args_iter.next(); // skip program name

    // Get command
    const command = args_iter.next() orelse {
        try printUsage(&stdout.interface);
        try stdout.interface.flush();
        return;
    };

    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "help")) {
        try printUsage(&stdout.interface);
        try stdout.interface.flush();
        return;
    }

    if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        try stdout.interface.print("spectacle " ++ version ++ " (" ++ @tagName(builtin.os.tag) ++ ")\n", .{});
        try stdout.interface.flush();
        return;
    }

    // Dispatch commands
    if (std.mem.eql(u8, command, "record")) {
        try runRecord(&args_iter, &stderr.interface);
    } else if (std.mem.eql(u8, command, "screenshot")) {
        try runScreenshot(&args_iter, &stderr.interface);
    } else if (std.mem.eql(u8, command, "audio")) {
        try runAudio(&args_iter, &stderr.interface);
    } else if (std.mem.eql(u8, command, "list")) {
        // Parse list sub-target and optional --json flag
        const list_target = args_iter.next() orelse {
            try stderr.interface.print("Error: 'list' requires a target: displays, windows, or audio-sources\n", .{});
            try stderr.interface.flush();
            std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
            unreachable;
        };

        var json_output = false;
        // Check remaining args for --json
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--json")) {
                json_output = true;
            }
        }

        if (std.mem.eql(u8, list_target, "displays")) {
            const displays = capture.listDisplays(allocator) catch |err| {
                switch (err) {
                    error.PermissionDenied => {
                        try stderr.interface.print("Error: Screen recording permission denied.\nGrant access in System Settings > Privacy & Security > Screen Recording.\n", .{});
                        try stderr.interface.flush();
                        std.process.exit(@intFromEnum(types.ExitCode.permission_denied));
                    },
                    else => {
                        try stderr.interface.print("Error: Failed to enumerate displays.\n", .{});
                        try stderr.interface.flush();
                        std.process.exit(@intFromEnum(types.ExitCode.runtime_error));
                    },
                }
                unreachable;
            };
            defer allocator.free(displays);

            if (json_output) {
                try printDisplaysJson(&stdout.interface, displays);
            } else {
                try printDisplaysHuman(&stdout.interface, displays);
            }
        } else if (std.mem.eql(u8, list_target, "windows")) {
            const windows = capture.listWindows(allocator) catch |err| {
                switch (err) {
                    error.PermissionDenied => {
                        try stderr.interface.print("Error: Screen recording permission denied.\nGrant access in System Settings > Privacy & Security > Screen Recording.\n", .{});
                        try stderr.interface.flush();
                        std.process.exit(@intFromEnum(types.ExitCode.permission_denied));
                    },
                    else => {
                        try stderr.interface.print("Error: Failed to enumerate windows.\n", .{});
                        try stderr.interface.flush();
                        std.process.exit(@intFromEnum(types.ExitCode.runtime_error));
                    },
                }
                unreachable;
            };
            defer allocator.free(windows);

            if (json_output) {
                try printWindowsJson(&stdout.interface, windows);
            } else {
                try printWindowsHuman(&stdout.interface, windows);
            }
        } else if (std.mem.eql(u8, list_target, "audio-sources")) {
            const sources = audio_mod.listSources(allocator) catch {
                try stderr.interface.print("Error: Failed to enumerate audio sources.\n", .{});
                try stderr.interface.flush();
                std.process.exit(@intFromEnum(types.ExitCode.runtime_error));
                unreachable;
            };
            defer allocator.free(sources);

            const mic_result = capture.listMicDevices(allocator);
            const mic_devices: []const types.MicDevice = mic_result catch &.{};
            const mic_owned = if (mic_result) |_| true else |_| false;
            defer if (mic_owned) allocator.free(mic_devices);

            if (json_output) {
                try printAudioSourcesJson(&stdout.interface, sources, mic_devices);
            } else {
                try printAudioSourcesHuman(&stdout.interface, sources, mic_devices);
            }
        } else {
            try stderr.interface.print("Error: unknown list target '{s}'. Expected: displays, windows, or audio-sources\n", .{list_target});
            try stderr.interface.flush();
            std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
        }

        try stdout.interface.flush();
    } else {
        try stderr.interface.print("Error: unknown command '{s}'\n\n", .{command});
        try printUsage(&stderr.interface);
        try stderr.interface.flush();
        std.process.exit(@intFromEnum(types.ExitCode.invalid_args));
    }
}
