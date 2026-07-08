const std = @import("std");
const Io = std.Io;

const FFmpeg = @import("ffmpeg");

const NALUnit = struct {
    data: []u8,
    nal_type: u5,
    start_code_len: u8,
};

pub const NALError = error{
    NoStartCode,
    InvalidData,
    OutOfMemory,
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
                    return .{ .pos = i, .len = 4 };
                }
            }
            i += 1;
        }
        return null;
    }

    pub fn next(self: *NALSplitter) !?NALUnit {
        const start_code = self.findStartCode(self.pos) orelse {
            return null;
        };

        const nalu_start = start_code.pos + start_code.len;

        const next_start = self.findStartCode(nalu_start);

        const nalu_end = if (next_start) |ns| ns.pos else self.data.len;
        const nalu_len = nalu_end - nalu_start;

        if (nalu_len == 0) {
            self.pos = nalu_end;
            return NALError.InvalidData;
        }
        const nalu_data = try self.allocator.dupe(u8, self.data[nalu_start..nalu_end]);
        const nal_type = @as(u5, @intCast(nalu_data[0] & 0x1F));

        self.pos = nalu_end;

        return NALUnit{
            .data = nalu_data,
            .nal_type = nal_type,
            .start_code_len = start_code.len,
        };
    }

    pub fn deinit(self: *NALSplitter) void {
        _ = self;
    }
};

pub fn extractAllNALUnits(allocator: std.mem.Allocator, data: []u8) ![]NALUnit {
    var list = try std.ArrayList(NALUnit).initCapacity(allocator, 100);
    defer list.deinit(allocator);

    var splitter = NALSplitter.init(allocator, data);

    while (try splitter.next()) |nal| {
        try list.append(allocator, nal);
    }
    return try list.toOwnedSlice(allocator);
}

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

fn split_nals(data: []u8) ![]NALUnit {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var splitter = NALSplitter.init(allocator, data);
    var nal_count: usize = 0;

    while (try splitter.next()) |nal| {
        nal_count += 1;
        const type_name = switch (nal.nal_type) {
            7 => "SPS",
            8 => "PPS",
            5 => "IDR",
            1 => "非IDR Slice",
            6 => "SEI",
            9 => "分隔符",
            12 => "填充数据",
            28 => "FU-A (分片)",
            29 => "FU-B (分片)",
            else => "Unknown",
        };
        std.debug.print("  NAL {d}: type={s}, size={d} bytes, start_code_len={d}\n", .{ nal_count, type_name, nal.data.len, nal.start_code_len });
    }
    std.debug.print("共找到 {d} 个 NAL 单元\n", .{nal_count});

    return TypeError.NotMaintainedType;
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
    const p_ptr = pkt.?;
    // transfer the size from c_int to usize

    const data_size: usize = @as(usize, @intCast(p_ptr.size));
    const data_slice: []u8 = p_ptr.data[0..data_size];

    if (data_size == 0) {
        // TODO: end of stream, output the remaining frames
    }

    std.debug.print("Received packet size {d}\n", .{data_size});

    const nals = switch (data_slice[0]) {
        0 => split_nals(data_slice) catch |err| {
            std.debug.print("Error splitting NAL units: {any}\n", .{err});
            return -1;
        },
        // 1 => {avcc/mp4}
        else => unreachable,
    };

    _ = nals;
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

    _ = ctx;
    _ = frame;
    _ = got_packet;
    // _ = pkt;
    return 0;
}
