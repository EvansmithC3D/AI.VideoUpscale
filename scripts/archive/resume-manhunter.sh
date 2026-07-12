#!/bin/bash
# Resume Manhunter (1986) upscale from chunk 7
# Segments 1-6 already in /tmp/upscale_segments_37271/
# Resumes from START=1800s (chunk 7 of 25)

INPUT="/mnt/jellyfin-movies/Manhunter (1986).mkv"
OUTPUT="/mnt/jellyfin-movies/Manhunter (1986) [upscaled].mkv"
CHUNK_MIN=5
QUARTER_W=480
QUARTER_H=270
SCALE=4
MODEL="realesrgan-x4plus"
MODEL_PATH="/usr/local/share/realesrgan-models"
WORK_DIR="/tmp/upscale_work_$$"
SEGMENTS_DIR="/tmp/upscale_segments_37271"   # reuse existing segments 1-6

FPS_ROUNDED="29.970"
DURATION=7300
CHUNK_SEC=$((CHUNK_MIN * 60))
TOTAL_CHUNKS=$(( (DURATION + CHUNK_SEC - 1) / CHUNK_SEC ))   # 25

echo "=== Manhunter Resume: chunk 7/${TOTAL_CHUNKS} → ${TOTAL_CHUNKS} ==="
echo "Reusing segments dir: $SEGMENTS_DIR"
echo "Segments already done: $(ls $SEGMENTS_DIR/segment_*.mkv | wc -l)"
echo ""

mkdir -p "$WORK_DIR/frames" "$WORK_DIR/upscaled"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

SEGMENT_LIST="$SEGMENTS_DIR/segments.txt"

# Rebuild segments.txt from existing files (covers chunks 1-6)
> "$SEGMENT_LIST"
for seg in $(ls "$SEGMENTS_DIR"/segment_*.mkv | sort); do
    echo "file '$seg'" >> "$SEGMENT_LIST"
done
echo "Rebuilt segments.txt with $(wc -l < "$SEGMENT_LIST") existing entries"

CHUNK=6
START=1800   # chunk 7 starts at 1800s

while [ "$START" -lt "$DURATION" ]; do
    CHUNK=$((CHUNK + 1))
    END=$((START + CHUNK_SEC))
    [ "$END" -gt "$DURATION" ] && END=$DURATION
    SEGMENT="$SEGMENTS_DIR/segment_$(printf '%04d' $CHUNK).mkv"

    echo "[Chunk $CHUNK/$TOTAL_CHUNKS] ${START}s → ${END}s"

    rm -rf "$WORK_DIR/frames" "$WORK_DIR/upscaled"
    mkdir -p "$WORK_DIR/frames" "$WORK_DIR/upscaled"

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

    realesrgan-ncnn-vulkan \
        -i "$WORK_DIR/frames" \
        -o "$WORK_DIR/upscaled" \
        -n "$MODEL" \
        -m "$MODEL_PATH" \
        -s "$SCALE" \
        -t 800 \
        -g 0 -j 2:4:4 \
        -f png 2>&1 | grep -v "^$" | tail -3

    UPSCALED_COUNT=$(ls "$WORK_DIR/upscaled" | wc -l)
    echo "  Upscaled frames: $UPSCALED_COUNT"
    if [ "$UPSCALED_COUNT" -eq 0 ]; then
        echo "  ERROR: realesrgan produced no output frames — aborting"
        exit 1
    fi

    ffmpeg -y \
        -framerate "$FPS_ROUNDED" \
        -i "$WORK_DIR/upscaled/frame_%08d.png" \
        -c:v libx265 -crf 18 -preset slow -pix_fmt yuv420p \
        "$SEGMENT"
    ENCODE_EXIT=$?

    if [ $ENCODE_EXIT -ne 0 ] || [ ! -f "$SEGMENT" ]; then
        echo "  ERROR: Segment encoding failed (ffmpeg exit $ENCODE_EXIT)"
        exit 1
    fi

    echo "file '$SEGMENT'" >> "$SEGMENT_LIST"
    echo "  Segment saved: $(basename "$SEGMENT")"
    START=$END
done

echo ""
echo "[Final] Concatenating $TOTAL_CHUNKS segments + muxing audio/subtitles..."
ffmpeg -y \
    -f concat -safe 0 -i "$SEGMENT_LIST" \
    -i "$INPUT" \
    -map 0:v -map 1:a -map 1:s? \
    -c:v copy -c:a copy -c:s copy \
    -metadata title="Manhunter (1986) [upscaled 1080p]" \
    "$OUTPUT"
FFMPEG_EXIT=$?

if [ $FFMPEG_EXIT -ne 0 ] || [ ! -f "$OUTPUT" ]; then
    echo ""
    echo "=== ERROR: Final concat failed (exit $FFMPEG_EXIT) — segments preserved in $SEGMENTS_DIR ==="
    exit 1
fi

rm -rf "$SEGMENTS_DIR"
echo ""
echo "=== Done! ==="
ffprobe "$OUTPUT" 2>&1 | grep -E "Duration|Video:|Audio:"
ls -lh "$OUTPUT"
