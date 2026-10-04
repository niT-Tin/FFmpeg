//! 真实码流 I 帧一致性测试工具
//!
//!   ./h264-check <annexb.h264> [max_i_slices]   单文件模式(详细日志 + 汇总框)
//!   ./h264-check --suite [样本目录]             批量模式(默认 tests/vectors, TUI 汇总)
//!   zig build check                             等价于 --suite tests/vectors
//!
//! 判据(每条 I slice 三条同时成立才算过):
//!   1. decoded == total        宏块解满
//!   2. stopped == end          停在正确的 slice 边界(多 slice 时 end = 下一条 first_mb-1)
//!   3. terminate == 1          end_of_slice_flag 恰好为 1 = CABAC 全程同步
//! 经验判据: qp 范围必须合理(有 AQ 时 min<max; 出现 [2,43] 这类离谱范围即失步)
const std = @import("std");
const BitReader = @import("bit_reader.zig").BitReader;
const NALSplitter = @import("nal_splitter.zig").NALSplitter;
const ZigH264Context = @import("context.zig").ZigH264Context;
const sps_mod = @import("sps.zig");
const pps_mod = @import("pps.zig");
const slice_mod = @import("slice.zig");
const CABACEngine = @import("cabac.zig").CABACEngine;
const CABACSyntax = @import("cabac_syntax.zig").CABACSyntax;
const SliceDecoder = @import("macroblock.zig").SliceDecoder;
const MbTypeI = @import("cabac_syntax.zig").MbTypeI;
const remove_emulation_prevention = @import("nal_splitter.zig").remove_emulation_prevention;
const expGolomb = @import("exp_golomb.zig");
const tui = @import("tui.zig");

// ============================================================================
// 单个文件的解码统计
// ============================================================================
const Stats = struct {
    mb_w: u32 = 0,
    mb_h: u32 = 0,
    total_mb: u32 = 0,
    slices_i: usize = 0,
    slices_ok: usize = 0,
    slices_bad: usize = 0,
    mbs_ok: u64 = 0,
    i4: u64 = 0,
    i16: u64 = 0,
    qp_min: u8 = 255,
    qp_max: u8 = 0,
    err_name: ?[]const u8 = null, // 第一个失败的 error 名
    err_mb_x: u32 = 0,
    err_mb_y: u32 = 0,
};

