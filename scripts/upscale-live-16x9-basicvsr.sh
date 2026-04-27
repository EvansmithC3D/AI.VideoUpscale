#!/bin/bash
# Upscale live-action widescreen (16:9) MKV to 1080p using BasicVSR (PyTorch/ROCm)
# Bidirectional temporal SR: suppresses per-frame detail flicker that single-image
# RealESRGAN x2plus produces. BasicVSR is a 4x model.
#
# Two input-resolution modes (measured on RX 6700 XT, 12 GB):
#   270p (default): extract at 480x270, model runs 270→1080 direct (4x)
#                   ~3.3 fps warm, ~2.2 GB VRAM at sub_seq=30 → ~14.5 hr/2hr film
#                   Matches BasicVSR's training distribution (REDS4 LR is 4x-downsampled)
#   540p (opt-in):  extract at 960x540, model runs 540→2160 and downscales to 1080 in ffmpeg
#                   ~1.0 fps warm, ~9 GB VRAM at sub_seq=10 → ~50 hr/2hr film
#                   Preserves more source detail but drifts from training distribution
# Encoding: hevc_vaapi (AMD GPU hardware encoder, VCN).
# Usage: ./upscale-live-16x9-basicvsr.sh "input.mkv" "output.mkv" [chunk_minutes=5] [denoise=none|spatial|full] [in_res=270p|540p] [sub_seq_len=auto]

INPUT="$1"
OUTPUT="$2"
CHUNK_MIN="${3:-5}"
DENOISE="${4:-}"
IN_RES="${5:-270p}"
SUB_SEQ_LEN="${6:-}"

case "$IN_RES" in
    270p) IN_W=480; IN_H=270; DEFAULT_SUB_SEQ=30 ;;
    540p) IN_W=960; IN_H=540; DEFAULT_SUB_SEQ=10 ;;
    *)    echo "ERROR: in_res must be '270p' or '540p' (got '$IN_RES')" >&2; exit 1 ;;
esac
[[ -z "$SUB_SEQ_LEN" ]] && SUB_SEQ_LEN="$DEFAULT_SUB_SEQ"

# Year-based denoise default if not explicitly set (matches EGVSR heuristic)
if [[ -z "$DENOISE" ]]; then
    YEAR=$(basename "$INPUT" .mkv | grep -oE '\([0-9]{4}\)' | tr -d '()' | tail -1)
    if [[ -n "$YEAR" && "$YEAR" -lt 2000 ]]; then
        DENOISE="none"
    else
        DENOISE="spatial"
    fi
fi

OUT_W=1920
OUT_H=1080
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
SEGMENTS_DIR="/tmp/upscale_segments_$$"

if [[ -z "$INPUT" || -z "$OUTPUT" ]]; then
    echo "Usage: $0 <input.mkv> <output.mkv> [chunk_minutes=5] [denoise=none|spatial|full] [in_res=270p|540p] [sub_seq_len=auto]"
    exit 1
fi

ts() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

echo "=== Live-Action 16:9 BasicVSR Upscaler: ${IN_RES} → 1920x1080 ==="
echo "Input:       $INPUT"
echo "Output:      $OUTPUT"
echo "Model:       BasicVSR (4x, bidirectional, PyTorch/ROCm) — REDS4 weights"
if [ "$((IN_W * 4))" -eq "$OUT_W" ] && [ "$((IN_H * 4))" -eq "$OUT_H" ]; then
    echo "Pipeline:    ${IN_W}x${IN_H} → 4x → ${OUT_W}x${OUT_H} (direct, no downscale)"
else
    echo "Pipeline:    ${IN_W}x${IN_H} → 4x → $((IN_W * 4))x$((IN_H * 4)) → downscale → ${OUT_W}x${OUT_H}"
fi
echo "Chunk:       ${CHUNK_MIN} minutes"
echo "Denoise:     $DENOISE"
echo "Sub-seq len: $SUB_SEQ_LEN frames"
echo ""

FPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate \
    -of default=noprint_wrappers=1:nokey=1 "$INPUT" | bc -l)
FPS_ROUNDED=$(printf "%.3f" "$FPS")
DURATION=$(ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$INPUT" | cut -d. -f1)
CHUNK_SEC=$((CHUNK_MIN * 60))
TOTAL_CHUNKS=$(( (DURATION + CHUNK_SEC - 1) / CHUNK_SEC ))

echo "Duration: ${DURATION}s  FPS: $FPS_ROUNDED  Chunks: $TOTAL_CHUNKS"
echo ""

mkdir -p "$SEGMENTS_DIR"
SEGMENT_LIST="$SEGMENTS_DIR/segments.txt"

ts "[Processing] Launching BasicVSR pipeline (single Python process)..."
HSA_OVERRIDE_GFX_VERSION=10.3.0 python3 "$SCRIPT_DIR/basicvsr-upscale.py" \
    --input "$INPUT" \
    --segments-dir "$SEGMENTS_DIR" \
    --in-width "$IN_W" \
    --in-height "$IN_H" \
    --out-width "$OUT_W" \
    --out-height "$OUT_H" \
    --duration "$DURATION" \
    --chunk-sec "$CHUNK_SEC" \
    --sub-seq-len "$SUB_SEQ_LEN" \
    --denoise "$DENOISE"
PYTHON_EXIT=$?

if [ "$PYTHON_EXIT" -ne 0 ]; then
    ts "  ERROR: BasicVSR pipeline failed (exit $PYTHON_EXIT) — segments preserved in $SEGMENTS_DIR"
    exit 1
fi

echo ""
MUXED_TMP="${OUTPUT%.mkv}.muxed.mkv"
ts "[Final] Concatenating $TOTAL_CHUNKS segments + muxing audio/subtitles..."
ffmpeg -y \
    -f concat -safe 0 -i "$SEGMENT_LIST" \
    -i "$INPUT" \
    -map 0:v \
    -map 1:a \
    -map 1:s? \
    -c:v copy \
    -c:a eac3 \
    -c:s copy \
    -metadata title="$(basename "$INPUT" .mkv) [live 16:9 basicvsr 1080p]" \
    "$MUXED_TMP" 2>&1 | grep -E "frame=.*fps=|time=" | tail -1

rm -rf "$SEGMENTS_DIR"

ts "[Final] Rebuilding seek index with mkvmerge..."
mkvmerge --cues 0:all --cues 1:all --cues 2:all --cues 3:all --cues 4:all \
  -o "$OUTPUT" "$MUXED_TMP" 2>&1 | grep -E "Progress: 100%|Warning|Error" | tail -2
rm -f "$MUXED_TMP"

echo ""
ts "=== Done! ==="
ffprobe "$OUTPUT" 2>&1 | grep -E "Duration|Video:|Audio:"
ls -lh "$OUTPUT"
