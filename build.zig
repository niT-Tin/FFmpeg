
const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.
    //
    const ffmpeg_c = b.addTranslateC(.{
        .root_source_file = b.path("ffmpeg_headers.h"),
        .target = target,
        .optimize = optimize
    });

    ffmpeg_c.addIncludePath(b.path("."));

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "myzigh264",
        // .root_module = b
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/myzigh264.zig"),
        })
    });

    // lib.addCScou(b.path("libavcodec/my_zigh264.c"));

    lib.root_module.addImport("ffmpeg", ffmpeg_c.createModule());


    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(lib);

    // 端到端验证工具: zig build 后 zig-out/bin/h264-check <annexb.h264>
    const check_exe = b.addExecutable(.{
        .name = "h264-check",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/decode_file.zig"),
        }),
    });
    b.installArtifact(check_exe);

    // 单元测试: zig build test (各模块独立编译, 不依赖 ffmpeg 头文件)
    const test_step = b.step("test", "Run unit tests");
    for ([_][]const u8{
        "src/cabac.zig",
        "src/cabac_syntax.zig",
        "src/macroblock.zig",
    }) |path| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .root_source_file = b.path(path),
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

}
