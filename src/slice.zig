const BitReader = @import("bit_reader.zig").BitReader;
const NALType = @import("types.zig").NALType;
const sps_mod = @import("sps.zig");
const pps_mod = @import("pps.zig");
const expGolomb = @import("exp_golomb.zig");
const NALError = @import("types.zig").NALError;

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

    pub fn parse_slice_header(slice_header_bit_reader: *BitReader, nal_type: NALType, sps_list: [32]?sps_mod.SPS, pps_list: [256]?pps_mod.PPS) !SliceHeader {
        var slice_header = SliceHeader.init();

        slice_header.first_mb_in_slice = try expGolomb.read_ue(slice_header_bit_reader);
        slice_header.slice_type = try expGolomb.read_ue(slice_header_bit_reader);
        slice_header.pic_parameter_set_id = try expGolomb.read_ue(slice_header_bit_reader);
        const pps = pps_list[slice_header.pic_parameter_set_id] orelse return NALError.PPSNotFound;
        const sps = sps_list[pps.seq_parameter_set_id] orelse return NALError.PPSNotFound;

        if (nal_type == .H264_NAL_IDR_SLICE) {
            slice_header.idr_pic_id = try expGolomb.read_ue(slice_header_bit_reader);
        }
        // 跳过 nal_type == .H264_NAL_SPS_EXT(13)
        slice_header.frame_num = try slice_header_bit_reader.next_bits(sps.log2_max_frame_num_minus4 + 4);
        // 隔行扫描
        if (!sps.frame_mbs_only_flag) {
            // slice_header.fi
            // _ = try slice_header_bit_reader.next_bit();
            // 先不作任何事情
            // _ = try slice_header_bit_reader.next_bit();
        }

        if (nal_type == .H264_NAL_IDR_SLICE) {
            // slice_header_bit_reader.
            // no_output_of_prior_pics_flag
        }

        if (sps.pic_order_cnt_type == 0) {
            slice_header.pic_order_cnt_lsb = try slice_header_bit_reader.next_bits(sps.log2_max_pic_order_cnt_lsb_minus4 + 4);
        }
        const is_i_slice = (slice_header.slice_type % 5) == 2;
        const is_si_slice = (slice_header.slice_type % 5) == 4;
        if (pps.entropy_coding_mode_flag and !is_i_slice and !is_si_slice) {
            slice_header.cabac_init_idc = try expGolomb.read_ue(slice_header_bit_reader);
        }

        if (pps.entropy_coding_mode_flag and !is_i_slice and !is_si_slice) {
            slice_header.slice_qp_delta = try expGolomb.read_se(slice_header_bit_reader);
        } else if (!pps.entropy_coding_mode_flag and !is_i_slice and !is_si_slice) {
            slice_header.slice_qp_delta = try expGolomb.read_se(slice_header_bit_reader);
        }

        return slice_header;
    }
};