fn runFile(aa: std.mem.Allocator, io: std.Io, path: []const u8, verbose: bool, max_slices: usize) !Stats {
    var st = Stats{};
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, aa, .unlimited);

    var h = ZigH264Context{
        .allocator = aa,
        .sps_list = [_]?sps_mod.SPS{null} ** 32,
        .pps_list = [_]?pps_mod.PPS{null} ** 256,
        .nals = try .initCapacity(aa, 4),
        .raw_nal_buffer = try .initCapacity(aa, 4),
        .read_pos = 0,
    };

    // ---- 预扫: 收集所有 VCL slice 的 first_mb_in_slice ----
    // 一帧多条 slice 时, 每条 slice 的结束位置 = 下一条 slice 的 first_mb - 1,
    // 最后一条 slice 停在整帧末尾。first_mb_in_slice 是 slice header 的第一个
    // 语法元素 (ue(v)), 不需要 SPS/PPS 就能取到, 所以这趟很便宜。
    var all_first_mbs = try std.ArrayList(u32).initCapacity(aa, 16);
    {
        var pre_splitter = NALSplitter.init(aa, data);
        while (try pre_splitter.next(&h)) |nal| {
            switch (nal.nal_type) {
                .H264_NAL_SLICE, .H264_NAL_IDR_SLICE => {
                    const rbsp = try remove_emulation_prevention(aa, nal.data[1..]);
                    var br = BitReader.init(rbsp);
                    try all_first_mbs.append(aa, try expGolomb.read_ue(&br));
                },
                else => {},
            }
        }
        h.read_pos = 0; // NALSplitter 用 h.read_pos 作游标, 复位后主循环从头扫
    }

    var splitter = NALSplitter.init(aa, data);
    var vcl_idx: usize = 0;
    var i_slice_idx: usize = 0;

    while (try splitter.next(&h)) |nal| {
        switch (nal.nal_type) {
            .H264_NAL_SPS => {
                const rbsp = try remove_emulation_prevention(aa, nal.data[1..]);
                var br = BitReader.init(rbsp);
                const sps = try sps_mod.SPS.parse_sps(&br);
                h.sps_list[sps.seq_parameter_set_id] = sps;
                if (verbose) std.debug.print("SPS id={d}: profile={d} {d}x{d} MBs, frame_mbs_only={}\n", .{
                    sps.seq_parameter_set_id,
                    sps.profile_idc,
                    sps.pic_width_in_mbs_minus1 + 1,
                    sps.pic_height_in_map_units_minus1 + 1,
                    sps.frame_mbs_only_flag,
                });
            },
            .H264_NAL_PPS => {
                const rbsp = try remove_emulation_prevention(aa, nal.data[1..]);
                var br = BitReader.init(rbsp);
                const pps = try pps_mod.PPS.parse_pps(&br);
                h.pps_list[pps.pic_parameter_set_id] = pps;
                if (verbose) std.debug.print("PPS id={d}: entropy_coding_mode(CABAC)={}, transform_8x8_mode_flag={}\n", .{
                    pps.pic_parameter_set_id,
                    pps.entropy_coding_mode_flag,
                    pps.transform_8x8_mode_flag,
                });
            },
            .H264_NAL_SLICE, .H264_NAL_IDR_SLICE => {
                const this_vcl = vcl_idx;
                vcl_idx += 1;
                if (i_slice_idx >= max_slices) break;
                const rbsp = try remove_emulation_prevention(aa, nal.data[1..]);
                var br = BitReader.init(rbsp);
                const nal_ref_idc: u2 = @intCast((nal.data[0] >> 5) & 3);
                const sh = try slice_mod.SliceHeader.parse_slice_header(&br, nal.nal_type, nal_ref_idc, h.sps_list, h.pps_list);
                const is_i = (sh.slice_type % 5) == 2;
                if (!is_i) {
                    if (verbose) std.debug.print("slice: type={d} (非 I slice, 跳过)\n", .{sh.slice_type});
                    continue;
                }
                st.slices_i += 1;
                const pps = h.pps_list[sh.pic_parameter_set_id].?;
                const sps = h.sps_list[pps.seq_parameter_set_id].?;
                const slice_qp_y = pps.pic_init_qp_minus26 + 26 + sh.slice_qp_delta;

                // CABAC 数据从下一字节边界开始 (cabac_alignment_one_bit)
                br.align_byte();
                var engine = try CABACEngine.init(sh.slice_type, sh.cabac_init_idc, slice_qp_y, &br);
                var syntax = CABACSyntax.init(&engine);
                const dec = try SliceDecoder.init(aa, &syntax, &sps, &pps, slice_qp_y);
                dec.decode_slice_data(sh.first_mb_in_slice) catch |err| {
                    st.slices_bad += 1;
                    if (st.err_name == null) {
                        st.err_name = @errorName(err);
                        st.err_mb_x = dec.mb_x;
                        st.err_mb_y = dec.mb_y;
                    }
                    if (verbose) std.debug.print("I slice {d}: !! 解码失败 @mb({d},{d}): {s}\n", .{
                        i_slice_idx, dec.mb_x, dec.mb_y, @errorName(err),
                    });
                    i_slice_idx += 1;
                    continue;
                };

                st.mb_w = dec.width_in_mbs;
                st.mb_h = dec.height_in_mbs;
                const total = dec.width_in_mbs * dec.height_in_mbs;
                st.total_mb = total;
                const decoded = dec.mb_y * dec.width_in_mbs + dec.mb_x + 1 - sh.first_mb_in_slice;
                var n_i4: usize = 0;
                var n_i16: usize = 0;
                var qp_min: u8 = 255;
                var qp_max: u8 = 0;
                for (dec.mbs[sh.first_mb_in_slice .. sh.first_mb_in_slice + decoded]) |mb| {
                    if (mb.mb_type == .i_4x4) n_i4 += 1 else n_i16 += 1;
                    qp_min = @min(qp_min, mb.qp_y);
                    qp_max = @max(qp_max, mb.qp_y);
                }
                st.mbs_ok += decoded;
                st.i4 += n_i4;
                st.i16 += n_i16;
                st.qp_min = @min(st.qp_min, qp_min);
                st.qp_max = @max(st.qp_max, qp_max);

                const stopped_mb = dec.mb_y * dec.width_in_mbs + dec.mb_x;
                // 本条 slice 该在哪儿结束: 同帧的下一条 slice 之前, 否则整帧末尾。
                // next_first <= 当前 first_mb 说明下一条属于新的一帧 (first_mb 归零)。
                const expected_end: u32 = blk: {
                    if (this_vcl + 1 < all_first_mbs.items.len) {
                        const next_first = all_first_mbs.items[this_vcl + 1];
                        if (next_first > sh.first_mb_in_slice) break :blk next_first - 1;
                    }
                    break :blk total - 1;
                };
                const sync_ok = dec.last_end_of_slice_flag == 1 and stopped_mb == expected_end;
                if (sync_ok) st.slices_ok += 1 else st.slices_bad += 1;
                if (verbose) std.debug.print("I slice {d} ({s}): first_mb={d} decoded={d}/{d} end={d} stopped={d} terminate={d} I4x4={d} I16x16={d} qp=[{d},{d}] -> {s}\n", .{
                    i_slice_idx,
                    if (nal.nal_type == .H264_NAL_IDR_SLICE) "IDR" else "I",
                    sh.first_mb_in_slice,
                    decoded,
                    total,
                    expected_end,
                    stopped_mb,
                    dec.last_end_of_slice_flag,
                    n_i4,
                    n_i16,
                    qp_min,
                    qp_max,
                    if (sync_ok) "OK 同步" else "!! 失步",
                });
                i_slice_idx += 1;
            },
            else => {},
        }
    }
    return st;
}

