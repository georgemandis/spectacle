/// WAV file writer — pure Zig, no OS dependencies.
/// Writes 16-bit PCM, little-endian, RIFF/WAVE format.
///
/// The caller supplies an output buffer ([]u8) large enough to hold the
/// entire WAV file.  WavWriter tracks a cursor and writes into the slice
/// directly, which means finalize() can patch the header in-place without
/// needing a seekable stream.
///
/// Typical usage:
///
///   var buf: [huge]u8 = undefined;
///   var wav = try WavWriter.init(&buf, 48000, 2);
///   try wav.writeSamples(samples_slice);
///   const written_slice = try wav.finalize();   // returns buf[0..total_bytes]
///
const std = @import("std");
const types = @import("types");

// ---------------------------------------------------------------------------
// WAV / RIFF constants
// ---------------------------------------------------------------------------

/// Total header size: RIFF(12) + fmt (24) + data(8) = 44 bytes.
pub const HEADER_SIZE: u32 = 44;

const RIFF_ID = [4]u8{ 'R', 'I', 'F', 'F' };
const WAVE_ID = [4]u8{ 'W', 'A', 'V', 'E' };
const FMT_ID = [4]u8{ 'f', 'm', 't', ' ' };
const DATA_ID = [4]u8{ 'd', 'a', 't', 'a' };

const PCM_FORMAT: u16 = 1;
const BITS_PER_SAMPLE: u16 = 16;
const BYTES_PER_SAMPLE: u32 = 2;

// ---------------------------------------------------------------------------
// WavWriter
// ---------------------------------------------------------------------------

