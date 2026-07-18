const BitReader = @import("bit_reader.zig").BitReader;
const NALType = @import("types.zig").NALType;
const sps_mod = @import("sps.zig");
const pps_mod = @import("pps.zig");
const expGolomb = @import("exp_golomb.zig");
const NALError = @import("types.zig").NALError;

//TODO: 如果后续需要这些字段，其实可以删除
fn skip_ref_pic_list_modification(br: *BitReader, is_b: bool) !void {
    const flag_l0 = try br.next_bit();
    if (flag_l0 != 0) {
        while (true) {
            const idc = try expGolomb.read_ue(br);
            if (idc == 3) break;
            if (idc == 0 or idc == 1) _ = try expGolomb.read_ue(br);
            if (idc == 2) _ = try expGolomb.read_ue(br);
        }
    }
    if (is_b) {
        const flag_l1 = try br.next_bit();
        if (flag_l1 != 0) {
            while (true) {
                const idc = try expGolomb.read_ue(br);
                if (idc == 3) break;
                if (idc == 0 or idc == 1) _ = try expGolomb.read_ue(br);
                if (idc == 2) _ = try expGolomb.read_ue(br);
            }
        }
    }
}

fn skip_dec_ref_pic_marking(br: *BitReader, nal_type: NALType) !void {
    if (nal_type == .H264_NAL_IDR_SLICE) {
        _ = try br.next_bit(); // long_term_reference_flag, 只是标记位，无后续字段
    } else {
        const mmco_flag = try br.next_bit();
        if (mmco_flag != 0) {
            while (true) {
                const mmco = try expGolomb.read_ue(br);
                if (mmco == 0) break;
                if (mmco == 1 or mmco == 3) _ = try expGolomb.read_ue(br);
                if (mmco == 2) _ = try expGolomb.read_ue(br);
            }
        }
    }
}

pub const SliceHeader = struct {
    first_mb_in_slice: u32, // ue(v) 判断是否新帧
    slice_type: u32, // ue(v) I/P/B 决定编码路径
    pic_parameter_set_id: u32, // ue(v) 查PPS -> 查 SPS
    idr_pic_id: u32, // ue(v)
    frame_num: u32, // u(v) 参考帧管理，位宽 = sps.log2_max_frame_num_minus4 + 1
    pic_order_cnt_lsb: u32, // u(v) POC, 位宽 = sps.log2_max_pic_order_cnt_lsb_minus4 + 1
    cabac_init_idc: u32, // ue(v)
    slice_qp_delta: i32, // se(v) 当前slice 的量化参数

    pub fn init() SliceHeader {
        return .{
            .first_mb_in_slice = 0,
            .slice_type = 0,
            .pic_parameter_set_id = 0,
            .idr_pic_id = 0,
            .frame_num = 0,
            .cabac_init_idc = 0,
            .pic_order_cnt_lsb = 0,
            .slice_qp_delta = 0,
        };
    }

    pub fn parse_slice_header(
        br: *BitReader,
        nal_type: NALType,
        nal_ref_idc: u2,
        sps_list: [32]?sps_mod.SPS,
        pps_list: [256]?pps_mod.PPS,
    ) !SliceHeader {
        var sh = SliceHeader.init();

        // 1. Always present
        sh.first_mb_in_slice = try expGolomb.read_ue(br);
        sh.slice_type = try expGolomb.read_ue(br);
        sh.pic_parameter_set_id = try expGolomb.read_ue(br);
        const pps = pps_list[sh.pic_parameter_set_id] orelse return NALError.PPSNotFound;
        const sps = sps_list[pps.seq_parameter_set_id] orelse return NALError.PPSNotFound;

        const is_i = (sh.slice_type % 5) == 2;
        const is_si = (sh.slice_type % 5) == 4;
        const is_b = (sh.slice_type % 5) == 1;

        // 2. IDR only: idr_pic_id
        if (nal_type == .H264_NAL_IDR_SLICE) {
            sh.idr_pic_id = try expGolomb.read_ue(br);
        }

        // 3. frame_num
        sh.frame_num = try br.next_bits(sps.log2_max_frame_num_minus4 + 4);

        // 4. field_pic_flag / bottom_field_flag
        if (!sps.frame_mbs_only_flag) {
            const field_pic_flag = try br.next_bit();
            if (field_pic_flag != 0) _ = try br.next_bit();
        }

        // 5. IDR only: no_output_of_prior_pics_flag
        if (nal_type == .H264_NAL_IDR_SLICE) {
            _ = try br.next_bit();
        }

        // 6. POC
        if (sps.pic_order_cnt_type == 0) {
            sh.pic_order_cnt_lsb = try br.next_bits(sps.log2_max_pic_order_cnt_lsb_minus4 + 4);
            if (pps.pic_order_present_flag and !sps.frame_mbs_only_flag) {
                _ = try expGolomb.read_se(br);
            }
        } else if (sps.pic_order_cnt_type == 1) {
            if (!sps.delta_pic_order_always_zero_flag) {
                _ = try expGolomb.read_se(br);
                if (pps.pic_order_present_flag and !sps.frame_mbs_only_flag) {
                    _ = try expGolomb.read_se(br);
                }
            }
            _ = try expGolomb.read_ue(br);
            return NALError.FMONotSupported;
        }

        // 7. redundant_pic_cnt
        if (pps.redundant_pic_cnt_present_flag) {
            _ = try expGolomb.read_ue(br);
        }

        // 8. B slice only: direct_spatial_mv_pred_flag
        if (is_b) {
            _ = try br.next_bit();
        }

        // 9. P/SP/B: num_ref_idx_active_override_flag
        if (!is_i and !is_si) {
            const override = try br.next_bit();
            if (override != 0) {
                _ = try expGolomb.read_ue(br);
                if (is_b) _ = try expGolomb.read_ue(br);
            }
        }

        // 10. ref_pic_list_modification()
        if (!is_i and !is_si) {
            try skip_ref_pic_list_modification(br, is_b);
        }

        // 11. dec_ref_pic_marking()
        if (nal_ref_idc != 0) {
            try skip_dec_ref_pic_marking(br, nal_type);
        }

        // 12. cabac_init_idc + slice_qp_delta (non-I/SI only)
        if (!is_i and !is_si) {
            if (pps.entropy_coding_mode_flag) {
                sh.cabac_init_idc = try expGolomb.read_ue(br);
            }
            sh.slice_qp_delta = try expGolomb.read_se(br);
        }

        // 13. deblocking filter
        if (pps.deblocking_filter_control_present_flag) {
            const idc = try expGolomb.read_ue(br);
            if (idc != 1) {
                _ = try expGolomb.read_se(br);
                _ = try expGolomb.read_se(br);
            }
        }

        return sh;
    }
};
