const BitReader = @import("bit_reader.zig").BitReader;
// ue(v) 解码:
//      1. 读 leadingZeroBits: 数连续 0 的个数(discard)，直到遇见第一个 1 → 得到 N
//      2. 再读 N 个 bit → 得到 suffix (无符号整数)
//      3. codeNum = (1 << N) - 1 + suffix
//
//    se(v) 解码:
//      1. 先用 ue(v) 得到 codeNum
//      2. 映射: k = (codeNum + 1) / 2
//              如果 codeNum 是偶数 → -k, 奇数 → k

// 读取一个u字段
pub fn read_ue(nal_bit_reader: *BitReader) !u32 {
    var leadingZeroBits: usize = 0;
    while (true) {
        const bit = try nal_bit_reader.next_bit();
        if (bit == 1) break;
        leadingZeroBits += 1;
    }
    const result: u32 = if (leadingZeroBits == 0)
        @as(u32, 0)
    else
        ((@as(u32, 1) << @intCast(leadingZeroBits)) - 1) + try nal_bit_reader.next_bits(leadingZeroBits);
    return result;
}

pub fn read_se(nal_bit_reader: *BitReader) !i32 {
    const code_num = try read_ue(nal_bit_reader);
    const k: i32 = @intCast((code_num + 1) / 2);
    if (code_num % 2 == 0) return -k;
    return k;
}