// ============================================================================
// 批量模式: 样本清单
// ============================================================================
const Expect = enum { pass, unsupported };

const Vector = struct {
    file: []const u8,
    expect: Expect,
    /// expect == .unsupported 时, 期望命中的 error 名
    want_err: []const u8 = "",
    note: []const u8,
};

/// 清单即文档: 实现新功能后, 把对应行的 expect 改成 .pass 就完成"转正"
const vectors = [_]Vector{
    .{ .file = "01_i_cqp.h264", .expect = .pass, .note = "640x360 全 I · 恒定 QP (最干净通路)" },
    .{ .file = "02_i_aq.h264", .expect = .pass, .note = "640x360 全 I · AQ 逐MB变QP (mb_qp_delta)" },
    .{ .file = "03_i_slices4.h264", .expect = .pass, .note = "640x360 全 I · 每帧 4 条带" },
    .{ .file = "04_gop15.h264", .expect = .pass, .note = "640x360 GOP15 · IDR+P (P 跳过)" },
    .{ .file = "06_fullres_1080p_aq.h264", .expect = .pass, .note = "1080p 真实内容 · 全 I · AQ" },
    .{ .file = "00_copy_original.h264", .expect = .unsupported, .want_err = "Transform8x8NotSupportedYet", .note = "真实原码流 High · 8x8 变换 (待实现)" },
    .{ .file = "05_dct8x8.h264", .expect = .unsupported, .want_err = "Transform8x8NotSupportedYet", .note = "8x8 变换 (待实现)" },
};

const Outcome = enum { ok, fail, skip, new_feature, missing };

