const std = @import("std");
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
    sps_list: std.ArrayList(Sps),
    pps_list: std.ArrayList(Pps),
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


const Pps = struct {};
const Sps = struct {};

const H264Type = enum { Annex_B, AVCC };

const TypeError = error{
    NotMaintainedType,
};

// fn what_type(type_data: []u8) !H264Type {
//     return switch (type_data[0]) {
//         1 => .AVCC,
//         // 直接这么判断(可能会存在问题？)
//         else => .Annex_B,
//     };
// }

fn split_nals(allocator: std.mem.Allocator, h: *ZigH264Context) !void {
    var splitter = NALSplitter.init(allocator, h.raw_nal_buffer.items);

    while (try splitter.next(h)) |nal| {
        nal_count += 1;
        const type_name = @tagName(nal.nal_type);
        // 这个switch后续可能会用到，但是目前暂时不需要
        // const type_name = switch (nal.nal_type) {
        //     inline else => |tag| @tagName(tag),
            // .H264_NAL_UNSPECIFIED = 0,
            // .H264_NAL_SLICE = 1, // 非 IDR 图像的编码条带
            // .H264_NAL_DPA = 2, // 数据分区 A
            // .H264_NAL_DPB = 3, // 数据分区 B
            // .H264_NAL_DPC = 4, // 数据分区 C
            // .H264_NAL_IDR_SLICE = 5, // IDR 图像编码条带 (关
            // .H264_NAL_SEI = 6, // 补充增强信息
            // .H264_NAL_SPS = 7, // 序列参数集
            // .H264_NAL_PPS = 8, // 图像参数集
            // .H264_NAL_AUD = 9, // 访问单元分隔符
            // .H264_NAL_END_SEQUENCE = 10, // 序列结束
            // .H264_NAL_END_STREAM = 11, // 码流结束
            // .H264_NAL_FILLER_DATA = 12, // 填充数据
            // .H264_NAL_SPS_EXT = 13, // SPS 扩展
            // .H264_NAL_PREFIX = 14, // 前缀 NAL (用于
            // .// SVC/MVC)
            // .H264_NAL_SUB_SPS = 15, // 子集 SPS (用于 SVC)
            // .H264_NAL_DPS = 16, // 深度参数集 (3D)
            // .H264_NAL_RESERVED17 = 17, // 保留
            // .H264_NAL_RESERVED18 = 18, // 保留
            // .H264_NAL_AUXILIARY_SLICE = 19, // 辅助编码图像
            // .H264_NAL_EXTEN_SLICE = 20, // 扩展条带 (SVC/MVC)
            // .H264_NAL_DEPTH_EXTEN_SLICE = 21, // 深度扩展条带 (3D)
        //     else => "Unknown",
        // };
        h.nals.append(nal) catch |err| {
            std.debug.print("Error appending NAL unit: {any}\n", .{err});
            return err;
        };
        std.debug.print("  NAL {d}: type={s}, size={d} bytes, start_code_len={d}\n", .{ nal_count, type_name, nal.data.len, nal.start_code_len });
    } else {
        return;
    }
    std.debug.print("共找到 {d} 个 NAL 单元\n", .{nal_count});

    // return TypeError.NotMaintainedType;
}

fn remove_emulation_prevention(src: []u8) ![]u8 {
    _ = src;
}

fn parse_sps(data: []u8) !Sps {
    _ = data;
}

fn parse_pps(data: []u8) !Pps {
    _ = data;
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
