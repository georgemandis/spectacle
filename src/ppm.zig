/// PPM P6 frame writer — pure Zig, no OS dependencies beyond std.fs.Dir.
/// Converts BGRA VideoFrame pixels to raw RGB bytes (drops the alpha channel).
const std = @import("std");
const types = @import("types");

// ---------------------------------------------------------------------------
// writeFrame
// ---------------------------------------------------------------------------

/// Write a single VideoFrame as a PPM P6 image.
/// Pixel format conversion: BGRA → RGB (byte order: B=0, G=1, R=2, A=3).
pub fn writeFrame(writer: *std.Io.Writer, frame: types.VideoFrame) !void {
    // P6 header: "P6\n{width} {height}\n255\n"
    try writer.print("P6\n{d} {d}\n255\n", .{ frame.width, frame.height });

    // Write pixel data row by row, converting BGRA → RGB
    var row: u32 = 0;
    while (row < frame.height) : (row += 1) {
        const row_start = row * frame.bytes_per_row;
        var col: u32 = 0;
        while (col < frame.width) : (col += 1) {
            const pixel_offset = row_start + col * 4;
            const b = frame.data[pixel_offset + 0];
            const g = frame.data[pixel_offset + 1];
            const r = frame.data[pixel_offset + 2];
            // alpha (pixel_offset + 3) is discarded
            try writer.writeByte(r);
            try writer.writeByte(g);
            try writer.writeByte(b);
        }
    }
}

// ---------------------------------------------------------------------------
// writeNumberedFrame
// ---------------------------------------------------------------------------

/// Write frame to `dir` as a zero-padded filename, e.g. "000001.ppm".
pub fn writeNumberedFrame(dir: std.fs.Dir, frame_number: u64, frame: types.VideoFrame) !void {
    var name_buf: [16]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "{d:0>6}.ppm", .{frame_number});

    const file = try dir.createFile(name, .{});
    defer file.close();

    // TODO: wire up std.Io.File.Writer when Io is available in the runtime
    // For now delegate to the POSIX-level writer via std.fs.File.
    _ = frame;
    return error.Unsupported;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "PPM header format" {
    // 2x1 frame (2 pixels wide, 1 pixel tall)
    const pixel_data = [_]u8{
        // Pixel 0: BGRA = (10, 20, 30, 255)
        10, 20, 30, 255,
        // Pixel 1: BGRA = (40, 50, 60, 255)
        40, 50, 60, 255,
    };

    const frame = types.VideoFrame{
        .data = &pixel_data,
        .len = pixel_data.len,
        .width = 2,
        .height = 1,
        .bytes_per_row = 8,
        .timestamp_ns = 0,
    };

    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writeFrame(&writer, frame);

    const written = writer.buffered();

    // Header must start with "P6\n"
    try std.testing.expect(std.mem.startsWith(u8, written, "P6\n"));

    // Header must contain width and height
    try std.testing.expect(std.mem.indexOf(u8, written, "2 1") != null);

    // Header must contain max value "255"
    try std.testing.expect(std.mem.indexOf(u8, written, "255") != null);

    // Header must end with a newline before the binary data
    const expected_header = "P6\n2 1\n255\n";
    try std.testing.expect(std.mem.startsWith(u8, written, expected_header));

    // Binary data starts right after the header
    const pixel_bytes = written[expected_header.len..];
    // 2 pixels * 3 bytes (RGB) = 6 bytes
    try std.testing.expectEqual(@as(usize, 6), pixel_bytes.len);
}

test "PPM BGRA to RGB conversion" {
    // 1x1 frame: BGRA = (B=10, G=20, R=30, A=255)
    // Expected RGB output: R=30, G=20, B=10
    const pixel_data = [_]u8{ 10, 20, 30, 255 };

    const frame = types.VideoFrame{
        .data = &pixel_data,
        .len = pixel_data.len,
        .width = 1,
        .height = 1,
        .bytes_per_row = 4,
        .timestamp_ns = 0,
    };

    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writeFrame(&writer, frame);

    const written = writer.buffered();
    const header = "P6\n1 1\n255\n";
    const pixel_bytes = written[header.len..];

    // Must be exactly 3 bytes (one RGB pixel)
    try std.testing.expectEqual(@as(usize, 3), pixel_bytes.len);

    // R comes first in PPM output
    try std.testing.expectEqual(@as(u8, 30), pixel_bytes[0]); // R from BGRA[2]
    try std.testing.expectEqual(@as(u8, 20), pixel_bytes[1]); // G from BGRA[1]
    try std.testing.expectEqual(@as(u8, 10), pixel_bytes[2]); // B from BGRA[0]
}
