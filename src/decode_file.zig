// 端到端验证工具: 读取 Annex-B 裸 H.264 码流, 对 I slice 做完整 CABAC 宏块层解码
// 复用与 myzigh264.split_nals 相同的链路:
//   NAL 分割 -> 去 emulation prevention -> SPS/PPS -> slice header -> CABACEngine -> SliceDecoder
// 判据 (对齐 commit ed1fdbb 的 TODO):
//   1. 每个 I slice 的宏块全部解出 (无 error / 不中途 terminate)
//   2. 最后一个宏块后 end_of_slice_flag 恰好为 1 = CABAC 全程同步正确
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

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const argv = init.minimal.args.vector;
    if (argv.len < 2) {
        std.debug.print("usage: h264-check <annexb.h264> [max_i_slices]\n", .{});
        return error.InvalidArgs;
    }
    const max_slices: usize = if (argv.len >= 3)
        try std.fmt.parseInt(usize, std.mem.span(argv[2]), 10)
    else
        std.math.maxInt(usize);

    const data = try std.Io.Dir.cwd().readFileAlloc(init.io, std.mem.span(argv[1]), aa, .unlimited);
    defer aa.free(data);

    var h = ZigH264Context{
        .allocator = aa,
        .sps_list = [_]?sps_mod.SPS{null} ** 32,
        .pps_list = [_]?pps_mod.PPS{null} ** 256,
        .nals = try .initCapacity(aa, 4),
        .raw_nal_buffer = try .initCapacity(aa, 4),
        .read_pos = 0,
    };

    var splitter = NALSplitter.init(aa, data);
    var i_slice_idx: usize = 0;
    var ok_slices: usize = 0;
    var bad_slices: usize = 0;

    while (try splitter.next(&h)) |nal| {
        switch (nal.nal_type) {
            .H264_NAL_SPS => {
                const rbsp = try remove_emulation_prevention(aa, nal.data[1..]);
                var br = BitReader.init(rbsp);
                const sps = try sps_mod.SPS.parse_sps(&br);
                h.sps_list[sps.seq_parameter_set_id] = sps;
                std.debug.print("SPS id={d}: profile={d} {d}x{d} MBs, frame_mbs_only={}\n", .{
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
                std.debug.print("PPS id={d}: entropy_coding_mode(CABAC)={}, transform_8x8_mode_flag={}\n", .{
                    pps.pic_parameter_set_id,
                    pps.entropy_coding_mode_flag,
                    pps.transform_8x8_mode_flag,
                });
            },
            .H264_NAL_SLICE, .H264_NAL_IDR_SLICE => {
                if (i_slice_idx >= max_slices) break;
                const rbsp = try remove_emulation_prevention(aa, nal.data[1..]);
                var br = BitReader.init(rbsp);
                const nal_ref_idc: u2 = @intCast((nal.data[0] >> 5) & 3);
                const sh = try slice_mod.SliceHeader.parse_slice_header(&br, nal.nal_type, nal_ref_idc, h.sps_list, h.pps_list);
                const is_i = (sh.slice_type % 5) == 2;
                if (!is_i) {
                    std.debug.print("slice: type={d} (非 I slice, 跳过)\n", .{sh.slice_type});
                    continue;
                }
                const pps = h.pps_list[sh.pic_parameter_set_id].?;
                const sps = h.sps_list[pps.seq_parameter_set_id].?;
                const slice_qp_y = pps.pic_init_qp_minus26 + 26 + sh.slice_qp_delta;

                // CABAC 数据从下一字节边界开始 (cabac_alignment_one_bit)
                br.align_byte();
                var engine = try CABACEngine.init(sh.slice_type, sh.cabac_init_idc, slice_qp_y, &br);
                var syntax = CABACSyntax.init(&engine);
                const dec = try SliceDecoder.init(aa, &syntax, &sps, &pps, slice_qp_y);
                dec.decode_slice_data(sh.first_mb_in_slice) catch |err| {
                    std.debug.print("I slice {d}: !! 解码失败 @mb({d},{d}): {s}\n", .{ i_slice_idx, dec.mb_x, dec.mb_y, @errorName(err) });
                    bad_slices += 1;
                    i_slice_idx += 1;
                    continue;
                };

                const total = dec.width_in_mbs * dec.height_in_mbs;
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
                const sync_ok = dec.last_end_of_slice_flag == 1 and
                    (dec.mb_y * dec.width_in_mbs + dec.mb_x == total - 1);
                std.debug.print("I slice {d} ({s}): first_mb={d} decoded={d}/{d} terminate={d} I4x4={d} I16x16={d} qp=[{d},{d}] -> {s}\n", .{
                    i_slice_idx,
                    if (nal.nal_type == .H264_NAL_IDR_SLICE) "IDR" else "I",
                    sh.first_mb_in_slice,
                    decoded,
                    total,
                    dec.last_end_of_slice_flag,
                    n_i4,
                    n_i16,
                    qp_min,
                    qp_max,
                    if (sync_ok) "OK 同步" else "!! 失步",
                });
                if (sync_ok) ok_slices += 1 else bad_slices += 1;
                i_slice_idx += 1;
            },
            else => {},
        }
    }
    std.debug.print("== {d} 个 I slice 同步正确, {d} 个失败 ==\n", .{ ok_slices, bad_slices });
    if (bad_slices > 0) return error.SliceSyncFailed;
}
