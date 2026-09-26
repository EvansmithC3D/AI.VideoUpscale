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
. "$SCRIPT_DIR/lib/vfr-timing.sh"
# Stable per input: rerunning the same job resumes after the last finished chunk.
SEGMENTS_DIR=$(vfr_segments_dir "$INPUT")
WORK_DIR="/tmp/upscale_work_$$"

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

FINGERPRINT="$(basename "$0")|$(stat -c '%s %Y' "$INPUT")|$CHUNK_SEC|$DENOISE|${OUT_W}x${OUT_H}"
DONE_CHUNKS=$(vfr_resume_init "$SEGMENTS_DIR" "$FINGERPRINT")
[ "$DONE_CHUNKS" -gt 0 ] && echo "Resuming: $DONE_CHUNKS chunk(s) already done in $SEGMENTS_DIR"
SEGMENT_LIST="$SEGMENTS_DIR/segments.txt"
mkdir -p "$WORK_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT

ts "[Processing] Launching EGVSR pipeline (single process, state persists across chunks)..."
HSA_OVERRIDE_GFX_VERSION=10.3.0 python3 "$SCRIPT_DIR/egvsr-upscale.py" \
    --input "$INPUT" \
    --segments-dir "$SEGMENTS_DIR" \
    --in-width "$QUARTER_W" \
    --in-height "$QUARTER_H" \
    --out-width "$OUT_W" \
    --out-height "$OUT_H" \
    --duration "$DURATION" \
    --chunk-sec "$CHUNK_SEC" \
    --denoise "$DENOISE" \
    --resume-from "$DONE_CHUNKS"
PYTHON_EXIT=$?

if [ "$PYTHON_EXIT" -ne 0 ]; then
    ts "  ERROR: EGVSR pipeline failed (exit $PYTHON_EXIT) — segments preserved in $SEGMENTS_DIR"
    exit 1
fi

echo ""
FINAL_TMP="/tmp/upscale_final_$$.mkv"
ts "[Final] Joining $(wc -l < "$SEGMENT_LIST") segments + stamping per-frame timestamps..."
if ! vfr_build_video "$SEGMENTS_DIR" "$(vfr_src_start "$INPUT")" "$WORK_DIR/video.hevc" "$WORK_DIR/timestamps.txt"; then
    echo "=== ERROR: joining segments failed — segments preserved in $SEGMENTS_DIR ==="
    exit 1
fi
ts "[Final] Muxing video + source audio/subtitles/chapters with mkvmerge..."
if ! vfr_mux "$WORK_DIR/video.hevc" "$WORK_DIR/timestamps.txt" "$INPUT" \
        "$(basename "$INPUT" .mkv) [live 16:9 upscaled 4K]" "$FINAL_TMP"; then
    rm -f "$FINAL_TMP"
    echo "=== ERROR: mkvmerge failed — segments preserved in $SEGMENTS_DIR ==="
    exit 1
fi
ts "[Final] Copying to destination..."
vfr_install "$FINAL_TMP" "$OUTPUT" || exit 1
rm -rf "$SEGMENTS_DIR"

echo ""
ts "=== Done! ==="
ffprobe "$OUTPUT" 2>&1 | grep -E "Duration|Video:|Audio:"
ls -lh "$OUTPUT"
