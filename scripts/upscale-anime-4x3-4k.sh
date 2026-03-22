#!/bin/bash
# Upscale animated fullscreen (4:3) MKV to 4K (2880x2160) via two-pass Real-ESRGAN animevideov3
# Pass 1: source → 720x540 → 2x → 1440x1080 (temp intermediate, video-only)
# Pass 2: 1440x1080 → 2x → 2880x2160 (final output, audio/subs muxed from source)
# Note: 2880x2160 is correct 4:3 at 4K height — player handles pillarboxing
# Usage: ./upscale-anime-4x3-4k.sh "input.mkv" "output.mkv" [chunk_minutes=2]

INPUT="$1"
OUTPUT="$2"
CHUNK_MIN="${3:-2}"

MODEL="realesr-animevideov3-x2"
MODEL_PATH="/usr/local/share/realesrgan-models"
INTERMEDIATE="/tmp/upscale_intermediate_$$.mkv"
WORK_DIR="/tmp/upscale_work_$$"
P1_SEGMENTS="/tmp/upscale_p1_segments_$$"
P2_SEGMENTS="/tmp/upscale_p2_segments_$$"

if [[ -z "$INPUT" || -z "$OUTPUT" ]]; then
    echo "Usage: $0 <input.mkv> <output.mkv> [chunk_minutes=2]"
    exit 1
fi

echo "=== Anime 4:3 4K Upscaler: source → 1440x1080 → 2880x2160 (two-pass) ==="
echo "Input:    $INPUT"
echo "Output:   $OUTPUT"
echo "Model:    $MODEL (2x × 2 passes)"
echo "Chunk:    ${CHUNK_MIN} minutes"
echo ""

FPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate \
    -of default=noprint_wrappers=1:nokey=1 "$INPUT" | bc -l)
