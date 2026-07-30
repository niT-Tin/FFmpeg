const CABACEngine = @import("cabac.zig").CABACEngine;

const CABACSyntax = struct {
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