fn classify(v: Vector, st_opt: ?Stats, err_opt: ?anyerror) Outcome {
    if (err_opt) |err| return if (err == error.FileNotFound) .missing else .fail;
    const st = st_opt.?;
    switch (v.expect) {
        .pass => {
            if (st.slices_bad == 0 and st.slices_ok > 0 and st.slices_i == st.slices_ok) return .ok;
            return .fail;
        },
        .unsupported => {
            // 之前明确不支持的流: 命中预期 error => skip; 现在能全过 => 功能已实现
            if (st.slices_bad == 0 and st.slices_ok > 0) return .new_feature;
            if (st.err_name) |name| {
                if (std.mem.eql(u8, name, v.want_err)) return .skip;
            }
            return .fail;
        },
    }
}

fn fmtMs(aa: std.mem.Allocator, ms: i64) ![]const u8 {
    if (ms >= 1000) return std.fmt.allocPrint(aa, "{d:.2} s", .{@as(f64, @floatFromInt(ms)) / 1000.0});
    return std.fmt.allocPrint(aa, "{d} ms", .{ms});
}

fn runSuite(io: std.Io, dir: []const u8) !u8 {
    var gpa_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer gpa_state.deinit();
    const aa = gpa_state.allocator();

    const t_start = std.Io.Clock.Timestamp.now(io, .awake);

    // ---- 表头 ----
    tui.line("", .{});
    tui.line("{s}", .{try tui.boxTop(aa, try std.fmt.allocPrint(aa, "{s}myzigh264{s} · 真实码流 I 帧一致性测试", .{ tui.ansi.bold, tui.ansi.reset }))});
    tui.line("{s}", .{try tui.boxRow(aa, try std.fmt.allocPrint(aa, "样本目录  {s}", .{dir}))});
    tui.line("{s}", .{try tui.boxRow(aa, try std.fmt.allocPrint(aa, "判据      decoded==total · stopped==end · terminate==1 (CABAC 全程同步)", .{}))});
    tui.line("{s}", .{try tui.boxRow(aa, try std.fmt.allocPrint(aa, "经验判据  qp 范围合理 (AQ 时 min<max; 出现 [2,43] 即失步)", .{}))});
    tui.line("{s}", .{try tui.boxBot(aa)});
    tui.line("", .{});

    var n_ok: usize = 0;
    var n_fail: usize = 0;
    var n_skip: usize = 0;
    var n_new: usize = 0;
    var n_missing: usize = 0;
    var total_mb: u64 = 0;

    for (vectors) |v| {
        const path = try std.fmt.allocPrint(aa, "{s}/{s}", .{ dir, v.file });
        var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer file_arena.deinit();
        const fa = file_arena.allocator();

        const t0 = std.Io.Clock.Timestamp.now(io, .awake);
        const res = runFile(fa, io, path, false, std.math.maxInt(usize));
        const ms = t0.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.toMilliseconds();
        var st_opt: ?Stats = null;
        var err_opt: ?anyerror = null;
        if (res) |st| {
            st_opt = st;
        } else |e| {
            err_opt = e;
        }
        const outcome = classify(v, st_opt, err_opt);

        switch (outcome) {
            .ok => n_ok += 1,
            .fail => n_fail += 1,
            .skip => n_skip += 1,
            .new_feature => n_new += 1,
            .missing => n_missing += 1,
        }

        const badge = switch (outcome) {
            .ok => try tui.paint(aa, tui.ansi.green, "[ OK ]"),
            .fail => try tui.paint(aa, tui.ansi.red, "[FAIL]"),
            .skip => try tui.paint(aa, tui.ansi.yellow, "[SKIP]"),
            .new_feature => try tui.paint(aa, tui.ansi.cyan, "[NEW!]"),
            .missing => try tui.paint(aa, tui.ansi.red, "[MISS]"),
        };

        // ---- 主行: 有统计就出数据列, 否则只出状态 ----
        if (st_opt) |st| total_mb += st.mbs_ok;
        if (st_opt != null and st_opt.?.mbs_ok > 0) {
            const st = st_opt.?;
            const res_str = try std.fmt.allocPrint(aa, "{d}x{d}", .{ st.mb_w, st.mb_h });
            const speed: u64 = if (ms > 0) @intCast(@divTrunc(@as(i64, @intCast(st.mbs_ok)) * 1000, ms)) else 0;
            tui.line(" {s} {s} {s:>8} {d:>6}MB  {s}4x4 {d:>6}{s}  {s}16x16 {d:>6}{s}  {s}qp{d:>3}..{d:<3}{s}  {s:>7} {d:>5}MB/s", .{
                badge,
                try tui.padRight(aa, v.file, 26),
                res_str,
                st.mbs_ok,
                tui.ansi.grey, st.i4,  tui.ansi.reset,
                tui.ansi.grey, st.i16, tui.ansi.reset,
                tui.ansi.dim,  st.qp_min, st.qp_max, tui.ansi.reset,
                try fmtMs(aa, ms),
                speed,
            });
        } else {
            tui.line(" {s} {s} ——", .{ badge, try tui.padRight(aa, v.file, 26) });
        }

        // ---- 备注行 ----
        const status = switch (outcome) {
            .ok => try tui.paint(aa, tui.ansi.green, "通过"),
            .fail => blk: {
                if (st_opt) |st| {
                    if (st.err_name) |name| break :blk try std.fmt.allocPrint(aa, "{s}失败 {s} @mb({d},{d}){s}", .{
                        tui.ansi.red, name, st.err_mb_x, st.err_mb_y, tui.ansi.reset,
                    });
                    break :blk try tui.paint(aa, tui.ansi.red, "失败 同步判据未通过");
                }
                break :blk try tui.paint(aa, tui.ansi.red, "失败 读文件出错");
            },
            .skip => try tui.paint(aa, tui.ansi.yellow, "符合预期 (功能未实现)"),
            .new_feature => try tui.paint(aa, tui.ansi.cyan, "已经能通过了! 把这行改成 .pass"),
            .missing => try tui.paint(aa, tui.ansi.red, "样本缺失, 先跑 zig build vectors"),
        };
        tui.line("        {s}└─{s} {s} {s}· {s}{s}", .{
            tui.ansi.dim, tui.ansi.reset, status, tui.ansi.dim, v.note, tui.ansi.reset,
        });
    }

    const total_ms = t_start.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.toMilliseconds();

    // ---- 汇总 ----
    tui.line("", .{});
    tui.line("{s}", .{try tui.boxTop(aa, "汇总")});
    const counters = try std.fmt.allocPrint(aa, "{s}通过 {d}{s}   已知未支持 {d}   失败 {d}   缺失 {d}      总耗时 {s}      {d} MB",
        .{
            tui.ansi.green, n_ok,   tui.ansi.reset,
            n_skip,         n_fail, n_missing,
            try fmtMs(aa, total_ms), total_mb,
        });
    tui.line("{s}", .{try tui.boxRow(aa, counters)});
    const ratio = if (vectors.len > 0)
        @as(f64, @floatFromInt(n_ok + n_skip)) / @as(f64, @floatFromInt(vectors.len))
    else
        1.0;
    tui.line("{s}", .{try tui.boxRow(aa, try std.fmt.allocPrint(aa, "{s} [{s}] {d:.0}%", .{
        tui.ansi.green, try tui.bar(aa, ratio, 40), ratio * 100,
    }))});
    tui.line("{s}", .{try tui.boxBot(aa)});
    tui.line("", .{});

    if (n_fail > 0 or n_missing > 0) {
        tui.line("{s}  有 {d} 个样本失败 / {d} 个缺失{s}", .{ tui.ansi.red, n_fail, n_missing, tui.ansi.reset });
        return 1;
    }
    if (n_new > 0) {
        tui.line("{s}  有 {d} 个原本不支持的样本已经通过, 记得把清单改成 .pass{s}", .{ tui.ansi.cyan, n_new, tui.ansi.reset });
    }
    return 0;
}

