/// macOS audio capture — Core Audio Taps implementation.
/// Discovery uses NSWorkspace to enumerate running GUI applications.
///
/// Note: Obj-C runtime bindings are inlined here rather than importing objc.zig
/// because Zig 0.16 requires each source file to belong to exactly one module,
/// and objc.zig is already claimed by the capture module via screen.zig.
const std = @import("std");
const types = @import("types");

// ---------------------------------------------------------------------------
// Inline Obj-C runtime bindings (subset needed for audio discovery)
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

fn sel_reg(name: [*:0]const u8) SEL {
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
        else => @compileError("msgSend: too many arguments"),
    };
}

fn fromNSString(nsstr: id) ?[*:0]const u8 {
    return msgSend(?[*:0]const u8, nsstr, sel_reg("UTF8String"), .{});
}

fn nsString(str: [*:0]const u8) id {
    const NSString = getClass("NSString") orelse unreachable;
    return msgSend(id, NSString, sel_reg("stringWithUTF8String:"), .{str});
}

fn nsArrayCount(nsarray: id) NSUInteger {
    return msgSend(NSUInteger, nsarray, sel_reg("count"), .{});
}

fn nsArrayObjectAtIndex(nsarray: id, index: NSUInteger) id {
    return msgSend(id, nsarray, sel_reg("objectAtIndex:"), .{index});
}

fn autoreleasePoolPush() id {
    const NSAutoreleasePool = getClass("NSAutoreleasePool") orelse unreachable;
    const pool = msgSend(id, NSAutoreleasePool, sel_reg("alloc"), .{});
    return msgSend(id, pool, sel_reg("init"), .{});
}

fn autoreleasePoolPop(pool: id) void {
    msgSend(void, pool, sel_reg("drain"), .{});
}

// ---------------------------------------------------------------------------
// listSources
// ---------------------------------------------------------------------------

pub fn listSources(allocator: std.mem.Allocator) ![]types.AudioSource {
    const pool = autoreleasePoolPush();
    defer autoreleasePoolPop(pool);

    // [NSWorkspace sharedWorkspace]
    const NSWorkspace = getClass("NSWorkspace") orelse
        return error.BackendInitFailed;
    const workspace = msgSend(id, NSWorkspace, sel_reg("sharedWorkspace"), .{});

    // [workspace runningApplications] -> NSArray<NSRunningApplication*>
    const apps_array = msgSend(id, workspace, sel_reg("runningApplications"), .{});
    const count = nsArrayCount(apps_array);

    // First pass: count regular (GUI) applications
    // NSApplicationActivationPolicyRegular == 0
    var gui_count: usize = 0;
    for (0..count) |i| {
        const app = nsArrayObjectAtIndex(apps_array, i);
        const policy = msgSend(NSInteger, app, sel_reg("activationPolicy"), .{});
        if (policy == 0) {
            gui_count += 1;
        }
    }

    // +1 for the "System Audio" entry
    var result = try allocator.alloc(types.AudioSource, gui_count + 1);
    errdefer allocator.free(result);

    // System Audio is always first
    result[0] = .{
        .name = "System Audio",
        .pid = 0,
        .source_id = 0,
    };

    // Second pass: populate GUI apps
    var idx: usize = 1;
    for (0..count) |i| {
        const app = nsArrayObjectAtIndex(apps_array, i);
        const policy = msgSend(NSInteger, app, sel_reg("activationPolicy"), .{});
        if (policy != 0) continue;

        // [app localizedName] -> NSString?
        const name_ns: ?id = msgSend(?id, app, sel_reg("localizedName"), .{});
        var name: ?[*:0]const u8 = null;
        if (name_ns) |n| {
            name = fromNSString(n);
        }

        // [app processIdentifier] -> pid_t (int32_t)
        const pid = msgSend(i32, app, sel_reg("processIdentifier"), .{});

        result[idx] = .{
            .name = name,
            .pid = if (pid >= 0) @intCast(pid) else 0,
            .source_id = if (pid >= 0) @intCast(pid) else 0,
        };
        idx += 1;
    }

    return result;
}

