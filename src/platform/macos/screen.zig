/// macOS screen capture — ScreenCaptureKit implementation.
const std = @import("std");
const types = @import("types");
const objc = @import("objc.zig");

// ---------------------------------------------------------------------------
// GCD dispatch_semaphore (available on all macOS via libSystem)
// ---------------------------------------------------------------------------

const dispatch_semaphore_t = *opaque {};
extern "c" fn dispatch_semaphore_create(value: isize) ?dispatch_semaphore_t;
extern "c" fn dispatch_semaphore_wait(dsema: dispatch_semaphore_t, timeout: u64) isize;
extern "c" fn dispatch_semaphore_signal(dsema: dispatch_semaphore_t) isize;

// DISPATCH_TIME_FOREVER
const DISPATCH_TIME_FOREVER: u64 = ~@as(u64, 0);

// GCD dispatch_queue
const dispatch_queue_t = *opaque {};
extern "c" fn dispatch_queue_create(label: [*:0]const u8, attr: ?*anyopaque) ?dispatch_queue_t;

// ---------------------------------------------------------------------------
// Obj-C block ABI structures for async ScreenCaptureKit calls
// ---------------------------------------------------------------------------

const BlockDescriptor = extern struct {
    reserved: c_ulong,
    size: c_ulong,
};

const BlockLiteral = extern struct {
    isa: *anyopaque,
    flags: c_int,
    reserved: c_int,
    invoke: *const anyopaque,
    descriptor: *const BlockDescriptor,
};

// ---------------------------------------------------------------------------
// CoreMedia / CoreVideo externs
// ---------------------------------------------------------------------------

// Force CoreGraphics initialization (needed before window captures)
extern "c" fn CGMainDisplayID() u32;

extern "c" fn CMSampleBufferGetImageBuffer(sbuf: objc.id) ?objc.id;
extern "c" fn CVPixelBufferLockBaseAddress(pb: objc.id, flags: u64) i32;
extern "c" fn CVPixelBufferUnlockBaseAddress(pb: objc.id, flags: u64) i32;
extern "c" fn CVPixelBufferGetBaseAddress(pb: objc.id) ?[*]u8;
extern "c" fn CVPixelBufferGetBytesPerRow(pb: objc.id) usize;
extern "c" fn CVPixelBufferGetWidth(pb: objc.id) usize;
extern "c" fn CVPixelBufferGetHeight(pb: objc.id) usize;

extern "c" fn CMSampleBufferGetPresentationTimeStamp(sbuf: objc.id) CMTime;
extern "c" fn CMSampleBufferGetDataBuffer(sbuf: objc.id) ?objc.id;
extern "c" fn CMBlockBufferGetDataPointer(bbuf: objc.id, offset: usize, length_at_offset: ?*usize, total_length: ?*usize, data_pointer: *?[*]u8) i32;
extern "c" fn CMSampleBufferGetNumSamples(sbuf: objc.id) isize;
extern "c" fn CMSampleBufferGetFormatDescription(sbuf: objc.id) ?objc.id;

const AudioStreamBasicDescription = extern struct {
    mSampleRate: f64,
    mFormatID: u32,
    mFormatFlags: u32,
    mBytesPerPacket: u32,
    mFramesPerPacket: u32,
    mBytesPerFrame: u32,
    mChannelsPerFrame: u32,
    mBitsPerChannel: u32,
    mReserved: u32,
};

extern "c" fn CMAudioFormatDescriptionGetStreamBasicDescription(desc: objc.id) ?*const AudioStreamBasicDescription;

const CMTime = extern struct {
    value: i64,
    timescale: i32,
    flags: u32,
    epoch: i64,
};

/// Convert CMTime to nanoseconds, using 128-bit arithmetic to avoid overflow.
fn cmTimeToNanos(t: CMTime) u64 {
    if (t.timescale <= 0) return 0;
    // Use i128 to avoid overflow: value * 1_000_000_000 / timescale
    const ns_per_sec: i128 = 1_000_000_000;
    const result = @divTrunc(@as(i128, t.value) * ns_per_sec, @as(i128, t.timescale));
    if (result < 0) return 0;
    return @intCast(result);
}

// ---------------------------------------------------------------------------
// Shared state for the async SCShareableContent callback
// ---------------------------------------------------------------------------

var sc_content: ?objc.id = null;
var sc_error: ?objc.id = null;
var sc_semaphore: ?dispatch_semaphore_t = null;

fn shareableContentHandler(_: *const BlockLiteral, content: ?objc.id, err: ?objc.id) callconv(.c) void {
    sc_content = content;
    sc_error = err;
    // Retain the content so it survives the autorelease pool drain
    if (content) |c| {
        objc.msgSend(void, c, objc.sel("retain"), .{});
    }
    if (sc_semaphore) |sem| {
        _ = dispatch_semaphore_signal(sem);
    }
}

