const std = @import("std");
const BitReader = @import("tools.zig").BitReader;
const Io = std.Io;

var g_h: ZigH264Context = undefined;
var g_initialized: bool = false;
var nal_count: usize = 0;

const FFmpeg = @import("ffmpeg");

const NALUnit = struct {
    data: []u8,
    nal_type: NALType,
    start_code_len: u8,
};

pub const NALError = error{
    NoStartCode,
    InvalidData,
    OutOfMemory,
    FMONotSupported,
};

const NALType = enum(u5) {
    H264_NAL_UNSPECIFIED = 0,
    H264_NAL_SLICE = 1, // 非 IDR 图像的编码条带
    H264_NAL_DPA = 2, // 数据分区 A
    H264_NAL_DPB = 3, // 数据分区 B
    H264_NAL_DPC = 4, // 数据分区 C
    H264_NAL_IDR_SLICE = 5, // IDR 图像编码条带 (关
    H264_NAL_SEI = 6, // 补充增强信息
    H264_NAL_SPS = 7, // 序列参数集
    H264_NAL_PPS = 8, // 图像参数集
    H264_NAL_AUD = 9, // 访问单元分隔符
    H264_NAL_END_SEQUENCE = 10, // 序列结束
    H264_NAL_END_STREAM = 11, // 码流结束
    H264_NAL_FILLER_DATA = 12, // 填充数据
    H264_NAL_SPS_EXT = 13, // SPS 扩展
    H264_NAL_PREFIX = 14, // 前缀 NAL (用于
    // SVC/MVC)
    H264_NAL_SUB_SPS = 15, // 子集 SPS (用于 SVC)
    H264_NAL_DPS = 16, // 深度参数集 (3D)
    H264_NAL_RESERVED17 = 17, // 保留
    H264_NAL_RESERVED18 = 18, // 保留
    H264_NAL_AUXILIARY_SLICE = 19, // 辅助编码图像
    H264_NAL_EXTEN_SLICE = 20, // 扩展条带 (SVC/MVC)
    H264_NAL_DEPTH_EXTEN_SLICE = 21, // 深度扩展条带 (3D)
    // 22-23 H264_NAL_RESERVED22/23     保留
    // 24-31 H264_NAL_UNSPECIFIED24-31  未指定 (RTP 用
    //                                  24=STAP-A, 28=FU-A)
    //
    // 重要补充：类型 14 和 20（SVC/MVC 扩展）的 NAL unit header 不是
};

pub const ZigH264Context = struct {
    width: u32 = 0,
    height: u32 = 0,
    sps_list: std.ArrayList(SPS),
    pps_list: std.ArrayList(PPS),
    nals: std.ArrayList(NALUnit),
    // nal data
    raw_nal_buffer: std.ArrayList(u8),
    read_pos: usize,
};

pub const NALSplitter = struct {
    allocator: std.mem.Allocator,
    data: []u8,
    pos: usize,

    pub fn init(allocator: std.mem.Allocator, data: []u8) NALSplitter {
        return NALSplitter{
            .allocator = allocator,
            .data = data,
            .pos = 0,
        };
    }

    pub fn findStartCode(self: *NALSplitter, start: usize) ?struct { pos: usize, len: u8 } {
        var i = start;

        while (i + 3 <= self.data.len) {
            if (i + 3 < self.data.len and self.data[i] == 0 and self.data[i + 1] == 0 and self.data[i + 2] == 0 and self.data[i + 3] == 1) {
                return .{ .pos = i, .len = 4 };
            }
            if (i + 2 < self.data.len and self.data[i] == 0 and self.data[i + 1] == 0 and self.data[i + 2] == 1) {
                if (i + 3 >= self.data.len or self.data[i + 3] != 0) {
                    return .{ .pos = i, .len = 3 };
                }
            }
            i += 1;
        }
        return null;
    }

    pub fn next(self: *NALSplitter, h: *ZigH264Context) !?NALUnit {
        // std.debug.print("read_pos: {d}\n", .{h.read_pos});
        const start_code = self.findStartCode(h.read_pos) orelse {
            return null;
        };

        const nalu_start = start_code.pos + start_code.len;

        const next_start = self.findStartCode(nalu_start);

        var nalu_end = if (next_start) |ns| ns.pos else self.data.len;
        // 去除尾部填充00
        while (nalu_end > nalu_start and self.data[nalu_end - 1] == 0) {
            nalu_end -= 1;
        }
        const nalu_len = nalu_end - nalu_start;

        if (nalu_len == 0) {
            self.pos = nalu_end;
            return NALError.InvalidData;
        }
        // const nalu_data = try self.allocator.dupe(u8, self.data[nalu_start..nalu_end]);
        const nalu_data = self.data[nalu_start..nalu_end];
        const nal_type = @as(u5, @intCast(nalu_data[0] & 0x1F));

        // self.pos = nalu_end;
        h.read_pos = nalu_end;

        return NALUnit{
            .data = nalu_data,
            .nal_type = @enumFromInt(nal_type),
            .start_code_len = start_code.len,
        };
    }

    pub fn deinit(self: *NALSplitter) void {
        _ = self;
    }
};

