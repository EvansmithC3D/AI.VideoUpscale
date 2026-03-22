#!/bin/bash
# Resume upscale from chunk 9 (2400s), reusing existing segments
INPUT="/mnt/jellyfin-movies/Pokemon The First Movie (1998).mkv"
OUTPUT="/mnt/jellyfin-movies/Pokemon The First Movie (1998) [upscaled].mkv"
SCALE=2
NOISE=1
CHUNK_MIN=5
MODEL="models-cunet"
WORK_DIR="/tmp/waifu2x_work_resume"
SEGMENTS_DIR="/tmp/waifu2x_segments_95285"   # existing segments
START_CHUNK=9
START_SEC=2400
CHUNK_SEC=$((CHUNK_MIN * 60))

FPS_ROUNDED="29.970"
DURATION=4469
TOTAL_CHUNKS=15

echo "=== Resuming from chunk $START_CHUNK/$TOTAL_CHUNKS (${START_SEC}s) ==="

mkdir -p "$WORK_DIR/frames" "$WORK_DIR/upscaled"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

CHUNK=$((START_CHUNK - 1))
START=$START_SEC

while [ "$START" -lt "$DURATION" ]; do
    CHUNK=$((CHUNK + 1))
    END=$((START + CHUNK_SEC))
    [ "$END" -gt "$DURATION" ] && END=$DURATION
    SEGMENT="$SEGMENTS_DIR/segment_$(printf '%04d' $CHUNK).mkv"

    echo "[Chunk $CHUNK/$TOTAL_CHUNKS] ${START}s → ${END}s"

    rm -rf "$WORK_DIR/frames" "$WORK_DIR/upscaled"
    mkdir -p "$WORK_DIR/frames" "$WORK_DIR/upscaled"

    ffmpeg -y -ss "$START" -t "$CHUNK_SEC" -i "$INPUT" \
        -vf "fps=$FPS_ROUNDED" -vsync vfr -q:v 1 \
        "$WORK_DIR/frames/frame_%08d.png" -an \
        2>&1 | grep -E "^frame=" | tail -1

    FRAME_COUNT=$(ls "$WORK_DIR/frames" | wc -l)
    echo "  Frames: $FRAME_COUNT"

    if [ "$FRAME_COUNT" -eq 0 ]; then
        START=$END
        continue
    fi

    waifu2x-ncnn-vulkan \
        -i "$WORK_DIR/frames" \
        -o "$WORK_DIR/upscaled" \
        -s "$SCALE" -n "$NOISE" \
        -m "/usr/local/share/$MODEL" \
        -f png -g 0 -j 1:2:2 2>&1 | grep -v "^$" | tail -3

    ffmpeg -y \
        -framerate "$FPS_ROUNDED" \
        -i "$WORK_DIR/upscaled/frame_%08d.png" \
        -c:v libx265 -crf 18 -preset slow -pix_fmt yuv420p \
        "$SEGMENT" 2>&1 | grep -E "frame=.*fps=" | tail -1

    echo "file '$SEGMENT'" >> "$SEGMENTS_DIR/segments.txt"
    echo "  Segment saved: $(basename $SEGMENT)"
    START=$END
done

echo ""
echo "[Final] Concatenating all 15 segments + muxing audio/subtitles..."
ffmpeg -y \
    -f concat -safe 0 -i "$SEGMENTS_DIR/segments.txt" \
    -i "$INPUT" \
    -map 0:v -map 1:a -map 1:s? \
    -c:v copy -c:a copy -c:s copy \
    -metadata title="Pokemon The First Movie (1998) [waifu2x 2x]" \
    "$OUTPUT" 2>&1 | grep -E "time=|frame=.*fps=" | tail -1

echo ""
echo "=== Done! ==="
ffprobe "$OUTPUT" 2>&1 | grep -E "Duration|Video:|Audio:"
ls -lh "$OUTPUT"