/// Fetch SCShareableContent synchronously (blocks until the async callback fires).
fn getShareableContent() !objc.id {
    const pool = objc.autoreleasePoolPush();
    defer objc.autoreleasePoolPop(pool);

    // Reset state
    sc_content = null;
    sc_error = null;

    const sem = dispatch_semaphore_create(0) orelse return error.BackendInitFailed;
    sc_semaphore = sem;

    const SCShareableContent = objc.getClass("SCShareableContent") orelse
        return error.BackendInitFailed;

    // Build an Obj-C compatible block for the completion handler.
    const desc = BlockDescriptor{
        .reserved = 0,
        .size = @sizeOf(BlockLiteral),
    };

    // _NSConcreteStackBlock
    const NSConcreteStackBlock = @as(
        *anyopaque,
        @ptrCast(@extern(*anyopaque, .{ .name = "_NSConcreteStackBlock" })),
    );

    var block = BlockLiteral{
        .isa = NSConcreteStackBlock,
        .flags = 0,
        .reserved = 0,
        .invoke = @ptrCast(&shareableContentHandler),
        .descriptor = &desc,
    };

    // Call [SCShareableContent getShareableContentWithCompletionHandler:]
    const send = objc.msgSendFn(void, struct { *BlockLiteral });
    const cls_as_id: objc.id = @ptrCast(SCShareableContent);
    send(
        cls_as_id,
        objc.sel("getShareableContentWithCompletionHandler:"),
        &block,
    );

    // Wait for the callback (blocks indefinitely)
    _ = dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

    sc_semaphore = null;

    if (sc_error != null) {
        if (sc_content) |c| {
            objc.msgSend(void, c, objc.sel("release"), .{});
        }
        return error.PermissionDenied;
    }

    return sc_content orelse error.BackendInitFailed;
}

// ---------------------------------------------------------------------------
// listDisplays
// ---------------------------------------------------------------------------

pub fn listDisplays(allocator: std.mem.Allocator) ![]types.Display {
    const content = try getShareableContent();
    defer objc.msgSend(void, content, objc.sel("release"), .{});

    const pool = objc.autoreleasePoolPush();
    defer objc.autoreleasePoolPop(pool);

    // [content displays] -> NSArray<SCDisplay*>
    const displays_array = objc.msgSend(objc.id, content, objc.sel("displays"), .{});
    const count = objc.nsArrayCount(displays_array);

    if (count == 0) {
        return allocator.alloc(types.Display, 0);
    }

    var result = try allocator.alloc(types.Display, count);
    errdefer allocator.free(result);

    for (0..count) |i| {
        const display = objc.nsArrayObjectAtIndex(displays_array, i);

        // [display displayID] -> CGDirectDisplayID (uint32_t)
        const display_id = objc.msgSend(u32, display, objc.sel("displayID"), .{});

        // [display width] -> NSInteger
        const width = objc.msgSend(objc.NSInteger, display, objc.sel("width"), .{});
        const height = objc.msgSend(objc.NSInteger, display, objc.sel("height"), .{});

        // SCDisplay doesn't expose a name property directly.
        // Use a simple index-based naming scheme.
        result[i] = .{
            .index = @intCast(i),
            .name = null,
            .width = @intCast(width),
            .height = @intCast(height),
            .platform_id = @intCast(display_id),
        };
    }

    return result;
}

// ---------------------------------------------------------------------------
// listWindows
// ---------------------------------------------------------------------------