const SPS = struct {
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
};
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

const H264Type = enum { Annex_B, AVCC };

const TypeError = error{
    NotMaintainedType,
};

fn remove_emulation_prevention(allocator: std.mem.Allocator, src: []u8) ![]u8 {
    var di: usize = 0;
    var si: usize = 0;
    var dst = try allocator.alloc(u8, src.len);

    while (si + 2 <= src.len) {
        if (src[si] == 0 and src[si + 1] == 0 and src[si + 2] == 3) {
            dst[di] = 0;
            dst[di + 1] = 0;
            di += 2;
            si += 3;
        } else {
            dst[di] = src[si];
            di += 1;
            si += 1;
        }
    }
    return allocator.realloc(dst, di);
}

fn decode_slice(data: []u8, reader: BitReader) !void {
    _ = data;
    _ = reader;
    // const result: []u8 = "";
    // 先这么直接返回
    // return result;
}

// ue(v) 解码:
//      1. 读 leadingZeroBits: 数连续 0 的个数(discard)，直到遇见第一个 1 → 得到 N
//      2. 再读 N 个 bit → 得到 suffix (无符号整数)
//      3. codeNum = (1 << N) - 1 + suffix
//
//    se(v) 解码:
//      1. 先用 ue(v) 得到 codeNum
//      2. 映射: k = (codeNum + 1) / 2
//              如果 codeNum 是偶数 → -k, 奇数 → k

// 读取一个u字段
fn read_ue(nal_bit_reader: *BitReader) !u32 {
    var leadingZeroBits: usize = 0;
    while (true) {
        const bit = try nal_bit_reader.next_bit();
        if (bit == 1) break;
        leadingZeroBits += 1;
    }
    if (leadingZeroBits == 0) return 0;
    return (@as(u32, 1) << @intCast(leadingZeroBits)) - 1 + try nal_bit_reader.next_bits(leadingZeroBits);
}

fn read_se(nal_bit_reader: *BitReader) !i32 {
    const code_num = try read_ue(nal_bit_reader);
    const k: i32 = @intCast((code_num + 1) / 2);
    if (code_num % 2 == 0) return -k;
    return k;
}

fn split_nals(allocator: std.mem.Allocator, h: *ZigH264Context) !void {
    var splitter = NALSplitter.init(allocator, h.raw_nal_buffer.items);

    while (try splitter.next(h)) |nal| {
        nal_count += 1;

        const rbsp_data = try remove_emulation_prevention(allocator, nal.data[1..]);
        defer allocator.free(rbsp_data);
        var bit_reader = BitReader.init(rbsp_data);
        // 这个switch后续可能会用到，但是目前暂时不需要
        const type_name = naltype: switch (nal.nal_type) {
            // inline else => |tag| @tagName(tag),
            .H264_NAL_UNSPECIFIED => continue,
            .H264_NAL_SPS => {
                const sps = try parse_sps(&bit_reader);
                std.debug.print("SPS: {any}\n", .{sps});
                break :naltype "H264_NAL_SPS";
            },
            .H264_NAL_PPS => {
                const pps = try parse_pps(&bit_reader);
                std.debug.print("PPS: {any}\n", .{pps});
                break :naltype "H264_NAL_PPS";
            },
            .H264_NAL_SEI => {
                try decode_slice(rbsp_data, bit_reader); // SEI 信息的解码
                break :naltype "H264_NAL_SEI";
            },
            .H264_NAL_SLICE, .H264_NAL_IDR_SLICE => {
                try decode_slice(rbsp_data, bit_reader); // 非 IDR 图像的编码条带
                break :naltype "H264_NAL_SLICE,H264_NAL_IDR_SLICE";
            },
            else => @tagName(nal.nal_type),
        };
        // h.nals.append(nal) catch |err| {
        //     std.debug.print("Error appending NAL unit: {any}\n", .{err});
        //     return err;
        // };
        if (!std.mem.eql(u8, type_name, "H264_NAL_SLICE,H264_NAL_IDR_SLICE")) {
            std.debug.print("  NAL {d}: type={s}, size={d} bytes, start_code_len={d}\n", .{ nal_count, type_name, nal.data.len, nal.start_code_len });
        }
    } else {
        return;
    }
    std.debug.print("共找到 {d} 个 NAL 单元\n", .{nal_count});

    // return TypeError.NotMaintainedType;
}

