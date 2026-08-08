const BitReader = @import("bit_reader.zig").BitReader;
const expGolomb = @import("exp_golomb.zig");
const NALError = @import("types.zig").NALError;

pub const PPS = struct {
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

    // ===== High profile 扩展字段 (RBSP 有剩余数据时才存在) =====
    // 注意: 规范里这个 PPS 字段叫 transform_8x8_mode_flag;
    // transform_size_8x8_flag 是宏块层里的语法元素, 别混淆
    transform_8x8_mode_flag: bool, // u(1)   为1时 I_4x4 宏块前多一个 transform_size_8x8_flag
    pic_scaling_matrix_present_flag: bool, // u(1)
    second_chroma_qp_index_offset: i32, // se(v)

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
            .transform_8x8_mode_flag = false,
            .pic_scaling_matrix_present_flag = false,
            .second_chroma_qp_index_offset = 0,
        };
    }

    pub fn parse_pps(pps_bit_reader: *BitReader) !PPS {
        var pps = PPS.init();
        pps.pic_parameter_set_id = try expGolomb.read_ue(pps_bit_reader);
        pps.seq_parameter_set_id = try expGolomb.read_ue(pps_bit_reader);
        pps.entropy_coding_mode_flag = try pps_bit_reader.next_bit() != 0;
        pps.pic_order_present_flag = try pps_bit_reader.next_bit() != 0;
        pps.num_slice_groups_minus1 = try expGolomb.read_ue(pps_bit_reader);
        if (pps.num_slice_groups_minus1 > 0) {
            return NALError.FMONotSupported;
        }
        pps.num_ref_idx_l0_active_minus1 = try expGolomb.read_ue(pps_bit_reader);
        pps.num_ref_idx_l1_active_minus1 = try expGolomb.read_ue(pps_bit_reader);
        pps.weighted_pred_flag = try pps_bit_reader.next_bit() != 0;
        pps.weighted_bipred_idc = @intCast(try pps_bit_reader.next_bits(2));

        pps.pic_init_qp_minus26 = try expGolomb.read_se(pps_bit_reader);
        pps.pic_init_qs_minus26 = try expGolomb.read_se(pps_bit_reader);
        pps.chroma_qp_index_offset = try expGolomb.read_se(pps_bit_reader);

        pps.deblocking_filter_control_present_flag = try pps_bit_reader.next_bit() != 0;
        pps.constrained_intra_pred_flag = try pps_bit_reader.next_bit() != 0;
        pps.redundant_pic_cnt_present_flag = try pps_bit_reader.next_bit() != 0;

        // High profile 扩展: 仅当 RBSP 还有剩余数据时存在 (baseline 的 PPS 到此结束)
        if (pps_bit_reader.byte_pos < pps_bit_reader.buf.len) {
            pps.transform_8x8_mode_flag = try pps_bit_reader.next_bit() != 0;
            pps.pic_scaling_matrix_present_flag = try pps_bit_reader.next_bit() != 0;
            if (pps.pic_scaling_matrix_present_flag) {
                // TODO: 列表个数依赖 SPS 的 chroma_format_idc (4:4:4 时为 6+6*flag),
                // 这里按 4:2:0 写死为 6 + 2*flag; 后续 parse_pps 应传入 SPS 查询
                const list_count = 6 + 2 * @as(u32, @intFromBool(pps.transform_8x8_mode_flag));
                for (0..list_count) |i| {
                    const present = try pps_bit_reader.next_bit() != 0;
                    if (present) {
                        try skip_scaling_list(pps_bit_reader, if (i < 6) 16 else 64);
                    }
                }
            }
            pps.second_chroma_qp_index_offset = try expGolomb.read_se(pps_bit_reader);
        }
        return pps;
    }
};

// 跳过 scaling_list (规范 7.3.2.1.1.1): delta 链编码, next_scale 归零后不再消耗 bit
// TODO: 与 sps.zig:126 的同类逻辑去重, 抽成公共函数
fn skip_scaling_list(br: *BitReader, size: usize) !void {
    var last_scale: i32 = 8;
    var next_scale: i32 = 8;
    for (0..size) |_| {
        if (next_scale != 0) {
            const delta = try expGolomb.read_se(br);
            next_scale = (last_scale + delta) & 0xFF;
        }
        last_scale = if (next_scale != 0) next_scale else last_scale;
    }
}
