const std = @import("std");
const Io = std.Io;

const FFmpeg = @import("ffmpeg");


export fn my_zigh264(
    ctx: ?*FFmpeg.AVCodecContext, 
    frame: ?*FFmpeg.AVFrame, 
    got_packet: ?*c_int,
    pkt: ?*FFmpeg.AVPacket, 
    ) callconv(.c) c_int {

    const buf_size: c_int = pkt.?.size;

    if (buf_size == 0) {
        // TODO: end of stream, output the remaining frames
    }
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
    _ = pkt;
    return 0;
}
