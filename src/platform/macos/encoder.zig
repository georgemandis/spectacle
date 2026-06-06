/// macOS encoder — AVAssetWriter implementation for MP4/MOV output.
///
/// Note: Obj-C runtime bindings are inlined here rather than importing objc.zig
/// because Zig 0.16 requires each source file to belong to exactly one module,
/// and objc.zig is already claimed by the capture module via screen.zig.
const std = @import("std");
const types = @import("types");

// ---------------------------------------------------------------------------
// Inline Obj-C runtime bindings (subset needed for encoder)
// ---------------------------------------------------------------------------

const Class = *opaque {};
const SEL = *opaque {};
const id = *opaque {};
const NSUInteger = usize;
const NSInteger = isize;

extern "objc" fn objc_getClass(name: [*:0]const u8) ?Class;
extern "objc" fn sel_registerName(name: [*:0]const u8) SEL;
extern "objc" fn objc_msgSend() void;

fn getClass(name: [*:0]const u8) ?Class {
    return objc_getClass(name);
}

fn sel(name: [*:0]const u8) SEL {
    return sel_registerName(name);
}

fn MsgSendFnType(comptime ReturnType: type, comptime ArgTypes: type) type {
    const args_info = @typeInfo(ArgTypes);
    const fields = args_info.@"struct".fields;

    return switch (fields.len) {
        0 => *const fn (id, SEL) callconv(.c) ReturnType,
        1 => *const fn (id, SEL, fields[0].type) callconv(.c) ReturnType,
        2 => *const fn (id, SEL, fields[0].type, fields[1].type) callconv(.c) ReturnType,
        3 => *const fn (id, SEL, fields[0].type, fields[1].type, fields[2].type) callconv(.c) ReturnType,
        4 => *const fn (id, SEL, fields[0].type, fields[1].type, fields[2].type, fields[3].type) callconv(.c) ReturnType,
        5 => *const fn (id, SEL, fields[0].type, fields[1].type, fields[2].type, fields[3].type, fields[4].type) callconv(.c) ReturnType,
        else => @compileError("msgSend: too many arguments"),
    };
}

fn msgSend(comptime ReturnType: type, target: anytype, selector: SEL, args: anytype) ReturnType {
    const target_as_id: id = @ptrCast(target);
    const ArgsType = @TypeOf(args);
    const func: MsgSendFnType(ReturnType, ArgsType) = @ptrCast(&objc_msgSend);

    const args_info = @typeInfo(ArgsType);
    const fields = args_info.@"struct".fields;

    return switch (fields.len) {
        0 => func(target_as_id, selector),
        1 => func(target_as_id, selector, args[0]),
        2 => func(target_as_id, selector, args[0], args[1]),
        3 => func(target_as_id, selector, args[0], args[1], args[2]),
        4 => func(target_as_id, selector, args[0], args[1], args[2], args[3]),
        5 => func(target_as_id, selector, args[0], args[1], args[2], args[3], args[4]),
        else => @compileError("msgSend: too many arguments"),
    };
}

fn nsString(str: [*:0]const u8) id {
    const NSString = getClass("NSString") orelse unreachable;
    return msgSend(id, NSString, sel("stringWithUTF8String:"), .{str});
}

fn autoreleasePoolPush() id {
    const NSAutoreleasePool = getClass("NSAutoreleasePool") orelse unreachable;
    const pool = msgSend(id, NSAutoreleasePool, sel("alloc"), .{});
    return msgSend(id, pool, sel("init"), .{});
}

fn autoreleasePoolPop(pool: id) void {
    msgSend(void, pool, sel("drain"), .{});
}

// ---------------------------------------------------------------------------
// GCD dispatch_semaphore
// ---------------------------------------------------------------------------