// ---------------------------------------------------------------------------
// Core Audio types and externs
// ---------------------------------------------------------------------------

const AudioObjectID = u32;
const AudioDeviceID = AudioObjectID;
const AudioDeviceIOProcID = ?*const anyopaque;
const OSStatus = i32;

const AudioObjectPropertyAddress = extern struct {
    mSelector: u32,
    mScope: u32,
    mElement: u32,
};

const AudioTimeStamp = extern struct {
    mSampleTime: f64,
    mHostTime: u64,
    mRateScalar: f64,
    mWordClockTime: u64,
    mSMPTETime: [24]u8, // SMPTETime struct (24 bytes)
    mFlags: u32,
    mReserved: u32,
};

const AudioBufferList = extern struct {
    mNumberBuffers: u32,
    mBuffers: [1]AudioBuffer,
};

const AudioBuffer = extern struct {
    mNumberChannels: u32,
    mDataByteSize: u32,
    mData: ?*anyopaque,
};

// Core Audio Taps — CATapDescription (macOS 14.2+)
// These are Obj-C classes but we use them via objc_msgSend
// CATapDescription: initStereoMixdownOfProcesses: / initStereoGlobalTapButExcludeProcesses:

// AudioDeviceIOProc callback type (7 params including clientData)
const AudioDeviceIOProc = *const fn (
    device: AudioDeviceID,
    now: *const AudioTimeStamp,
    input_data: *const AudioBufferList,
    input_time: *const AudioTimeStamp,
    output_data: *AudioBufferList,
    output_time: *const AudioTimeStamp,
    client_data: ?*anyopaque,
) callconv(.c) OSStatus;

// Core Audio C API — use @extern for precise control
const AudioDeviceCreateIOProcID_fn = @extern(*const fn (
    AudioDeviceID,
    AudioDeviceIOProc,
    ?*anyopaque,
    *AudioDeviceIOProcID,
) callconv(.c) OSStatus, .{ .name = "AudioDeviceCreateIOProcID" });

const AudioDeviceStart_fn = @extern(*const fn (
    AudioDeviceID,
    AudioDeviceIOProcID,
) callconv(.c) OSStatus, .{ .name = "AudioDeviceStart" });

const AudioDeviceStop_fn = @extern(*const fn (
    AudioDeviceID,
    AudioDeviceIOProcID,
) callconv(.c) OSStatus, .{ .name = "AudioDeviceStop" });

const AudioDeviceDestroyIOProcID_fn = @extern(*const fn (
    AudioDeviceID,
    AudioDeviceIOProcID,
) callconv(.c) OSStatus, .{ .name = "AudioDeviceDestroyIOProcID" });

extern "c" fn AudioObjectGetPropertyData(
    object_id: AudioObjectID,
    address: *const AudioObjectPropertyAddress,
    qualifier_data_size: u32,
    qualifier_data: ?*const anyopaque,
    data_size: *u32,
    data: *anyopaque,
) OSStatus;

// Property selectors
const kAudioObjectSystemObject: AudioObjectID = 1;
const kAudioObjectPropertyScopeGlobal: u32 = 0x676C6F62; // 'glob'
const kAudioObjectPropertyElementMain: u32 = 0;
const kAudioHardwarePropertyProcessObjectList: u32 = 0x70727323; // 'prs#'
const kAudioHardwarePropertyTranslatePIDToProcessObject: u32 = 0x69643270; // 'id2p'
const kAudioProcessPropertyPID: u32 = 0x70706964; // 'ppid'
const kAudioTapPropertyUID: u32 = 0x74756964; // 'tuid'

extern "c" fn AudioObjectGetPropertyDataSize(
    object_id: AudioObjectID,
    address: *const AudioObjectPropertyAddress,
    qualifier_data_size: u32,
    qualifier_data: ?*const anyopaque,
    data_size: *u32,
) OSStatus;