fn parse_sps(bit_reader: *BitReader) !SPS {
    var sps = SPS.init();
    sps.profile_idc = @intCast(try bit_reader.next_bits(8));
    sps.constraint_set0_flag = try bit_reader.next_bit() != 0;
    sps.constraint_set1_flag = try bit_reader.next_bit() != 0;
    sps.constraint_set2_flag = try bit_reader.next_bit() != 0;
    sps.constraint_set3_flag = try bit_reader.next_bit() != 0;
    sps.constraint_set4_flag = try bit_reader.next_bit() != 0;
    sps.constraint_set5_flag = try bit_reader.next_bit() != 0;

    _ = try bit_reader.next_bits(2);
    sps.level_idc = @intCast(try bit_reader.next_bits(8));

    sps.seq_parameter_set_id = try read_ue(bit_reader);
    sps.log2_max_frame_num_minus4 = try read_ue(bit_reader);
    sps.pic_order_cnt_type = try read_ue(bit_reader);

    if (sps.pic_order_cnt_type == 0) {
        sps.log2_max_pic_order_cnt_lsb_minus4 = try read_ue(bit_reader);
    } else if (sps.pic_order_cnt_type == 1) {
        sps.delta_pic_order_always_zero_flag = try bit_reader.next_bit() != 0;
        sps.offset_for_non_ref_pic = try read_se(bit_reader);
        sps.offset_for_top_to_bottom_field = try read_se(bit_reader);
        sps.num_ref_frames_in_pic_order_cnt_cycle = try read_ue(bit_reader);
        for (0..sps.num_ref_frames_in_pic_order_cnt_cycle) |i| {
            sps.offset_for_ref_frame[i] = try read_se(bit_reader);
        }
    }

    sps.num_ref_frames = try read_ue(bit_reader);
    sps.gaps_in_frame_num_value_allowed_flag = try bit_reader.next_bit() != 0;
    sps.pic_width_in_mbs_minus1 = try read_ue(bit_reader);
    sps.frame_mbs_only_flag = try bit_reader.next_bit() != 0;
    if (!sps.frame_mbs_only_flag) {
        sps.mb_adaptive_frame_field_flag = try bit_reader.next_bit() != 0;
    }
    sps.direct_8x8_inference_flag = try bit_reader.next_bit() != 0;
    sps.frame_cropping_flag = try bit_reader.next_bit() != 0;
    if (sps.frame_cropping_flag) {
        sps.frame_crop_left_offset = try read_ue(bit_reader);
        sps.frame_crop_right_offset = try read_ue(bit_reader);
        sps.frame_crop_top_offset = try read_ue(bit_reader);
        sps.frame_crop_bottom_offset = try read_ue(bit_reader);
    }
    sps.vui_parameters_present_flag = try bit_reader.next_bit() != 0;

    return sps;
}

fn parse_pps(bit_reader: *BitReader) !PPS {
    var pps = PPS.init();
    pps.pic_parameter_set_id = try read_ue(bit_reader);
    pps.seq_parameter_set_id = try read_ue(bit_reader);
    pps.entropy_coding_mode_flag = try bit_reader.next_bit() != 0;
    pps.pic_order_present_flag = try bit_reader.next_bit() != 0;
    pps.num_slice_groups_minus1 = try read_ue(bit_reader);
    if (pps.num_slice_groups_minus1 > 0) {
        return NALError.FMONotSupported;
    }
    pps.num_ref_idx_l0_active_minus1 = try read_ue(bit_reader);
    pps.num_ref_idx_l1_active_minus1 = try read_ue(bit_reader);
    pps.weighted_pred_flag = try bit_reader.next_bit() != 0;
    pps.weighted_bipred_idc = @intCast(try bit_reader.next_bits(2));

    pps.pic_init_qp_minus26 = try read_se(bit_reader);
    pps.pic_init_qs_minus26 = try read_se(bit_reader);
    pps.chroma_qp_index_offset = try read_se(bit_reader);

    pps.deblocking_filter_control_present_flag = try bit_reader.next_bit() != 0;
    pps.constrained_intra_pred_flag = try bit_reader.next_bit() != 0;
    pps.redundant_pic_cnt_present_flag = try bit_reader.next_bit() != 0;
    return pps;
}