const dispatch_semaphore_t = *opaque {};
extern "c" fn dispatch_semaphore_create(value: isize) ?dispatch_semaphore_t;
extern "c" fn dispatch_semaphore_wait(dsema: dispatch_semaphore_t, timeout: u64) isize;
extern "c" fn dispatch_semaphore_signal(dsema: dispatch_semaphore_t) isize;
const DISPATCH_TIME_FOREVER: u64 = ~@as(u64, 0);

// ---------------------------------------------------------------------------
// Block ABI
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

const CMTime = extern struct {
    value: i64,
    timescale: i32,
    flags: u32,
    epoch: i64,
};

// CMTimeFlags: kCMTimeFlags_Valid = 1
const kCMTimeFlags_Valid: u32 = 1;

fn cmTimeMake(value: i64, timescale: i32) CMTime {
    return .{
        .value = value,
        .timescale = timescale,
        .flags = kCMTimeFlags_Valid,
        .epoch = 0,
    };
}

extern "c" fn CVPixelBufferCreateWithBytes(
    allocator: ?*anyopaque,
    width: usize,
    height: usize,
    pixelFormatType: u32,
    baseAddress: *const anyopaque,
    bytesPerRow: usize,
    releaseCallback: ?*const anyopaque,
    releaseRefCon: ?*anyopaque,
    pixelBufferAttributes: ?id,
    pixelBufferOut: *?id,
) i32;

extern "c" fn CVPixelBufferCreate(
    allocator: ?*anyopaque,
    width: usize,
    height: usize,
    pixelFormatType: u32,
    pixelBufferAttributes: ?id,
    pixelBufferOut: *?id,
) i32;

extern "c" fn CVPixelBufferLockBaseAddress(pb: id, flags: u64) i32;
extern "c" fn CVPixelBufferUnlockBaseAddress(pb: id, flags: u64) i32;
extern "c" fn CVPixelBufferGetBaseAddress(pb: id) ?[*]u8;
extern "c" fn CVPixelBufferGetBytesPerRow(pb: id) usize;

const CFRelease = @extern(*const fn (?*anyopaque) callconv(.c) void, .{ .name = "CFRelease" });
const kCFAllocatorNull_ptr = @extern(*const ?*anyopaque, .{ .name = "kCFAllocatorNull" });

// kCVPixelFormatType_32BGRA = 'BGRA' = 0x42475241
const kCVPixelFormatType_32BGRA: u32 = 0x42475241;

// ---------------------------------------------------------------------------
// CMSampleBuffer creation from CVPixelBuffer
// ---------------------------------------------------------------------------

extern "c" fn CMSampleBufferCreateReadyWithImageBuffer(
    allocator: ?*anyopaque,
    imageBuffer: id,
    formatDescription: id,
    sampleTiming: *const CMSampleTimingInfo,
    sampleBufferOut: *?id,
) i32;

extern "c" fn CMVideoFormatDescriptionCreateForImageBuffer(
    allocator: ?*anyopaque,
    imageBuffer: id,
    formatDescriptionOut: *?id,
) i32;

const CMSampleTimingInfo = extern struct {
    duration: CMTime,
    presentationTimeStamp: CMTime,
    decodeTimeStamp: CMTime,
};

const kCMTimeInvalid = CMTime{ .value = 0, .timescale = 0, .flags = 0, .epoch = 0 };

// ---------------------------------------------------------------------------
// Audio CMSampleBuffer creation
// ---------------------------------------------------------------------------

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

// kAudioFormatLinearPCM = 'lpcm' = 0x6C70636D
const kAudioFormatLinearPCM: u32 = 0x6C70636D;
// kAudioFormatFlagIsFloat = 1, kAudioFormatFlagIsPacked = 8
const kAudioFormatFlagsFloat: u32 = 1 | 8;

extern "c" fn CMAudioFormatDescriptionCreate(
    allocator: ?*anyopaque,
    asbd: *const AudioStreamBasicDescription,
    layoutSize: u32,
    layout: ?*const anyopaque,
    magicCookieSize: u32,
    magicCookie: ?*const anyopaque,
    extensions: ?*const anyopaque,
    formatDescriptionOut: *?id,
) i32;

