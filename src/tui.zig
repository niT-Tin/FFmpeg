//! 极简 TUI 小工具: ANSI 颜色 / 框线 / 进度条 / 宽字符(CJK)对齐
//! 只依赖 std, 全部输出走 stderr(与 std.debug.print 一致)
const std = @import("std");

/// main 里按 isTty / NO_COLOR 设置; false 时所有函数退化为纯文本
pub var enabled: bool = true;
/// 框宽(列): 默认 78
pub const width: usize = 78;

pub const ansi = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const red = "\x1b[31m";
    pub const green = "\x1b[32m";
    pub const yellow = "\x1b[33m";
    pub const cyan = "\x1b[36m";
    pub const grey = "\x1b[90m";
};

fn out(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

/// 直接打印一行
pub fn line(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

/// ANSI 包裹(arena 分配); enabled=false 时原样返回 text
pub fn paint(a: std.mem.Allocator, code: []const u8, text: []const u8) ![]const u8 {
    if (!enabled) return text;
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ code, text, ansi.reset });
}

// ---------------- 显示宽度 ----------------

pub fn isWide(cp: u21) bool {
    return cp >= 0x1100 and
        (cp <= 0x115F or // Hangul Jamo
        cp == 0x2329 or cp == 0x232A or
        (cp >= 0x2E80 and cp <= 0xA4CF) or // CJK 部首/汉字/假名
        (cp >= 0xAC00 and cp <= 0xD7A3) or // Hangul 音节
        (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFE30 and cp <= 0xFE6F) or
        (cp >= 0xFF00 and cp <= 0xFF60) or // 全角
        (cp >= 0xFFE0 and cp <= 0xFFE6) or
        (cp >= 0x20000 and cp <= 0x3FFFD));
}

/// 终端显示宽度: 跳过 ANSI 转义, CJK 记 2 列
pub fn visualWidth(text: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b) { // ESC ... m
            i += 1;
            while (i < text.len and text[i] != 'm') i += 1;
            if (i < text.len) i += 1;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const avail = @min(@as(usize, n), text.len - i);
        const cp: u21 = if (avail > 1)
            (std.unicode.utf8Decode(text[i .. i + avail]) catch text[i])
        else
            text[i];
        w += if (isWide(cp)) 2 else 1;
        i += avail;
    }
    return w;
}

/// 右侧补空格到指定显示宽度(超宽则原样返回)
pub fn padRight(a: std.mem.Allocator, text: []const u8, cols: usize) ![]const u8 {
    const w = visualWidth(text);
    if (w >= cols) return text;
    return std.fmt.allocPrint(a, "{s}{s}", .{ text, try repeat(a, " ", cols - w) });
}


/// 把 unit 重复 n 次(运行时 n, 支持多字节字符如 "─")
pub fn repeat(a: std.mem.Allocator, unit: []const u8, n: usize) ![]const u8 {
    const buf = try a.alloc(u8, unit.len * n);
    var i: usize = 0;
    while (i < n) : (i += 1) @memcpy(buf[i * unit.len ..][0..unit.len], unit);
    return buf;
}


/// 保证显示宽度不超过 cols: 太宽则从左侧截断并加 "…", 否则右侧补空格
pub fn fitRight(a: std.mem.Allocator, text: []const u8, cols: usize) ![]const u8 {
    const w = visualWidth(text);
    if (w <= cols) return padRight(a, text, cols);
    var start = text.len - (cols - 1);
    while (start < text.len and (text[start] & 0xC0) == 0x80) start += 1; // 不切坏 UTF-8
    return std.fmt.allocPrint(a, "…{s}", .{text[start..]});
}

// ---------------- 框 ----------------

pub fn boxTop(a: std.mem.Allocator, title: []const u8) ![]const u8 {
    const tw = visualWidth(title);
    const fill = if (width > tw + 5) width - tw - 5 else 0;
    return std.fmt.allocPrint(a, "╭─ {s} {s}╮", .{ title, try repeat(a, "─", fill) });
}

pub fn boxRow(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    const inner = width - 4;
    const padded = try padRight(a, text, inner);
    return std.fmt.allocPrint(a, "│ {s} │", .{padded});
}

pub fn boxBot(a: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(a, "╰{s}╯", .{try repeat(a, "─", width - 2)});
}

/// 进度条: ratio ∈ [0,1]
pub fn bar(a: std.mem.Allocator, ratio: f64, cols: usize) ![]const u8 {
    const filled: usize = @intFromFloat(@round(@min(@max(ratio, 0), 1) * @as(f64, @floatFromInt(cols))));
    return std.fmt.allocPrint(a, "{s}{s}", .{ try repeat(a, "█", filled), try repeat(a, "░", cols - filled) });
}

/// 人类可读的字节数
pub fn humanBytes(a: std.mem.Allocator, n: u64) ![]const u8 {
    if (n < 1024) return std.fmt.allocPrint(a, "{d} B", .{n});
    if (n < 1024 * 1024) return std.fmt.allocPrint(a, "{d:.1} K", .{@as(f64, @floatFromInt(n)) / 1024.0});
    return std.fmt.allocPrint(a, "{d:.1} M", .{@as(f64, @floatFromInt(n)) / (1024.0 * 1024.0)});
}

/// 便捷: 直接打印一行框内容
pub fn emit(a: std.mem.Allocator, text: []const u8) void {
    out("{s}\n", .{text});
    _ = a;
}