// ============================================================================
// main
// ============================================================================
fn detectColor(init: std.process.Init) bool {
    if (init.environ_map.get("NO_COLOR") != null) return false;
    const is_tty = std.Io.File.stderr().isTty(init.io) catch return true;
    return is_tty;
}

fn runSingle(io: std.Io, path: []const u8, max_slices: usize) !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const t0 = std.Io.Clock.Timestamp.now(io, .awake);
    const st = runFile(aa, io, path, true, max_slices) catch |err| {
        if (err == error.FileNotFound) {
            tui.line("{s}  找不到文件: {s}{s}", .{ tui.ansi.red, path, tui.ansi.reset });
            return 1;
        }
        return err;
    };
    const ms = t0.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.toMilliseconds();
    const speed: u64 = if (ms > 0) @intCast(@divTrunc(@as(i64, @intCast(st.mbs_ok)) * 1000, ms)) else 0;

    tui.line("", .{});
    tui.line("{s}", .{try tui.boxTop(aa, "结果")});
    tui.line("{s}", .{try tui.boxRow(aa, try std.fmt.allocPrint(aa, "文件      {s}", .{try tui.fitRight(aa, path, tui.width - 14)}))});
    tui.line("{s}", .{try tui.boxRow(aa, try std.fmt.allocPrint(aa, "分辨率    {d}x{d} MB ({d} 宏块)   I slice {d} 条", .{
        st.mb_w, st.mb_h, st.total_mb, st.slices_i,
    }))});
    tui.line("{s}", .{try tui.boxRow(aa, try std.fmt.allocPrint(aa, "宏块统计  I4x4 {d} · I16x16 {d} · qp {d}..{d}", .{
        st.i4, st.i16, st.qp_min, st.qp_max,
    }))});
    tui.line("{s}", .{try tui.boxRow(aa, try std.fmt.allocPrint(aa, "同步      {s}{d} 通过 / {d} 失败{s}   {s}   {d} MB/s", .{
        if (st.slices_bad == 0) tui.ansi.green else tui.ansi.red,
        st.slices_ok,
        st.slices_bad,
        tui.ansi.reset,
        try fmtMs(aa, ms),
        speed,
    }))});
    tui.line("{s}", .{try tui.boxBot(aa)});
    tui.line("", .{});

    if (st.err_name) |name| {
        tui.line("  {s}首个错误: {s} @mb({d},{d}){s}", .{ tui.ansi.red, name, st.err_mb_x, st.err_mb_y, tui.ansi.reset });
        return 1;
    }
    if (st.slices_bad > 0) return 1;
    return 0;
}

pub fn main(init: std.process.Init) !void {
    tui.enabled = detectColor(init);
    const argv = init.minimal.args.vector;
    if (argv.len < 2) {
        tui.line("用法:", .{});
        tui.line("  h264-check <annexb.h264> [max_i_slices]   单文件详细模式", .{});
        tui.line("  h264-check --suite [样本目录]             批量模式 (默认 tests/vectors)", .{});
        return error.InvalidArgs;
    }
    const first = std.mem.span(argv[1]);

    if (std.mem.eql(u8, first, "--suite")) {
        const dir = if (argv.len >= 3) std.mem.span(argv[2]) else "tests/vectors";
        const code = try runSuite(init.io, dir);
        if (code != 0) std.process.exit(code);
        return;
    }

    const max_slices: usize = if (argv.len >= 3)
        try std.fmt.parseInt(usize, std.mem.span(argv[2]), 10)
    else
        std.math.maxInt(usize);
    const code = try runSingle(init.io, first, max_slices);
    if (code != 0) std.process.exit(code);
}