pub const WavWriter = struct {
    buf: []u8,
    pos: usize,
    sample_rate: u32,
    channels: u32,

    /// Initialise a WavWriter and write a placeholder 44-byte RIFF/WAVE
    /// header into `buf`.  `buf` must be at least HEADER_SIZE bytes.
    pub fn init(buf: []u8, sample_rate: u32, channels: u32) !WavWriter {
        if (buf.len < HEADER_SIZE) return error.BufferTooSmall;
        var self = WavWriter{
            .buf = buf,
            .pos = 0,
            .sample_rate = sample_rate,
            .channels = channels,
        };
        try self.writeHeader(0); // sizes are placeholders; finalize() patches them
        return self;
    }

    /// Convert f32 samples to 16-bit PCM and append them to the data chunk.
    /// `samples` is interleaved, matching types.AudioSamples layout.
    pub fn writeSamples(self: *WavWriter, samples: []const f32) !void {
        for (samples) |s| {
            if (self.pos + 2 > self.buf.len) return error.BufferTooSmall;
            const clamped = std.math.clamp(s, -1.0, 1.0);
            const pcm: i16 = @intFromFloat(clamped * 32767.0);
            std.mem.writeInt(i16, self.buf[self.pos..][0..2], pcm, .little);
            self.pos += 2;
        }
    }

    /// Convenience wrapper that accepts a types.AudioSamples struct.
    pub fn writeAudioSamples(self: *WavWriter, audio: types.AudioSamples) !void {
        const total = audio.frame_count * audio.channels;
        const slice = audio.data[0..total];
        try self.writeSamples(slice);
    }

    /// Patch the RIFF and data chunk sizes in the header, then return the
    /// portion of `buf` that was actually written.
    ///
    ///   offset  4 — RIFF chunk size = data_bytes + 36
    ///   offset 40 — data chunk size = data_bytes
    pub fn finalize(self: *WavWriter) ![]const u8 {
        const data_bytes: u32 = @intCast(self.pos - HEADER_SIZE);
        const riff_size: u32 = data_bytes + 36;

        std.mem.writeInt(u32, self.buf[4..8], riff_size, .little);
        std.mem.writeInt(u32, self.buf[40..44], data_bytes, .little);

        return self.buf[0..self.pos];
    }

    // -----------------------------------------------------------------------
    // Private helpers
    // -----------------------------------------------------------------------

    fn writeU16LE(self: *WavWriter, value: u16) !void {
        if (self.pos + 2 > self.buf.len) return error.BufferTooSmall;
        std.mem.writeInt(u16, self.buf[self.pos..][0..2], value, .little);
        self.pos += 2;
    }

    fn writeU32LE(self: *WavWriter, value: u32) !void {
        if (self.pos + 4 > self.buf.len) return error.BufferTooSmall;
        std.mem.writeInt(u32, self.buf[self.pos..][0..4], value, .little);
        self.pos += 4;
    }

    fn writeBytes(self: *WavWriter, bytes: []const u8) !void {
        if (self.pos + bytes.len > self.buf.len) return error.BufferTooSmall;
        @memcpy(self.buf[self.pos..][0..bytes.len], bytes);
        self.pos += bytes.len;
    }

    fn writeHeader(self: *WavWriter, data_size: u32) !void {
        const byte_rate: u32 = self.sample_rate * self.channels * BYTES_PER_SAMPLE;
        const block_align: u16 = @intCast(self.channels * BYTES_PER_SAMPLE);
        const riff_size: u32 = data_size + 36;

        // RIFF chunk descriptor (12 bytes)
        try self.writeBytes(&RIFF_ID);
        try self.writeU32LE(riff_size);
        try self.writeBytes(&WAVE_ID);

        // fmt sub-chunk (24 bytes: 8 chunk header + 16 body)
        try self.writeBytes(&FMT_ID);
        try self.writeU32LE(16); // sub-chunk size
        try self.writeU16LE(PCM_FORMAT);
        try self.writeU16LE(@intCast(self.channels));
        try self.writeU32LE(self.sample_rate);
        try self.writeU32LE(byte_rate);
        try self.writeU16LE(block_align);
        try self.writeU16LE(BITS_PER_SAMPLE);

        // data sub-chunk header (8 bytes; size is a placeholder here)
        try self.writeBytes(&DATA_ID);
        try self.writeU32LE(data_size);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "WAV writer creates valid RIFF header" {
    var buf: [1024]u8 = undefined;
    var wav = try WavWriter.init(&buf, 48000, 2);

    // Write a handful of samples so the file is non-trivial
    const samples = [_]f32{ 0.0, 0.5, -0.5, 1.0, -1.0, 0.25 };
    try wav.writeSamples(&samples);
    const written = try wav.finalize();

    // Must be at least 44 (header) + 6*2 (samples) bytes
    try std.testing.expect(written.len >= HEADER_SIZE + 12);

    // "RIFF" at offset 0
    try std.testing.expectEqualSlices(u8, "RIFF", written[0..4]);

    // "WAVE" at offset 8
    try std.testing.expectEqualSlices(u8, "WAVE", written[8..12]);

    // "fmt " at offset 12
    try std.testing.expectEqualSlices(u8, "fmt ", written[12..16]);

    // fmt sub-chunk size = 16 (little-endian u32 at offset 16)
    const fmt_chunk_size = std.mem.readInt(u32, written[16..20], .little);
    try std.testing.expectEqual(@as(u32, 16), fmt_chunk_size);

    // Audio format = 1 (PCM) at offset 20
    const audio_format = std.mem.readInt(u16, written[20..22], .little);
    try std.testing.expectEqual(@as(u16, 1), audio_format);

    // Num channels = 2 at offset 22
    const num_channels = std.mem.readInt(u16, written[22..24], .little);
    try std.testing.expectEqual(@as(u16, 2), num_channels);

    // Sample rate = 48000 at offset 24
    const sample_rate = std.mem.readInt(u32, written[24..28], .little);
    try std.testing.expectEqual(@as(u32, 48000), sample_rate);

    // "data" at offset 36
    try std.testing.expectEqualSlices(u8, "data", written[36..40]);
}

test "WAV writer finalize fixes data length" {
    var buf: [1024]u8 = undefined;
    var wav = try WavWriter.init(&buf, 44100, 1);

    // Write exactly 100 mono f32 samples → 100 * 2 = 200 PCM bytes
    var samples: [100]f32 = undefined;
    for (&samples, 0..) |*s, i| {
        s.* = @as(f32, @floatFromInt(i)) / 100.0 - 0.5;
    }
    try wav.writeSamples(&samples);
    const written = try wav.finalize();

    // data chunk size at offset 40
    const data_size = std.mem.readInt(u32, written[40..44], .little);
    try std.testing.expectEqual(@as(u32, 200), data_size);

    // RIFF chunk size at offset 4 must be data_size + 36
    const riff_size = std.mem.readInt(u32, written[4..8], .little);
    try std.testing.expectEqual(@as(u32, 236), riff_size);
}
