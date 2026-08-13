const CABACEngine = @import("cabac.zig").CABACEngine;
const DecodeError = @import("types.zig").DecodeError;

// ============================================================================
// I slice 宏块层 (macroblock_layer, 规范 7.3.5) 实施路线 M0 ~ M5
//
// 一个宏块的码流顺序: mb_type -> [预测模式] -> intra_chroma_pred_mode
//   -> coded_block_pattern -> mb_qp_delta -> 残差 -> (下一个宏块前) end_of_slice_flag
// 每步做完都用 "terminate 恰好在帧尾触发" 做同步性检查。
//
// M0: I_PCM 分支 (mb_type = 25)
//   - pcm_alignment_zero_bit: 丢弃 bit 直到字节对齐 (bit_reader 层做)
//   - 跳过裸 PCM 数据: 256 亮度 + 2*64 色度字节 (8bit 4:2:0), 不走 CABAC
//   - 之后 CABACEngine 必须重新 init (规范要求)
//
// M1: 4x4 预测模式 (I_4x4 路径, mb_type = 0)
//   - 若 pps.transform_8x8_mode_flag = 1: 先读 transform_size_8x8_flag (1 bin),
//     为 1 则本宏块改读 4 组 intra8x8 (否则 16 组 intra4x4)
//   - 每块: prev_intra4x4_pred_mode_flag (ctxIdx 68, 1 bin);
//     为 0 再读 rem_intra4x4_pred_mode (ctxIdx 69, 3 bin 定长 -> decode_fixed_length)
//   - 无邻居依赖, 纯查表
//
// M2: intra_chroma_pred_mode
//   - truncated unary, cMax = 3 (复用 decode_truncated_unary)
//   - ctxIdxOffset = 64, ctxIdxInc = condTermA + 2*condTermB
//     (condTerm: 左/上宏块可用且其 intra_chroma_pred_mode != 0)
//   - 前置: 邻居状态基建 (top 数组按列缓存 + left 变量, 行首 left 置不可用)
//
// M3: coded_block_pattern (仅 I_4x4 / inter 路径; I_16x16 的 cbp 已含在 mb_type 里)
//   - luma: 4 bin 查 Table 9-17 码表反解 (ctxIdxOffset 73)
//   - chroma: 2 bin (ctxIdxOffset 77)
//   - ctxIdxInc 均为邻居依赖 (左/上的对应 bit 位)
//
// M4: mb_qp_delta (仅当 cbp 非 0 时存在)
//   - 有符号值, binarization: bin0 表 "是否为 0", 之后一元码 + 末尾符号位
//   - ctxIdxOffset 60/61/62 (bin0 / 一元码部分 / 符号位)
//
// M5: 残差 (大头, 规范 7.3.5.3)
//   - coded_block_flag: 每个 4x4 块一个 (ctxIdxOffset 85~, 依赖邻居)
//   - 逐块: significant_coeff_flag / last_significant_coeff_flag
//     (按扫描位置查表, 已有 last_coeff_flag_offset_8x8; 4x4 的表待补)
//   - coeff_abs_level_minus1: uegk (前缀 decision + 后缀 bypass, 已就绪)
//   - coeff_sign_flag: 每系数 1 bin, 走 decode_bypass
//   - 完成后 terminate 同步性检查真正生效
// ============================================================================

pub const CoeffList = struct {};

