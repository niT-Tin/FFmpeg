const std = @import("std");
const SPS = @import("sps.zig");
const PPS = @import("pps.zig");
const NALUnit = @import("types.zig").NALUnit;

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