pub fn listWindows(allocator: std.mem.Allocator) ![]types.Window {
    const content = try getShareableContent();
    defer objc.msgSend(void, content, objc.sel("release"), .{});

    const pool = objc.autoreleasePoolPush();
    defer objc.autoreleasePoolPop(pool);

    // [content windows] -> NSArray<SCWindow*>
    const windows_array = objc.msgSend(objc.id, content, objc.sel("windows"), .{});
    const count = objc.nsArrayCount(windows_array);

    if (count == 0) {
        return allocator.alloc(types.Window, 0);
    }

    // First pass: count on-screen windows with titles
    var valid_count: usize = 0;
    for (0..count) |i| {
        const window = objc.nsArrayObjectAtIndex(windows_array, i);

        // [window isOnScreen] -> BOOL
        const on_screen = objc.msgSend(bool, window, objc.sel("isOnScreen"), .{});
        if (!on_screen) continue;

        // [window title] -> NSString? (may be nil)
        const title_ns: ?objc.id = objc.msgSend(?objc.id, window, objc.sel("title"), .{});
        if (title_ns == null) continue;

        // Skip empty titles
        const title_len = objc.nsStringLength(title_ns.?);
        if (title_len == 0) continue;

        valid_count += 1;
    }

    var result = try allocator.alloc(types.Window, valid_count);
    errdefer allocator.free(result);

    // Second pass: populate
    var idx: usize = 0;
    for (0..count) |i| {
        const window = objc.nsArrayObjectAtIndex(windows_array, i);

        const on_screen = objc.msgSend(bool, window, objc.sel("isOnScreen"), .{});
        if (!on_screen) continue;

        const title_ns: ?objc.id = objc.msgSend(?objc.id, window, objc.sel("title"), .{});
        if (title_ns == null) continue;

        const title_len = objc.nsStringLength(title_ns.?);
        if (title_len == 0) continue;

        // Extract title
        const title_cstr: ?[*:0]const u8 = objc.fromNSString(title_ns.?);

        // [window windowID] -> CGWindowID (uint32_t)
        const window_id = objc.msgSend(u32, window, objc.sel("windowID"), .{});

        // [window owningApplication] -> SCRunningApplication?
        const app: ?objc.id = objc.msgSend(?objc.id, window, objc.sel("owningApplication"), .{});

        var app_name: ?[*:0]const u8 = null;
        var pid: u32 = 0;

        if (app) |a| {
            // [app applicationName] -> NSString?
            const name_ns: ?objc.id = objc.msgSend(?objc.id, a, objc.sel("applicationName"), .{});
            if (name_ns) |n| {
                app_name = objc.fromNSString(n);
            }

            // [app processID] -> pid_t (int32_t)
            const p = objc.msgSend(i32, a, objc.sel("processID"), .{});
            pid = @intCast(p);
        }

        result[idx] = .{
            .title = title_cstr,
            .app_name = app_name,
            .pid = pid,
            .window_id = @intCast(window_id),
            .display_index = 0, // SCWindow doesn't directly expose display index
        };
        idx += 1;
    }

    return result;
}

// ---------------------------------------------------------------------------
// Capture implementation
// ---------------------------------------------------------------------------

/// Heap-allocated state kept alive for the duration of a capture session.
const CaptureState = struct {
    stream: objc.id,
    delegate: objc.id,
};

// File-level callback storage (delegate method reads these)
var g_frame_cb: ?*const fn (types.VideoFrame) void = null;
var g_audio_cb: ?*const fn (types.AudioSamples) void = null;

// Start capture semaphore
var start_capture_sem: ?dispatch_semaphore_t = null;
var start_capture_error: bool = false;

fn startCaptureCompletionHandler(_: *const BlockLiteral, err: ?objc.id) callconv(.c) void {
    start_capture_error = (err != null);
    if (start_capture_sem) |sem| {
        _ = dispatch_semaphore_signal(sem);
    }
}

/// SCStreamOutput delegate method:  stream:didOutputSampleBuffer:ofType:
/// Signature: (id self, SEL _cmd, SCStream* stream, CMSampleBufferRef sampleBuffer, SCStreamOutputType type)
/// SCStreamOutputType: 0 = screen, 1 = audio
fn streamOutputHandler(
    _: objc.id, // self
    _: objc.SEL, // _cmd
    _: objc.id, // stream
    sample_buffer: objc.id, // CMSampleBufferRef
    output_type: objc.NSInteger, // SCStreamOutputType
) callconv(.c) void {
    if (output_type == 0) {
        // Video frame
        handleVideoSampleBuffer(sample_buffer);
    } else if (output_type == 1) {
        // Audio samples
        handleAudioSampleBuffer(sample_buffer);
    }
}

fn handleVideoSampleBuffer(sample_buffer: objc.id) void {
    const frame_cb = g_frame_cb orelse return;

    const image_buffer = CMSampleBufferGetImageBuffer(sample_buffer) orelse return;

    _ = CVPixelBufferLockBaseAddress(image_buffer, 1); // kCVPixelBufferLock_ReadOnly = 1
    defer _ = CVPixelBufferUnlockBaseAddress(image_buffer, 1);

    const base = CVPixelBufferGetBaseAddress(image_buffer) orelse return;
    const bytes_per_row = CVPixelBufferGetBytesPerRow(image_buffer);
    const width = CVPixelBufferGetWidth(image_buffer);
    const height = CVPixelBufferGetHeight(image_buffer);

    // Get presentation timestamp
    const pts = CMSampleBufferGetPresentationTimeStamp(sample_buffer);
    const timestamp_ns = cmTimeToNanos(pts);

    const frame = types.VideoFrame{
        .data = base,
        .len = bytes_per_row * height,
        .width = @intCast(width),
        .height = @intCast(height),
        .bytes_per_row = @intCast(bytes_per_row),
        .timestamp_ns = timestamp_ns,
    };

    frame_cb(frame);
}

