# Screenshot Capture Feature

## Summary

Add a `spectacle screenshot` subcommand that captures a single frame and writes it to a PNG or JPEG file. Reuses the existing targeting system (`--window`, `--app`, `--pid`, `--display`, `--region`) so users can capture specific windows by name — something macOS `screencapture` cannot do without first looking up a window ID.

## CLI Interface

```
spectacle screenshot [options]
```

### Options

All existing targeting flags apply:

| Flag | Description |
|------|-------------|
| `--output FILE` | Output path. Default: `screenshot.png`. Format inferred from extension. |
| `--window NAME` | Capture specific window by title (substring match) |
| `--app NAME` | Capture specific app by name (same as `--window` — matches via window title) |
| `--pid PID` | Capture by process ID |
| `--display N` | Which display (default: 0) |
| `--region X,Y,W,H` | Capture a screen region |
| `--scale F` | Resolution scale factor (default: 1.0) |
| `--no-cursor` | Hide cursor |

Audio flags (`--no-audio`, `--mic`, `--sample-rate`, `--channels`) are ignored/inapplicable.

### Output Formats

- `.png` — default, lossless
- `.jpg` / `.jpeg` — lossy, smaller files

## Architecture

### Flow

1. Parse args, resolve `CaptureTarget` (same logic as `record`)
2. Start a ScreenCaptureKit capture targeting the display/window
3. Frame callback receives the first `VideoFrame` (BGRA pixel data)
4. **Inside the callback**: copy pixel data to an owned buffer (the underlying `CVPixelBuffer` is only valid for the duration of the callback)
5. Signal a dispatch semaphore to wake the main thread
6. Main thread encodes the copied BGRA data to PNG or JPEG using CoreGraphics
7. Write to disk, stop capture, exit

**Timeout**: If no frame is received within 5 seconds (e.g., window minimized, stream produces no frames), exit with a `runtime_error` and a descriptive message. Use `dispatch_semaphore_wait` with `dispatch_time` for the timed wait.

### Image Encoding — macOS

Use CoreGraphics + ImageIO APIs (zero additional dependencies):

- `CGImageCreate` — create a `CGImage` from raw BGRA pixel buffer
- `CGImageDestinationCreateWithURL` — create a destination file (from **ImageIO** framework)
- `CGImageDestinationAddImage` — add the image
- `CGImageDestinationFinalize` — write to disk

Format is selected by UTI string: `"public.png"` or `"public.jpeg"` (hardcoded string literals, avoids needing to link CoreServices for `kUTTypePNG`/`kUTTypeJPEG` constants).

### Function Signature

```zig
pub fn captureScreenshot(
    target: CaptureTarget,
    config: CaptureConfig,
    output_path: [*:0]const u8,
    format: ImageFormat,
) CaptureError!void
```

This keeps encoding platform-specific and internal — the caller just says "capture this target to this file."

### Cross-Platform

Linux and Windows stubs will return `CaptureError.Unsupported` for now. When a Zig-native PNG/JPEG encoder is added later, it can replace the CoreGraphics path and work everywhere.

## Files to Modify

| File | Change |
|------|--------|
| `src/main.zig` | Add `screenshot` subcommand parsing, call screenshot flow |
| `src/capture.zig` | Re-export `captureScreenshot` from platform module |
| `src/platform/macos/screen.zig` | Add `captureScreenshot` — starts capture, grabs one frame, stops |
| `src/platform/macos/image.zig` | **New file.** ImageIO-based encoding (BGRA -> PNG/JPEG) |
| `src/platform/linux/screen.zig` | Stub: return `Unsupported` |
| `src/platform/windows/screen.zig` | Stub: return `Unsupported` |
| `src/types.zig` | Add `ImageFormat` enum (`png`, `jpeg`) |
| `build.zig` | Link `ImageIO` framework on `capture_mod` |

## Implementation Notes

- `captureScreenshot` reuses the existing `startCapture`/`stopCapture` internally — start a stream, grab the first frame, stop. This avoids duplicating the ScreenCaptureKit setup logic.
- The frame callback must **copy** pixel data to an owned buffer before returning, since the `CVPixelBuffer` backing `VideoFrame.data` is released after the callback.
- The frame callback signals completion via a dispatch semaphore (same pattern already used for `SCShareableContent` enumeration).
- 5-second timeout on frame receipt prevents hanging if the stream never delivers.
- No delay flag — users can `sleep N && spectacle screenshot` if needed.
- Default output filename: `screenshot.png`.
