# Screenshot Feature Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `spectacle screenshot` subcommand that captures a single frame to PNG or JPEG, supporting window/app targeting by name.

**Architecture:** Reuse existing `startCapture`/`stopCapture` ScreenCaptureKit flow. A new `captureScreenshot` function starts a stream, copies the first frame's pixel data, signals a semaphore, then the main thread encodes via CoreGraphics ImageIO and writes to disk.

**Tech Stack:** Zig, ScreenCaptureKit, CoreGraphics, ImageIO (macOS)

**Spec:** `docs/superpowers/specs/2026-06-12-screenshot-design.md`

---

## File Structure

| File | Responsibility |
|------|---------------|
| `src/types.zig` | Add `ImageFormat` enum |
| `src/platform/macos/image.zig` | **New.** CoreGraphics/ImageIO encoding (BGRA → PNG/JPEG) |
| `src/platform/macos/screen.zig` | Add `captureScreenshot` — one-frame capture flow |
| `src/platform/linux/screen.zig` | Stub `captureScreenshot` |
| `src/platform/windows/screen.zig` | Stub `captureScreenshot` |
| `src/capture.zig` | Re-export `captureScreenshot` |
| `build.zig` | Link `ImageIO` framework on `capture_mod` |
| `src/main.zig` | Add `screenshot` subcommand + `runScreenshot` function |

---

### Task 1: Add `ImageFormat` to types

**Files:**
- Modify: `src/types.zig:45` (after `CaptureTarget` union)

- [ ] **Step 1: Add the ImageFormat enum**

In `src/types.zig`, add after the `CaptureTarget` union (after line 45):

```zig
pub const ImageFormat = enum {
    png,
    jpeg,
};
```

- [ ] **Step 2: Verify it compiles**

Run: `zig build 2>&1 | head -20`
Expected: successful build (no references to `ImageFormat` yet, just checking syntax)

- [ ] **Step 3: Commit**

```bash
git add src/types.zig
git commit -m "Add ImageFormat enum to types"
```

---

### Task 2: Create macOS image encoder (`image.zig`)

**Files:**
- Create: `src/platform/macos/image.zig`

This file provides a single function: `writeImageToFile` that takes raw BGRA pixel data and writes a PNG or JPEG using CoreGraphics + ImageIO.

- [ ] **Step 1: Create `src/platform/macos/image.zig`**

```zig
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
```

- [ ] **Step 2: Verify it compiles**

Run: `zig build 2>&1 | head -20`
Expected: successful build (file not imported yet, but no syntax errors in the module)

Note: This file won't actually compile standalone since it depends on the `types` and `objc.zig` imports that come through the capture module. We'll verify it properly in Task 4.

- [ ] **Step 3: Commit**

```bash
git add src/platform/macos/image.zig
git commit -m "Add macOS image encoder using CoreGraphics/ImageIO"
```

---

### Task 3: Link ImageIO framework in build.zig

**Files:**
- Modify: `build.zig:44-51` (macOS framework linkage for capture_mod)

- [ ] **Step 1: Add ImageIO framework linkage**

In `build.zig`, inside the `.macos` switch case for `capture_mod` (line 44-51), add after the existing framework links:

```zig
capture_mod.linkFramework("ImageIO", .{});
```

So the block becomes:
```zig
.macos => {
    capture_mod.linkSystemLibrary("objc", .{});
    capture_mod.linkFramework("Foundation", .{});
    capture_mod.linkFramework("CoreMedia", .{});
    capture_mod.linkFramework("ScreenCaptureKit", .{});
    capture_mod.linkFramework("CoreGraphics", .{});
    capture_mod.linkFramework("AVFoundation", .{});
    capture_mod.linkFramework("ImageIO", .{});
},
```

- [ ] **Step 2: Verify it compiles**

Run: `zig build 2>&1 | head -20`
Expected: successful build

- [ ] **Step 3: Commit**

```bash
git add build.zig
git commit -m "Link ImageIO framework for screenshot encoding"
```

---

### Task 4: Add `captureScreenshot` to macOS screen.zig

**Files:**
- Modify: `src/platform/macos/screen.zig` (add after `stopCapture`, around line 650)

- [ ] **Step 1: Add screenshot state variables and frame handler**

