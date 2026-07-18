const std = @import("std");
const sps_mod = @import("sps.zig");
const pps_mod = @import("pps.zig");
const NALUnit = @import("types.zig").NALUnit;

pub const ZigH264Context = struct {
    allocator: std.mem.Allocator,
    width: u32 = 0,
    height: u32 = 0,
    sps_list: [32]?sps_mod.SPS,
    pps_list: [256]?pps_mod.PPS,
    nals: std.ArrayList(NALUnit),
    // nal data
    raw_nal_buffer: std.ArrayList(u8),
    read_pos: usize,
};