// kAudioFormatFlagIsNonInterleaved = 0x20
const kAudioFormatFlagIsNonInterleaved: u32 = 0x20;

// Static buffer for interleaving planar audio (up to ~21ms at 48kHz stereo)
var interleave_buf: [4096]f32 = undefined;

fn handleAudioSampleBuffer(sample_buffer: objc.id) void {
    const audio_cb = g_audio_cb orelse return;

    const block_buffer = CMSampleBufferGetDataBuffer(sample_buffer) orelse return;

    var data_ptr: ?[*]u8 = null;
    var total_length: usize = 0;

    const bb_status = CMBlockBufferGetDataPointer(block_buffer, 0, null, &total_length, &data_ptr);
    if (bb_status != 0) return;
    const data = data_ptr orelse return;

    // Extract actual format from the sample buffer's format description
    const fmt_desc = CMSampleBufferGetFormatDescription(sample_buffer) orelse return;
    const asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt_desc) orelse return;

    const channels: u32 = asbd.mChannelsPerFrame;
    const sample_rate: u32 = @intFromFloat(asbd.mSampleRate);
    if (channels == 0) return;

    const num_samples = CMSampleBufferGetNumSamples(sample_buffer);
    if (num_samples <= 0) return;
    const frame_count: u32 = @intCast(num_samples);

    const pts = CMSampleBufferGetPresentationTimeStamp(sample_buffer);
    const timestamp_ns = cmTimeToNanos(pts);

    const is_non_interleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;

    if (is_non_interleaved and channels > 1) {
        // Planar layout: channel 0 data then channel 1 data, etc.
        // Interleave into [L0 R0 L1 R1 ...] format.
        const total_interleaved = @as(usize, frame_count) * @as(usize, channels);
        if (total_interleaved > interleave_buf.len) return;

        const src: [*]const f32 = @ptrCast(@alignCast(data));
        const fc: usize = @intCast(frame_count);

        for (0..fc) |i| {
            for (0..channels) |ch| {
                interleave_buf[i * channels + ch] = src[ch * fc + i];
            }
        }

        const samples = types.AudioSamples{
            .data = &interleave_buf,
            .frame_count = frame_count,
            .channels = channels,
            .sample_rate = sample_rate,
            .timestamp_ns = timestamp_ns,
        };
        audio_cb(samples);
    } else {
        // Already interleaved
        const float_data: [*]const f32 = @ptrCast(@alignCast(data));
        const samples = types.AudioSamples{
            .data = float_data,
            .frame_count = frame_count,
            .channels = channels,
            .sample_rate = sample_rate,
            .timestamp_ns = timestamp_ns,
        };
        audio_cb(samples);
    }
}

// Stop capture completion handler
var stop_capture_sem: ?dispatch_semaphore_t = null;

fn stopCaptureCompletionHandler(_: *const BlockLiteral, _: ?objc.id) callconv(.c) void {
    if (stop_capture_sem) |sem| {
        _ = dispatch_semaphore_signal(sem);
    }
}

// Flag to track if delegate class has been registered (can only do it once)
var delegate_class_registered: bool = false;
var delegate_class: ?objc.Class = null;