extern "c" fn CMBlockBufferCreateWithMemoryBlock(
    structureAllocator: ?*anyopaque,
    memoryBlock: ?*const anyopaque,
    blockLength: usize,
    blockAllocator: ?*anyopaque,
    customBlockSource: ?*const anyopaque,
    offsetToData: usize,
    dataLength: usize,
    flags: u32,
    blockBufferOut: *?id,
) i32;

extern "c" fn CMSampleBufferCreate(
    allocator: ?*anyopaque,
    dataBuffer: ?id,
    dataReady: u8,
    makeDataReadyCallback: ?*const anyopaque,
    makeDataReadyRefcon: ?*anyopaque,
    formatDescription: ?id,
    numSamples: i32,
    numSampleTimingEntries: i32,
    sampleTimingArray: ?*const CMSampleTimingInfo,
    numSampleSizeEntries: i32,
    sampleSizeArray: ?*const usize,
    sampleBufferOut: *?id,
) i32;

// ---------------------------------------------------------------------------
// Encoder
// ---------------------------------------------------------------------------

pub const Encoder = struct {
    writer: id, // AVAssetWriter
    video_input: ?id, // AVAssetWriterInput for video (created on first frame)
    adaptor: ?id, // AVAssetWriterInputPixelBufferAdaptor (created on first frame)
    audio_input: ?id, // AVAssetWriterInput for audio (null if --no-audio)
    audio_format_desc: ?id, // CMAudioFormatDescription (cached)
    session_started: bool,
    capture_audio: bool, // whether audio was requested
    frame_count: u64,
    first_timestamp_ns: ?u64, // first frame timestamp for relative PTS
    audio_sample_offset: u64, // total audio frames written (for PTS)
    width: u32,
    height: u32,
    fps: u32,
    sample_rate: u32,
    channels: u32,
};

pub fn init(format: []const u8, path: []const u8, config: types.CaptureConfig) !Encoder {
    const pool = autoreleasePoolPush();
    defer autoreleasePoolPop(pool);

    // Determine AVFileType string
    const file_type_str: [*:0]const u8 = if (std.mem.eql(u8, format, "mp4"))
        "public.mpeg-4"
    else if (std.mem.eql(u8, format, "mov"))
        "com.apple.quicktime-movie"
    else
        return error.Unsupported;

    // Create NSURL from path
    // We need a null-terminated copy of path
    var path_buf: [4096]u8 = undefined;
    if (path.len >= path_buf.len) return error.Unsupported;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z: [*:0]const u8 = path_buf[0..path.len :0];

    const path_nsstring = nsString(path_z);

    const NSURL = getClass("NSURL") orelse return error.Unsupported;
    const url = msgSend(id, NSURL, sel("fileURLWithPath:"), .{path_nsstring});

    // Create AVAssetWriter
    const AVAssetWriter = getClass("AVAssetWriter") orelse return error.Unsupported;
    const file_type_ns = nsString(file_type_str);

    const writer_alloc = msgSend(id, AVAssetWriter, sel("alloc"), .{});
    const writer = msgSend(?id, writer_alloc, sel("initWithURL:fileType:error:"), .{
        url,
        file_type_ns,
        @as(?*?id, null),
    }) orelse return error.Unsupported;

    // Dimensions will be set from first video frame.
    // Use 0 as placeholder — video input will be created lazily.
    const width: u32 = 0;
    const height: u32 = 0;

    // Video input and adaptor will be created on the first frame,
    // when we know the actual pixel dimensions from ScreenCaptureKit.

    // Audio input (optional) — created now since format is known from config
    var audio_input: ?id = null;
    if (config.capture_audio) {
        const AVAssetWriterInput = getClass("AVAssetWriterInput") orelse return error.Unsupported;
        const audio_settings = try createAudioSettings(config.sample_rate, config.channels);
        const media_type_audio = nsString("soun");

        const audio_input_alloc = msgSend(id, AVAssetWriterInput, sel("alloc"), .{});
        const ai = msgSend(id, audio_input_alloc, sel("initWithMediaType:outputSettings:"), .{
            media_type_audio,
            audio_settings,
        });
        msgSend(void, ai, sel("setExpectsMediaDataInRealTime:"), .{@as(u8, 1)});
        msgSend(void, writer, sel("addInput:"), .{ai});
        audio_input = ai;
    }

    return Encoder{
        .writer = writer,
        .video_input = null,
        .adaptor = null,
        .audio_input = audio_input,
        .audio_format_desc = null,
        .session_started = false,
        .capture_audio = config.capture_audio,
        .frame_count = 0,
        .first_timestamp_ns = null,
        .audio_sample_offset = 0,
        .width = width,
        .height = height,
        .fps = config.fps,
        .sample_rate = config.sample_rate,
        .channels = config.channels,
    };
}

