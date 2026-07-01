const std = @import("std");
const Io = std.Io;

const FFmpeg = @import("ffmpeg");


export fn my_zigh264(
    ctx: ?*FFmpeg.AVCodecContext, 
    frame: ?*FFmpeg.AVFrame, 
    got_packet: ?*c_int,
    pkt: ?*FFmpeg.AVPacket, 
    ) callconv(.c) c_int {

    _ = ctx;
    _ = frame;
    _ = got_packet;
    _ = pkt;
    return 0;
}
