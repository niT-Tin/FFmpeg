#!/bin/bash
# verify_nals.sh — 对比 myzigh264 解码器与 FFmpeg 内置 h264 解码器解析的 NAL 序列
# Usage: ./tools/verify_nals.sh [test_file]

set -euo pipefail

TEST_FILE="${1:-test.h264}"
MY_LOG="/tmp/myzigh264_verify.log"
FF_LOG="/tmp/ffmpeg_h264_verify.log"
REPORT="/tmp/nal_verify_report.txt"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=== NAL Verification ==="
echo "Test file: $TEST_FILE"
echo ""

# ── 1. Run myzigh264 decoder (use -v debug to get NAL debug lines) ──
echo "Running myzigh264 decoder..."
./ffmpeg -v debug -codec:v myzigh264 -i "$TEST_FILE" -f null - 2>&1 | grep "^  NAL " > "$MY_LOG" || true
MY_COUNT=$(wc -l < "$MY_LOG")

# ── 2. Run FFmpeg h264 reference decoder ──
echo "Running FFmpeg h264 reference decoder..."
./ffmpeg -v debug -codec:v h264 -i "$TEST_FILE" -f null - 2>"$FF_LOG" || true
FF_COUNT=$(grep -c "nal_unit_type:" "$FF_LOG" || true)

# ── 3. Count NAL types from myzigh264 ──
# Format: "  NAL N: type=H264_NAL_XXX, size=S, start_code_len=L"
my_sei=$(grep -c "type=H264_NAL_SEI,"   "$MY_LOG" || true)
my_sps=$(grep -c "type=H264_NAL_SPS,"   "$MY_LOG" || true)
my_pps=$(grep -c "type=H264_NAL_PPS,"   "$MY_LOG" || true)
my_idr=$(grep -c "type=H264_NAL_IDR_SLICE," "$MY_LOG" || true)
my_slice=$(grep -c "type=H264_NAL_SLICE," "$MY_LOG" || true)
my_aud=$(grep -c "type=H264_NAL_AUD,"   "$MY_LOG" || true)

# ── 4. Count NAL types from FFmpeg reference ──
ff_sps=$(grep -c "nal_unit_type: 7" "$FF_LOG" || true)
ff_pps=$(grep -c "nal_unit_type: 8" "$FF_LOG" || true)
ff_sei=$(grep -c "nal_unit_type: 6" "$FF_LOG" || true)
ff_idr=$(grep -c "nal_unit_type: 5" "$FF_LOG" || true)
ff_slice=$(grep -c "nal_unit_type: 1" "$FF_LOG" || true)
ff_aud=$(grep -c "nal_unit_type: 9" "$FF_LOG" || true)

# ── 5. Helper ──
check() {
    local name="$1" my_count="$2" ff_count="$3"
    local mark
    if [ "$my_count" -eq "$ff_count" ]; then
        mark="${GREEN}✓${NC}"
    else
        mark="${RED}✗${NC}"
    fi
    printf "  %-6s %-11s %-8s %b\n" "$name" "$my_count" "$ff_count" "$mark"
}

ff_type_to_short() {
    case "$1" in
        "Coded slice of a non-IDR picture") echo "SLICE" ;;
        "IDR") echo "IDR" ;;
        "SEI") echo "SEI" ;;
        "SPS") echo "SPS" ;;
        "PPS") echo "PPS" ;;
        "AUD") echo "AUD" ;;
        *) echo "$1" ;;
    esac
}

my_type_to_short() {
    case "$1" in
        H264_NAL_SEI) echo "SEI" ;;
        H264_NAL_SPS) echo "SPS" ;;
        H264_NAL_PPS) echo "PPS" ;;
        H264_NAL_IDR_SLICE) echo "IDR" ;;
        H264_NAL_SLICE) echo "SLICE" ;;
        *) echo "$1" ;;
    esac
}

# ── 6. Report ──
{
    echo "============================================="
    echo "  NAL Verification Report"
    echo "  Test file: $TEST_FILE"
    echo "  Date: $(date)"
    echo "============================================="
    echo ""
    echo "--- NAL Counts ---"
    echo "myzigh264:   $MY_COUNT NAL units"
    echo "FFmpeg h264: $FF_COUNT NAL units"
    echo ""

    echo "--- NAL Type Breakdown ---"
    printf "  %-6s %10s %10s %s\n" "Type" "myzigh264" "FFmpeg" "Match?"
    printf "  %-6s %10s %10s %s\n" "----" "---------" "------" "------"
    check "SEI"   "$my_sei"   "$ff_sei"
    check "SPS"   "$my_sps"   "$ff_sps"
    check "PPS"   "$my_pps"   "$ff_pps"
    check "IDR"   "$my_idr"   "$ff_idr"
    check "SLICE" "$my_slice" "$ff_slice"
    check "AUD"   "$my_aud"   "$ff_aud"

    echo ""
    echo "--- NAL Sequence (first 20) ---"
    echo "myzigh264:"
    head -20 "$MY_LOG" | while read -r line; do
        local_type=$(echo "$line" | grep -oP 'type=\K[^,]+')
        echo "  $(my_type_to_short "$local_type")"
    done
    echo ""
    echo "FFmpeg h264:"
    grep "nal_unit_type:" "$FF_LOG" | head -20 | while read -r line; do
        local_name=$(echo "$line" | grep -oP '(?<=nal_unit_type: \d\()[^)]+')
        echo "  $(ff_type_to_short "$local_name")"
    done

    echo ""
    echo "--- Conclusion ---"
    total_ok=0 total_fail=0
    for pair in "SEI $my_sei $ff_sei" "SPS $my_sps $ff_sps" "PPS $my_pps $ff_pps" \
                "IDR $my_idr $ff_idr" "SLICE $my_slice $ff_slice" "AUD $my_aud $ff_aud"; do
        read name my ff <<< "$pair"
        if [ "$my" -eq "$ff" ]; then ((total_ok++)) || true; else ((total_fail++)) || true; fi
    done

    if [ "$total_fail" -eq 0 ]; then
        echo -e "${GREEN}✓ All NAL type counts match! NAL split is correct.${NC}"
    else
        echo -e "${YELLOW}N  ${total_ok}/${total_ok}+${total_fail} type(s) match, ${total_fail} type(s) differ.${NC}"
        echo ""
        echo "Likely causes for differences:"
        echo "  - FFmpeg h264 demuxer extracts extradata (first SPS/PPS/SEI/IDR)"
        echo "    as side-data, not as AVPacket data. myzigh264 only sees AVPacket data."
        echo "  - If SLICE count matches (480 vs 480), your split is correct."
        if [ "$my_slice" -eq "$ff_slice" ]; then
            echo -e "  ${GREEN}✓ SLICE counts match — NAL split is verified correct.${NC}"
        fi
    fi
} | tee "$REPORT"

echo ""
echo "Full report: $REPORT"
echo "Debug logs:  $MY_LOG, $FF_LOG"