fn ensureSessionStarted(encoder: *Encoder) void {
    if (encoder.session_started) return;
    const started = msgSend(u8, encoder.writer, sel("startWriting"), .{});
    if (started == 0) return;
    const zero_time = cmTimeMake(0, 1_000_000_000);
    const startSession = @as(
        *const fn (id, SEL, CMTime) callconv(.c) void,
        @ptrCast(&objc_msgSend),
    );
    startSession(encoder.writer, sel("startSessionAtSourceTime:"), zero_time);
    encoder.session_started = true;
}

pub fn writeVideoFrame(encoder: *Encoder, frame: types.VideoFrame) !void {
    const pool = autoreleasePoolPush();
    defer autoreleasePoolPop(pool);

    // Use the actual frame dimensions
    const w: usize = @intCast(frame.width);
    const h: usize = @intCast(frame.height);

    // Lazily create video input and adaptor on first frame, using actual dimensions
    if (encoder.video_input == null) {
        const actual_w: u32 = @intCast(w);
        const actual_h: u32 = @intCast(h);

        const video_settings = createVideoSettings(actual_w, actual_h) catch return;
        const AVAssetWriterInput = getClass("AVAssetWriterInput") orelse return;
        const media_type_video = nsString("vide");

        const video_input_alloc = msgSend(id, AVAssetWriterInput, sel("alloc"), .{});
        const vi = msgSend(id, video_input_alloc, sel("initWithMediaType:outputSettings:"), .{
            media_type_video,
            video_settings,
        });
        msgSend(void, vi, sel("setExpectsMediaDataInRealTime:"), .{@as(u8, 1)});
        msgSend(void, encoder.writer, sel("addInput:"), .{vi});

        // Create pixel buffer adaptor
        const AVAssetWriterInputPixelBufferAdaptor = getClass("AVAssetWriterInputPixelBufferAdaptor") orelse return;
        const pb_attrs = createPixelBufferAttributes(actual_w, actual_h) catch return;
        const adaptor_alloc = msgSend(id, AVAssetWriterInputPixelBufferAdaptor, sel("alloc"), .{});
        const adp = msgSend(id, adaptor_alloc, sel("initWithAssetWriterInput:sourcePixelBufferAttributes:"), .{
            vi,
            pb_attrs,
        });

        encoder.video_input = vi;
        encoder.adaptor = adp;
        encoder.width = actual_w;
        encoder.height = actual_h;

        // Start session if not already started
        ensureSessionStarted(encoder);
    }

    const video_input = encoder.video_input orelse return;
    const adaptor = encoder.adaptor orelse return;

    // Check if input is ready for more data
    const ready = msgSend(u8, video_input, sel("isReadyForMoreMediaData"), .{});
    if (ready == 0) return;

    // Create CVPixelBuffer from frame data
    var pixel_buffer: ?id = null;
    const status = CVPixelBufferCreate(
        null,
        w,
        h,
        kCVPixelFormatType_32BGRA,
        null,
        &pixel_buffer,
    );

    if (status != 0 or pixel_buffer == null) return;

    const pb = pixel_buffer.?;
    defer CFRelease(@ptrCast(pb));

    // Lock and copy data
    _ = CVPixelBufferLockBaseAddress(pb, 0);
    const dest_base = CVPixelBufferGetBaseAddress(pb);
    const dest_stride = CVPixelBufferGetBytesPerRow(pb);

    if (dest_base) |dest| {
        const src_stride: usize = @intCast(frame.bytes_per_row);
        const copy_width = @min(src_stride, dest_stride);
        for (0..h) |row| {
            const src_offset = row * src_stride;
            const dst_offset = row * dest_stride;
            if (src_offset + copy_width <= frame.len) {
                @memcpy(dest[dst_offset .. dst_offset + copy_width], frame.data[src_offset .. src_offset + copy_width]);
            }
        }
    }
    _ = CVPixelBufferUnlockBaseAddress(pb, 0);

    // Use actual presentation timestamp from capture, relative to first frame
    if (encoder.first_timestamp_ns == null) {
        encoder.first_timestamp_ns = frame.timestamp_ns;
    }
    const relative_ns: i64 = @intCast(frame.timestamp_ns -| (encoder.first_timestamp_ns orelse 0));
    // Use nanosecond timescale (1 billion) for precise timing
    const pts = cmTimeMake(relative_ns, 1_000_000_000);

    // Append pixel buffer via adaptor
    const appendFn = @as(
        *const fn (id, SEL, id, CMTime) callconv(.c) u8,
        @ptrCast(&objc_msgSend),
    );
    const appended = appendFn(
        adaptor,
        sel("appendPixelBuffer:withPresentationTime:"),
        pb,
        pts,
    );

    if (appended != 0) {
        encoder.frame_count += 1;
    }
}