pub const CABACSyntax = struct {
    engine: *CABACEngine,
    pub fn init(e: *CABACEngine) CABACSyntax {
        return .{
            .engine = e,
        };
    }
    // I slice 的 mb_type 解码 (规范 Table 9-32 / 9-34, 值含义见 Table 7-11)
    // 解码树 (对齐 FFmpeg decode_cabac_intra_mb_type):
    //   bin0 (ctxIdx 3): 0 -> I_4x4 (mb_type 0)
    //   bin1: 走 decode_terminate (该 bin 的 ctxIdx = 276), 命中 -> I_PCM (mb_type 25)
    //   否则 I_16x16 家族, mb_type = 1 + 12*cbp_luma + 4*cbp_chroma + pred
    //   对应 Table 7-11 命名 I_16x16_{pred}_{chroma}_{luma}
    pub fn decode_mb_type_I(self: *CABACSyntax) !u32 {
        const bin0 = try self.engine.decode_decision(3);
        if (bin0 == 0) return 0; // I_4x4

        if (try self.engine.decode_terminate() == 1) return 25; // I_PCM
        // 注意: 返回 25 后调用方需做 pcm_alignment_zero_bit 字节对齐 + 裸 PCM 数据, 不走 CABAC

        var mb_type: u32 = 1; // I_16x16
        mb_type += 12 * @as(u32, try self.engine.decode_decision(4)); // cbp_luma != 0
        if (try self.engine.decode_decision(5) == 1) { // cbp_chroma != 0
            mb_type += 4 + 4 * @as(u32, try self.engine.decode_decision(5)); // 10 -> +4, 11 -> +8
        }
        mb_type += 2 * @as(u32, try self.engine.decode_decision(6)); // intra16x16_pred_mode 高位
        mb_type += 1 * @as(u32, try self.engine.decode_decision(6)); // intra16x16_pred_mode 低位
        return mb_type;
    }

    pub fn decode_I_4x4_intra_premod(self: *CABACSyntax, most_probable_mode: u32) !u32 {
        const flag = try self.engine.decode_decision(68);
        if (flag == 1) return most_probable_mode;

        var bins = [_]u1{0} ** 3;
        for (0..3) |i| {
            bins[i] = try self.engine.decode_decision(69);
        }
        const rem: u32 = @as(u32, bins[0]) + @as(u32, bins[1]) * 2 + @as(u32, bins[2]) * 4;

        return rem + (if (rem >= most_probable_mode) @as(u32, 1) else @as(u32, 0));
    }

    pub fn decode_I_16x16_intra_chrom_premod(self: *CABACSyntax, cond_term_a: u16, cond_term_b: u16) !u32 {
        const ctx_0 = 64 + cond_term_a + cond_term_b;
        if (try self.engine.decode_decision(ctx_0) == 0) return 0; // DC
        if (try self.engine.decode_decision(67) == 0) return 1; // Horizontal
        if (try self.engine.decode_decision(67) == 0) return 2; // Vertical
        return 3; // Plane
    }

    pub fn decode_mb_qp_delta(self: *CABACSyntax, prev_mb_qp_delta: i32) !i32 {
        var ctx: u16 = 60 + (if (prev_mb_qp_delta != 0) @as(u16, 1) else @as(u16, 0));
        var val: i32 = 0;
        while (try self.engine.decode_decision(ctx) == 1) {
            val += 1;
            ctx = 62;
            if (val > 2 * 51) return DecodeError.DecodeMBQPDeltaError;
        }
        var delta: i32 = 0;
        if ((val & 1) == 1) {
            delta = @divTrunc((val + 1), 2);
        } else {
            delta = @divTrunc(-(val + 1), 2);
        }
        return delta;
    }

    // pub fn decode_coded_block_flag(self: *CABACSyntax, cat: u32, nza: u32, nzb: u32) !u1 {}

    // pub fn decode_significance(self: *CABACSyntax, cat: u32, max_coeff: u32) !CoeffList {}

    // pub fn decode_coef_levels(self: *CABACSyntax, cat: u32, list: []CoeffList) !void {}

    // pub fn decode_residual_block(cat: u32)

    // pub fn decode_residual(mb_type: u16, cbp)
};

// ---- 测试辅助 ----
const std = @import("std");
const BitReader = @import("bit_reader.zig").BitReader;
const slice_mod = @import("slice.zig");

// 所有上下文初始化为 p_state_idx=0, val_mps=0 (LPS 概率 ~0.5, 最不确定)
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

test "decode_mb_type_I: bin0=0 -> I_4x4 (mb_type 0)" {
    // ctx3 p=0,mps=0: range=510,q=3,lps=240,mps=270; offset=100 < 270 -> MPS -> bin=0
    const data = [1]u8{0};
    var br = BitReader.init(&data);
    var engine = testEngine(510, 100, &br);
    var syntax = CABACSyntax.init(&engine);
    try std.testing.expectEqual(0, try syntax.decode_mb_type_I());
}

test "decode_mb_type_I: bin0=1 后 terminate 命中 -> I_PCM (mb_type 25)" {
    // bin0 (ctx3): offset=510 >= 270 -> LPS -> bin=1; offset=240, range=240
    //   -> renorm n=1 -> range=480, offset=480|1=481
    // terminate: range=480-2=478; 481 >= 478 -> 命中 -> 25
    const data = [1]u8{0b1000_0000};
    var br = BitReader.init(&data);
    var engine = testEngine(510, 510, &br);
    var syntax = CABACSyntax.init(&engine);
    try std.testing.expectEqual(25, try syntax.decode_mb_type_I());
}