Add the following after the `stopMicCapture` function at the end of `screen.zig`:

```zig
// ---------------------------------------------------------------------------
// Screenshot capture (single frame)
// ---------------------------------------------------------------------------

const image = @import("image.zig");

// Screenshot state: owned copy of first frame's pixel data
var screenshot_data: ?[]u8 = null;
var screenshot_width: u32 = 0;
var screenshot_height: u32 = 0;
var screenshot_bytes_per_row: u32 = 0;
var screenshot_sem: ?dispatch_semaphore_t = null;
var screenshot_captured: bool = false;

fn screenshotFrameCallback(frame: types.VideoFrame) void {
    // Only capture the first frame
    if (screenshot_captured) return;

    // Copy pixel data to owned buffer (CVPixelBuffer released after callback)
    const alloc = std.heap.page_allocator;
    const buf = alloc.alloc(u8, frame.len) catch return;
    @memcpy(buf, frame.data[0..frame.len]);

    screenshot_data = buf;
    screenshot_width = frame.width;
    screenshot_height = frame.height;
    screenshot_bytes_per_row = frame.bytes_per_row;
    screenshot_captured = true;

    // Signal main thread
    if (screenshot_sem) |sem| {
        _ = dispatch_semaphore_signal(sem);
    }
}

pub fn captureScreenshot(
    target: types.CaptureTarget,
    config: types.CaptureConfig,
    output_path: [*:0]const u8,
    format: types.ImageFormat,
) !void {
    // Reset screenshot state
    screenshot_data = null;
    screenshot_width = 0;
    screenshot_height = 0;
    screenshot_bytes_per_row = 0;
    screenshot_captured = false;

    // Create semaphore for waiting on first frame
    const sem = dispatch_semaphore_create(0) orelse return error.BackendInitFailed;
    screenshot_sem = sem;

    // Start capture with our screenshot callback (no audio)
    const handle = try startCapture(target, config, &screenshotFrameCallback, null);

    // Wait for first frame with 5-second timeout
    // dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)
    const timeout_ns: u64 = 5_000_000_000;
    const deadline = dispatch_time(0, @intCast(timeout_ns));
    const wait_result = dispatch_semaphore_wait(sem, deadline);
    screenshot_sem = null;

    // Stop capture regardless
    stopCapture(handle);

    // Check if we got a frame
    if (wait_result != 0) {
        // Timeout — no frame received
        if (screenshot_data) |d| {
            std.heap.page_allocator.free(d);
            screenshot_data = null;
        }
        return error.BackendInitFailed;
    }

    const data = screenshot_data orelse return error.BackendInitFailed;
    defer {
        std.heap.page_allocator.free(data);
        screenshot_data = null;
    }

    // Encode and write to disk
    try image.writeImageToFile(
        data,
        screenshot_width,
        screenshot_height,
        screenshot_bytes_per_row,
        output_path,
        format,
    );
}
```

- [ ] **Step 2: Add `dispatch_time` extern**

Near the top of `screen.zig`, with the other dispatch externs (around line 11-13), add:

```zig
extern "c" fn dispatch_time(when: u64, delta: i64) u64;
```

- [ ] **Step 3: Verify it compiles**

Run: `zig build 2>&1 | head -20`
Expected: successful build

- [ ] **Step 4: Commit**

```bash
git add src/platform/macos/screen.zig src/platform/macos/image.zig
git commit -m "Add captureScreenshot to macOS screen capture"
```

---

### Task 5: Add stubs for Linux and Windows

**Files:**
- Modify: `src/platform/linux/screen.zig` (add at end)
- Modify: `src/platform/windows/screen.zig` (add at end)

- [ ] **Step 1: Add stub to Linux**

Append to `src/platform/linux/screen.zig`:

```zig
pub fn captureScreenshot(
    target: types.CaptureTarget,
    config: types.CaptureConfig,
    output_path: [*:0]const u8,
    format: types.ImageFormat,
) !void {
    _ = target;
    _ = config;
    _ = output_path;
    _ = format;
    return error.Unsupported;
}
```

- [ ] **Step 2: Add identical stub to Windows**

Append the same function to `src/platform/windows/screen.zig`.

- [ ] **Step 3: Verify it compiles**