pub fn writeAudioSamples(encoder: *Encoder, samples: types.AudioSamples) !void {
    const ai = encoder.audio_input orelse return;
    if (samples.frame_count == 0) return;

    // Start session if this is the first data (audio arrived before video)
    ensureSessionStarted(encoder);
    if (!encoder.session_started) return;

    const pool = autoreleasePoolPush();
    defer autoreleasePoolPop(pool);

    // Check if input is ready
    const ready = msgSend(u8, ai, sel("isReadyForMoreMediaData"), .{});
    if (ready == 0) return;

    const ch: u32 = samples.channels;
    const sr: u32 = samples.sample_rate;
    const bytes_per_frame: u32 = ch * @sizeOf(f32);
    const total_bytes: usize = @as(usize, samples.frame_count) * @as(usize, bytes_per_frame);

    // Create or reuse CMAudioFormatDescription
    if (encoder.audio_format_desc == null) {
        const asbd = AudioStreamBasicDescription{
            .mSampleRate = @floatFromInt(sr),
            .mFormatID = kAudioFormatLinearPCM,
            .mFormatFlags = kAudioFormatFlagsFloat,
            .mBytesPerPacket = bytes_per_frame,
            .mFramesPerPacket = 1,
            .mBytesPerFrame = bytes_per_frame,
            .mChannelsPerFrame = ch,
            .mBitsPerChannel = 32,
            .mReserved = 0,
        };
        var fmt_desc: ?id = null;
        const fmt_status = CMAudioFormatDescriptionCreate(null, &asbd, 0, null, 0, null, null, &fmt_desc);
        if (fmt_status != 0 or fmt_desc == null) return;
        encoder.audio_format_desc = fmt_desc;
    }

    // Create CMBlockBuffer wrapping the audio data (no copy — data lifetime covers this call)
    var block_buffer: ?id = null;
    const bb_status = CMBlockBufferCreateWithMemoryBlock(
        null,
        @ptrCast(samples.data),
        total_bytes,
        kCFAllocatorNull_ptr.*, // don't free the data — caller owns it
        null,
        0,
        total_bytes,
        0,
        &block_buffer,
    );
    if (bb_status != 0 or block_buffer == null) return;

    // Record first timestamp if audio arrives before video
    if (encoder.first_timestamp_ns == null) {
        encoder.first_timestamp_ns = samples.timestamp_ns;
    }

    // Build timing info — use actual timestamp relative to first data
    const first_ts = encoder.first_timestamp_ns orelse 0;
    const relative_ns: i64 = @intCast(samples.timestamp_ns -| first_ts);
    const pts = cmTimeMake(relative_ns, 1_000_000_000);
    const duration = cmTimeMake(@intCast(samples.frame_count), @intCast(sr));
    const timing = CMSampleTimingInfo{
        .duration = duration,
        .presentationTimeStamp = pts,
        .decodeTimeStamp = kCMTimeInvalid,
    };

    // Each frame is one "sample" from CMSampleBuffer's perspective (1 frame per packet for PCM)
    const sample_size: usize = @as(usize, bytes_per_frame);

    // Create CMSampleBuffer
    var sample_buffer: ?id = null;
    const sb_status = CMSampleBufferCreate(
        null,
        block_buffer,
        1, // dataReady = true
        null,
        null,
        encoder.audio_format_desc,
        @intCast(samples.frame_count),
        1, // numSampleTimingEntries
        &timing,
        1, // numSampleSizeEntries
        &sample_size,
        &sample_buffer,
    );

    if (sb_status != 0 or sample_buffer == null) return;

    // Append to audio input
    const appended = msgSend(u8, ai, sel("appendSampleBuffer:"), .{sample_buffer.?});
    if (appended != 0) {
        encoder.audio_sample_offset += @as(u64, samples.frame_count);
    }

    // Release the CMSampleBuffer and CMBlockBuffer
    CFRelease(@ptrCast(sample_buffer.?));
    CFRelease(@ptrCast(block_buffer.?));
}

