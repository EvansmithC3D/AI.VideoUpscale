#!/bin/bash
# Upscale a live-action widescreen (16:9) MKV to 1080p using Real-ESRGAN x2plus (PyTorch/ROCm)
# Pre-scales to 960x540 so 2x output lands exactly at 1920x1080
# Usage: ./upscale-live-16x9.sh "input.mkv" "output.mkv" [chunk_minutes=5]

INPUT="$1"
OUTPUT="$2"
CHUNK_MIN="${3:-5}"

HALF_W=960
HALF_H=540
SCALE=2
MODEL="x2plus"
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
WORK_DIR="/tmp/upscale_work_$$"
SEGMENTS_DIR="/tmp/upscale_segments_$$"

if [[ -z "$INPUT" || -z "$OUTPUT" ]]; then
    echo "Usage: $0 <input.mkv> <output.mkv> [chunk_minutes=5]"
    exit 1
fi

ts() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

echo "=== Live-Action 16:9 Upscaler: 540p → 1080p ==="
echo "Input:    $INPUT"
echo "Output:   $OUTPUT"
echo "Model:    RealESRGAN-$MODEL (2x, live-action, PyTorch/ROCm)"
echo "Pipeline: ${HALF_W}x${HALF_H} → 2x → $((HALF_W * SCALE))x$((HALF_H * SCALE))"
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

mkdir -p "$WORK_DIR/frames" "$WORK_DIR/upscaled" "$SEGMENTS_DIR"

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

    rm -rf "$WORK_DIR/frames" "$WORK_DIR/upscaled"
    mkdir -p "$WORK_DIR/frames" "$WORK_DIR/upscaled"

    # Extract frames, scale to 960x540 (correct 16:9 display, handles anamorphic 720x480 DAR)
    ffmpeg -y -ss "$START" -t "$CHUNK_SEC" -i "$INPUT" \
        -vf "scale=${HALF_W}:${HALF_H}:flags=lanczos,fps=$FPS_ROUNDED" -vsync vfr -q:v 1 \
        "$WORK_DIR/frames/frame_%08d.png" -an \
        2>&1 | grep -E "^frame=" | tail -1

    FRAME_COUNT=$(ls "$WORK_DIR/frames" | wc -l)
    echo "  Frames: $FRAME_COUNT"

    if [ "$FRAME_COUNT" -eq 0 ]; then
        echo "  No frames extracted, skipping."
        START=$END
        continue
    fi

    HSA_OVERRIDE_GFX_VERSION=10.3.0 python3 "$SCRIPT_DIR/realesrgan-upscale.py" \
        --model "$MODEL" \
        --input "$WORK_DIR/frames" \
        --output "$WORK_DIR/upscaled"

    UPSCALED_COUNT=$(ls "$WORK_DIR/upscaled" | wc -l)
    echo "  Upscaled frames: $UPSCALED_COUNT"
    if [ "$UPSCALED_COUNT" -eq 0 ]; then
        echo "  ERROR: realesrgan produced no output frames — aborting"
        exit 1
    fi

    ffmpeg -y \
        -framerate "$FPS_ROUNDED" \
        -i "$WORK_DIR/upscaled/frame_%08d.png" \
        -c:v libx265 -crf 18 -preset medium -pix_fmt yuv420p \
        "$SEGMENT"
    ENCODE_EXIT=$?

    if [ $ENCODE_EXIT -ne 0 ] || [ ! -f "$SEGMENT" ]; then
        echo "  ERROR: Segment encoding failed (ffmpeg exit $ENCODE_EXIT)"
        echo "  First few upscaled frames:"
        ls "$WORK_DIR/upscaled" | head -5
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
    -c:a copy \
    -c:s copy \
    -metadata title="$(basename "$INPUT" .mkv) [upscaled 1080p]" \
    "$MUXED_TMP"
FFMPEG_EXIT=$?

if [ $FFMPEG_EXIT -ne 0 ] || [ ! -f "$MUXED_TMP" ]; then
    echo ""
    echo "=== ERROR: Final concat failed (exit $FFMPEG_EXIT) — segments preserved in $SEGMENTS_DIR ==="
    exit 1
fi

rm -rf "$SEGMENTS_DIR"

ts "[Final] Rebuilding seek index with mkvmerge..."
mkvmerge -o "$OUTPUT" "$MUXED_TMP" 2>&1 | grep -E "Progress: 100%|Warning|Error" | tail -2
rm -f "$MUXED_TMP"

echo ""
ts "=== Done! ==="
ffprobe "$OUTPUT" 2>&1 | grep -E "Duration|Video:|Audio:"
ls -lh "$OUTPUT"
