const BitReader = @import("bit_reader.zig").BitReader;
const expGolomb = @import("exp_golomb.zig");

pub const SPS = struct {
    // ===== Level 1: 固定长度字段（必定存在） =====
    profile_idc: u8, // u(8)
    constraint_set0_flag: bool, // u(1)
    constraint_set1_flag: bool, // u(1)
    constraint_set2_flag: bool, // u(1)
    constraint_set3_flag: bool, // u(1)
    constraint_set4_flag: bool, // u(1)
    constraint_set5_flag: bool, // u(1)
    reserved_zero_2bits: u2 = 0, // u(2), 必须为 0
    level_idc: u8, // u(8)

    // ===== Level 2: ue(v) 核心字段（必定存在） =====
    seq_parameter_set_id: u32, // ue(v)  范围 0~31
    log2_max_frame_num_minus4: u32, // ue(v)  范围 0~12
    pic_order_cnt_type: u32, // ue(v)  范围 0~2

    // ===== Level 3: 按 pic_order_cnt_type 分支 =====
    // if pic_order_cnt_type == 0
    log2_max_pic_order_cnt_lsb_minus4: u32, // ue(v)

    // if pic_order_cnt_type == 1
    delta_pic_order_always_zero_flag: bool, // u(1)
    offset_for_non_ref_pic: i32, // se(v)
    offset_for_top_to_bottom_field: i32, // se(v)
    num_ref_frames_in_pic_order_cnt_cycle: u32, // ue(v)
    offset_for_ref_frame: [256]i32, // se(v) × N

    // ===== Level 4: 继续必选字段 =====
    num_ref_frames: u32, // ue(v)
    gaps_in_frame_num_value_allowed_flag: bool, // u(1)
    pic_width_in_mbs_minus1: u32, // ue(v)
    pic_height_in_map_units_minus1: u32, // ue(v)
    frame_mbs_only_flag: bool, // u(1)

    // if !frame_mbs_only_flag
    mb_adaptive_frame_field_flag: bool, // u(1)

    direct_8x8_inference_flag: bool, // u(1)
    frame_cropping_flag: bool, // u(1)

    // if frame_cropping_flag
    frame_crop_left_offset: u32, // ue(v)
    frame_crop_right_offset: u32, // ue(v)
    frame_crop_top_offset: u32, // ue(v)
    frame_crop_bottom_offset: u32, // ue(v)

    // ===== Level 5: VUI（跳过标记） =====
    vui_parameters_present_flag: bool, // u(1)
    // if vui_parameters_present_flag: vui_parameters() → 先跳过
    pub fn init() SPS {
        return SPS{
            .profile_idc = 0,
            .constraint_set0_flag = false,
            .constraint_set1_flag = false,
            .constraint_set2_flag = false,
            .constraint_set3_flag = false,
            .constraint_set4_flag = false,
            .constraint_set5_flag = false,
            .level_idc = 0,

            .seq_parameter_set_id = 0,
            .log2_max_frame_num_minus4 = 0,
            .pic_order_cnt_type = 0,

            .log2_max_pic_order_cnt_lsb_minus4 = 0,

            .delta_pic_order_always_zero_flag = false,
            .offset_for_non_ref_pic = 0,
            .offset_for_top_to_bottom_field = 0,
            .num_ref_frames_in_pic_order_cnt_cycle = 0,
            .offset_for_ref_frame = [_]i32{0} ** 256,

            .num_ref_frames = 0,
            .gaps_in_frame_num_value_allowed_flag = false,
            .pic_width_in_mbs_minus1 = 0,
            .pic_height_in_map_units_minus1 = 0,
            .frame_mbs_only_flag = true,

            .mb_adaptive_frame_field_flag = false,

            .direct_8x8_inference_flag = true,
            .frame_cropping_flag = false,

            .frame_crop_left_offset = 0,
            .frame_crop_right_offset = 0,
            .frame_crop_top_offset = 0,
            .frame_crop_bottom_offset = 0,

            .vui_parameters_present_flag = false,
        };
    }

    pub fn parse_sps(sps_bit_reader: *BitReader) !SPS {
        var sps = SPS.init();
        sps.profile_idc = @intCast(try sps_bit_reader.next_bits(8));
        sps.constraint_set0_flag = try sps_bit_reader.next_bit() != 0;
        sps.constraint_set1_flag = try sps_bit_reader.next_bit() != 0;
        sps.constraint_set2_flag = try sps_bit_reader.next_bit() != 0;
        sps.constraint_set3_flag = try sps_bit_reader.next_bit() != 0;
        sps.constraint_set4_flag = try sps_bit_reader.next_bit() != 0;
        sps.constraint_set5_flag = try sps_bit_reader.next_bit() != 0;

        _ = try sps_bit_reader.next_bits(2);
        sps.level_idc = @intCast(try sps_bit_reader.next_bits(8));

        const high_profiles = [_]u8{ 100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135 };
        const has_high_ext: bool = for (high_profiles) |p| {
            if (sps.profile_idc == p) break true;
        } else false;

        sps.seq_parameter_set_id = try expGolomb.read_ue(sps_bit_reader);

        if (has_high_ext) {
            const chroma_format_idc = try expGolomb.read_ue(sps_bit_reader);
            if (chroma_format_idc == 3) {
                _ = try sps_bit_reader.next_bit();
            }

            _ = try expGolomb.read_ue(sps_bit_reader); // bit_depth_luma_minus8
            _ = try expGolomb.read_ue(sps_bit_reader); // bit_depth_chroma_minus8
            _ = try sps_bit_reader.next_bit(); // qpprime_y_zero_transform_bypass_flag
            const scaling_present = try sps_bit_reader.next_bit() != 0;

            if (scaling_present) {
                const scaling_lists = if (chroma_format_idc != 3) @as(u32, 8) else 12;
                for (0..scaling_lists) |i| {
                    const flag = try sps_bit_reader.next_bit() != 0;
                    if (flag) {
                        const list_size: u32 = if (i < 6) 16 else 64;
                        var last_scale: i32 = 8;
                        var next_scale: i32 = 8;
                        for (0..list_size) |_| {
                            if (next_scale != 0) {
                                const delta = try expGolomb.read_se(sps_bit_reader);
                                next_scale = (last_scale + delta) & 0xFF;
                            }
                            last_scale = if (next_scale != 0) next_scale else last_scale;
                        }
                    }
                }
            }
        }
        sps.log2_max_frame_num_minus4 = try expGolomb.read_ue(sps_bit_reader);
        sps.pic_order_cnt_type = try expGolomb.read_ue(sps_bit_reader);

        if (sps.pic_order_cnt_type == 0) {
            sps.log2_max_pic_order_cnt_lsb_minus4 = try expGolomb.read_ue(sps_bit_reader);
        } else if (sps.pic_order_cnt_type == 1) {
            sps.delta_pic_order_always_zero_flag = try sps_bit_reader.next_bit() != 0;
            sps.offset_for_non_ref_pic = try expGolomb.read_se(sps_bit_reader);
            sps.offset_for_top_to_bottom_field = try expGolomb.read_se(sps_bit_reader);
            sps.num_ref_frames_in_pic_order_cnt_cycle = try expGolomb.read_ue(sps_bit_reader);
            for (0..sps.num_ref_frames_in_pic_order_cnt_cycle) |i| {
                sps.offset_for_ref_frame[i] = try expGolomb.read_se(sps_bit_reader);
            }
        }

        sps.num_ref_frames = try expGolomb.read_ue(sps_bit_reader);
        sps.gaps_in_frame_num_value_allowed_flag = try sps_bit_reader.next_bit() != 0;
        sps.pic_width_in_mbs_minus1 = try expGolomb.read_ue(sps_bit_reader);
        sps.pic_height_in_map_units_minus1 = try expGolomb.read_ue(sps_bit_reader);
        sps.frame_mbs_only_flag = try sps_bit_reader.next_bit() != 0;
        if (!sps.frame_mbs_only_flag) {
            sps.mb_adaptive_frame_field_flag = try sps_bit_reader.next_bit() != 0;
        }
        sps.direct_8x8_inference_flag = try sps_bit_reader.next_bit() != 0;
        sps.frame_cropping_flag = try sps_bit_reader.next_bit() != 0;
        if (sps.frame_cropping_flag) {
            sps.frame_crop_left_offset = try expGolomb.read_ue(sps_bit_reader);
            sps.frame_crop_right_offset = try expGolomb.read_ue(sps_bit_reader);
            sps.frame_crop_top_offset = try expGolomb.read_ue(sps_bit_reader);
            sps.frame_crop_bottom_offset = try expGolomb.read_ue(sps_bit_reader);
        }
        sps.vui_parameters_present_flag = try sps_bit_reader.next_bit() != 0;

        return sps;
    }
};
