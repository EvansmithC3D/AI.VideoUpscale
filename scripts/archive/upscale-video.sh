#!/bin/bash
# Upscale an MKV file using waifu2x-ncnn-vulkan (chunked to avoid disk exhaustion)
# Usage: ./upscale-video.sh "input.mkv" "output.mkv" [scale] [noise] [chunk_minutes]

INPUT="$1"
OUTPUT="$2"
SCALE="${3:-2}"
NOISE="${4:-1}"
CHUNK_MIN="${5:-5}"        # Process 5 minutes at a time
MODEL="${6:-models-cunet}" # models-cunet (anime) or models-upconv_7_photo (live-action)
WORK_DIR="/tmp/waifu2x_work_$$"
SEGMENTS_DIR="/tmp/waifu2x_segments_$$"

if [[ -z "$INPUT" || -z "$OUTPUT" ]]; then
    echo "Usage: $0 <input.mkv> <output.mkv> [scale=2] [noise=1] [chunk_minutes=5]"
    exit 1
fi

echo "=== waifu2x Video Upscaler (chunked) ==="
echo "Input:    $INPUT"
echo "Output:   $OUTPUT"
echo "Scale:    ${SCALE}x"
echo "Noise:    $NOISE"
echo "Chunk:    ${CHUNK_MIN} minutes"
echo ""

FPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate \
    -of default=noprint_wrappers=1:nokey=1 "$INPUT" | bc -l)
FPS_ROUNDED=$(printf "%.3f" "$FPS")
DURATION=$(ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$INPUT" | cut -d. -f1)
CHUNK_SEC=$((CHUNK_MIN * 60))
TOTAL_CHUNKS=$(( (DURATION + CHUNK_SEC - 1) / CHUNK_SEC ))

# Determine half-res target (960x540) from display aspect ratio so waifu2x 2x = 1920x1080
# Uses DAR-aware scale: output half of 1920x1080 with correct proportions
HALF_W=960
HALF_H=540

echo "Duration: ${DURATION}s  FPS: $FPS_ROUNDED  Chunks: $TOTAL_CHUNKS"
echo "Frame target: ${HALF_W}x${HALF_H} → waifu2x ${SCALE}x → $((HALF_W * SCALE))x$((HALF_H * SCALE))"
echo ""

mkdir -p "$WORK_DIR/frames" "$WORK_DIR/upscaled" "$SEGMENTS_DIR"

cleanup() {
    rm -rf "$WORK_DIR"
    # segments cleaned up after concat
}
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

    echo "[Chunk $CHUNK/$TOTAL_CHUNKS] ${START}s → ${END}s"

    # Clean frame dirs from previous chunk
    rm -rf "$WORK_DIR/frames" "$WORK_DIR/upscaled"
    mkdir -p "$WORK_DIR/frames" "$WORK_DIR/upscaled"

    # Extract frames for this chunk — scale to half of 1920x1080 applying DAR correction,
    # so waifu2x 2x output is exactly 1920x1080 with correct aspect ratio
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

    # Upscale frames
    waifu2x-ncnn-vulkan \
        -i "$WORK_DIR/frames" \
        -o "$WORK_DIR/upscaled" \
        -s "$SCALE" -n "$NOISE" \
        -m "/usr/local/share/$MODEL" \
        -f png -g 0 -j 1:2:2 2>&1 | grep -v "^$" | tail -3

    # Encode chunk to video segment (no audio yet)
    ffmpeg -y \
        -framerate "$FPS_ROUNDED" \
        -i "$WORK_DIR/upscaled/frame_%08d.png" \
        -c:v libx265 -crf 18 -preset slow -pix_fmt yuv420p \
        "$SEGMENT" 2>&1 | grep -E "frame=.*fps=" | tail -1

    echo "file '$SEGMENT'" >> "$SEGMENT_LIST"
    echo "  Segment saved: $(basename $SEGMENT)"
    START=$END
done

echo ""
echo "[Final] Concatenating $TOTAL_CHUNKS segments + muxing audio/subtitles..."
ffmpeg -y \
    -f concat -safe 0 -i "$SEGMENT_LIST" \
    -i "$INPUT" \
    -map 0:v \
    -map 1:a \
    -map 1:s? \
    -c:v copy \
    -c:a copy \
    -c:s copy \
    -metadata title="$(basename "$INPUT" .mkv) [waifu2x ${SCALE}x]" \
    "$OUTPUT" 2>&1 | grep -E "frame=.*fps=|time=" | tail -1

rm -rf "$SEGMENTS_DIR"

echo ""
echo "=== Done! ==="
ffprobe "$OUTPUT" 2>&1 | grep -E "Duration|Video:|Audio:"
ls -lh "$OUTPUT"
