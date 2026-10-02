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

// 邻居不可用时的 nz 账本哨兵 (对齐 FFmpeg: CABAC intra 不可用邻居 nnz=64,
// coded_block_flag 的 condTerm 视为有系数; 这里只需非零, 统一填 1)
const nz_left_unavailable: NzCacheLeft = .{
    .left_luma = .{ 1, 1, 1, 1 },
    .left_cb = .{ 1, 1 },
    .left_cr = .{ 1, 1 },
    .left_luma_dc = 1,
    .left_cb_dc = 1,
    .left_cr_dc = 1,
};

// 邻居不可用时的 cbp 账本 (对齐 FFmpeg cbp=0x7CF: luma 4 bit 全 1, chroma 为 0)
const cbp_unavailable: u8 = 0x0F;

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

    // mb_type 账本 (decode_mb_type_I bin0 的 ctxIdxInc: 邻居是否 I_16x16/I_PCM)
    left_intra16_or_pcm: bool,
    top_intra16_or_pcm: []bool,

    // 输出: 帧级宏块数组, 供后面逆量化/逆DCT/帧内预测使用
    mbs: []Macroblock,

    // 最近一次 decode_slice_data 循环里读到的 end_of_slice_flag
    // (最后一个宏块后恰好为 1 = CABAC 全程同步正确的判据)
    last_end_of_slice_flag: u1,

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
            .left_nz = nz_left_unavailable,
            .left_modes = .{ 2, 2, 2, 2 },
            .top_modes = try allocator.alloc([4]u8, w),
            .left_chroma_pred = 0,
            .top_chroma_pred = try allocator.alloc(u8, w),
            .left_cbp = cbp_unavailable,
            .top_cbp = try allocator.alloc(u8, w),
            .left_intra16_or_pcm = false,
            .top_intra16_or_pcm = try allocator.alloc(bool, w),
            .mbs = try allocator.alloc(Macroblock, w * h),
            .last_end_of_slice_flag = 0,
        };

        // alloc 出来的是未初始化内存, 按列数组全部初始化。
        // coded_block_flag / coded_block_pattern 的邻居约定 (对齐 FFmpeg
        // fill_decode_neighbors): 不可用的邻居按"有系数"处理 ——
        //   CABAC intra slice 里 FFmpeg 给不可用邻居填 nnz=64, cbp=0x7CF
        //   (luma 4 bit 全 1, chroma 为 0), 因此:
        //   - nz 账本填 1 (只有 >0 会被读, 哨兵值任意非零即可)
        //   - cbp 账本填 0x0F (luma 全 1 / chroma 0)
        // top_modes 填 2 (DC), 与 "邻居不可用视为 DC" 的约定一致
        @memset(result.top_nz_luma, [_]u8{1} ** 4);
        @memset(result.top_nz_cb, [_]u8{1} ** 2);
        @memset(result.top_nz_cr, [_]u8{1} ** 2);
        @memset(result.top_nz_luma_dc, 1);
        @memset(result.top_nz_cb_dc, 1);
        @memset(result.top_nz_cr_dc, 1);
        @memset(result.top_modes, [_]u8{2} ** 4);
        @memset(result.top_chroma_pred, 0);
        @memset(result.top_cbp, 0x0F);
        @memset(result.top_intra16_or_pcm, false);
        // mbs 是纯输出, 每个宏块解完都会被整体覆写, 不初始化

        return result;
    }

    pub fn decode_macroblock_I(self: *SliceDecoder) !void {
        // bin0 的 ctxIdxInc = condTermA + condTermB (邻居可用且为 I_16x16/I_PCM)
        const cond_a: u1 = @intFromBool(self.mb_x > 0 and self.left_intra16_or_pcm);
        const cond_b: u1 = @intFromBool(self.mb_y > 0 and self.top_intra16_or_pcm[self.mb_x]);
        const mb_type_i: MbTypeI = @enumFromInt(try self.syntax.decode_mb_type_I(cond_a, cond_b));
        const is_16_or_pcm = mb_type_i != .i_4x4;
        self.left_intra16_or_pcm = is_16_or_pcm;
        self.top_intra16_or_pcm[self.mb_x] = is_16_or_pcm;
        // self.syntax.engine.bit_reader.next_bits()
        var modes: [16]u8 = undefined;
        switch (mb_type_i) {
            .i_4x4 => {
                if (self.pps.transform_8x8_mode_flag) {
                    // 4x4 + 8x8 transform
                    // 暂时先不管
                    return error.Transform8x8NotSupportedYet;
                } else {
                    // H.264 luma4x4BlkIdx 布局 (8x8 区域优先, 不是纯光栅!):
                    //   0  1  4  5      索引 i 的位置: x = (i%2) + 2*((i/4)%2)
                    //   2  3  6  7                     y = ((i%4)/2) + 2*(i/8)
                    //   8  9  12 13
                    //   10 11 14 15
                    for (0..16) |i| {
                        const x: usize = (i % 2) + 2 * ((i / 4) % 2);
                        const y: usize = ((i % 4) / 2) + 2 * (i / 8);
                        const left_avail = (x != 0) or (self.mb_x > 0);
                        const top_avail = (y != 0) or (self.mb_y > 0);
                        const l = if (x != 0) modes[if (x % 2 == 1) i - 1 else i - 3] else self.left_modes[y];
                        const t = if (y != 0) modes[if (y % 2 == 1) i - 2 else i - 6] else self.top_modes[self.mb_x][x];
                        const mpm: u32 = if (!left_avail or !top_avail) 2 else @min(l, t);
                        modes[i] = @intCast(try self.syntax.decode_I_4x4_intra_premod(mpm));
                    }
                    // 交接: 右列 (3,y) -> left, 下行 (x,3) -> top
                    const right_col = [4]u8{ 5, 7, 13, 15 };
                    const bottom_row = [4]u8{ 10, 11, 14, 15 };
                    for (0..4) |r| {
                        self.left_modes[r] = modes[right_col[r]];
                    }
                    for (0..4) |c| {
                        self.top_modes[self.mb_x][c] = modes[bottom_row[c]];
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
            @memset(&self.left_nz.left_luma, 0);
            @memset(&self.left_nz.left_cb, 0);
            @memset(&self.left_nz.left_cr, 0);
            self.left_nz.left_cr_dc = 0;
            self.left_nz.left_luma_dc = 0;

            @memset(&self.top_nz_luma[self.mb_x], 0);
            @memset(&self.top_nz_cb[self.mb_x], 0);
            @memset(&self.top_nz_cr[self.mb_x], 0);
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
                // 行首: 左邻居不可用, left 账本按"不可用邻居"约定重置
                // (nz 填哨兵 1, cbp 填 0x0F; 见 init 注释)
                self.left_nz = nz_left_unavailable;
                self.left_cbp = cbp_unavailable;
                self.left_chroma_pred = 0;
                self.left_intra16_or_pcm = false;
                for (0..4) |i| {
                    self.left_modes[i] = 2;
                }
            }
            try self.decode_macroblock_I();
            mb_addr += 1;
            self.last_end_of_slice_flag = try self.syntax.engine.decode_terminate();
            if (self.last_end_of_slice_flag == 1) {
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

// ============================================================================
// ---- 测试辅助 ----
const BitReader = @import("bit_reader.zig").BitReader;
const CABACEngine = @import("cabac.zig").CABACEngine;
const slice_mod = @import("slice.zig");

// 所有上下文初始化为 p_state_idx=0, val_mps=0 (与 cabac_syntax.zig 测试同一约定):
//   range=510, q=3, lps=240, mps区间=270
//   offset=0 时全程 MPS -> bin = val_mps; renorm 只补 0 bit, offset 恒为 0,
//   整条宏块解码链 (mb_type -> 预测模式 -> chroma -> cbp -> qp -> 残差) 变得完全确定:
//   每个 bin 的返回值 = 该 ctx 的 val_mps (可用 val_mps=1 预置来 "写" 想要的 bin)
fn testEngine(range: u32, offset: u32, br: *BitReader) CABACEngine {
    var ctx_arr: [1024]slice_mod.StateContext = undefined;
    for (&ctx_arr) |*c| c.* = .{ .p_state_idx = 0, .val_mps = 0 };
    return .{
        .code_I_range = range,
        .code_I_offset = offset,
        .context = ctx_arr,
        .bit_reader = br,
    };
}

fn makeSps(w: u32, h: u32) sps_mod.SPS {
    var sps = sps_mod.SPS.init();
    sps.pic_width_in_mbs_minus1 = w - 1;
    sps.pic_height_in_map_units_minus1 = h - 1;
    return sps;
}

fn expectResidualAllZero(r: *const ResidualBuffers) !void {
    for (r.luma) |blk| for (blk) |v| {
        try std.testing.expectEqual(0, v);
    };
    for (r.luma_dc) |v| try std.testing.expectEqual(0, v);
    for (r.cb_dc) |v| try std.testing.expectEqual(0, v);
    for (r.cr_dc) |v| try std.testing.expectEqual(0, v);
    for (r.cb) |blk| for (blk) |v| {
        try std.testing.expectEqual(0, v);
    };
    for (r.cr) |blk| for (blk) |v| {
        try std.testing.expectEqual(0, v);
    };
}

test "init: 帧级账本按 SPS 尺寸分配, 不可用邻居按哨兵填充, top_modes 填 2 (DC)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var sps = makeSps(3, 2);
    var pps = pps_mod.PPS.init();
    const data = [1]u8{0};
    var br = BitReader.init(&data);
    var engine = testEngine(510, 0, &br);
    var syntax = CABACSyntax.init(&engine);

    const dec = try SliceDecoder.init(aa, &syntax, &sps, &pps, 30);
    try std.testing.expectEqual(3, dec.width_in_mbs);
    try std.testing.expectEqual(2, dec.height_in_mbs);
    try std.testing.expectEqual(6, dec.mbs.len);
    try std.testing.expectEqual(3, dec.top_nz_luma.len);
    try std.testing.expectEqual(30, dec.qp_y);
    try std.testing.expectEqual(0, dec.prev_mb_qp_delta);
    try std.testing.expectEqual(0, dec.mb_x);
    try std.testing.expectEqual(0, dec.mb_y);
    // 按列数组必须显式初始化 (alloc 出来的是未初始化内存)。
    // 不可用邻居约定 (对齐 FFmpeg fill_decode_neighbors):
    //   nz 账本填哨兵 1 ("有系数"), cbp 账本填 0x0F (luma 全 1, chroma 0)
    for (dec.top_nz_luma) |n| try std.testing.expectEqual([4]u8{ 1, 1, 1, 1 }, n);
    for (dec.top_nz_cb) |n| try std.testing.expectEqual([2]u8{ 1, 1 }, n);
    for (dec.top_nz_cr) |n| try std.testing.expectEqual([2]u8{ 1, 1 }, n);
    for (dec.top_nz_luma_dc) |n| try std.testing.expectEqual(1, n);
    for (dec.top_nz_cb_dc) |n| try std.testing.expectEqual(1, n);
    for (dec.top_nz_cr_dc) |n| try std.testing.expectEqual(1, n);
    for (dec.top_cbp) |c| try std.testing.expectEqual(0x0F, c);
    for (dec.top_chroma_pred) |c| try std.testing.expectEqual(0, c);
    // 预测模式缓存: "邻居不可用视为 DC" 约定
    for (dec.top_modes) |m| try std.testing.expectEqual([4]u8{ 2, 2, 2, 2 }, m);
    try std.testing.expectEqual([4]u8{ 2, 2, 2, 2 }, dec.left_modes);
    // left 账本按同一"不可用邻居"约定初始化
    try std.testing.expectEqual(nz_left_unavailable, dec.left_nz);
    try std.testing.expectEqual(cbp_unavailable, dec.left_cbp);
    try std.testing.expectEqual(0, dec.left_chroma_pred);
    try std.testing.expectEqual(false, dec.left_intra16_or_pcm);
    for (dec.top_intra16_or_pcm) |b| try std.testing.expectEqual(false, b);
}

test "decode_macroblock_I: 全 MPS (offset=0) -> I_4x4 cbp=0 无残差, MPM 推导与模式账本交接" {
    // 全部 bin = 0 的确定性轨迹 (1x1 帧, mb_x=mb_y=0, 邻居全不可用):
    //   mb_type: ctx3 MPS -> bin0=0 -> I_4x4
    //   16 个 4x4 块: flag(ctx68)=0 -> rem(ctx69 x3)=000 -> rem=0
    //     mode = 0 + (0 >= mpm); mpm=0 时 mode=1, 否则 0
    //     luma4x4BlkIdx 布局是 8x8 区域优先:
    //       i=0..2 与 i=4,5,8,10 有一个邻居不可用 -> mpm=2 -> mode=0
    //       i=3:  mpm=min(modes[2],modes[1])=0 -> 1;  i=6,7: mpm=min(1,0)=0 -> 1
    //       i=9,11: mpm=min(0,1)=0 -> 1;  i=12: mpm=min(1,1)=1 -> 0
    //       i=13,14: mpm=0 -> 1;  i=15: mpm=1 -> 0
    //     -> modes = {0,0,0,1, 0,0,1,1, 0,1,0,1, 0,1,1,0}
    //   chroma (ctx64) = 0 (DC);  cbp: 4 个 luma bin 全 0 + chroma bin0 = 0 -> cbp=0
    //     邻居 cbp 哨兵 0x0F: bin0 ctx73, bin1 ctx74 (!cur_bit0), bin2 ctx75 (2*!cur_bit0),
    //     bin3 ctx76 (!cur_bit2+2*!cur_bit1), chroma bin0 ctx77
    //   has_residual=false -> 不读 mb_qp_delta / 残差, prev_mb_qp_delta 归零
    // 交接: left_modes = modes[{5,7,13,15}] = {0,1,1,0}
    //       top_modes[0] = modes[{10,11,14,15}] = {0,1,1,0}
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var sps = makeSps(1, 1);
    var pps = pps_mod.PPS.init();
    const data = [_]u8{0} ** 64;
    var br = BitReader.init(&data);
    var engine = testEngine(510, 0, &br);
    var syntax = CABACSyntax.init(&engine);
    const dec = try SliceDecoder.init(aa, &syntax, &sps, &pps, 26);

    try dec.decode_macroblock_I();

    const mb = dec.mbs[0];
    try std.testing.expectEqual(MbTypeI.i_4x4, mb.mb_type);
    try std.testing.expectEqual([16]u8{ 0, 0, 0, 1, 0, 0, 1, 1, 0, 1, 0, 1, 0, 1, 1, 0 }, mb.pred_mode_4x4);
    try std.testing.expectEqual(0, mb.intra_chroma_pred_mode);
    try std.testing.expectEqual(0, mb.cbp);
    try std.testing.expectEqual(26, mb.qp_y);
    try expectResidualAllZero(&mb.residual);
    // 模式账本交接
    try std.testing.expectEqual([4]u8{ 0, 1, 1, 0 }, dec.left_modes);
    try std.testing.expectEqual([4]u8{ 0, 1, 1, 0 }, dec.top_modes[0]);
    // 无残差: qp delta 不读, prev 归零, nz 账本清零
    try std.testing.expectEqual(0, dec.prev_mb_qp_delta);
    try std.testing.expectEqual(0, engine.context[60].p_state_idx); // mb_qp_delta 未读
    try std.testing.expectEqual(0, engine.context[93].p_state_idx); // coded_block_flag 未读
    try std.testing.expectEqual(std.mem.zeroes(NzCacheLeft), dec.left_nz);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, dec.top_nz_luma[0]);
    try std.testing.expectEqual(0, dec.top_nz_luma_dc[0]);
    // ctx 触碰记录 = 解码链路的证据
    try std.testing.expectEqual(1, engine.context[3].p_state_idx); // mb_type bin0
    try std.testing.expectEqual(16, engine.context[68].p_state_idx); // 16 个 pred mode flag
    try std.testing.expectEqual(48, engine.context[69].p_state_idx); // 16 x 3 个 rem bin
    try std.testing.expectEqual(1, engine.context[64].p_state_idx); // chroma bin0
    try std.testing.expectEqual(0, engine.context[67].p_state_idx); // chroma bin1/2 未到达
    try std.testing.expectEqual(1, engine.context[73].p_state_idx); // luma cbp bin0
    try std.testing.expectEqual(1, engine.context[74].p_state_idx); // luma cbp bin1
    try std.testing.expectEqual(1, engine.context[75].p_state_idx); // luma cbp bin2
    try std.testing.expectEqual(1, engine.context[76].p_state_idx); // luma cbp bin3
    try std.testing.expectEqual(1, engine.context[77].p_state_idx); // chroma cbp bin0
}

test "decode_macroblock_I: 无残差宏块清零 12 槽 nz 账本并归零 prev_mb_qp_delta" {
    // 预填脏账本 (模拟上一宏块留下的非零计数), 解一个 I_4x4 cbp=0 宏块:
    // else 分支必须把 left_nz 全部槽位与 top 数组本列清零, prev_mb_qp_delta 归零,
    // 且不消耗任何残差相关 bin (ctx60/85/93 都不被触碰)
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var sps = makeSps(1, 1);
    var pps = pps_mod.PPS.init();
    const data = [_]u8{0} ** 64;
    var br = BitReader.init(&data);
    var engine = testEngine(510, 0, &br);
    var syntax = CABACSyntax.init(&engine);
    const dec = try SliceDecoder.init(aa, &syntax, &sps, &pps, 26);

    dec.left_nz = .{
        .left_luma = .{ 5, 5, 5, 5 },
        .left_cb = .{ 3, 3 },
        .left_cr = .{ 2, 2 },
        .left_luma_dc = 7,
        .left_cb_dc = 1,
        .left_cr_dc = 1,
    };
    dec.top_nz_luma[0] = .{ 9, 9, 9, 9 };
    dec.top_nz_cb[0] = .{ 4, 4 };
    dec.top_nz_cr[0] = .{ 4, 4 };
    dec.top_nz_luma_dc[0] = 6;
    dec.top_nz_cb_dc[0] = 2;
    dec.top_nz_cr_dc[0] = 2;
    dec.prev_mb_qp_delta = 5;

    try dec.decode_macroblock_I();

    try std.testing.expectEqual(std.mem.zeroes(NzCacheLeft), dec.left_nz);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, dec.top_nz_luma[0]);
    try std.testing.expectEqual([2]u8{ 0, 0 }, dec.top_nz_cb[0]);
    try std.testing.expectEqual([2]u8{ 0, 0 }, dec.top_nz_cr[0]);
    try std.testing.expectEqual(0, dec.top_nz_luma_dc[0]);
    try std.testing.expectEqual(0, dec.top_nz_cb_dc[0]);
    try std.testing.expectEqual(0, dec.top_nz_cr_dc[0]);
    try std.testing.expectEqual(0, dec.prev_mb_qp_delta);
    try std.testing.expectEqual(26, dec.qp_y); // qp 不动
    try std.testing.expectEqual(0, engine.context[60].p_state_idx);
    try std.testing.expectEqual(0, engine.context[85].p_state_idx);
    try std.testing.expectEqual(0, engine.context[93].p_state_idx);
    try expectResidualAllZero(&dec.mbs[0].residual);
}

test "decode_slice_data: I_16x16 恒有残差 + mb_qp_delta, nz 账本跨宏块交接 (2x1 帧)" {
    // 预置 ctx3.val_mps=1 与 ctx4.val_mps=1 (mb_type bin0 恒 1: MB(0,0) 走 ctx3,
    // MB(1,0) 因左邻是 I_16x16, condA=1 -> 走 ctx4), ctx88.val_mps=1 (DC flag 恒 1),
    // 其余 ctx val_mps=0, offset=0 全程 MPS:
    //   mb_type: bin0=1 -> terminate=0 -> cbp_luma(ctx6)=0 -> cbp_chroma(ctx7)=0
    //     -> pred(ctx9/10)=0 -> mb_type 1 = i_16x16_0_0_0
    //   16x16: modes 全置 2 (DC)
    //   cbp=0 但 has_residual=true (i_16x16 恒有 luma DC 块) -> 读 mb_qp_delta (ctx60) = 0
    //   DC flag 的 ctxIdx = 85 + nza + 2*nzb; 不可用邻居的 nz 账本按哨兵 1 ("有系数"):
    //   MB(0,0): nza=1 (哨兵), nzb=1 (哨兵) -> ctx88, flag=1 -> sig 全 0 -> 隐式位置 15
    //     -> luma_dc[15]=1; 交接 left_luma_dc=1, top_nz_luma_dc[0]=1
    //   MB(1,0): nza=1 (MB(0,0) 交接), nzb=1 (top 列 1 仍是哨兵) -> 同样走 ctx88,
    //     同样解出 luma_dc[15]=1
    //   若 nz 账本交接缺失或被误清零, MB(1,0) 会落到 ctx87/86; 若 mb_type 账本缺失,
    //   bin0 会落回 ctx3
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var sps = makeSps(2, 1);
    var pps = pps_mod.PPS.init();
    const data = [_]u8{0} ** 64;
    var br = BitReader.init(&data);
    var engine = testEngine(510, 0, &br);
    engine.context[3].val_mps = 1;
    engine.context[4].val_mps = 1;
    engine.context[88].val_mps = 1;
    var syntax = CABACSyntax.init(&engine);
    const dec = try SliceDecoder.init(aa, &syntax, &sps, &pps, 26);

    try dec.decode_slice_data(0);

    // MB(0,0): i_16x16, DC 块解出 1 个系数
    const mb0 = dec.mbs[0];
    try std.testing.expectEqual(MbTypeI.i_16x16_0_0_0, mb0.mb_type);
    try std.testing.expectEqual([_]u8{2} ** 16, mb0.pred_mode_4x4);
    try std.testing.expectEqual(0, mb0.cbp);
    try std.testing.expectEqual(26, mb0.qp_y);
    try std.testing.expectEqual(1, mb0.residual.luma_dc[15]);
    for (mb0.residual.luma_dc[0..15]) |v| try std.testing.expectEqual(0, v);
    for (mb0.residual.luma) |blk| for (blk) |v| {
        try std.testing.expectEqual(0, v); // cbp_luma=0 -> AC 全跳过
    };
    // MB(1,0): nza=1 (交接), nzb=1 (哨兵) -> ctx88, 同样解出 luma_dc[15]=1
    try std.testing.expectEqual(1, dec.mbs[1].residual.luma_dc[15]);
    for (dec.mbs[1].residual.luma_dc[0..15]) |v| try std.testing.expectEqual(0, v);
    for (dec.mbs[1].residual.luma) |blk| for (blk) |v| {
        try std.testing.expectEqual(0, v);
    };
    // 账本: 两个宏块的 DC 计数都进了 top 列, left 停在 MB(1,0) 的结果上
    try std.testing.expectEqual(1, dec.top_nz_luma_dc[0]);
    try std.testing.expectEqual(1, dec.top_nz_luma_dc[1]);
    try std.testing.expectEqual(1, dec.left_nz.left_luma_dc);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, dec.left_nz.left_luma);
    // 16x16 邻居模式置 DC
    try std.testing.expectEqual([4]u8{ 2, 2, 2, 2 }, dec.left_modes);
    try std.testing.expectEqual([4]u8{ 2, 2, 2, 2 }, dec.top_modes[0]);
    // ctx 触碰记录
    try std.testing.expectEqual(1, engine.context[3].p_state_idx); // MB(0,0) bin0 (邻居全不可用)
    try std.testing.expectEqual(1, engine.context[4].p_state_idx); // MB(1,0) bin0 (condA=1, mb_type 账本生效)
    try std.testing.expectEqual(2, engine.context[6].p_state_idx); // 两个 MB 的 cbp_luma bin
    try std.testing.expectEqual(2, engine.context[7].p_state_idx); // 两个 MB 的 cbp_chroma bin
    try std.testing.expectEqual(2, engine.context[60].p_state_idx); // 两个 MB 都读了 qp delta (I_16x16 恒读)
    try std.testing.expectEqual(0, engine.context[85].p_state_idx); // nza=nzb=0 组合未出现
    try std.testing.expectEqual(0, engine.context[86].p_state_idx);
    try std.testing.expectEqual(0, engine.context[87].p_state_idx);
    try std.testing.expectEqual(2, engine.context[88].p_state_idx); // 两个 MB 的 DC flag 都走 ctx88
    try std.testing.expectEqual(1, engine.context[88].val_mps);
    try std.testing.expectEqual(0, engine.context[89].p_state_idx); // AC flag 一个没读
    try std.testing.expectEqual(2, engine.context[105].p_state_idx); // 两个 DC 块的 significance i=0
    try std.testing.expectEqual(2, engine.context[119].p_state_idx); // 扫描到位置 14
    try std.testing.expectEqual(2, engine.context[228].p_state_idx); // levels bin0 (227+1)
    try std.testing.expectEqual(0, dec.prev_mb_qp_delta);
}

test "decode_slice_data: 行首 left 账本重置, top 按列保留 (1x2 帧)" {
    // 预置 ctx3/ctx4.val_mps=1 (两个 MB 都是 I_16x16), 其余 ctx val_mps=0, offset=0 全程 MPS。
    // MB(0,0): DC flag 走 ctx88 (nza/nzb 都是哨兵 1), val_mps=0 -> flag=0 -> cur=0,
    //   交接后 left_luma_dc=0, top_nz_luma_dc[0]=0, top_intra16_or_pcm[0]=true。
    // MB(0,1) 在行首: left 账本必须重置为"不可用邻居"哨兵 -> nza=1;
    //   top 按列保留 -> nzb=top_nz_luma_dc[0]=0
    //   -> DC flag 落在 ctx 85 + 1 + 2*0 = 86
    //   mb_type bin0: condA=0 (行首), condB=1 (上邻 I_16x16) -> 落在 ctx4
    // 若行首没重置 left, nza=0 会落到 ctx85; 若 top 被误清, nzb=1 (哨兵) 会落到 ctx88;
    // 若 top 的 mb_type 账本缺失, bin0 会落回 ctx3
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var sps = makeSps(1, 2);
    var pps = pps_mod.PPS.init();
    const data = [_]u8{0} ** 64;
    var br = BitReader.init(&data);
    var engine = testEngine(510, 0, &br);
    engine.context[3].val_mps = 1;
    engine.context[4].val_mps = 1;
    var syntax = CABACSyntax.init(&engine);
    const dec = try SliceDecoder.init(aa, &syntax, &sps, &pps, 26);

    try dec.decode_slice_data(0);

    try std.testing.expectEqual(1, engine.context[3].p_state_idx); // 只有 MB(0,0) 的 bin0 用过
    try std.testing.expectEqual(1, engine.context[4].p_state_idx); // MB(0,1) bin0 (condB=1)
    try std.testing.expectEqual(1, engine.context[88].p_state_idx); // MB(0,0): nza=1, nzb=1 (哨兵)
    try std.testing.expectEqual(1, engine.context[86].p_state_idx); // MB(0,1): nza=1 (重置哨兵), nzb=0
    try std.testing.expectEqual(0, engine.context[85].p_state_idx); // 没走 nza=0,nzb=0
    try std.testing.expectEqual(0, engine.context[87].p_state_idx); // 也没走 nza=0,nzb=1
    // 两个 DC flag 都是 0 -> cur=0, top 槽保持 0
    try std.testing.expectEqual(0, dec.top_nz_luma_dc[0]);
    try std.testing.expectEqual(0, dec.left_nz.left_luma_dc);
    try expectResidualAllZero(&dec.mbs[0].residual);
    try expectResidualAllZero(&dec.mbs[1].residual);
    // 行首 left_cbp / left_chroma_pred 也被重置 (全零路径下本就为 0, 语义不变)
    try std.testing.expectEqual(0, dec.left_cbp);
    try std.testing.expectEqual(0, dec.left_chroma_pred);
}

test "decode_slice_data: 2x2 全 I_4x4 帧, 预测模式 left/top 账本跨宏块交接" {
    // 全 MPS 轨迹, 4 个宏块光栅解码, 全程 terminate=0, 靠宏块计数退出循环。
    // 每个宏块 modes = f(自己的 left_modes, top_modes[mb_x]), 逐块推演 (rem 恒 0,
    // mode = (mpm == 0) ? 1 : 0; luma4x4BlkIdx 是 8x8 区域优先布局, 邻居索引:
    //   左: x 奇 -> i-1, x=2 -> i-3, x=0 -> left_modes[y]
    //   上: y 奇 -> i-2, y=2 -> i-6, y=0 -> top_modes[mb_x][x])
    //   MB(0,0): 邻居全不可用      -> {0,0,0,1, 0,0,1,1, 0,1,0,1, 0,1,1,0}
    //     交接 left=modes[{5,7,13,15}]={0,1,1,0}, top[0]=modes[{10,11,14,15}]={0,1,1,0}
    //   MB(1,0): left={0,1,1,0}, top 不可用 -> {0,0,1,1, 0,0,1,1, 0,1,1,0, 0,1,1,0}
    //     交接 left={0,1,1,0}, top[1]={1,0,1,0}
    //   MB(0,1): left 不可用 (重置), top[0]={0,1,1,0} -> {0,1,0,1, 0,1,1,0, 0,1,0,1, 0,1,1,0}
    //     交接 left={1,0,1,0}, top[0]={0,1,1,0}
    //   MB(1,1): left={1,0,1,0}, top[1]={1,0,1,0} -> {0,1,1,0, 0,1,1,0, 0,1,1,0, 0,1,1,0}
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var sps = makeSps(2, 2);
    var pps = pps_mod.PPS.init();
    const data = [_]u8{0} ** 128;
    var br = BitReader.init(&data);
    var engine = testEngine(510, 0, &br);
    var syntax = CABACSyntax.init(&engine);
    const dec = try SliceDecoder.init(aa, &syntax, &sps, &pps, 26);

    try dec.decode_slice_data(0);

    const m00 = [16]u8{ 0, 0, 0, 1, 0, 0, 1, 1, 0, 1, 0, 1, 0, 1, 1, 0 };
    const m10 = [16]u8{ 0, 0, 1, 1, 0, 0, 1, 1, 0, 1, 1, 0, 0, 1, 1, 0 };
    const m01 = [16]u8{ 0, 1, 0, 1, 0, 1, 1, 0, 0, 1, 0, 1, 0, 1, 1, 0 };
    const m11 = [16]u8{ 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0 };
    try std.testing.expectEqual(m00, dec.mbs[0].pred_mode_4x4); // MB(0,0)
    try std.testing.expectEqual(m10, dec.mbs[1].pred_mode_4x4); // MB(1,0)
    try std.testing.expectEqual(m01, dec.mbs[2].pred_mode_4x4); // MB(0,1)
    try std.testing.expectEqual(m11, dec.mbs[3].pred_mode_4x4); // MB(1,1)
    for (dec.mbs) |mb| {
        try std.testing.expectEqual(MbTypeI.i_4x4, mb.mb_type);
        try std.testing.expectEqual(0, mb.cbp);
        try std.testing.expectEqual(26, mb.qp_y);
    }
    // 4 个宏块 x 16 个 flag, 全程 MPS 爬到饱和 (p=62; 63 只能由 LPS 到达)
    try std.testing.expectEqual(62, engine.context[68].p_state_idx);
}

test "decode_macroblock_I: transform_8x8_mode_flag=1 + I_4x4 -> 显式报错" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var sps = makeSps(1, 1);
    var pps = pps_mod.PPS.init();
    pps.transform_8x8_mode_flag = true;
    const data = [_]u8{0} ** 8;
    var br = BitReader.init(&data);
    var engine = testEngine(510, 0, &br); // offset=0 -> bin0=0 -> I_4x4
    var syntax = CABACSyntax.init(&engine);
    const dec = try SliceDecoder.init(aa, &syntax, &sps, &pps, 26);

    try std.testing.expectError(error.Transform8x8NotSupportedYet, dec.decode_macroblock_I());
}

test "decode_macroblock_I: I_PCM (mb_type 25) -> 显式报错" {
    // bin0 (ctx3) LPS -> 1; terminate 命中 -> mb_type 25 (轨迹同 cabac_syntax 的 I_PCM 测试)
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var sps = makeSps(1, 1);
    var pps = pps_mod.PPS.init();
    const data = [1]u8{0b1000_0000};
    var br = BitReader.init(&data);
    var engine = testEngine(510, 510, &br);
    var syntax = CABACSyntax.init(&engine);
    const dec = try SliceDecoder.init(aa, &syntax, &sps, &pps, 26);

    try std.testing.expectError(error.IPCMNotSupportedYet, dec.decode_macroblock_I());
}