// CoreFoundation externs for aggregate device creation
extern "c" fn CFStringCreateWithCString(alloc: ?*anyopaque, cStr: [*:0]const u8, encoding: u32) ?*anyopaque;
extern "c" fn CFNumberCreate(alloc: ?*anyopaque, theType: i64, valuePtr: *const anyopaque) ?*anyopaque;
extern "c" fn CFDictionaryCreateMutable(alloc: ?*anyopaque, capacity: isize, keyCallBacks: ?*const anyopaque, valueCallBacks: ?*const anyopaque) ?*anyopaque;
extern "c" fn CFDictionarySetValue(theDict: *anyopaque, key: *const anyopaque, value: *const anyopaque) void;
extern "c" fn CFArrayCreateMutable(alloc: ?*anyopaque, capacity: isize, callBacks: ?*const anyopaque) ?*anyopaque;
extern "c" fn CFArrayAppendValue(theArray: *anyopaque, value: *const anyopaque) void;
const CFRelease_fn = @extern(*const fn (?*anyopaque) callconv(.c) void, .{ .name = "CFRelease" });
// These are extern struct globals. To get pointers to pass to CF functions,
// we declare them as extern arrays of a single byte and take pointers.
extern "c" const kCFTypeDictionaryKeyCallBacks: anyopaque;
extern "c" const kCFTypeDictionaryValueCallBacks: anyopaque;
extern "c" const kCFTypeArrayCallBacks: anyopaque;

// kCFStringEncodingUTF8 = 0x08000100
const kCFStringEncodingUTF8: u32 = 0x08000100;
// kCFNumberSInt32Type = 3
const kCFNumberSInt32Type: i64 = 3;

extern "c" fn AudioHardwareCreateAggregateDevice(description: *const anyopaque, outDeviceID: *AudioObjectID) OSStatus;
extern "c" fn AudioHardwareDestroyAggregateDevice(deviceID: AudioObjectID) OSStatus;

const AudioHardwareCreateProcessTap = @extern(
    *const fn (id, *AudioObjectID) callconv(.c) OSStatus,
    .{ .name = "AudioHardwareCreateProcessTap" },
);
const AudioHardwareDestroyProcessTap = @extern(
    *const fn (AudioObjectID) callconv(.c) OSStatus,
    .{ .name = "AudioHardwareDestroyProcessTap" },
);

// ---------------------------------------------------------------------------
// Capture state
// ---------------------------------------------------------------------------

const AudioCaptureState = struct {
    aggregate_device_id: AudioDeviceID,
    io_proc_id: AudioDeviceIOProcID,
    tap_object_id: AudioObjectID,
    sample_rate: u32,
    channels: u32,
};

// Global callback storage (IO proc can't capture state)
var g_audio_sample_cb: ?*const fn (types.AudioSamples) void = null;
var g_audio_sample_rate: u32 = 48000;
var g_audio_channels: u32 = 2;

// C helper functions for Core Audio IO proc (audio_tap_helper.c)
const SpectacleAudioCallback = *const fn ([*]const f32, u32, u32, u32, u64) callconv(.c) void;
extern "c" fn spectacle_tap_set_callback(cb: SpectacleAudioCallback, sample_rate: u32, channels: u32) void;
extern "c" fn spectacle_tap_get_io_proc() AudioDeviceIOProc;

fn cAudioCallback(data: [*]const f32, frame_count: u32, channels: u32, sample_rate: u32, timestamp_ns: u64) callconv(.c) void {
    const cb = g_audio_sample_cb orelse return;
    const samples = types.AudioSamples{
        .data = data,
        .frame_count = frame_count,
        .channels = channels,
        .sample_rate = sample_rate,
        .timestamp_ns = timestamp_ns,
    };
    cb(samples);
}

// ---------------------------------------------------------------------------
// startCapture / stopCapture via Core Audio Taps
// ---------------------------------------------------------------------------

/// Look up the Core Audio AudioObjectID for a given Unix PID.
fn findAudioObjectIdForPid(pid: u32) ?AudioObjectID {
    const address = AudioObjectPropertyAddress{
        .mSelector = kAudioHardwarePropertyTranslatePIDToProcessObject,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };

    var obj_id: AudioObjectID = 0;
    var data_size: u32 = @sizeOf(AudioObjectID);
    const status = AudioObjectGetPropertyData(
        kAudioObjectSystemObject,
        &address,
        @sizeOf(u32),
        @ptrCast(&pid),
        &data_size,
        @ptrCast(&obj_id),
    );
    if (status != 0 or obj_id == 0) return null;
    return obj_id;
}

