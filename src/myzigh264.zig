const std = @import("std");
const expGolomb = @import("exp_golomb.zig");
const BitReader = @import("bit_reader.zig").BitReader;
const ZigH264Context = @import("context.zig").ZigH264Context;
const NALSplitter = @import("nal_splitter.zig").NALSplitter;
const sps_mod = @import("sps.zig");
const pps_mod = @import("pps.zig");
const slice_mod = @import("slice.zig");
const NALUnit = @import("types.zig").NALUnit;

const FFmpeg = @import("ffmpeg");


fn remove_emulation_prevention(allocator: std.mem.Allocator, src: []u8) ![]u8 {
    var di: usize = 0;
    var si: usize = 0;
    var dst = try allocator.alloc(u8, src.len);

    while (si + 2 < src.len) {
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
    while (si < src.len) {
        dst[di] = src[si];
        di += 1;
        si += 1;
    }
    return allocator.realloc(dst, di);
}

fn decode_slice_data(data: []u8, reader: *BitReader) !void {
    // var codIRange = 510;
    // var codIOffset = try reader.next_bits(9);
    _ = data;
    _ = reader;
    // const result: []u8 = "";
    // 先这么直接返回
    // return result;
}

fn split_nals(allocator: std.mem.Allocator, h: *ZigH264Context) !void {
    var splitter = NALSplitter.init(allocator, h.raw_nal_buffer.items);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    // var current_pps: ?pps_mod.PPS = null;
    // var current_sps: ?sps_mod.SPS = null;


    while (try splitter.next(h)) |nal| {
        h.nal_count += 1;

        const rbsp_data = try remove_emulation_prevention(aa, nal.data[1..]);
        var bit_reader = BitReader.init(rbsp_data);
        // 这个switch后续可能会用到，但是目前暂时不需要
        const type_name = naltype: switch (nal.nal_type) {
            // inline else => |tag| @tagName(tag),
            .H264_NAL_UNSPECIFIED => continue,
            .H264_NAL_SPS => {
                const sps = try sps_mod.SPS.parse_sps(&bit_reader);
                h.sps_list[sps.seq_parameter_set_id] = sps;
                // std.debug.print("SPS: {any}\n", .{sps});
                break :naltype "H264_NAL_SPS";
            },
            .H264_NAL_PPS => {
                const pps = try pps_mod.PPS.parse_pps(&bit_reader);
                h.pps_list[pps.pic_parameter_set_id] = pps;
                // std.debug.print("PPS: {any}\n", .{pps});
                break :naltype "H264_NAL_PPS";
            },
            .H264_NAL_SEI => {
                // try decode_slice_data(rbsp_data, &bit_reader); // SEI 信息的解码
                break :naltype "H264_NAL_SEI";
            },
            .H264_NAL_SLICE, .H264_NAL_IDR_SLICE => {
                const nal_ref_idc: u2 = @intCast((nal.data[0] >> 5) & 3);
                const slice_header = try slice_mod.SliceHeader.parse_slice_header(&bit_reader, nal.nal_type, nal_ref_idc, h.sps_list, h.pps_list);
                // 初始化算术解码引擎
                // 初始化上下文变量表
                if (slice_header.first_mb_in_slice == 0) {
                    // 输出上一帧AVFrame
                    if (nal.nal_type == .H264_NAL_IDR_SLICE) {
                        //TODO: IDR帧: 清空所有参考帧
                    }
                    // 按照新SPS重新分配帧缓存
                    // begin_new_picture
                }
                std.debug.print("Slice_header: {any}\n", .{slice_header});
                try decode_slice_data(rbsp_data, &bit_reader); // 非 IDR 图像的编码条带
                break :naltype "H264_NAL_SLICE,H264_NAL_IDR_SLICE";
            },
            else => @tagName(nal.nal_type),
        };
        // h.nals.append(nal) catch |err| {
        //     std.debug.print("Error appending NAL unit: {any}\n", .{err});
        //     return err;
        // };
        if (!std.mem.eql(u8, type_name, "H264_NAL_SLICE,H264_NAL_IDR_SLICE")) {
            std.debug.print("  NAL {d}: type={s}, size={d} bytes, start_code_len={d}\n", .{ h.nal_count, type_name, nal.data.len, nal.start_code_len });
        }
    } else {
        return;
    }
    std.debug.print("共找到 {d} 个 NAL 单元\n", .{h.nal_count});

    // return TypeError.NotMaintainedType;
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
            .allocator = std.heap.c_allocator,
            .width = 0,
            .height = 0,
            .sps_list = [_]?sps_mod.SPS{null} ** 32,
            .pps_list= [_]?pps_mod.PPS{null} ** 256,
            .nals = std.ArrayList(NALUnit).initCapacity(std.heap.c_allocator, 10) catch |e| {
                std.debug.print("{any}\n", .{e});
                return -1;
            },
            .raw_nal_buffer = std.ArrayList(u8).initCapacity(std.heap.c_allocator, 100) catch |e| {
                std.debug.print("{any}\n", .{e});
                return -1;
            },
            .read_pos = 0,
            .nal_count = 0,
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

    //FIX:  这个地方，数据会不断增长，可能内存泄漏
    h.raw_nal_buffer.appendSlice(h.allocator, data_slice) catch |err| {
        std.debug.print("Error allocator memory: {any}\n", .{err});
        return -1;
    };

    // std.debug.print("appendSlice success! {any}\n", .{h.raw_nal_buffer});
    // 有必要删除之前的data吗?担心性能不够

    // 暂时不做switch
    split_nals(h.allocator, h) catch |err| {
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