pub fn finalize(encoder: *Encoder) !void {
    const pool = autoreleasePoolPush();
    defer autoreleasePoolPop(pool);

    // Mark inputs as finished
    if (encoder.video_input) |vi| {
        msgSend(void, vi, sel("markAsFinished"), .{});
    }
    if (encoder.audio_input) |ai| {
        msgSend(void, ai, sel("markAsFinished"), .{});
    }

    // If we never started the session (no frames received), nothing to finalize
    if (!encoder.session_started) return error.Unsupported;

    // Finish writing with completion handler using dispatch_semaphore
    const sem = dispatch_semaphore_create(0) orelse return error.Unsupported;

    const NSConcreteStackBlock = @as(
        *anyopaque,
        @ptrCast(@extern(*anyopaque, .{ .name = "_NSConcreteStackBlock" })),
    );

    const desc = BlockDescriptor{
        .reserved = 0,
        .size = @sizeOf(BlockLiteral),
    };

    const handler = struct {
        fn invoke(_: *const BlockLiteral) callconv(.c) void {
            if (finalize_semaphore) |s| {
                _ = dispatch_semaphore_signal(s);
            }
        }
    };

    var block = BlockLiteral{
        .isa = NSConcreteStackBlock,
        .flags = 0,
        .reserved = 0,
        .invoke = @ptrCast(&handler.invoke),
        .descriptor = &desc,
    };

    finalize_semaphore = sem;

    msgSend(void, encoder.writer, sel("finishWritingWithCompletionHandler:"), .{&block});

    // Wait for completion
    _ = dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    finalize_semaphore = null;

    // Check writer status: AVAssetWriterStatusCompleted = 2
    const status = msgSend(NSInteger, encoder.writer, sel("status"), .{});
    if (status != 2) {
        return error.Unsupported;
    }
}

// ---------------------------------------------------------------------------
// File-level state for finalize callback
// ---------------------------------------------------------------------------

var finalize_semaphore: ?dispatch_semaphore_t = null;

