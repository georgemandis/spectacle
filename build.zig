const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const target_os = target.result.os.tag;

    // -----------------------------------------------------------------------
    // Shared types module (pure Zig, no OS deps)
    // -----------------------------------------------------------------------
    const types_mod = b.createModule(.{
        .root_source_file = b.path("src/types.zig"),
        .target = target,
        .optimize = optimize,
    });

    // -----------------------------------------------------------------------
    // Cross-compilation SDK support for macOS
    // (e.g. -Dtarget=x86_64-macos on an aarch64 host)
    // -----------------------------------------------------------------------
    const is_native = target.query.isNativeOs() and target.query.isNativeCpu();
    const macos_sdk = b.option([]const u8, "macos-sdk", "Path to macOS SDK for cross-compilation");

    // -----------------------------------------------------------------------
    // Capture module (screen capture interface)
    // -----------------------------------------------------------------------
    const capture_mod = b.createModule(.{
        .root_source_file = b.path("src/capture.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
        },
    });

    if (!is_native and target_os == .macos) {
        if (macos_sdk) |sdk| {
            capture_mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk}) });
            capture_mod.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) });
        }
    }

    switch (target_os) {
        .macos => {
            capture_mod.linkSystemLibrary("objc", .{});
            capture_mod.linkFramework("Foundation", .{});
            capture_mod.linkFramework("CoreMedia", .{});
            capture_mod.linkFramework("ScreenCaptureKit", .{});
            capture_mod.linkFramework("CoreGraphics", .{});
        },
        .windows => {
            capture_mod.link_libc = true;
            capture_mod.linkSystemLibrary("d3d11", .{});
            capture_mod.linkSystemLibrary("dxgi", .{});
        },
        .linux => {
            capture_mod.link_libc = true;
            capture_mod.linkSystemLibrary("pipewire-0.3", .{});
            capture_mod.linkSystemLibrary("dbus-1", .{});
        },
        else => {},
    }

    // -----------------------------------------------------------------------
    // Audio module (audio capture interface)
    // -----------------------------------------------------------------------
    const audio_mod = b.createModule(.{
        .root_source_file = b.path("src/audio.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
        },
    });

    if (!is_native and target_os == .macos) {
        if (macos_sdk) |sdk| {
            audio_mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk}) });
            audio_mod.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) });
        }
    }

    switch (target_os) {
        .macos => {
            audio_mod.linkSystemLibrary("objc", .{});
            audio_mod.linkFramework("Foundation", .{});
            audio_mod.linkFramework("CoreAudio", .{});
            audio_mod.linkFramework("AudioToolbox", .{});
            audio_mod.link_libc = true;
            audio_mod.addCSourceFile(.{
                .file = b.path("src/platform/macos/audio_tap_helper.c"),
                .flags = &.{"-fno-sanitize=undefined"},
            });
        },
        .windows => {
            audio_mod.link_libc = true;
            audio_mod.linkSystemLibrary("ole32", .{});
        },
        .linux => {
            audio_mod.link_libc = true;
            audio_mod.linkSystemLibrary("pipewire-0.3", .{});
        },
        else => {},
    }

    // -----------------------------------------------------------------------
    // Encoder module (encoding/muxing interface)
    // -----------------------------------------------------------------------
    const encoder_mod = b.createModule(.{
        .root_source_file = b.path("src/encoder.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
        },
    });

    if (!is_native and target_os == .macos) {
        if (macos_sdk) |sdk| {
            encoder_mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk}) });
            encoder_mod.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) });
        }
    }

    switch (target_os) {
        .macos => {
            encoder_mod.linkSystemLibrary("objc", .{});
            encoder_mod.linkFramework("Foundation", .{});
            encoder_mod.linkFramework("AVFoundation", .{});
            encoder_mod.linkFramework("CoreVideo", .{});
            encoder_mod.linkFramework("CoreMedia", .{});
        },
        .windows => {
            encoder_mod.link_libc = true;
        },
        .linux => {
            encoder_mod.link_libc = true;
        },
        else => {},
    }

    // -----------------------------------------------------------------------
    // CLI executable
    // -----------------------------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "spectacle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "types", .module = types_mod },
                .{ .name = "capture", .module = capture_mod },
                .{ .name = "audio", .module = audio_mod },
                .{ .name = "encoder", .module = encoder_mod },
            },
        }),
    });
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the spectacle CLI");
    run_step.dependOn(&run_cmd.step);

    // -----------------------------------------------------------------------
    // Shared library (C ABI for FFI consumers)
    // -----------------------------------------------------------------------
    const lib_shared = b.addLibrary(.{
        .name = "spectacle",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "types", .module = types_mod },
                .{ .name = "capture", .module = capture_mod },
                .{ .name = "audio", .module = audio_mod },
                .{ .name = "encoder", .module = encoder_mod },
            },
        }),
    });
    b.installArtifact(lib_shared);

    // -----------------------------------------------------------------------
    // Static library (for embedding, e.g. Tauri/Rust)
    // -----------------------------------------------------------------------
    const lib_static = b.addLibrary(.{
        .name = "spectacle",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "types", .module = types_mod },
                .{ .name = "capture", .module = capture_mod },
                .{ .name = "audio", .module = audio_mod },
                .{ .name = "encoder", .module = encoder_mod },
            },
        }),
    });
    b.installArtifact(lib_static);

    // -----------------------------------------------------------------------
    // Tests — pure Zig modules (no OS deps, run on host)
    // -----------------------------------------------------------------------

    // wav.zig tests
    const wav_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wav.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "types", .module = types_mod },
            },
        }),
    });

    // ppm.zig tests
    const ppm_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ppm.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "types", .module = types_mod },
            },
        }),
    });

    const run_wav_tests = b.addRunArtifact(wav_tests);
    const run_ppm_tests = b.addRunArtifact(ppm_tests);

    const test_step = b.step("test", "Run pure-Zig unit tests");
    test_step.dependOn(&run_wav_tests.step);
    test_step.dependOn(&run_ppm_tests.step);
}