pub fn startCapture(
    target: types.CaptureTarget,
    config: types.CaptureConfig,
    frame_cb: *const fn (types.VideoFrame) void,
    audio_cb: ?*const fn (types.AudioSamples) void,
) !types.CaptureHandle {
    const pool = objc.autoreleasePoolPush();
    defer objc.autoreleasePoolPop(pool);

    // Force CoreGraphics initialization (required before window captures)
    _ = CGMainDisplayID();

    // Store callbacks in file-level vars
    g_frame_cb = frame_cb;
    g_audio_cb = audio_cb;

    // 1. Get shareable content
    const content = try getShareableContent();
    defer objc.msgSend(void, content, objc.sel("release"), .{});

    // 2. Build SCContentFilter based on target
    const filter = try buildContentFilter(target, content);

    // 3. Create SCStreamConfiguration
    const stream_config = try buildStreamConfig(config, target, content);

    // 4. Create SCStream
    const SCStream = objc.getClass("SCStream") orelse return error.BackendInitFailed;
    const stream_alloc = objc.msgSend(objc.id, SCStream, objc.sel("alloc"), .{});
    const stream = objc.msgSend(objc.id, stream_alloc, objc.sel("initWithFilter:configuration:delegate:"), .{
        filter,
        stream_config,
        @as(?objc.id, null),
    });

    // 5. Create and register delegate class for SCStreamOutput protocol
    if (!delegate_class_registered) {
        const NSObject = objc.getClass("NSObject") orelse return error.BackendInitFailed;
        delegate_class = objc.allocateClassPair(NSObject, "SpectacleStreamDelegate");
        if (delegate_class) |cls| {
            // Add the stream:didOutputSampleBuffer:ofType: method
            // Type encoding: v@:@@q  (void, id self, SEL _cmd, id stream, id sampleBuffer, NSInteger type)
            _ = objc.addMethod(
                cls,
                objc.sel("stream:didOutputSampleBuffer:ofType:"),
                @ptrCast(&streamOutputHandler),
                "v@:@@q",
            );

            // Add SCStreamOutput protocol
            _ = objc.addProtocol(cls, "SCStreamOutput");

            objc.registerClassPair(cls);
            delegate_class_registered = true;
        } else {
            return error.BackendInitFailed;
        }
    }

    // 6. Instantiate delegate
    const del_cls = delegate_class orelse return error.BackendInitFailed;
    const del_cls_id: objc.id = @ptrCast(del_cls);
    const del_alloc = objc.msgSend(objc.id, del_cls_id, objc.sel("alloc"), .{});
    const delegate = objc.msgSend(objc.id, del_alloc, objc.sel("init"), .{});

    // Retain delegate so it stays alive
    objc.msgSend(void, delegate, objc.sel("retain"), .{});

    // 7. Create dispatch queue for output
    const queue = dispatch_queue_create("com.spectacle.capture", null) orelse return error.BackendInitFailed;

    // 8. Add stream output: [stream addStreamOutput:delegate type:0 sampleHandlerQueue:queue error:nil]
    // SCStreamOutputType: 0 = screen
    const addOutputFn = @as(
        *const fn (objc.id, objc.SEL, objc.id, objc.NSInteger, dispatch_queue_t, ?*?objc.id) callconv(.c) u8,
        @ptrCast(&objc_msgSend),
    );
    const added_video = addOutputFn(
        stream,
        objc.sel("addStreamOutput:type:sampleHandlerQueue:error:"),
        delegate,
        0, // SCStreamOutputTypeScreen
        queue,
        null,
    );
    if (added_video == 0) {
        return error.BackendInitFailed;
    }

    // Add audio output if configured
    if (config.capture_audio and audio_cb != null) {
        const added_audio = addOutputFn(
            stream,
            objc.sel("addStreamOutput:type:sampleHandlerQueue:error:"),
            delegate,
            1, // SCStreamOutputTypeAudio
            queue,
            null,
        );
        _ = added_audio; // Audio output may fail on older macOS, not fatal
    }

    // 9. Start capture synchronously
    const sem = dispatch_semaphore_create(0) orelse return error.BackendInitFailed;
    start_capture_sem = sem;
    start_capture_error = false;

    const NSConcreteStackBlock = @as(
        *anyopaque,
        @ptrCast(@extern(*anyopaque, .{ .name = "_NSConcreteStackBlock" })),
    );

    const desc = BlockDescriptor{
        .reserved = 0,
        .size = @sizeOf(BlockLiteral),
    };

    var start_block = BlockLiteral{
        .isa = NSConcreteStackBlock,
        .flags = 0,
        .reserved = 0,
        .invoke = @ptrCast(&startCaptureCompletionHandler),
        .descriptor = &desc,
    };

    objc.msgSend(void, stream, objc.sel("startCaptureWithCompletionHandler:"), .{&start_block});

    _ = dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    start_capture_sem = null;

    if (start_capture_error) {
        return error.PermissionDenied;
    }

    // Retain stream
    objc.msgSend(void, stream, objc.sel("retain"), .{});

    // 10. Allocate CaptureState on heap
    const state = std.heap.page_allocator.create(CaptureState) catch return error.BackendInitFailed;
    state.* = .{
        .stream = stream,
        .delegate = delegate,
    };

    return types.CaptureHandle{
        .platform_handle = @ptrCast(state),
    };
}

pub fn stopCapture(handle: types.CaptureHandle) void {
    const state: *CaptureState = @ptrCast(@alignCast(handle.platform_handle));

    const pool = objc.autoreleasePoolPush();
    defer objc.autoreleasePoolPop(pool);

    // Stop capture synchronously
    const sem = dispatch_semaphore_create(0) orelse return;
    stop_capture_sem = sem;

    const NSConcreteStackBlock = @as(
        *anyopaque,
        @ptrCast(@extern(*anyopaque, .{ .name = "_NSConcreteStackBlock" })),
    );

    const desc = BlockDescriptor{
        .reserved = 0,
        .size = @sizeOf(BlockLiteral),
    };

    var stop_block = BlockLiteral{
        .isa = NSConcreteStackBlock,
        .flags = 0,
        .reserved = 0,
        .invoke = @ptrCast(&stopCaptureCompletionHandler),
        .descriptor = &desc,
    };

    objc.msgSend(void, state.stream, objc.sel("stopCaptureWithCompletionHandler:"), .{&stop_block});

    _ = dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    stop_capture_sem = null;

    // Release the stream and delegate
    objc.msgSend(void, state.stream, objc.sel("release"), .{});
    objc.msgSend(void, state.delegate, objc.sel("release"), .{});

    // Clear callbacks
    g_frame_cb = null;
    g_audio_cb = null;

    // Free state
    std.heap.page_allocator.destroy(state);
}

