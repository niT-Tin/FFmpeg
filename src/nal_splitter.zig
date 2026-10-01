const std = @import("std");
const ZigH264Context = @import("context.zig").ZigH264Context;
const NALUnit = @import("types.zig").NALUnit;
const NALError = @import("types.zig").NALError;

// 去除 emulation_prevention_three_byte (0x000003 -> 0x0000), 返回 RBSP
pub fn remove_emulation_prevention(allocator: std.mem.Allocator, src: []u8) ![]u8 {
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
