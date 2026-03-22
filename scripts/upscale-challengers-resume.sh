#!/bin/bash
INPUT="/mnt/jellyfin-movies/Challengers (2024).mkv"
OUTPUT="/mnt/jellyfin-movies/Challengers (2024) [upscaled].mkv"
SCALE=2
NOISE=1
CHUNK_SEC=120   # 2 minutes per chunk (smaller = less lost on crash)
MODEL="models-upconv_7_photo"
WORK_DIR="/tmp/waifu2x_work_challengers_resume"
SEGMENTS_DIR="/tmp/waifu2x_segments_290781"
FPS_ROUNDED="29.970"
DURATION=7871
# Segments 1-34 are done. Resume from 5880s, numbering from segment 34
START_SEC=5880
CHUNK_NUM=34

echo "=== Resuming Challengers from ${START_SEC}s with 2-min chunks ==="
echo "Segments dir: $SEGMENTS_DIR"

mkdir -p "$WORK_DIR/frames" "$WORK_DIR/upscaled"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

START=$START_SEC

while [ "$START" -lt "$DURATION" ]; do
    CHUNK_NUM=$((CHUNK_NUM + 1))
    END=$((START + CHUNK_SEC))
    [ "$END" -gt "$DURATION" ] && END=$DURATION
    SEGMENT="$SEGMENTS_DIR/segment_$(printf '%04d' $CHUNK_NUM).mkv"
    ACTUAL_LEN=$((END - START))
    echo "[Chunk $CHUNK_NUM] ${START}s → ${END}s (${ACTUAL_LEN}s)"

    rm -rf "$WORK_DIR/frames" "$WORK_DIR/upscaled"
    mkdir -p "$WORK_DIR/frames" "$WORK_DIR/upscaled"

    ffmpeg -y -ss "$START" -t "$ACTUAL_LEN" -i "$INPUT" \
        -vf "scale=960:540:flags=lanczos,fps=$FPS_ROUNDED" -vsync vfr -q:v 1 \
        "$WORK_DIR/frames/frame_%08d.png" -an \
        2>&1 | grep -E "^frame=" | tail -1

    FRAME_COUNT=$(ls "$WORK_DIR/frames" | wc -l)
    echo "  Frames: $FRAME_COUNT"
    [ "$FRAME_COUNT" -eq 0 ] && START=$END && continue

    echo "  Upscaling..."
    waifu2x-ncnn-vulkan \
        -i "$WORK_DIR/frames" -o "$WORK_DIR/upscaled" \
        -s "$SCALE" -n "$NOISE" \
        -m "/usr/local/share/$MODEL" \
        -f png -g 0 -j 1:2:2
    WAIFU_EXIT=$?
    echo "  waifu2x exit code: $WAIFU_EXIT"
    [ "$WAIFU_EXIT" -ne 0 ] && echo "  ERROR: waifu2x failed on chunk $CHUNK_NUM" && exit 1

    UPSCALED_COUNT=$(ls "$WORK_DIR/upscaled" | wc -l)
    echo "  Upscaled frames: $UPSCALED_COUNT"

    ffmpeg -y -framerate "$FPS_ROUNDED" \
        -i "$WORK_DIR/upscaled/frame_%08d.png" \
        -c:v libx265 -crf 18 -preset slow -pix_fmt yuv420p \
        "$SEGMENT" 2>&1 | grep -E "frame=.*fps=" | tail -1

    echo "file '$SEGMENT'" >> "$SEGMENTS_DIR/segments.txt"
    echo "  Segment saved: $(basename $SEGMENT)"

    # Brief pause between chunks to let GPU breathe
    sleep 5
    START=$END
done

echo ""
echo "[Final] Concatenating all segments + muxing audio..."
ffmpeg -y -f concat -safe 0 -i "$SEGMENTS_DIR/segments.txt" \
    -i "$INPUT" \
    -map 0:v -map 1:a -map 1:s? \
    -c:v copy -c:a copy -c:s copy \
    -metadata title="Challengers (2024) [waifu2x 2x]" \
    "$OUTPUT" 2>&1 | grep -E "time=|frame=.*fps=" | tail -1

rm -rf "$SEGMENTS_DIR"
echo "=== Done! ==="
ffprobe "$OUTPUT" 2>&1 | grep -E "Duration|Video:|Audio:"
ls -lh "$OUTPUT"
