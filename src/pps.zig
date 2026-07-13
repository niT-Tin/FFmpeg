const BitReader = @import("bit_reader.zig");
const expGolomb = @import("exp_golomb.zig");
const NALError = @import("types.zig").NALError;

const PPS = struct {
    // ===== 核心字段（必定存在） =====
    pic_parameter_set_id: u32, // ue(v)  范围 0~255
    seq_parameter_set_id: u32, // ue(v)  范围 0~31
    entropy_coding_mode_flag: bool, // u(1)   0=CAVLC, 1=CABAC
    pic_order_present_flag: bool, // u(1)   bottom_field_pic_order 相关
    num_slice_groups_minus1: u32, // ue(v)   0 表示没有 slice group

    // ===== slice group 分支（num_slice_groups_minus1 > 0 时） =====
    slice_group_map_type: u32, // ue(v)
    // 先不处理大于0的情况吧，据说绝大多数视频num_slice_groups_minus1都是0
    // type 0: run_length_minus1[i]     ue(v) × N
    // type 2: top_left[i], bottom_right[i]  ue(v) × N × 2
    // type 3/4/5: slice_group_change_direction_flag u(1)
    //             slice_group_change_rate_minus1   ue(v)
    // type 6: pic_size_in_map_units_minus1  ue(v)
    //         slice_group_id[i]              u(v) × N

    num_ref_idx_l0_active_minus1: u32, // ue(v)
    num_ref_idx_l1_active_minus1: u32, // ue(v)
    weighted_pred_flag: bool, // u(1)
    weighted_bipred_idc: u2, // u(2)

    pic_init_qp_minus26: i32, // se(v)   初始 QP = 26 + 此值
    pic_init_qs_minus26: i32, // se(v)   SP/SI 用
    chroma_qp_index_offset: i32, // se(v)

    deblocking_filter_control_present_flag: bool, // u(1)
    constrained_intra_pred_flag: bool, // u(1)
    redundant_pic_cnt_present_flag: bool, // u(1)
    pub fn init() PPS {
        return PPS{
            .pic_parameter_set_id = 0,
            .seq_parameter_set_id = 0,
            .entropy_coding_mode_flag = false,
            .pic_order_present_flag = false,
            .num_slice_groups_minus1 = 0,

            .slice_group_map_type = 0,

            .num_ref_idx_l0_active_minus1 = 0,
            .num_ref_idx_l1_active_minus1 = 0,
            .weighted_pred_flag = false,
            .weighted_bipred_idc = 0,

            .pic_init_qp_minus26 = 0,
            .pic_init_qs_minus26 = 0,
            .chroma_qp_index_offset = 0,

            .deblocking_filter_control_present_flag = false,
            .constrained_intra_pred_flag = false,
            .redundant_pic_cnt_present_flag = false,
        };
    }
};

pub fn parse_pps(bit_reader: *BitReader) !PPS {
    var pps = PPS.init();
    pps.pic_parameter_set_id = try expGolomb.read_ue(bit_reader);
    pps.seq_parameter_set_id = try expGolomb.read_ue(bit_reader);
    pps.entropy_coding_mode_flag = try bit_reader.next_bit() != 0;
    pps.pic_order_present_flag = try bit_reader.next_bit() != 0;
    pps.num_slice_groups_minus1 = try expGolomb.read_ue(bit_reader);
    if (pps.num_slice_groups_minus1 > 0) {
        return NALError.FMONotSupported;
    }
    pps.num_ref_idx_l0_active_minus1 = try expGolomb.read_ue(bit_reader);
    pps.num_ref_idx_l1_active_minus1 = try expGolomb.read_ue(bit_reader);
    pps.weighted_pred_flag = try bit_reader.next_bit() != 0;
    pps.weighted_bipred_idc = @intCast(try bit_reader.next_bits(2));

    pps.pic_init_qp_minus26 = try expGolomb.read_se(bit_reader);
    pps.pic_init_qs_minus26 = try expGolomb.read_se(bit_reader);
    pps.chroma_qp_index_offset = try expGolomb.read_se(bit_reader);

    pps.deblocking_filter_control_present_flag = try bit_reader.next_bit() != 0;
    pps.constrained_intra_pred_flag = try bit_reader.next_bit() != 0;
    pps.redundant_pic_cnt_present_flag = try bit_reader.next_bit() != 0;
    return pps;
}