// ---------------------------------------------------------------------------
// Helpers for building SCContentFilter and SCStreamConfiguration
// ---------------------------------------------------------------------------

// Need objc_msgSend extern for direct function pointer casts
extern "objc" fn objc_msgSend() void;

fn buildContentFilter(target: types.CaptureTarget, content: objc.id) !objc.id {
    const SCContentFilter = objc.getClass("SCContentFilter") orelse return error.BackendInitFailed;

    switch (target) {
        .display => |display_index| {
            // Find the display at the given index
            const displays_array = objc.msgSend(objc.id, content, objc.sel("displays"), .{});
            const count = objc.nsArrayCount(displays_array);
            if (display_index >= count) return error.TargetNotFound;

            const display = objc.nsArrayObjectAtIndex(displays_array, display_index);

            // Create empty NSArray for excludingWindows
            const NSArray = objc.getClass("NSArray") orelse return error.BackendInitFailed;
            const empty_array = objc.msgSend(objc.id, NSArray, objc.sel("array"), .{});

            const filter_alloc = objc.msgSend(objc.id, SCContentFilter, objc.sel("alloc"), .{});
            return objc.msgSend(objc.id, filter_alloc, objc.sel("initWithDisplay:excludingWindows:"), .{
                display,
                empty_array,
            });
        },

        .window_id => |wid| {
            const window = try findWindowById(content, wid);
            const filter_alloc = objc.msgSend(objc.id, SCContentFilter, objc.sel("alloc"), .{});
            return objc.msgSend(objc.id, filter_alloc, objc.sel("initWithDesktopIndependentWindow:"), .{window});
        },

        .window_title => |title_z| {
            const window = try findWindowByTitle(content, std.mem.sliceTo(title_z, 0));
            const filter_alloc = objc.msgSend(objc.id, SCContentFilter, objc.sel("alloc"), .{});
            return objc.msgSend(objc.id, filter_alloc, objc.sel("initWithDesktopIndependentWindow:"), .{window});
        },

        .window_pid => |pid| {
            const window = try findWindowByPid(content, pid);
            const filter_alloc = objc.msgSend(objc.id, SCContentFilter, objc.sel("alloc"), .{});
            return objc.msgSend(objc.id, filter_alloc, objc.sel("initWithDesktopIndependentWindow:"), .{window});
        },

        .region => |region| {
            // Use display filter, sourceRect will be set on stream config
            const displays_array = objc.msgSend(objc.id, content, objc.sel("displays"), .{});
            const count = objc.nsArrayCount(displays_array);
            if (region.display >= count) return error.TargetNotFound;

            const display = objc.nsArrayObjectAtIndex(displays_array, region.display);

            const NSArray = objc.getClass("NSArray") orelse return error.BackendInitFailed;
            const empty_array = objc.msgSend(objc.id, NSArray, objc.sel("array"), .{});

            const filter_alloc = objc.msgSend(objc.id, SCContentFilter, objc.sel("alloc"), .{});
            return objc.msgSend(objc.id, filter_alloc, objc.sel("initWithDisplay:excludingWindows:"), .{
                display,
                empty_array,
            });
        },
    }
}

const CGRect = extern struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

fn getWindowFrame(content: objc.id, target: types.CaptureTarget) ?CGRect {
    const window = switch (target) {
        .window_id => |wid| findWindowById(content, wid) catch return null,
        .window_title => |title_z| findWindowByTitle(content, std.mem.sliceTo(title_z, 0)) catch return null,
        .window_pid => |pid| findWindowByPid(content, pid) catch return null,
        else => return null,
    };
    // SCWindow.frame returns CGRect (32 bytes — fits in arm64 registers)
    const frameFn = @as(*const fn (objc.id, objc.SEL) callconv(.c) CGRect, @ptrCast(&objc_msgSend));
    return frameFn(window, objc.sel("frame"));
}

