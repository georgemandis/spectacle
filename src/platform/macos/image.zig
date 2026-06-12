/// macOS image encoding — CoreGraphics + ImageIO implementation.
/// Encodes raw BGRA pixel data to PNG or JPEG files.
const std = @import("std");
const types = @import("types");

// ---------------------------------------------------------------------------
// CoreGraphics externs
// ---------------------------------------------------------------------------

const CGColorSpaceRef = *anyopaque;
const CGImageRef = *anyopaque;
const CGDataProviderRef = *anyopaque;
const CFDataRef = *anyopaque;
const CFURLRef = *anyopaque;
const CFStringRef = *anyopaque;
const CGImageDestinationRef = *anyopaque;

extern "c" fn CGColorSpaceCreateDeviceRGB() ?CGColorSpaceRef;
extern "c" fn CGColorSpaceRelease(space: CGColorSpaceRef) void;

extern "c" fn CGDataProviderCreateWithData(
    info: ?*anyopaque,
    data: *const anyopaque,
    size: usize,
    releaseData: ?*const anyopaque,
) ?CGDataProviderRef;
extern "c" fn CGDataProviderRelease(provider: CGDataProviderRef) void;

extern "c" fn CGImageCreate(
    width: usize,
    height: usize,
    bitsPerComponent: usize,
    bitsPerPixel: usize,
    bytesPerRow: usize,
    space: CGColorSpaceRef,
    bitmapInfo: u32,
    provider: CGDataProviderRef,
    decode: ?*const anyopaque,
    shouldInterpolate: bool,
    intent: u32,
) ?CGImageRef;
extern "c" fn CGImageRelease(image: CGImageRef) void;

// ImageIO externs
extern "c" fn CGImageDestinationCreateWithURL(
    url: CFURLRef,
    image_type: CFStringRef,
    count: usize,
    options: ?*anyopaque,
) ?CGImageDestinationRef;
extern "c" fn CGImageDestinationAddImage(
    dest: CGImageDestinationRef,
    image: CGImageRef,
    properties: ?*anyopaque,
) void;
extern "c" fn CGImageDestinationFinalize(dest: CGImageDestinationRef) bool;

// CoreFoundation externs
extern "c" fn CFRelease(cf: *anyopaque) void;

// CFString creation from C string
extern "c" fn CFStringCreateWithCString(
    alloc: ?*anyopaque,
    cStr: [*:0]const u8,
    encoding: u32,
) ?CFStringRef;

// CFURL creation from file path
extern "c" fn CFURLCreateFromFileSystemRepresentation(
    allocator: ?*anyopaque,
    buffer: [*]const u8,
    bufLen: isize,
    isDirectory: bool,
) ?CFURLRef;

// kCFStringEncodingUTF8 = 0x08000100
const kCFStringEncodingUTF8: u32 = 0x08000100;

// CGBitmapInfo: kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst
// This matches the BGRA pixel format from ScreenCaptureKit
// kCGBitmapByteOrder32Little = 2 << 12 = 8192
// kCGImageAlphaPremultipliedFirst = 2
const kCGBitmapInfo_BGRA: u32 = (2 << 12) | 2;

// kCGRenderingIntentDefault = 0
const kCGRenderingIntentDefault: u32 = 0;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub fn writeImageToFile(
    data: []const u8,
    width: u32,
    height: u32,
    bytes_per_row: u32,
    output_path: [*:0]const u8,
    format: types.ImageFormat,
) !void {
    // 1. Create color space
    const color_space = CGColorSpaceCreateDeviceRGB() orelse return error.EncoderFailed;
    defer CGColorSpaceRelease(color_space);

    // 2. Create data provider from pixel data
    const provider = CGDataProviderCreateWithData(
        null,
        @ptrCast(data.ptr),
        data.len,
        null,
    ) orelse return error.EncoderFailed;
    defer CGDataProviderRelease(provider);

    // 3. Create CGImage
    const image = CGImageCreate(
        @intCast(width),
        @intCast(height),
        8, // bits per component
        32, // bits per pixel (BGRA)
        @intCast(bytes_per_row),
        color_space,
        kCGBitmapInfo_BGRA,
        provider,
        null, // no decode array
        false, // no interpolation
        kCGRenderingIntentDefault,
    ) orelse return error.EncoderFailed;
    defer CGImageRelease(image);

    // 4. Create CFURL from output path
    const path_slice = std.mem.sliceTo(output_path, 0);
    const url = CFURLCreateFromFileSystemRepresentation(
        null,
        path_slice.ptr,
        @intCast(path_slice.len),
        false,
    ) orelse return error.WriteFailed;
    defer CFRelease(url);

    // 5. Create UTI string for format
    const uti_str: [*:0]const u8 = switch (format) {
        .png => "public.png",
        .jpeg => "public.jpeg",
    };
    const uti = CFStringCreateWithCString(null, uti_str, kCFStringEncodingUTF8) orelse return error.EncoderFailed;
    defer CFRelease(uti);

    // 6. Create image destination
    const dest = CGImageDestinationCreateWithURL(url, uti, 1, null) orelse return error.WriteFailed;
    defer CFRelease(dest);

    // 7. Add image and finalize
    CGImageDestinationAddImage(dest, image, null);

    if (!CGImageDestinationFinalize(dest)) {
        return error.WriteFailed;
    }
}
