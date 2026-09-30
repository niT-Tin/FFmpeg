const CABACSyntax = @import("cabac_syntax.zig").CABACSyntax;
const sps_mod = @import("sps.zig");
const pps_mod = @import("pps.zig");
const NzCache = @import("cabac_syntax.zig").NzCache;
const MbTypeI = @import("cabac_syntax.zig").MbTypeI;
const ResidualBuffers = @import("cabac_syntax.zig").ResidualBuffers;
const std = @import("std");

pub const NzCacheLeft = struct {
    // 左邻宏块最右一列 (其块 3, 7, 11, 15) 的计数, 按行 0..3
    left_luma: [4]u8,
    left_cb: [2]u8,
    left_cr: [2]u8,
    left_luma_dc: u8,
    left_cb_dc: u8,
    left_cr_dc: u8,
};

pub const Macroblock = struct {
    mb_type: MbTypeI,
    pred_mode_4x4: [16]u8,
    intra_chroma_pred_mode: u8,
    cbp: u8,
    qp_y: u8,
    residual: ResidualBuffers,
};

pub const SliceDecoder = struct {
    syntax: *CABACSyntax,
    sps: *const sps_mod.SPS,
    pps: *const pps_mod.PPS,
    width_in_mbs: u32,
    height_in_mbs: u32, // 来自 SPS
    mb_x: u32,
    mb_y: u32,

    // QP 状态 (slice 开头: qp = 26 + pps.pic_init_qp_minus26 + slice_qp_delta)
    qp_y: i32,
    prev_mb_qp_delta: i32, // slice 开头归零, 供 ctx 60/61 选择

    // --- 邻居账本: left 是单份随宏块移动, top 必须是按列数组 ---
    // 残差 nz 计数 (NzCache 现在的 left_/top_ 槽混在一起, top 要拆成数组)
    top_nz_luma: [][4]u8, // [mb_x] -> 4 列
    top_nz_cb: [][2]u8,
    top_nz_cr: [][2]u8,
    top_nz_luma_dc: []u8,
    top_nz_cb_dc: []u8,
    top_nz_cr_dc: []u8,
    left_nz: NzCacheLeft, // 现 NzCache 的 left_* 部分

    // 预测模式缓存 (MPM / condTerm 推导用)
    left_modes: [4]u8, // 左邻宏块最右列 4 个 4x4 模式
    top_modes: [][4]u8, // [mb_x] -> 上邻最下行 4 个模式
    left_chroma_pred: u8,
    top_chroma_pred: []u8,

    // cbp 缓存 (decode_coded_block_pattern 的入参)
    left_cbp: u8,
    top_cbp: []u8,

    // 输出: 帧级宏块数组, 供后面逆量化/逆DCT/帧内预测使用
    mbs: []Macroblock,

    pub fn init(allocator: std.mem.Allocator, syntax: *CABACSyntax, sps: *const sps_mod.SPS, pps: *const pps_mod.PPS, slice_qp_y: i32) !*SliceDecoder {
        const w = sps.pic_width_in_mbs_minus1 + 1;
        const h = sps.pic_height_in_map_units_minus1 + 1;
        const result = try allocator.create(SliceDecoder);
        result.* = .{
            .syntax = syntax,
            .sps = sps,
            .pps = pps,
            .width_in_mbs = w,
            .height_in_mbs = h,
            .mb_x = 0,
            .mb_y = 0,
            .qp_y = slice_qp_y,
            .prev_mb_qp_delta = 0,
            // 按列数组: 元素类型分别是 [4]u8 / [2]u8 / u8
            .top_nz_luma = try allocator.alloc([4]u8, w),
            .top_nz_cb = try allocator.alloc([2]u8, w),
            .top_nz_cr = try allocator.alloc([2]u8, w),
            .top_nz_luma_dc = try allocator.alloc(u8, w),
            .top_nz_cb_dc = try allocator.alloc(u8, w),
            .top_nz_cr_dc = try allocator.alloc(u8, w),
            .left_nz = std.mem.zeroes(NzCacheLeft),
            .left_modes = .{ 2, 2, 2, 2 },
            .top_modes = try allocator.alloc([4]u8, w),
            .left_chroma_pred = 0,
            .top_chroma_pred = try allocator.alloc(u8, w),
            .left_cbp = 0,
            .top_cbp = try allocator.alloc(u8, w),
            .mbs = try allocator.alloc(Macroblock, w * h),
        };

        // alloc 出来的是未初始化内存, 按列数组全部置零;
        // top_modes 填 2 (DC), 与 "邻居不可用视为 DC" 的约定一致
        @memset(result.top_nz_luma, [_]u8{0} ** 4);
        @memset(result.top_nz_cb, [_]u8{0} ** 2);
        @memset(result.top_nz_cr, [_]u8{0} ** 2);
        @memset(result.top_nz_luma_dc, 0);
        @memset(result.top_nz_cb_dc, 0);
        @memset(result.top_nz_cr_dc, 0);
        @memset(result.top_modes, [_]u8{2} ** 4);
        @memset(result.top_chroma_pred, 0);
        @memset(result.top_cbp, 0);
        // mbs 是纯输出, 每个宏块解完都会被整体覆写, 不初始化

        return result;
    }

    pub fn decode_macroblock_I(self: *SliceDecoder) !void {
        const mb_type_i: MbTypeI = @enumFromInt(try self.syntax.decode_mb_type_I());
        // self.syntax.engine.bit_reader.next_bits()
        var modes: [16]u8 = undefined;
        switch (mb_type_i) {
            .i_4x4 => {
                if (self.pps.transform_8x8_mode_flag) {
                    // 4x4 + 8x8 transform
                    // 暂时先不管
                    return error.Transform8x8NotSupportedYet;
                } else {
                    for (0..16) |i| {
                        const left_avail = (i % 4 != 0) or (self.mb_x > 0);
                        const top_avail = (i >= 4) or (self.mb_y > 0);
                        const l = if (i % 4 != 0) modes[i - 1] else self.left_modes[i / 4];
                        const t = if (i >= 4) modes[i - 4] else self.top_modes[self.mb_x][i];
                        const mpm: u32 = if (!left_avail or !top_avail) 2 else @min(l, t);
                        modes[i] = @intCast(try self.syntax.decode_I_4x4_intra_premod(mpm));
                    }
                    for (0..4) |r| {
                        self.left_modes[r] = modes[3 + 4 * r];
                    }
                    for (0..4) |c| {
                        self.top_modes[self.mb_x][c] = modes[12 + c];
                    }
                    // 4x4 only
                }
            },
            // 后续实现
            .i_pcm => return error.IPCMNotSupportedYet,
            // i_16x16
            else => {
                for (0..4) |i| {
                    self.left_modes[i] = 2;
                    self.top_modes[self.mb_x][i] = 2;
                }
                for (0..16) |i| {
                    modes[i] = 2;
                }
            },
        }

        const condA: u16 = if (self.mb_x > 0 and self.left_chroma_pred != 0) 1 else 0;
        const condB: u16 = if (self.mb_y > 0 and self.top_chroma_pred[self.mb_x] != 0) 1 else 0;
        const chroma_pred = try self.syntax.decode_I_16x16_intra_chrom_premod(condA, condB);
        self.left_chroma_pred = @intCast(chroma_pred);
        self.top_chroma_pred[self.mb_x] = @intCast(chroma_pred);

        const cbp: u8 = if (mb_type_i == .i_4x4) try self.syntax.decode_coded_block_pattern(self.left_cbp, self.top_cbp[self.mb_x]) else (@as(u8, mb_type_i.cbpLuma()) * 0x0F | (@as(u8, mb_type_i.cbpChroma()) << 4));

        self.left_cbp = cbp;
        self.top_cbp[self.mb_x] = cbp;

        const has_residual = (cbp & 0x0F) != 0 or (cbp >> 4) != 0 or mb_type_i != .i_4x4;
        var bufs: ResidualBuffers = std.mem.zeroes(ResidualBuffers);
        if (has_residual) {
            const delta = try self.syntax.decode_mb_qp_delta(self.prev_mb_qp_delta);
            self.prev_mb_qp_delta = delta;
            self.qp_y = @mod(self.qp_y + delta, 52);

            var nz: NzCache = std.mem.zeroes(NzCache);
            nz.left_luma = self.left_nz.left_luma;
            nz.left_cb = self.left_nz.left_cb;
            nz.left_cr = self.left_nz.left_cr;
            nz.left_luma_dc = self.left_nz.left_luma_dc;
            nz.left_cb_dc = self.left_nz.left_cb_dc;
            nz.left_cr_dc = self.left_nz.left_cr_dc;
            nz.top_luma = self.top_nz_luma[self.mb_x];
            nz.top_cb = self.top_nz_cb[self.mb_x];
            nz.top_cr = self.top_nz_cr[self.mb_x];
            nz.top_luma_dc = self.top_nz_luma_dc[self.mb_x];
            nz.top_cb_dc = self.top_nz_cb_dc[self.mb_x];
            nz.top_cr_dc = self.top_nz_cr_dc[self.mb_x];
            try self.syntax.decode_residual(mb_type_i, cbp, &bufs, &nz);
            self.left_nz.left_luma = nz.left_luma;
            self.left_nz.left_cb = nz.left_cb;
            self.left_nz.left_cr = nz.left_cr;
            self.left_nz.left_luma_dc = nz.left_luma_dc;
            self.left_nz.left_cb_dc = nz.left_cb_dc;
            self.left_nz.left_cr_dc = nz.left_cr_dc;
            self.top_nz_luma[self.mb_x] = nz.top_luma;
            self.top_nz_cb[self.mb_x] = nz.top_cb;
            self.top_nz_cr[self.mb_x] = nz.top_cr;
            self.top_nz_luma_dc[self.mb_x] = nz.top_luma_dc;
            self.top_nz_cb_dc[self.mb_x] = nz.top_cb_dc;
            self.top_nz_cr_dc[self.mb_x] = nz.top_cr_dc;
        } else {
            // @memset(self.mbs, )
            self.left_nz.left_cb_dc = 0;
            @memset(self.left_nz.left_luma, 0);
            @memset(self.left_nz.left_cb, 0);
            @memset(self.left_nz.left_cr, 0);
            self.left_nz.left_cr_dc = 0;
            self.left_nz.left_luma_dc = 0;

            @memset(self.top_nz_luma[self.mb_x], 0);
            @memset(self.top_nz_cb[self.mb_x], 0);
            @memset(self.top_nz_cr[self.mb_x], 0);
            self.top_nz_luma_dc[self.mb_x] = 0;
            self.top_nz_cb_dc[self.mb_x] = 0;
            self.top_nz_cr_dc[self.mb_x] = 0;

            self.prev_mb_qp_delta = 0;
        }

        self.mbs[self.mb_y * self.width_in_mbs + self.mb_x] = .{
            .mb_type = mb_type_i,
            .pred_mode_4x4 = modes,
            .intra_chroma_pred_mode = @intCast(chroma_pred),
            .cbp = cbp,
            .qp_y = @intCast(self.qp_y),
            .residual = bufs,
        };
    }

    pub fn decode_slice_data(self: *SliceDecoder, first_mb: u32) !void {
        var mb_addr = first_mb;
        while (mb_addr < self.width_in_mbs * self.height_in_mbs) {
            self.mb_x = mb_addr % self.width_in_mbs;
            self.mb_y = mb_addr / self.width_in_mbs;
            if (self.mb_x == 0) {
                self.left_nz.left_cb_dc = 0;
                self.left_nz.left_luma_dc = 0;
                self.left_nz.left_cr_dc = 0;
                @memset(self.left_nz.left_cb, 0);
                @memset(self.left_nz.left_luma, 0);
                @memset(self.left_nz.left_cr, 0);
                self.left_cbp = 0;
                self.left_chroma_pred = 0;
                for (0..4) |i| {
                    self.left_modes[i] = 2;
                }
            }
            try self.decode_macroblock_I();
            mb_addr += 1;
            if (try self.syntax.engine.decode_terminate() == 1) {
                break;
            }
        }
        //     loop:
        //         mb_x = mb_addr % width
        //         mb_y = mb_addr / width
        //         if mb_x == 0:  // 行首, 左邻居不可用, left 缓存全部重置
        //             left_nz 全零; left_cbp = 0; left_chroma_pred = 0; left_modes 全 2
        //         decode_macroblock_I()
        //         mb_addr += 1
        //         if mb_addr < 本 slice 应解的宏块数:  // 通常 = 整帧宏块总数
        //             if decode_terminate() == 1: break   // end_of_slice_flag, 提前结束
    }
};