export fn my_zigh264(
    ctx: ?*FFmpeg.AVCodecContext,
    frame: ?*FFmpeg.AVFrame,
    got_packet: ?*c_int,
    pkt: ?*FFmpeg.AVPacket,
) callconv(.c) c_int {
    if (pkt == null or pkt.?.size == 0) {
        // return
    }
    if (ctx.?.priv_data == null) {
        const h = std.heap.c_allocator.create(ZigH264Context) catch {
            return -1;
        };
        h.* = ZigH264Context{
            .width = 0,
            .height = 0,
            .sps_list = .{ .items = &.{}, .capacity = 0 },
            .pps_list = .{ .items = &.{}, .capacity = 0 },
            .nals = std.ArrayList(NALUnit).initCapacity(std.heap.c_allocator, 10) catch |e| {
                std.debug.print("{any}\n", .{e});
                return -1;
            },
            .raw_nal_buffer = std.ArrayList(u8).initCapacity(std.heap.c_allocator, 100) catch |e| {
                std.debug.print("{any}\n", .{e});
                return -1;
            },
            .read_pos = 0,
        };
        ctx.?.priv_data = h;
    }
    const p_ptr = pkt.?;
    // transfer the size from c_int to usize

    const data_size: usize = @as(usize, @intCast(p_ptr.size));
    const data_slice: []u8 = p_ptr.data[0..data_size];

    if (data_size == 0) {
        // TODO: end of stream, output the remaining frames
        return 0;
    }

    // std.debug.print("Received packet size {d}\n", .{data_size});

    // var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // defer arena.deinit();
    //
    // const allocator = arena.allocator();
    // const h: *ZigH264Context = ctx.?.priv_data.?;
    //if (ctx.?.priv_data) |data| {
    //    std.debug.print("priv_data is not null: {any}\n", .{data});
    //} else {
    //    std.debug.print("priv_data is NULL!!!\n", .{});
    //}
    var h = @as(*ZigH264Context, @ptrCast(@alignCast(ctx.?.priv_data.?)));

    // std.debug.print("ZigH264Context h: {any}\n", .{h});

    h.raw_nal_buffer.appendSlice(std.heap.c_allocator, data_slice) catch |err| {
        std.debug.print("Error allocator memory: {any}\n", .{err});
        return -1;
    };

    // std.debug.print("appendSlice success! {any}\n", .{h.raw_nal_buffer});
    // 有必要删除之前的data吗?担心性能不够

    // 暂时不做switch
    split_nals(std.heap.c_allocator, h) catch |err| {
        std.debug.print("Error splitting NAL units: {any}\n", .{err});
    };
    // const nals = switch (data_slice[0]) {
    //     0 => split_nals(allocator, &h.raw_nal_buffer) catch |err| {
    //         std.debug.print("Error splitting NAL units: {any}\n", .{err});
    //         return -1;
    //     },
    //     // 1 => {avcc/mp4}
    //     else => unreachable,
    // };

    // _ = nals;
    // 编写自己的解码器
    //
    // QUES: 弄清楚整体的解码流程
    // raw -> vcl -> nal -> network
    // network -> nal -> acl -> raw
    // INFO:
    // 解析NAL Unit(找出起始码, 分割每个NALU单元) -> 解析NAL Header(判断类型: SPS/PPS/IDR/P/B/Slice)
    // -> 根据NAL类型做处理
    // - SPS/PPS: 保存参数，初始化解码上下文
    // - IDR/Slice: 使用SPS/PPS进行熵解码，宏块重建
    // - 输出重建的YUV帧到AVFrame
    //
    //
    // QUES: 进入解码器的数据是什么(我有什么数据可用)
    // avpacket -> data:
    // INFO: 裸H.264码流(Annex-B 格式) 或者AVCC格式(MP4常见)
    // 包含一个或多个NAL单元, 每个NAL单元以起始码(00 00 00 01)开头
    //
    //
    // 弄清楚格式，以及怎么拿到各种数据
    // 弄清楚需要输出的格式
    // 弄清楚怎么输出(中间的各种必要步骤)

    // _ = ctx;
    _ = frame;
    _ = got_packet;
    // _ = pkt;
    return 0;
}
