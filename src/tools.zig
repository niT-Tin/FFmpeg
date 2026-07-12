const std = @import("std");

const BitReadError = error{
    BufEmpty,
    OutOfBitsRange,
};

pub const BitReader = struct {
    buf: []const u8,
    u8_read_pos: u8,
    // FIXME: 如果只是解码NAL,在FFmpeg中，应该没问题，但是如果到更广泛的情况下
    // u32可能会溢出，需要考虑另一种形式的实现。
    buf_read_pos: u32, // 每u8_read_pos到1之后，增加1，往后移动一个byte
    pub fn init(buf: []const u8) BitReader {
        return .{
            .buf = buf,
            .u8_read_pos = 0x80, // 1000 0000
            .buf_read_pos = 0,
        };
    }

    pub fn next_bit(self: *BitReader) !u1 {
        if (self.buf_read_pos >= self.buf.len) {
            return BitReadError.BufEmpty;
        }
        // 正常情况
        const result: u1 = @truncate((self.buf[self.buf_read_pos] & self.u8_read_pos) >> @intCast(@ctz(self.u8_read_pos)));
        if (self.u8_read_pos == 0x01) {
            // reset bits
            self.u8_read_pos = 0x80;
        } else {
            self.u8_read_pos = self.u8_read_pos >> 1;
        }
        return result;
    }

    pub fn next_bits(self: *BitReader, num: usize) !u32 {
        if (num > 32) {
            // 暂时不处理大于u32类型bit位数长度的情况
            return BitReadError.OutOfBitsRange;
        }
        var result: u32 = 0;
        for (0..num) |i| {
            // 因为要移动位，所以需要转为u8类型
            const bit: u8 = try self.next_bit();
            result |= bit << @intCast(num - i - 1);
        }
        return result;
    }
};

test "next_bit reads individual bits MSB first" {
    // 0b10110010 = bit流: 1 0 1 1 0 0 1 0
    const data = [_]u8{0b10110010};
    var br = BitReader.init(&data);

    try std.testing.expectEqual(1, try br.next_bit());
    try std.testing.expectEqual(0, try br.next_bit());
    try std.testing.expectEqual(1, try br.next_bit());
    try std.testing.expectEqual(1, try br.next_bit());
    try std.testing.expectEqual(0, try br.next_bit());
    try std.testing.expectEqual(0, try br.next_bit());
    try std.testing.expectEqual(1, try br.next_bit());
    try std.testing.expectEqual(0, try br.next_bit());
}

test "next_bit across byte boundary" {
    // 第1字节末尾+第2字节开头：0b00000001, 0b10000000
    // 读 7 个 0，然后 1, 1, 0...
    const data = [_]u8{ 0b00000001, 0b10000000 };
    var br = BitReader.init(&data);

    var i: usize = 0;
    while (i < 7) : (i += 1) {
        try std.testing.expectEqual(@as(u1, 0), try br.next_bit());
    }
    try std.testing.expectEqual(@as(u1, 1), try br.next_bit()); // 第1字节最后一位
    try std.testing.expectEqual(@as(u1, 1), try br.next_bit()); // 第2字节第一位
    var j: usize = 0;
    while (j < 7) : (j += 1) {
        try std.testing.expectEqual(@as(u1, 0), try br.next_bit());
    }
}

test "next_bits reads multi-bit values" {
    const data = [_]u8{ 0b11010110, 0b00111001 };
    var br = BitReader.init(&data);

    // 110 = 6
    try std.testing.expectEqual(@as(u32, 6), try br.next_bits(3));
    // 剩下的: 10110 00111001
    // 10110 = 22
    try std.testing.expectEqual(@as(u32, 22), try br.next_bits(5));
    // 00111001 = 57
    try std.testing.expectEqual(@as(u32, 57), try br.next_bits(8));
}

test "next_bits reads 0 bits" {
    const data = [_]u8{0xFF};
    var br = BitReader.init(&data);

    try std.testing.expectEqual(@as(u32, 0), try br.next_bits(0));
    // 后续读取不受影响
    try std.testing.expectEqual(@as(u32, 0xFF), try br.next_bits(8));
}

test "mixed next_bit and next_bits" {
    const data = [_]u8{ 0b10101010, 0b11001100 };
    var br = BitReader.init(&data);

    try std.testing.expectEqual(@as(u32, 5), try br.next_bits(3)); // 101
    try std.testing.expectEqual(@as(u1, 0), try br.next_bit()); // 0
    try std.testing.expectEqual(@as(u32, 3), try br.next_bits(4)); // 1010 -> 但我们已经读了 101，剩下 0，下 4 位 = 1010? 等等... 再确认
}

test "read exactly 32 bits" {
    const data = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
    var br = BitReader.init(&data);

    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), try br.next_bits(32));
}

test "next_bits reads partial byte at end" {
    const data = [_]u8{0b11100000};
    var br = BitReader.init(&data);

    try std.testing.expectEqual(@as(u32, 7), try br.next_bits(3)); // 111
}

test "next_bit beyond buffer returns error" {
    const data = [_]u8{0xFF};
    var br = BitReader.init(&data);

    _ = try br.next_bits(8); // 读完所有位

    try std.testing.expectError(BitReadError.BufEmpty, br.next_bit());
}

test "next_bits beyond buffer returns error" {
    const data = [_]u8{0xFF};
    var br = BitReader.init(&data);

    _ = try br.next_bits(8);

    try std.testing.expectError(BitReadError.BufEmpty, br.next_bits(1));
}

// test "next_bits asking more than 32 bits" {
//     const data = [_]u8{ 0, 0, 0, 0, 0 };
//     var br = BitReader.init(&data);
//
//     // 如果你的 next_bits 签名是 !u32，那么 num > 32 应该编译报错还是运行时 error？
//     // 如果 num 是 usize 编译期不可知，可能运行时 panic
//     // 这个测试帮你确认行为
//     _ = br;
// }

test "empty buffer" {
    const data = [_]u8{};
    var br = BitReader.init(&data);

    try std.testing.expectError(BitReadError.BufEmpty, br.next_bit());
    try std.testing.expectError(BitReadError.BufEmpty, br.next_bits(1));
}

test "mixed next_bit and next_bits - exact verification" {
    // 完整位流: 1 0 1 0 1 1 0 0 | 1 1 1 1 0 0 0 0
    const data = [_]u8{ 0b10101100, 0b11110000 };
    var br = BitReader.init(&data);

    try std.testing.expectEqual(@as(u32, 5), try br.next_bits(3)); // 101 = 5
    try std.testing.expectEqual(@as(u1, 0), try br.next_bit()); // 第4位: 0
    try std.testing.expectEqual(@as(u32, 12), try br.next_bits(4)); // 第5-8位: 1100 = 12
    try std.testing.expectEqual(@as(u32, 0xF0), try br.next_bits(8)); // 第2字节: 11110000 = 0xF0
}