// ---------------------------------------------------------------------------
// NSDictionary construction helpers
// ---------------------------------------------------------------------------

fn createVideoSettings(width: u32, height: u32) !id {
    const NSMutableDictionary = getClass("NSMutableDictionary") orelse return error.Unsupported;
    const NSNumber = getClass("NSNumber") orelse return error.Unsupported;

    const dict = msgSend(id, NSMutableDictionary, sel("dictionary"), .{});

    // AVVideoCodecKey = "AVVideoCodecKey", value = "avc1" (H.264)
    const codec_key = nsString("AVVideoCodecKey");
    const codec_val = nsString("avc1");
    msgSend(void, dict, sel("setObject:forKey:"), .{ codec_val, codec_key });

    // AVVideoWidthKey
    const width_key = nsString("AVVideoWidthKey");
    const width_val = msgSend(id, NSNumber, sel("numberWithUnsignedInt:"), .{width});
    msgSend(void, dict, sel("setObject:forKey:"), .{ width_val, width_key });

    // AVVideoHeightKey
    const height_key = nsString("AVVideoHeightKey");
    const height_val = msgSend(id, NSNumber, sel("numberWithUnsignedInt:"), .{height});
    msgSend(void, dict, sel("setObject:forKey:"), .{ height_val, height_key });

    return dict;
}

fn createAudioSettings(sample_rate: u32, channels: u32) !id {
    const NSMutableDictionary = getClass("NSMutableDictionary") orelse return error.Unsupported;
    const NSNumber = getClass("NSNumber") orelse return error.Unsupported;

    const dict = msgSend(id, NSMutableDictionary, sel("dictionary"), .{});

    // AVFormatIDKey = "AVFormatIDKey", value = kAudioFormatMPEG4AAC = 1633772320 ('aac ')
    const format_key = nsString("AVFormatIDKey");
    const format_val = msgSend(id, NSNumber, sel("numberWithUnsignedInt:"), .{@as(u32, 1633772320)});
    msgSend(void, dict, sel("setObject:forKey:"), .{ format_val, format_key });

    // AVSampleRateKey
    const sr_key = nsString("AVSampleRateKey");
    const sr_val = msgSend(id, NSNumber, sel("numberWithFloat:"), .{@as(f32, @floatFromInt(sample_rate))});
    msgSend(void, dict, sel("setObject:forKey:"), .{ sr_val, sr_key });

    // AVNumberOfChannelsKey
    const ch_key = nsString("AVNumberOfChannelsKey");
    const ch_val = msgSend(id, NSNumber, sel("numberWithUnsignedInt:"), .{channels});
    msgSend(void, dict, sel("setObject:forKey:"), .{ ch_val, ch_key });

    return dict;
}

fn createPixelBufferAttributes(width: u32, height: u32) !id {
    const NSMutableDictionary = getClass("NSMutableDictionary") orelse return error.Unsupported;
    const NSNumber = getClass("NSNumber") orelse return error.Unsupported;

    const dict = msgSend(id, NSMutableDictionary, sel("dictionary"), .{});

    // kCVPixelBufferPixelFormatTypeKey
    const fmt_key = nsString("PixelFormatType");
    const fmt_val = msgSend(id, NSNumber, sel("numberWithUnsignedInt:"), .{kCVPixelFormatType_32BGRA});
    msgSend(void, dict, sel("setObject:forKey:"), .{ fmt_val, fmt_key });

    // kCVPixelBufferWidthKey
    const w_key = nsString("Width");
    const w_val = msgSend(id, NSNumber, sel("numberWithUnsignedInt:"), .{width});
    msgSend(void, dict, sel("setObject:forKey:"), .{ w_val, w_key });

    // kCVPixelBufferHeightKey
    const h_key = nsString("Height");
    const h_val = msgSend(id, NSNumber, sel("numberWithUnsignedInt:"), .{height});
    msgSend(void, dict, sel("setObject:forKey:"), .{ h_val, h_key });

    return dict;
}