FPS_ROUNDED=$(printf "%.3f" "$FPS")
DURATION=$(ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$INPUT" | cut -d. -f1)
CHUNK_SEC=$((CHUNK_MIN * 60))
TOTAL_CHUNKS=$(( (DURATION + CHUNK_SEC - 1) / CHUNK_SEC ))

echo "Duration: ${DURATION}s  FPS: $FPS_ROUNDED  Chunks per pass: $TOTAL_CHUNKS"
echo ""

cleanup_work() { rm -rf "$WORK_DIR"; }
trap cleanup_work EXIT

# ── Pass 1: source → 720x540 → 2x → 1440x1080 ──────────────────────────────

echo "=== Pass 1 of 2: source → 720x540 → 2x → 1440x1080 ==="
echo ""

mkdir -p "$WORK_DIR/frames" "$WORK_DIR/upscaled" "$P1_SEGMENTS"
P1_SEGMENT_LIST="$P1_SEGMENTS/segments.txt"
> "$P1_SEGMENT_LIST"

CHUNK=0
START=0
while [ "$START" -lt "$DURATION" ]; do
    CHUNK=$((CHUNK + 1))
    END=$((START + CHUNK_SEC))
    [ "$END" -gt "$DURATION" ] && END=$DURATION
    SEGMENT="$P1_SEGMENTS/segment_$(printf '%04d' $CHUNK).mkv"

    echo "[Pass 1 — Chunk $CHUNK/$TOTAL_CHUNKS] ${START}s → ${END}s"

    rm -rf "$WORK_DIR/frames" "$WORK_DIR/upscaled"
    mkdir -p "$WORK_DIR/frames" "$WORK_DIR/upscaled"

    ffmpeg -y -ss "$START" -t "$CHUNK_SEC" -i "$INPUT" \
        -vf "scale=720:540:flags=lanczos,fps=$FPS_ROUNDED" -vsync vfr -q:v 1 \
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
        -s 2 \
        -t 800 \
        -g 0 -j 2:4:4 \
        -f png 2>&1 | grep -v "^$" | tail -3

    ffmpeg -y \
        -framerate "$FPS_ROUNDED" \
        -i "$WORK_DIR/upscaled/frame_%08d.png" \
        -c:v libx265 -crf 18 -preset slow -pix_fmt yuv420p \
        "$SEGMENT" 2>&1 | grep -E "frame=.*fps=" | tail -1

    echo "file '$SEGMENT'" >> "$P1_SEGMENT_LIST"
    echo "  Segment saved: $(basename "$SEGMENT")"
    START=$END
done

echo ""
echo "[Pass 1 — Final] Concatenating segments → intermediate 1440x1080 (video only)..."
ffmpeg -y \
    -f concat -safe 0 -i "$P1_SEGMENT_LIST" \
    -c:v copy \
    "$INTERMEDIATE" 2>&1 | grep -E "frame=.*fps=|time=" | tail -1

rm -rf "$P1_SEGMENTS"
echo "  Intermediate: $INTERMEDIATE ($(du -sh "$INTERMEDIATE" | cut -f1))"
echo ""

# ── Pass 2: 1440x1080 → 2x → 2880x2160 ─────────────────────────────────────

DURATION2=$(ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$INTERMEDIATE" | cut -d. -f1)
TOTAL_CHUNKS2=$(( (DURATION2 + CHUNK_SEC - 1) / CHUNK_SEC ))

echo "=== Pass 2 of 2: 1440x1080 → 2x → 2880x2160 ==="
echo ""

mkdir -p "$P2_SEGMENTS"
P2_SEGMENT_LIST="$P2_SEGMENTS/segments.txt"
> "$P2_SEGMENT_LIST"

CHUNK=0
START=0
while [ "$START" -lt "$DURATION2" ]; do
    CHUNK=$((CHUNK + 1))
    END=$((START + CHUNK_SEC))
    [ "$END" -gt "$DURATION2" ] && END=$DURATION2
    SEGMENT="$P2_SEGMENTS/segment_$(printf '%04d' $CHUNK).mkv"

    echo "[Pass 2 — Chunk $CHUNK/$TOTAL_CHUNKS2] ${START}s → ${END}s"

    rm -rf "$WORK_DIR/frames" "$WORK_DIR/upscaled"
    mkdir -p "$WORK_DIR/frames" "$WORK_DIR/upscaled"

    ffmpeg -y -ss "$START" -t "$CHUNK_SEC" -i "$INTERMEDIATE" \
        -vf "fps=$FPS_ROUNDED" -vsync vfr -q:v 1 \
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
        -s 2 \
        -t 800 \
        -g 0 -j 2:4:4 \
        -f png 2>&1 | grep -v "^$" | tail -3

    ffmpeg -y \
        -framerate "$FPS_ROUNDED" \
        -i "$WORK_DIR/upscaled/frame_%08d.png" \
        -c:v libx265 -crf 18 -preset slow -pix_fmt yuv420p \
        "$SEGMENT" 2>&1 | grep -E "frame=.*fps=" | tail -1

    echo "file '$SEGMENT'" >> "$P2_SEGMENT_LIST"
    echo "  Segment saved: $(basename "$SEGMENT")"
    START=$END
done

echo ""
echo "[Final] Concatenating pass-2 segments + muxing audio/subtitles from source..."
ffmpeg -y \
    -f concat -safe 0 -i "$P2_SEGMENT_LIST" \
    -i "$INPUT" \
    -map 0:v \
    -map 1:a \
    -map 1:s? \
    -c:v copy \
    -c:a copy \
    -c:s copy \
    -metadata title="$(basename "$INPUT" .mkv) [anime 4:3 upscaled 4K]" \
    "$OUTPUT" 2>&1 | grep -E "frame=.*fps=|time=" | tail -1

rm -rf "$P2_SEGMENTS"
rm -f "$INTERMEDIATE"

echo ""
echo "=== Done! ==="
ffprobe "$OUTPUT" 2>&1 | grep -E "Duration|Video:|Audio:"
ls -lh "$OUTPUT"