Run: `zig build 2>&1 | head -20`
Expected: successful build

- [ ] **Step 4: Commit**

```bash
git add src/platform/linux/screen.zig src/platform/windows/screen.zig
git commit -m "Add captureScreenshot stubs for Linux and Windows"
```

---

### Task 6: Re-export `captureScreenshot` from `capture.zig`

**Files:**
- Modify: `src/capture.zig` (add after `stopMicCapture`)

- [ ] **Step 1: Add the re-export**

Append to `src/capture.zig`:

```zig
pub const ImageFormat = types.ImageFormat;

pub fn captureScreenshot(
    target: CaptureTarget,
    config: CaptureConfig,
    output_path: [*:0]const u8,
    format: ImageFormat,
) !void {
    return platform.captureScreenshot(target, config, output_path, format);
}
```

- [ ] **Step 2: Verify it compiles**

Run: `zig build 2>&1 | head -20`
Expected: successful build

- [ ] **Step 3: Commit**

```bash
git add src/capture.zig
git commit -m "Re-export captureScreenshot from cross-platform capture module"
```

---

### Task 7: Add `screenshot` subcommand to `main.zig`

**Files:**
- Modify: `src/main.zig`

- [ ] **Step 1: Add `screenshot` to usage text**

In `printUsage` (line 37), add after the `audio` line:

```
\\  screenshot          Take a screenshot (PNG or JPEG)
```

Add screenshot example at the end of the examples section (around line 67):

```
\\  spectacle screenshot --output shot.png
\\  spectacle screenshot --window "Chrome" --output page.png
```

- [ ] **Step 2: Add `runScreenshot` function**

Add the `runScreenshot` function before the `main` function (around line 958). Model it after `runRecord` but simpler — no audio, no signal handler, no run loop:

```zig
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
        const timestamp = cTime(null);
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
```

- [ ] **Step 3: Add command dispatch**

In the `main` function's command dispatch section (around line 997), add after the `record` branch:

```zig
} else if (std.mem.eql(u8, command, "screenshot")) {
    try runScreenshot(&args_iter, &stderr.interface);
```

- [ ] **Step 4: Verify it compiles**

Run: `zig build 2>&1 | head -20`
Expected: successful build

- [ ] **Step 5: Commit**

```bash
git add src/main.zig
git commit -m "Add screenshot subcommand to CLI"
```

---

### Task 8: Manual smoke test

- [ ] **Step 1: Build**

Run: `zig build -Doptimize=ReleaseFast`

- [ ] **Step 2: Test basic screenshot (full display)**

Run: `./zig-out/bin/spectacle screenshot --output /tmp/test_screenshot.png`
Expected: "Screenshot saved: /tmp/test_screenshot.png" — verify the file is a valid PNG.

- [ ] **Step 3: Test window capture by name**

Run: `./zig-out/bin/spectacle screenshot --window "Finder" --output /tmp/test_window.png`
Expected: Screenshot of a Finder window.

- [ ] **Step 4: Test JPEG output**

Run: `./zig-out/bin/spectacle screenshot --output /tmp/test_screenshot.jpg`
Expected: Valid JPEG file.

- [ ] **Step 5: Test app capture**

Run: `./zig-out/bin/spectacle screenshot --app "Terminal" --output /tmp/test_app.png`
Expected: Screenshot of Terminal.

- [ ] **Step 6: Test error cases**

Run: `./zig-out/bin/spectacle screenshot --output /tmp/test_screenshot.bmp`
Expected: "Error: unsupported screenshot format. Use .png or .jpg/.jpeg"

Run: `./zig-out/bin/spectacle screenshot --output /tmp/test_screenshot.png`
Expected: "Error: output file already exists: /tmp/test_screenshot.png"

- [ ] **Step 7: Clean up test files**

```bash
rm /tmp/test_screenshot.png /tmp/test_window.png /tmp/test_screenshot.jpg /tmp/test_app.png
```

- [ ] **Step 8: Commit (if any fixes were needed)**

---

### Task 9: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add screenshot examples to usage block**

In the usage examples at the top of README.md, add:

```bash
spectacle screenshot --output shot.png            # take a screenshot
spectacle screenshot --app "Chrome" --output p.png # capture a specific app
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "Add screenshot command to README"
```
