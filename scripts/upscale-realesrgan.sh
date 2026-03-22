#!/bin/bash
# Upscale a live-action MKV using Real-ESRGAN (chunked to avoid disk exhaustion)
# Usage: ./upscale-realesrgan.sh "input.mkv" "output.mkv" [chunk_minutes] [output_res]

INPUT="$1"
OUTPUT="$2"
CHUNK_MIN="${3:-5}"
OUTPUT_RES="${4:-1920x1080}"   # upscale 2x (1440x960) then lanczos to 1080p
MODEL="realesrgan-x4plus"
SCALE=2
MODEL_PATH="/usr/local/share/realesrgan-models"
WORK_DIR="/tmp/realesrgan_work_$$"
SEGMENTS_DIR="/tmp/realesrgan_segments_$$"

if [[ -z "$INPUT" || -z "$OUTPUT" ]]; then
    echo "Usage: $0 <input.mkv> <output.mkv> [chunk_minutes=5] [output_res=1920x1080]"
    exit 1
fi

echo "=== Real-ESRGAN Video Upscaler (chunked) ==="
echo "Input:      $INPUT"
echo "Output:     $OUTPUT"
echo "Model:      $MODEL (4x, live-action)"
echo "Output res: $OUTPUT_RES"
echo "Chunk:      ${CHUNK_MIN} minutes"
echo ""

FPS_ROUNDED=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate \
    -of default=noprint_wrappers=1:nokey=1 "$INPUT" | bc -l | xargs printf "%.3f")
DURATION=$(ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$INPUT" | cut -d. -f1)
CHUNK_SEC=$((CHUNK_MIN * 60))
TOTAL_CHUNKS=$(( (DURATION + CHUNK_SEC - 1) / CHUNK_SEC ))

echo "Duration: ${DURATION}s  FPS: $FPS_ROUNDED  Chunks: $TOTAL_CHUNKS"
echo ""

mkdir -p "$WORK_DIR/frames" "$WORK_DIR/upscaled" "$SEGMENTS_DIR"

cleanup() {
    rm -rf "$WORK_DIR"
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

    FRAMES_DIR="$WORK_DIR/frames_$CHUNK"
    UPSCALED_DIR="$WORK_DIR/upscaled_$CHUNK"
    mkdir -p "$FRAMES_DIR" "$UPSCALED_DIR"

    # Extract frames
    ffmpeg -y -ss "$START" -t "$CHUNK_SEC" -i "$INPUT" \
        -vf "fps=$FPS_ROUNDED" -vsync vfr -q:v 1 \
        "$FRAMES_DIR/frame_%08d.png" -an \
        2>&1 | grep -E "^frame=" | tail -1

    FRAME_COUNT=$(ls "$FRAMES_DIR" | wc -l)
    echo "  Frames: $FRAME_COUNT"

    if [ "$FRAME_COUNT" -eq 0 ]; then
        START=$END
        continue
    fi

    # Upscale with Real-ESRGAN (4x, live-action model)
    realesrgan-ncnn-vulkan \
        -i "$FRAMES_DIR" \
        -o "$UPSCALED_DIR" \
        -s "$SCALE" \
        -n "$MODEL" \
        -m "$MODEL_PATH" \
        -f png -g 0 -j 1:2:2 2>&1 | grep -v "^$" | tail -3

    # Encode chunk — scale down to target resolution for clean 1080p output
    ffmpeg -y \
        -framerate "$FPS_ROUNDED" \
        -i "$UPSCALED_DIR/frame_%08d.png" \
        -vf "scale=${OUTPUT_RES}:flags=lanczos" \
        -c:v libx265 -crf 18 -preset slow -pix_fmt yuv420p \
        "$SEGMENT" 2>&1 | grep -E "frame=.*fps=" | tail -1

    echo "file '$SEGMENT'" >> "$SEGMENT_LIST"
    echo "  Segment saved: $(basename $SEGMENT)"
    rm -rf "$FRAMES_DIR" "$UPSCALED_DIR"
    START=$END
done

echo ""
echo "[Final] Concatenating $TOTAL_CHUNKS segments + muxing all audio tracks/subtitles..."
ffmpeg -y \
    -f concat -safe 0 -i "$SEGMENT_LIST" \
    -i "$INPUT" \
    -map 0:v \
    -map 1:a \
    -map 1:s? \
    -c:v copy \
    -c:a copy \
    -c:s copy \
    -metadata title="$(basename "$INPUT" .mkv) [upscaled]" \
    "$OUTPUT" 2>&1 | grep -E "time=|frame=.*fps=" | tail -1

rm -rf "$SEGMENTS_DIR"

echo ""
echo "=== Done! ==="
ffprobe "$OUTPUT" 2>&1 | grep -E "Duration|Video:|Audio:"
ls -lh "$OUTPUT"
