#!/usr/bin/env bash
# gen_vectors.sh —— 从真实视频抽取 myzigh264 能验证的 Annex-B 码流样本
#
#   直接跑:            tools/gen_vectors.sh [输入视频]
#   通过 build 系统跑:  zig build vectors
#
# 输出: <仓库>/tests/vectors/*.h264 (文件名与 src/decode_file.zig 里的清单一一对应)
# 说明: 输入视频默认取 ~/Videos 下第一个 mp4; 必须是 H.264, 否则先重编码
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/tests/vectors
mkdir -p "$OUT"

pick_input() {
    if [ $# -ge 1 ] && [ -n "${1:-}" ]; then echo "$1"; return; fi
    if [ -n "${H264_SRC:-}" ]; then echo "$H264_SRC"; return; fi
    local f
    f=$(find "$HOME/Videos" -maxdepth 1 -type f \( -name '*.mp4' -o -name '*.mkv' -o -name '*.mov' -o -name '*.ts' \) 2>/dev/null | sort | head -1)
    [ -n "$f" ] || { echo "!! ~/Videos 下没找到视频, 用法: $0 <输入视频>" >&2; exit 1; }
    echo "$f"
}

IN=$(pick_input "${1:-}")
[ -f "$IN" ] || { echo "!! 输入不存在: $IN" >&2; exit 1; }

echo "== 输入: $IN"
PROBE=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name,profile,width,height,pix_fmt -of default=nw=1 "$IN")
echo "$PROBE" | sed 's/^/   /'
case "$PROBE" in
    *codec_name=h264*) ;;
    *) echo "!! 不是 H.264, 请先用 -c:v libx264 重编码" >&2; exit 1 ;;
esac

ENC=(-c:v libx264 -pix_fmt yuv420p -profile:v high -an)
BASE="cabac=1:8x8dct=0:bframes=0:keyint=1:ref=1:scenecut=0"
SMALL=(-vf scale=640:-2)

q() { ffmpeg -hide_banner -loglevel error "$@"; }

# 00 真实原码流(不重编码): High profile 通常开 8x8 变换 -> 当前命中 guard
q -ss 0 -t 1 -i "$IN" -c:v copy -bsf:v h264_mp4toannexb -f h264 "$OUT/00_copy_original.h264" -y

# 01 全 I + 恒定 QP: 最干净的通路
q -ss 0 -t 4 -i "$IN" "${SMALL[@]}" "${ENC[@]}" -frames:v 3 \
    -x264-params "$BASE:aq-mode=0:trellis=0:weightp=0" -f h264 "$OUT/01_i_cqp.h264" -y

# 02 全 I + AQ: 逼出非零 mb_qp_delta (ctx 61/62/63)
q -ss 0 -t 4 -i "$IN" "${SMALL[@]}" "${ENC[@]}" -frames:v 3 \
    -x264-params "$BASE:aq-mode=2:trellis=0:weightp=0" -f h264 "$OUT/02_i_aq.h264" -y

# 03 全 I + 每帧 4 条带: 覆盖多 slice 边界判据
q -ss 0 -t 4 -i "$IN" "${SMALL[@]}" "${ENC[@]}" -frames:v 3 \
    -x264-params "$BASE:aq-mode=0:slices=4" -f h264 "$OUT/03_i_slices4.h264" -y

# 04 正常 GOP (IDR+P): 验证 P slice 被正确跳过, 以后做参考帧用
q -ss 0 -t 2 -i "$IN" "${SMALL[@]}" "${ENC[@]}" -g 15 \
    -x264-params "cabac=1:8x8dct=0:bframes=0:ref=1:scenecut=0" -f h264 "$OUT/04_gop15.h264" -y

# 05 8x8 变换: 下一个功能的目标流
q -ss 0 -t 4 -i "$IN" "${SMALL[@]}" "${ENC[@]}" -frames:v 3 \
    -x264-params "cabac=1:8x8dct=1:bframes=0:keyint=1:ref=1" -f h264 "$OUT/05_dct8x8.h264" -y

# 06 1080p 原分辨率 + AQ: 最接近"真实视频"的验证
q -ss 0 -t 1 -i "$IN" "${ENC[@]}" -frames:v 2 \
    -x264-params "$BASE:aq-mode=2:trellis=0:weightp=0" -f h264 "$OUT/06_fullres_1080p_aq.h264" -y

echo
echo "== 生成到 $OUT"
total=0
for f in "$OUT"/*.h264; do
    sz=$(stat -c %s "$f"); total=$((total + sz))
    printf '   %-32s %8s\n' "$(basename "$f")" "$(numfmt --to=iec "$sz" 2>/dev/null || echo "${sz}B")"
done
printf '   %-32s %8s\n' "合计" "$(numfmt --to=iec "$total" 2>/dev/null || echo "${total}B")"
echo
echo "== 验证: zig build check   (或 ./zig-out/bin/h264-check --suite tests/vectors)"