pub fn startCapture(
    target: types.AudioTarget,
    config: types.AudioConfig,
    sample_cb: *const fn (types.AudioSamples) void,
) !types.CaptureHandle {
    const pool = autoreleasePoolPush();
    defer autoreleasePoolPop(pool);

    // Create CATapDescription
    const CATapDescription = getClass("CATapDescription") orelse return error.BackendInitFailed;
    const tap_desc_alloc = msgSend(id, CATapDescription, sel_reg("alloc"), .{});

    var tap_desc: id = undefined;
    switch (target) {
        .system => {
            // initStereoGlobalTapButExcludeProcesses: with empty array → capture all
            const NSArray = getClass("NSArray") orelse return error.BackendInitFailed;
            const empty_array = msgSend(id, NSArray, sel_reg("array"), .{});
            tap_desc = msgSend(id, tap_desc_alloc, sel_reg("initStereoGlobalTapButExcludeProcesses:"), .{empty_array});
        },
        .app_name => |name| {
            // Find all Core Audio process objects whose localizedName contains
            // the target app name. This includes helper processes (e.g. GPU/audio)
            // that actually handle sound for the app.
            const obj_id_array = findAudioObjectIdsForApp(name) orelse return error.TargetNotFound;
            tap_desc = msgSend(id, tap_desc_alloc, sel_reg("initStereoMixdownOfProcesses:"), .{obj_id_array});
        },
        .pid => |pid| {
            // Look up AudioObjectID for this PID
            const audio_obj_id = findAudioObjectIdForPid(pid) orelse return error.TargetNotFound;
            const NSArray = getClass("NSArray") orelse return error.BackendInitFailed;
            const NSNumber = getClass("NSNumber") orelse return error.BackendInitFailed;
            const obj_num = msgSend(id, NSNumber, sel_reg("numberWithUnsignedInt:"), .{audio_obj_id});
            const obj_array = msgSend(id, NSArray, sel_reg("arrayWithObject:"), .{obj_num});
            tap_desc = msgSend(id, tap_desc_alloc, sel_reg("initStereoMixdownOfProcesses:"), .{obj_array});
        },
    }

    // Create the tap
    var tap_id: AudioObjectID = 0;
    const tap_status = AudioHardwareCreateProcessTap(tap_desc, &tap_id);
    if (tap_status != 0) return error.BackendInitFailed;

    // Get the tap's UID for use in the aggregate device description
    const tap_uid_address = AudioObjectPropertyAddress{
        .mSelector = kAudioTapPropertyUID,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };
    var tap_uid: ?*anyopaque = null; // CFStringRef
    var uid_size: u32 = @sizeOf(?*anyopaque);
    const uid_status = AudioObjectGetPropertyData(tap_id, &tap_uid_address, 0, null, &uid_size, @ptrCast(&tap_uid));
    if (uid_status != 0 or tap_uid == null) {
        _ = AudioHardwareDestroyProcessTap(tap_id);
        return error.BackendInitFailed;
    }

    // Build aggregate device description CFDictionary:
    // {
    //   "uid": "spectacle_tap_<random>",
    //   "name": "Spectacle Tap",
    //   "private": 1,
    //   "tapautostart": 1,
    //   "taps": [{"uid": <tap_uid>}]
    // }
    const desc_dict = CFDictionaryCreateMutable(null, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) orelse {
        CFRelease_fn(tap_uid);
        _ = AudioHardwareDestroyProcessTap(tap_id);
        return error.BackendInitFailed;
    };

    const uid_key = CFStringCreateWithCString(null, "uid", kCFStringEncodingUTF8) orelse {
        CFRelease_fn(tap_uid);
        _ = AudioHardwareDestroyProcessTap(tap_id);
        return error.BackendInitFailed;
    };
    const agg_uid = CFStringCreateWithCString(null, "com.less.spectacle.tap", kCFStringEncodingUTF8) orelse {
        CFRelease_fn(tap_uid);
        _ = AudioHardwareDestroyProcessTap(tap_id);
        return error.BackendInitFailed;
    };
    CFDictionarySetValue(desc_dict, uid_key, agg_uid);

    const name_key = CFStringCreateWithCString(null, "name", kCFStringEncodingUTF8).?;
    const name_val = CFStringCreateWithCString(null, "Spectacle Tap", kCFStringEncodingUTF8).?;
    CFDictionarySetValue(desc_dict, name_key, name_val);

    const private_key = CFStringCreateWithCString(null, "private", kCFStringEncodingUTF8).?;
    var one: i32 = 1;
    const one_num = CFNumberCreate(null, kCFNumberSInt32Type, @ptrCast(&one)).?;
    CFDictionarySetValue(desc_dict, private_key, one_num);

    const autostart_key = CFStringCreateWithCString(null, "tapautostart", kCFStringEncodingUTF8).?;
    CFDictionarySetValue(desc_dict, autostart_key, one_num);

    // Build tap entry: {"uid": <tap_uid>}
    const tap_entry = CFDictionaryCreateMutable(null, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks).?;
    CFDictionarySetValue(tap_entry, uid_key, tap_uid.?);

    // Build taps array: [tap_entry]
    const taps_array = CFArrayCreateMutable(null, 0, &kCFTypeArrayCallBacks).?;
    CFArrayAppendValue(taps_array, tap_entry);

    const taps_key = CFStringCreateWithCString(null, "taps", kCFStringEncodingUTF8).?;
    CFDictionarySetValue(desc_dict, taps_key, taps_array);

    // Create the aggregate device
    var aggregate_device_id: AudioObjectID = 0;
    const agg_status = AudioHardwareCreateAggregateDevice(desc_dict, &aggregate_device_id);

    // Clean up CF objects
    CFRelease_fn(tap_uid);
    CFRelease_fn(desc_dict);

    if (agg_status != 0) {
        _ = AudioHardwareDestroyProcessTap(tap_id);
        return error.BackendInitFailed;
    }

    // Set global state for the IO proc callback
    g_audio_sample_cb = sample_cb;
    g_audio_sample_rate = config.sample_rate;
    g_audio_channels = config.channels;

    // Configure the C helper with our callback
    spectacle_tap_set_callback(&cAudioCallback, config.sample_rate, config.channels);

    // Create IO proc on the aggregate device using C function pointer
    var io_proc_id: AudioDeviceIOProcID = null;
    const c_io_proc = spectacle_tap_get_io_proc();
    const io_status = AudioDeviceCreateIOProcID_fn(aggregate_device_id, c_io_proc, null, &io_proc_id);
    if (io_status != 0) {
        std.debug.print("AudioDeviceCreateIOProcID failed: {d}\n", .{io_status});
        _ = AudioHardwareDestroyAggregateDevice(aggregate_device_id);
        _ = AudioHardwareDestroyProcessTap(tap_id);
        return error.BackendInitFailed;
    }

    // Start the device
    const start_status = AudioDeviceStart_fn(aggregate_device_id, io_proc_id);
    if (start_status != 0) {
        std.debug.print("AudioDeviceStart failed: {d}\n", .{start_status});
        _ = AudioDeviceDestroyIOProcID_fn(aggregate_device_id, io_proc_id);
        _ = AudioHardwareDestroyAggregateDevice(aggregate_device_id);
        _ = AudioHardwareDestroyProcessTap(tap_id);
        return error.BackendInitFailed;
    }
    // Allocate state on heap
    const gpa = std.heap.c_allocator;
    const state = gpa.create(AudioCaptureState) catch return error.BackendInitFailed;
    state.* = .{
        .aggregate_device_id = aggregate_device_id,
        .io_proc_id = io_proc_id,
        .tap_object_id = tap_id,
        .sample_rate = config.sample_rate,
        .channels = config.channels,
    };

    return types.CaptureHandle{ .platform_handle = @ptrCast(state) };
}