test "decode_mb_type_I: I_16x16 全零 -> mb_type 1" {
    // offset=280, 码流全 0; ctx3..6 全部 p=0, val_mps=0
    // bin0 (ctx3): 280>=270 -> LPS -> 1; offset=10, range=240 -> renorm -> 480, offset=20
    // terminate: 478; 20<478 -> 0 (不 renorm)
    // cbp_luma (ctx4, mps=240): 20<240 -> 0;  -> renorm -> offset=40
    // cbp_chroma (ctx5, mps=240): 40<240 -> 0; -> renorm -> offset=80
    // pred_hi (ctx6, mps=240): 80<240 -> 0;   -> renorm -> offset=160
    // pred_lo (ctx6 p=1, mps=253): 160<253 -> 0
    // mb_type = 1
    const data = [1]u8{0};
    var br = BitReader.init(&data);
    var engine = testEngine(510, 280, &br);
    var syntax = CABACSyntax.init(&engine);
    try std.testing.expectEqual(1, try syntax.decode_mb_type_I());
}

test "decode_mb_type_I: cbp_luma=1 -> mb_type 13" {
    // offset=400, 码流全 0
    // bin0 (ctx3): 400>=270 -> LPS -> 1; offset=130, range=240 -> renorm -> 480, offset=260
    // terminate: 478; 260<478 -> 0
    // cbp_luma (ctx4, mps=240): 260>=240 -> LPS -> 1; offset=20, -> renorm -> offset=40
    // cbp_chroma (ctx5): 40<240 -> 0; -> renorm -> offset=80
    // pred_hi (ctx6): 80<240 -> 0;  -> renorm -> offset=160
    // pred_lo (ctx6 p=1, mps=253): 160<253 -> 0
    // mb_type = 1 + 12 = 13
    const data = [1]u8{0};
    var br = BitReader.init(&data);
    var engine = testEngine(510, 400, &br);
    var syntax = CABACSyntax.init(&engine);
    try std.testing.expectEqual(13, try syntax.decode_mb_type_I());
}

test "decode_I_4x4_intra_premod: flag=1 -> 直接返回 most_probable_mode" {
    // ctx68 p=0,mps=0: range=510,q=3,lps=240,mps=270; offset=300 >= 270 -> LPS -> bin=1
    const data = [1]u8{0};
    var br = BitReader.init(&data);
    var engine = testEngine(510, 300, &br);
    var syntax = CABACSyntax.init(&engine);
    try std.testing.expectEqual(2, try syntax.decode_I_4x4_intra_premod(2));
}

test "decode_I_4x4_intra_premod: flag=0, rem=0, mpm=1 -> mode 0" {
    // offset=20, 码流全 0
    // flag (ctx68): 20<270 -> MPS -> 0; range=270 不 renorm
    // rem bin0 (ctx69): q=0,lps=128,mps=142; 20<142 -> 0; p 0->1; range=142 -> renorm -> 284, offset=40
    // rem bin1 (ctx69 p=1): q=0,lps=128,mps=156; 40<156 -> 0; p 1->2; range=156 -> renorm -> 312, offset=80
    // rem bin2 (ctx69 p=2): q=0,lps=128,mps=184; 80<184 -> 0
    // rem=0; 0 >= mpm(1)? 否 -> mode = 0
    const data = [1]u8{0};
    var br = BitReader.init(&data);
    var engine = testEngine(510, 20, &br);
    var syntax = CABACSyntax.init(&engine);
    try std.testing.expectEqual(0, try syntax.decode_I_4x4_intra_premod(1));
}

test "decode_I_4x4_intra_premod: flag=0, rem=3, mpm=2 -> mode 4 (验证 rem>=mpm 时 +1 跳过)" {
    // offset=180, 码流全 0
    // flag (ctx68): 180<270 -> MPS -> 0; range=270 不 renorm
    // rem bin0 (ctx69): q=0,lps=128,mps=142; 180>=142 -> LPS -> bin=1-0=1; val_mps->1
    //   offset=38, range=128 -> renorm -> 256, offset=76
    // rem bin1 (ctx69 val_mps=1): mps=128; 76<128 -> MPS -> bin=val_mps=1; p 0->1
    //   range=128 -> renorm -> 256, offset=152
    // rem bin2 (ctx69 p=1, val_mps=1): lps=128,mps=128; 152>=128 -> LPS -> bin=1-1=0
    // rem = 1+2 = 3; 3 >= mpm(2) -> mode = 3+1 = 4
    const data = [1]u8{0};
    var br = BitReader.init(&data);
    var engine = testEngine(510, 180, &br);
    var syntax = CABACSyntax.init(&engine);
    try std.testing.expectEqual(4, try syntax.decode_I_4x4_intra_premod(2));
}

