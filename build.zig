const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ffmpeg_c = b.addTranslateC(.{
        .root_source_file = b.path("ffmpeg_headers.h"),
        .target = target,
        .optimize = optimize,
    });
    ffmpeg_c.addIncludePath(b.path("."));

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "myzigh264",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/myzigh264.zig"),
        }),
    });
    lib.root_module.addImport("ffmpeg", ffmpeg_c.createModule());
    b.installArtifact(lib);

    // 端到端验证工具: zig build 后 zig-out/bin/h264-check
    //   h264-check <annexb.h264> [max_i_slices]   单文件详细模式
    //   h264-check --suite [目录]                 批量模式
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

    // 真实码流一致性测试: zig build check
    // 用 tests/vectors 下的真实视频样本, 每条 I slice 校验
    // decoded==total · stopped==end · terminate==1, 并汇总成一张表
    const check_step = b.step("check", "用真实码流跑 I 帧一致性测试 (tests/vectors)");
    const check_run = b.addRunArtifact(check_exe);
    check_run.addArg("--suite");
    check_run.addArg(b.pathFromRoot("tests/vectors"));
    check_run.stdio = .inherit;
    check_run.has_side_effects = true; // 每次都真跑, 不被 build 缓存跳过
    check_step.dependOn(&check_run.step);

    // 生成/更新码流样本: zig build vectors
    const gen_vectors = b.addSystemCommand(&.{ "bash", b.pathFromRoot("tools/gen_vectors.sh") });
    gen_vectors.stdio = .inherit;
    gen_vectors.has_side_effects = true;
    const vectors_step = b.step("vectors", "从 ~/Videos 抽取真实码流到 tests/vectors (需 ffmpeg)");
    vectors_step.dependOn(&gen_vectors.step);
}
