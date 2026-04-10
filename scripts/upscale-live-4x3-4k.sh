#!/bin/bash
# Upscale live-action fullscreen (4:3) MKV to 4K (2880x2160) using EGVSR (PyTorch/ROCm)
# Single pass: pre-scales to 720x540 so 4x output lands exactly at 2880x2160
# Note: 2880x2160 is correct 4:3 at 4K height — player handles pillarboxing
# EGVSR output is piped directly to ffmpeg — no intermediate 4K PNG writes
# Encoding: hevc_vaapi (AMD GPU hardware encoder, VCN) — frees CPU from libx265
# Usage: ./upscale-live-4x3-4k.sh "input.mkv" "output.mkv" [chunk_minutes=10]

INPUT="$1"
OUTPUT="$2"
CHUNK_MIN="${3:-10}"

QUARTER_W=720
QUARTER_H=540
SCALE=4
OUT_W=$((QUARTER_W * SCALE))
OUT_H=$((QUARTER_H * SCALE))
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
WORK_DIR="/tmp/upscale_work_$$"
SEGMENTS_DIR="/tmp/upscale_segments_$$"

if [[ -z "$INPUT" || -z "$OUTPUT" ]]; then
    echo "Usage: $0 <input.mkv> <output.mkv> [chunk_minutes=10]"
    exit 1
fi

ts() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

echo "=== Live-Action 4:3 4K Upscaler: source → 2880x2160 ==="
echo "Input:    $INPUT"
echo "Output:   $OUTPUT"
echo "Model:    EGVSR (4x, live-action, PyTorch/ROCm)"
echo "Pipeline: ${QUARTER_W}x${QUARTER_H} → 4x → $((QUARTER_W * SCALE))x$((QUARTER_H * SCALE))"
echo "Chunk:    ${CHUNK_MIN} minutes"
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

mkdir -p "$WORK_DIR/frames" "$SEGMENTS_DIR"

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

CHUNK=0
START=0
SEGMENT_LIST="$SEGMENTS_DIR/segments.txt"
> "$SEGMENT_LIST"

while [ "$START" -lt "$DURATION" ]; do
    CHUNK=$((CHUNK + 1))
    END=$((START + CHUNK_SEC))
    [ "$END" -gt "$DURATION" ] && END=$DURATION
    SEGMENT="$SEGMENTS_DIR/segment_$(printf '%04d' $CHUNK).mkv"

    CHUNK_START=$(date +%s)
    ts "[Chunk $CHUNK/$TOTAL_CHUNKS] ${START}s → ${END}s"

    rm -rf "$WORK_DIR/frames"
    mkdir -p "$WORK_DIR/frames"

    ffmpeg -y -ss "$START" -t "$CHUNK_SEC" -i "$INPUT" \
        -vf "scale=${QUARTER_W}:${QUARTER_H}:flags=lanczos,fps=$FPS_ROUNDED" -vsync vfr -q:v 1 \
        "$WORK_DIR/frames/frame_%08d.png" -an \
        2>&1 | grep -E "^frame=" | tail -1

    FRAME_COUNT=$(ls "$WORK_DIR/frames" | wc -l)
    echo "  Frames: $FRAME_COUNT"

    if [ "$FRAME_COUNT" -eq 0 ]; then
        echo "  No frames extracted, skipping."
        START=$END
        continue
    fi

    HSA_OVERRIDE_GFX_VERSION=10.3.0 python3 "$SCRIPT_DIR/egvsr-upscale.py" \
        --input "$WORK_DIR/frames" --warmup 30 | \
    ffmpeg -y \
        -vaapi_device /dev/dri/renderD128 \
        -f rawvideo -pixel_format bgr24 \
        -video_size "${OUT_W}x${OUT_H}" \
        -framerate "$FPS_ROUNDED" \
        -i pipe:0 \
        -vf "format=nv12,hwupload" \
        -c:v hevc_vaapi -qp 20 -g 48 \
        "$SEGMENT"
    PIPE_STATUS=("${PIPESTATUS[@]}")

    if [ "${PIPE_STATUS[0]}" -ne 0 ] || [ "${PIPE_STATUS[1]}" -ne 0 ] || [ ! -s "$SEGMENT" ]; then
        ts "  ERROR: pipe failed (python=${PIPE_STATUS[0]} ffmpeg=${PIPE_STATUS[1]}) — aborting"
        exit 1
    fi

    echo "file '$SEGMENT'" >> "$SEGMENT_LIST"
    CHUNK_ELAPSED=$(( $(date +%s) - CHUNK_START ))
    ts "  Chunk $CHUNK done in ${CHUNK_ELAPSED}s — segment saved: $(basename "$SEGMENT")"
    START=$END
done

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
    -metadata title="$(basename "$INPUT" .mkv) [live 4:3 upscaled 4K]" \
    "$MUXED_TMP" 2>&1 | grep -E "frame=.*fps=|time=" | tail -1

rm -rf "$SEGMENTS_DIR"

ts "[Final] Rebuilding seek index with mkvmerge..."
mkvmerge -o "$OUTPUT" "$MUXED_TMP" 2>&1 | grep -E "Progress: 100%|Warning|Error" | tail -2
rm -f "$MUXED_TMP"

echo ""
ts "=== Done! ==="
ffprobe "$OUTPUT" 2>&1 | grep -E "Duration|Video:|Audio:"
ls -lh "$OUTPUT"
