#!/bin/bash
# Upscale live-action widescreen (16:9) MKV to 4K (3840x2160) using EGVSR (PyTorch/ROCm)
# Single pass: pre-scales to 960x540 so 4x output lands exactly at 3840x2160
# EGVSR runs as a single Python process across all chunks — model loads once,
# hr_prev/lr_prev state carries across chunk boundaries (no warmup artifacts).
# Encoding: hevc_vaapi (AMD GPU hardware encoder, VCN) — frees CPU from libx265
# Usage: ./upscale-live-16x9-4k.sh "input.mkv" "output.mkv" [chunk_minutes=10] [denoise=none|spatial|full]
# denoise defaults by year parsed from filename: pre-2000 → none (preserve grain), 2000+ → spatial

INPUT="$1"
OUTPUT="$2"
CHUNK_MIN="${3:-10}"
DENOISE="${4:-}"

# Year-based denoise default if not explicitly set
if [[ -z "$DENOISE" ]]; then
    YEAR=$(basename "$INPUT" .mkv | grep -oE '\([0-9]{4}\)' | tr -d '()' | tail -1)
    if [[ -n "$YEAR" && "$YEAR" -lt 2000 ]]; then
        DENOISE="none"
    else
        DENOISE="spatial"
    fi
fi

QUARTER_W=960
QUARTER_H=540
SCALE=4
OUT_W=$((QUARTER_W * SCALE))
OUT_H=$((QUARTER_H * SCALE))
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
SEGMENTS_DIR="/tmp/upscale_segments_$$"

if [[ -z "$INPUT" || -z "$OUTPUT" ]]; then
    echo "Usage: $0 <input.mkv> <output.mkv> [chunk_minutes=10]"
    exit 1
fi

ts() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

echo "=== Live-Action 16:9 4K Upscaler: source → 3840x2160 ==="
echo "Input:    $INPUT"
echo "Output:   $OUTPUT"
echo "Model:    EGVSR (4x, live-action, PyTorch/ROCm)"
echo "Pipeline: ${QUARTER_W}x${QUARTER_H} → 4x → $((QUARTER_W * SCALE))x$((QUARTER_H * SCALE))"
echo "Chunk:    ${CHUNK_MIN} minutes"
echo "Denoise:  $DENOISE"
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

ts "[Processing] Launching EGVSR pipeline (single process, state persists across chunks)..."
HSA_OVERRIDE_GFX_VERSION=10.3.0 PYTORCH_HIP_ALLOC_CONF=expandable_segments:True python3 "$SCRIPT_DIR/egvsr-upscale.py" \
    --input "$INPUT" \
    --segments-dir "$SEGMENTS_DIR" \
    --in-width "$QUARTER_W" \
    --in-height "$QUARTER_H" \
    --out-width "$OUT_W" \
    --out-height "$OUT_H" \
    --duration "$DURATION" \
    --chunk-sec "$CHUNK_SEC" \
    --denoise "$DENOISE"
PYTHON_EXIT=$?

if [ "$PYTHON_EXIT" -ne 0 ]; then
    ts "  ERROR: EGVSR pipeline failed (exit $PYTHON_EXIT) — segments preserved in $SEGMENTS_DIR"
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
    -metadata title="$(basename "$INPUT" .mkv) [live 16:9 upscaled 4K]" \
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