pub fn stopCapture(handle: types.CaptureHandle) void {
    const state: *AudioCaptureState = @ptrCast(@alignCast(handle.platform_handle));

    _ = AudioDeviceStop_fn(state.aggregate_device_id, state.io_proc_id);
    _ = AudioDeviceDestroyIOProcID_fn(state.aggregate_device_id, state.io_proc_id);
    _ = AudioHardwareDestroyAggregateDevice(state.aggregate_device_id);
    _ = AudioHardwareDestroyProcessTap(state.tap_object_id);

    g_audio_sample_cb = null;

    const gpa = std.heap.c_allocator;
    gpa.destroy(state);
}

// ---------------------------------------------------------------------------
// Helper: find Core Audio process objects for an app
// ---------------------------------------------------------------------------

/// Find all Core Audio AudioObjectIDs whose process name matches the given app name.
/// This uses the localized name from NSRunningApplication for case-insensitive substring
/// matching, which also picks up helper processes (e.g. "Safari Graphics and Media").
/// Returns an NSArray<NSNumber*> of AudioObjectIDs, or null if none found.
fn findAudioObjectIdsForApp(app_name: [*:0]const u8) ?id {
    // Get the list of all Core Audio process objects
    const proc_list_addr = AudioObjectPropertyAddress{
        .mSelector = kAudioHardwarePropertyProcessObjectList,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };
    var data_size: u32 = 0;
    var status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &proc_list_addr, 0, null, &data_size);
    if (status != 0 or data_size == 0) return null;

    const proc_count = data_size / @sizeOf(AudioObjectID);
    if (proc_count == 0) return null;

    // Stack buffer for up to 128 process objects
    var proc_ids_buf: [128]AudioObjectID = undefined;
    if (proc_count > proc_ids_buf.len) return null;
    const proc_ids = proc_ids_buf[0..proc_count];

    status = AudioObjectGetPropertyData(
        kAudioObjectSystemObject,
        &proc_list_addr,
        0,
        null,
        &data_size,
        @ptrCast(proc_ids.ptr),
    );
    if (status != 0) return null;

    const pid_addr = AudioObjectPropertyAddress{
        .mSelector = kAudioProcessPropertyPID,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };

    const NSRunningApplication = getClass("NSRunningApplication") orelse return null;
    const NSNumber = getClass("NSNumber") orelse return null;
    const NSMutableArray = getClass("NSMutableArray") orelse return null;

    const result_array = msgSend(id, NSMutableArray, sel_reg("array"), .{});
    const needle = std.mem.sliceTo(app_name, 0);

    for (proc_ids) |obj_id| {
        var pid: i32 = 0;
        var pid_size: u32 = @sizeOf(i32);
        const pid_status = AudioObjectGetPropertyData(obj_id, &pid_addr, 0, null, &pid_size, @ptrCast(&pid));
        if (pid_status != 0 or pid <= 0) continue;

        // Look up NSRunningApplication for this PID
        const app: ?id = msgSend(?id, NSRunningApplication, sel_reg("runningApplicationWithProcessIdentifier:"), .{pid});
        if (app == null) continue;

        // Check localizedName for case-insensitive substring match
        // This picks up helper processes like "Safari Graphics and Media"
        const name_ns: ?id = msgSend(?id, app.?, sel_reg("localizedName"), .{});
        if (name_ns == null) continue;

        const proc_name = fromNSString(name_ns.?) orelse continue;
        const proc_name_slice = std.mem.sliceTo(proc_name, 0);

        if (caseInsensitiveContains(proc_name_slice, needle)) {
            const num = msgSend(id, NSNumber, sel_reg("numberWithUnsignedInt:"), .{obj_id});
            msgSend(void, result_array, sel_reg("addObject:"), .{num});
        }
    }

    // Return null if no matching processes found
    if (nsArrayCount(result_array) == 0) return null;
    return result_array;
}

fn caseInsensitiveContains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    if (needle.len == 0) return true;
    const end = haystack.len - needle.len + 1;
    for (0..end) |i| {
        var match = true;
        for (0..needle.len) |j| {
            const h = if (haystack[i + j] >= 'A' and haystack[i + j] <= 'Z') haystack[i + j] + 32 else haystack[i + j];
            const n = if (needle[j] >= 'A' and needle[j] <= 'Z') needle[j] + 32 else needle[j];
            if (h != n) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}