test "decode_I_16x16_intra_chrom_premod: bin0=0 -> DC (0)" {
    // offset=100 < 270 -> bin0 (ctx64, cond_term=0+0) = 0
    const data = [1]u8{0};
    var br = BitReader.init(&data);
    var engine = testEngine(510, 100, &br);
    var syntax = CABACSyntax.init(&engine);
    try std.testing.expectEqual(0, try syntax.decode_I_16x16_intra_chrom_premod(0, 0));
}

test "decode_I_16x16_intra_chrom_premod: bin串 10 -> Horizontal (1)" {
    // offset=300, 码流 0b1000_0000
    // bin0 (ctx64): 300>=270 -> LPS -> 1; offset=30, range=240 -> renorm -> 480, offset=61
    // bin1 (ctx67): q=3,lps=240,mps=240; 61<240 -> MPS -> 0 -> 返回 1
    const data = [1]u8{0b1000_0000};
    var br = BitReader.init(&data);
    var engine = testEngine(510, 300, &br);
    var syntax = CABACSyntax.init(&engine);
    try std.testing.expectEqual(1, try syntax.decode_I_16x16_intra_chrom_premod(0, 0));
}

test "decode_I_16x16_intra_chrom_premod: bin串 111 -> Plane (3)" {
    // offset=420, 码流 0b1100_0000
    // bin0 (ctx64): 420>=270 -> LPS -> 1; offset=150, range=240 -> renorm -> 480, offset=301
    // bin1 (ctx67): 301>=240 -> LPS -> 1; val_mps->1; offset=61, range=240 -> renorm -> 480, offset=123
    // bin2 (ctx67 val_mps=1): 123<240 -> MPS -> bin=val_mps=1 -> 返回 3
    const data = [1]u8{0b1100_0000};
    var br = BitReader.init(&data);
    var engine = testEngine(510, 420, &br);
    var syntax = CABACSyntax.init(&engine);
    try std.testing.expectEqual(3, try syntax.decode_I_16x16_intra_chrom_premod(0, 0));
}

test "decode_mb_qp_delta: 首 bin=0 -> delta 0" {
    // offset=100 < 270 -> bin0 (ctx60, prev=0) = 0 -> val=0 -> delta 0
    const data = [1]u8{0};
    var br = BitReader.init(&data);
    var engine = testEngine(510, 100, &br);
    var syntax = CABACSyntax.init(&engine);
    try std.testing.expectEqual(0, try syntax.decode_mb_qp_delta(0));
}

test "decode_mb_qp_delta: bin串 10 -> +1" {
    // offset=300, 码流 0b1000_0000
    // bin0 (ctx60): 300>=270 -> LPS -> 1; offset=30, range=240 -> renorm -> 480, offset=61
    // bin1 (ctx62): mps=240; 61<240 -> MPS -> 0 -> 停止, val=1 -> +(1+1)/2 = 1
    const data = [1]u8{0b1000_0000};
    var br = BitReader.init(&data);
    var engine = testEngine(510, 300, &br);
    var syntax = CABACSyntax.init(&engine);
    try std.testing.expectEqual(1, try syntax.decode_mb_qp_delta(0));
}

test "decode_mb_qp_delta: bin串 110 -> -1" {
    // offset=509, 码流 0b1100_0000
    // bin0 (ctx60): 509>=270 -> LPS -> 1; offset=239, range=240 -> renorm -> 480, offset=479
    // bin1 (ctx62): 479>=240 -> LPS -> 1; val_mps->1; offset=239, range=240 -> renorm -> 480, offset=479
    // bin2 (ctx62 val_mps=1): 479>=240 -> LPS -> 1-1=0 -> 停止, val=2 -> -(2+1)/2 = -1
    const data = [1]u8{0b1100_0000};
    var br = BitReader.init(&data);
    var engine = testEngine(510, 509, &br);
    var syntax = CABACSyntax.init(&engine);
    try std.testing.expectEqual(-1, try syntax.decode_mb_qp_delta(0));
}

test "decode_mb_qp_delta: prev != 0 时首 bin 用 ctx 61" {
    // prev=2: 首 bin 应作用于 ctx61 (规范和 FFmpeg: 60 + (prev != 0))
    // offset=100 -> MPS -> bin=0 -> delta=0
    // 若条件写反 (prev==0 时才 +1), ctx60 会被误触
    const data = [1]u8{0};
    var br = BitReader.init(&data);
    var engine = testEngine(510, 100, &br);
    var syntax = CABACSyntax.init(&engine);
    try std.testing.expectEqual(0, try syntax.decode_mb_qp_delta(2));
    try std.testing.expectEqual(1, engine.context[61].p_state_idx); // ctx61 被使用且 MPS 命中
    try std.testing.expectEqual(0, engine.context[60].p_state_idx); // ctx60 不受影响
}