fn buildStreamConfig(config: types.CaptureConfig, target: types.CaptureTarget, content: objc.id) !objc.id {
    const SCStreamConfiguration = objc.getClass("SCStreamConfiguration") orelse return error.BackendInitFailed;
    const stream_config_alloc = objc.msgSend(objc.id, SCStreamConfiguration, objc.sel("alloc"), .{});
    const stream_config = objc.msgSend(objc.id, stream_config_alloc, objc.sel("init"), .{});

    // Get dimensions for sizing
    var capture_width: usize = 1920;
    var capture_height: usize = 1080;

    switch (target) {
        .display => |display_index| {
            const displays_array = objc.msgSend(objc.id, content, objc.sel("displays"), .{});
            const count = objc.nsArrayCount(displays_array);
            if (display_index < count) {
                const display = objc.nsArrayObjectAtIndex(displays_array, display_index);
                capture_width = @intCast(objc.msgSend(objc.NSInteger, display, objc.sel("width"), .{}));
                capture_height = @intCast(objc.msgSend(objc.NSInteger, display, objc.sel("height"), .{}));
            }
        },
        .region => |region| {
            capture_width = region.w;
            capture_height = region.h;
        },
        .window_id, .window_title, .window_pid => {
            // Use the target window's frame dimensions
            if (getWindowFrame(content, target)) |frame| {
                if (frame.width > 0 and frame.height > 0) {
                    capture_width = @intFromFloat(frame.width);
                    capture_height = @intFromFloat(frame.height);
                }
            }
        },
    }

    // Get Retina backing scale factor from NSScreen.mainScreen
    // SCDisplay width/height returns logical points; multiply by backing scale for native pixels
    var backing_scale: f64 = 2.0; // default to 2x Retina
    const NSScreen = objc.getClass("NSScreen");
    if (NSScreen) |cls| {
        const main_screen: ?objc.id = objc.msgSend(?objc.id, @as(objc.id, @ptrCast(cls)), objc.sel("mainScreen"), .{});
        if (main_screen) |screen| {
            const scale_fn = @as(*const fn (objc.id, objc.SEL) callconv(.c) f64, @ptrCast(&objc_msgSend));
            backing_scale = scale_fn(screen, objc.sel("backingScaleFactor"));
        }
    }

    // Apply backing scale (logical → native pixels) then user's scale factor
    const scaled_width: usize = @intFromFloat(@as(f64, @floatFromInt(capture_width)) * backing_scale * @as(f64, config.scale));
    const scaled_height: usize = @intFromFloat(@as(f64, @floatFromInt(capture_height)) * backing_scale * @as(f64, config.scale));

    // setWidth: / setHeight:
    msgSendWithNSUInteger(stream_config, objc.sel("setWidth:"), scaled_width);
    msgSendWithNSUInteger(stream_config, objc.sel("setHeight:"), scaled_height);

    // setPixelFormat: kCVPixelFormatType_32BGRA = 'BGRA' = 0x42475241
    msgSendWithU32(stream_config, objc.sel("setPixelFormat:"), 0x42475241);

    // setMinimumFrameInterval: CMTime{1, fps}
    const frame_interval = CMTime{
        .value = 1,
        .timescale = @intCast(config.fps),
        .flags = 1, // kCMTimeFlags_Valid
        .epoch = 0,
    };
    const setIntervalFn = @as(
        *const fn (objc.id, objc.SEL, CMTime) callconv(.c) void,
        @ptrCast(&objc_msgSend),
    );
    setIntervalFn(stream_config, objc.sel("setMinimumFrameInterval:"), frame_interval);

    // setCapturesAudio:
    objc.msgSend(void, stream_config, objc.sel("setCapturesAudio:"), .{@as(u8, if (config.capture_audio) 1 else 0)});

    if (config.capture_audio) {
        // setSampleRate:
        msgSendWithNSInteger(stream_config, objc.sel("setSampleRate:"), @intCast(config.sample_rate));

        // setChannelCount:
        msgSendWithNSInteger(stream_config, objc.sel("setChannelCount:"), @intCast(config.channels));
    }

    // setShowsCursor:
    objc.msgSend(void, stream_config, objc.sel("setShowsCursor:"), .{@as(u8, if (config.show_cursor) 1 else 0)});

    // Handle region: set sourceRect on config
    if (target == .region) {
        const region = target.region;
        // sourceRect is a CGRect
        const setCGRectFn = @as(
            *const fn (objc.id, objc.SEL, f64, f64, f64, f64) callconv(.c) void,
            @ptrCast(&objc_msgSend),
        );
        // SCStreamConfiguration doesn't have setSourceRect directly with 4 doubles,
        // it takes a CGRect struct. But CGRect is { CGPoint origin, CGSize size } which
        // on arm64 macOS is passed in registers as 4 doubles.
        setCGRectFn(
            stream_config,
            objc.sel("setSourceRect:"),
            @floatFromInt(region.x),
            @floatFromInt(region.y),
            @floatFromInt(region.w),
            @floatFromInt(region.h),
        );
    }

    return stream_config;
}

// Helpers for sending messages with NSUInteger/NSInteger/u32 args
fn msgSendWithNSUInteger(target: objc.id, selector: objc.SEL, value: objc.NSUInteger) void {
    const func = @as(
        *const fn (objc.id, objc.SEL, objc.NSUInteger) callconv(.c) void,
        @ptrCast(&objc_msgSend),
    );
    func(target, selector, value);
}

