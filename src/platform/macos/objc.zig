// Objective-C runtime bindings for Zig.

const std = @import("std");

pub const Class = *opaque {};
pub const SEL = *opaque {};
pub const id = *opaque {};
pub const NSUInteger = usize;
pub const NSInteger = isize;

extern "objc" fn objc_getClass(name: [*:0]const u8) ?Class;
extern "objc" fn sel_registerName(name: [*:0]const u8) SEL;
extern "objc" fn objc_msgSend() void;

// Class creation (for dynamic observer registration)
extern "objc" fn objc_allocateClassPair(superclass: ?Class, name: [*:0]const u8, extra_bytes: usize) ?Class;
extern "objc" fn objc_registerClassPair(cls: Class) void;
extern "objc" fn class_addMethod(cls: Class, name: SEL, imp: *const anyopaque, types: [*:0]const u8) bool;
extern "objc" fn class_addProtocol(cls: Class, protocol: *anyopaque) bool;
extern "objc" fn objc_getProtocol(name: [*:0]const u8) ?*anyopaque;

pub fn getClass(name: [*:0]const u8) ?Class {
    return objc_getClass(name);
}

pub fn sel(name: [*:0]const u8) SEL {
    return sel_registerName(name);
}

pub fn msgSendFn(comptime ReturnType: type, comptime ArgTypes: type) MsgSendFnType(ReturnType, ArgTypes) {
    return @ptrCast(&objc_msgSend);
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
        else => @compileError("msgSendFn: too many arguments, add more cases"),
    };
}

pub fn msgSend(comptime ReturnType: type, target: anytype, selector: SEL, args: anytype) ReturnType {
    const target_as_id: id = @ptrCast(target);
    const ArgsType = @TypeOf(args);
    const func = msgSendFn(ReturnType, ArgsType);

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

pub fn allocateClassPair(superclass: ?Class, name: [*:0]const u8) ?Class {
    return objc_allocateClassPair(superclass, name, 0);
}

pub fn registerClassPair(cls: Class) void {
    objc_registerClassPair(cls);
}

pub fn addMethod(cls: Class, name: SEL, imp: *const anyopaque, types: [*:0]const u8) bool {
    return class_addMethod(cls, name, imp, types);
}

pub fn addProtocol(cls: Class, protocol_name: [*:0]const u8) bool {
    const protocol = objc_getProtocol(protocol_name) orelse return false;
    return class_addProtocol(cls, protocol);
}

// NSString helpers
pub fn nsString(str: [*:0]const u8) id {
    const NSString = getClass("NSString") orelse unreachable;
    return msgSend(id, NSString, sel("stringWithUTF8String:"), .{str});
}

pub fn nsStringFromSlice(bytes: [*]const u8, len: NSUInteger) ?id {
    const NSString = getClass("NSString") orelse return null;
    const alloc_str = msgSend(id, NSString, sel("alloc"), .{});
    return msgSend(?id, alloc_str, sel("initWithBytes:length:encoding:"), .{
        bytes,
        len,
        @as(NSUInteger, 4), // NSUTF8StringEncoding
    });
}

pub fn fromNSString(nsstr: id) ?[*:0]const u8 {
    return msgSend(?[*:0]const u8, nsstr, sel("UTF8String"), .{});
}

pub fn nsStringLength(nsstr: id) NSUInteger {
    return msgSend(NSUInteger, nsstr, sel("length"), .{});
}

// NSArray helpers
pub fn nsArrayCount(nsarray: id) NSUInteger {
    return msgSend(NSUInteger, nsarray, sel("count"), .{});
}

pub fn nsArrayObjectAtIndex(nsarray: id, index: NSUInteger) id {
    return msgSend(id, nsarray, sel("objectAtIndex:"), .{index});
}

// Autorelease pool
pub fn autoreleasePoolPush() id {
    const NSAutoreleasePool = getClass("NSAutoreleasePool") orelse unreachable;
    const pool = msgSend(id, NSAutoreleasePool, sel("alloc"), .{});
    return msgSend(id, pool, sel("init"), .{});
}

pub fn autoreleasePoolPop(pool: id) void {
    msgSend(void, pool, sel("drain"), .{});
}