fn msgSendWithNSInteger(target: objc.id, selector: objc.SEL, value: objc.NSInteger) void {
    const func = @as(
        *const fn (objc.id, objc.SEL, objc.NSInteger) callconv(.c) void,
        @ptrCast(&objc_msgSend),
    );
    func(target, selector, value);
}

fn msgSendWithU32(target: objc.id, selector: objc.SEL, value: u32) void {
    const func = @as(
        *const fn (objc.id, objc.SEL, u32) callconv(.c) void,
        @ptrCast(&objc_msgSend),
    );
    func(target, selector, value);
}

// ---------------------------------------------------------------------------
// Window finding helpers
// ---------------------------------------------------------------------------

fn findWindowById(content: objc.id, wid: u64) !objc.id {
    const windows_array = objc.msgSend(objc.id, content, objc.sel("windows"), .{});
    const count = objc.nsArrayCount(windows_array);

    for (0..count) |i| {
        const window = objc.nsArrayObjectAtIndex(windows_array, i);
        const window_id = objc.msgSend(u32, window, objc.sel("windowID"), .{});
        if (@as(u64, window_id) == wid) {
            return window;
        }
    }

    return error.TargetNotFound;
}

fn findWindowByTitle(content: objc.id, search_title: []const u8) !objc.id {
    const windows_array = objc.msgSend(objc.id, content, objc.sel("windows"), .{});
    const count = objc.nsArrayCount(windows_array);

    // Convert search title to lowercase for case-insensitive matching
    var search_lower: [256]u8 = undefined;
    const search_len = @min(search_title.len, search_lower.len);
    for (0..search_len) |i| {
        search_lower[i] = std.ascii.toLower(search_title[i]);
    }
    const search_slice = search_lower[0..search_len];

    for (0..count) |i| {
        const window = objc.nsArrayObjectAtIndex(windows_array, i);

        const on_screen = objc.msgSend(bool, window, objc.sel("isOnScreen"), .{});
        if (!on_screen) continue;

        const title_ns: ?objc.id = objc.msgSend(?objc.id, window, objc.sel("title"), .{});
        if (title_ns == null) continue;

        const title_cstr: ?[*:0]const u8 = objc.fromNSString(title_ns.?);
        if (title_cstr == null) continue;

        const title_slice = std.mem.sliceTo(title_cstr.?, 0);

        // Case-insensitive substring match
        var title_lower: [512]u8 = undefined;
        const title_len = @min(title_slice.len, title_lower.len);
        for (0..title_len) |j| {
            title_lower[j] = std.ascii.toLower(title_slice[j]);
        }

        if (std.mem.indexOf(u8, title_lower[0..title_len], search_slice) != null) {
            return window;
        }
    }

    // Also check app names
    for (0..count) |i| {
        const window = objc.nsArrayObjectAtIndex(windows_array, i);

        const on_screen = objc.msgSend(bool, window, objc.sel("isOnScreen"), .{});
        if (!on_screen) continue;

        const app: ?objc.id = objc.msgSend(?objc.id, window, objc.sel("owningApplication"), .{});
        if (app == null) continue;

        const name_ns: ?objc.id = objc.msgSend(?objc.id, app.?, objc.sel("applicationName"), .{});
        if (name_ns == null) continue;

        const name_cstr: ?[*:0]const u8 = objc.fromNSString(name_ns.?);
        if (name_cstr == null) continue;

        const name_slice = std.mem.sliceTo(name_cstr.?, 0);

        var name_lower: [256]u8 = undefined;
        const name_len = @min(name_slice.len, name_lower.len);
        for (0..name_len) |j| {
            name_lower[j] = std.ascii.toLower(name_slice[j]);
        }

        if (std.mem.indexOf(u8, name_lower[0..name_len], search_slice) != null) {
            return window;
        }
    }

    return error.TargetNotFound;
}

fn findWindowByPid(content: objc.id, pid: u32) !objc.id {
    const windows_array = objc.msgSend(objc.id, content, objc.sel("windows"), .{});
    const count = objc.nsArrayCount(windows_array);

    for (0..count) |i| {
        const window = objc.nsArrayObjectAtIndex(windows_array, i);

        const on_screen = objc.msgSend(bool, window, objc.sel("isOnScreen"), .{});
        if (!on_screen) continue;

        const app: ?objc.id = objc.msgSend(?objc.id, window, objc.sel("owningApplication"), .{});
        if (app == null) continue;

        const p = objc.msgSend(i32, app.?, objc.sel("processID"), .{});
        if (p >= 0 and @as(u32, @intCast(p)) == pid) {
            return window;
        }
    }

    return error.TargetNotFound;
}
