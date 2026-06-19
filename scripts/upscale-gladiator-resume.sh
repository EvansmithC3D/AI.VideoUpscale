#!/bin/bash
# Resume Gladiator (2000) upscale: chunk 31/31 only (the final 298s), then
# concat all 31 segments and mux audio/subs from the source.
#
# Original job: PID 2418589 via scripts/upscale-live-16x9.sh — hung on the
# final chunk's ffmpeg extract (D-state I/O). Segments 1-30 are intact in
# /tmp/upscale_segments_2418589/. This script processes only chunk 31 and
# finalizes the output, then leaves /tmp untouched on failure so it can be
# retried.

INPUT="/mnt/jellyfin-movies/Gladiator (2000).mkv"
OUTPUT="/mnt/jellyfin-movies/Gladiator (2000) [upscaled].mkv"

HALF_W=960
HALF_H=540
MODEL="realesrgan-x2plus"
MODEL_PATH="/usr/local/share/realesrgan-models"
WORK_DIR="/tmp/upscale_gladiator_resume_work"
SEGMENTS_DIR="/tmp/upscale_segments_2418589"
POSTFILTER="atadenoise=s=5"

# Chunk 31: derived from the original log (Duration=9298s, 5-min chunks).
CHUNK=31
TOTAL_CHUNKS=31
START=9000
END=9298
CHUNK_SEC=300   # `-t` for ffmpeg; will simply hit EOF at 9298s

# Source is progressive (original log: "Telecine: none") so the same yadif-only
# chain as the original chunks 1-30. Do NOT introduce decimate here.
IVTC_CHAIN="yadif=mode=0:parity=-1:deint=interlaced,"

ts() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Sanity: confirm we have exactly 30 prior segments
PRIOR=$(ls "$SEGMENTS_DIR"/segment_*.mkv 2>/dev/null | wc -l)
if [ "$PRIOR" -ne 30 ]; then
    echo "ABORT: expected 30 prior segments in $SEGMENTS_DIR, found $PRIOR"
    exit 1
fi
if [ ! -s "$SEGMENTS_DIR/segments.txt" ]; then
    echo "ABORT: segments.txt missing or empty"
    exit 1
fi

echo "=== Gladiator (2000) resume — chunk 31/31 ==="
echo "Segments dir: $SEGMENTS_DIR (30 prior segments OK)"
echo "Window:       ${START}s → ${END}s"
echo ""

mkdir -p "$WORK_DIR/frames" "$WORK_DIR/upscaled"
trap 'rm -rf "$WORK_DIR"' EXIT

SEGMENT="$SEGMENTS_DIR/segment_$(printf '%04d' $CHUNK).mkv"

# If a previous resume attempt left a partial chunk 31, drop it
if [ -f "$SEGMENT" ]; then
    ts "Removing stale $SEGMENT from prior resume attempt"
    rm -f "$SEGMENT"
fi

ts "[Chunk $CHUNK/$TOTAL_CHUNKS] ${START}s → ${END}s"

ffmpeg -y -ss "$START" -t "$CHUNK_SEC" -i "$INPUT" \
    -vf "${IVTC_CHAIN}deblock,hqdn3d=4:3:6:4.5,scale=${HALF_W}:${HALF_H}:flags=lanczos" -vsync vfr -q:v 1 \
    "$WORK_DIR/frames/frame_%08d.png" -an \
    2>&1 | grep -E "^frame=" | tail -1

FRAME_COUNT=$(ls "$WORK_DIR/frames" | wc -l)
echo "  Frames: $FRAME_COUNT"
if [ "$FRAME_COUNT" -eq 0 ]; then
    echo "  ABORT: no frames extracted"
    exit 1
fi

CHUNK_FPS=$(echo "scale=6; $FRAME_COUNT / ($END - $START)" | bc)
echo "  FPS: $CHUNK_FPS"

realesrgan-ncnn-vulkan \
    -i "$WORK_DIR/frames" \
    -o "$WORK_DIR/upscaled" \
    -n "$MODEL" \
    -m "$MODEL_PATH" \
    -s 2 \
    -t 1024 \
    -g 0 -j 2:4:4 \
    -f png 2>&1 | grep -v "^$" | tail -3

UPSCALED_COUNT=$(ls "$WORK_DIR/upscaled" | wc -l)
echo "  Upscaled frames: $UPSCALED_COUNT"
if [ "$UPSCALED_COUNT" -eq 0 ]; then
    echo "  ABORT: realesrgan produced no output frames"
    exit 1
fi

ffmpeg -y \
    -framerate "$CHUNK_FPS" \
    -i "$WORK_DIR/upscaled/frame_%08d.png" \
    -vf "$POSTFILTER" \
    -c:v libx265 -crf 18 -preset medium -pix_fmt yuv420p \
    "$SEGMENT"
ENCODE_EXIT=$?

if [ $ENCODE_EXIT -ne 0 ] || [ ! -f "$SEGMENT" ]; then
    echo "  ABORT: segment encoding failed (ffmpeg exit $ENCODE_EXIT)"
    exit 1
fi

# Append chunk 31 to segments.txt only if not already there
if ! grep -qF "$SEGMENT" "$SEGMENTS_DIR/segments.txt"; then
    echo "file '$SEGMENT'" >> "$SEGMENTS_DIR/segments.txt"
fi
ts "  Chunk $CHUNK done — segment saved: $(basename "$SEGMENT")"

echo ""
MUXED_TMP="${OUTPUT%.mkv}.muxed.mkv"
ts "[Final] Concatenating $TOTAL_CHUNKS segments + muxing audio/subtitles..."
ffmpeg -y \
    -f concat -safe 0 -i "$SEGMENTS_DIR/segments.txt" \
    -i "$INPUT" \
    -map 0:v \
    -map 1:a \
    -map 1:s? \
    -c:v copy \
    -c:a copy \
    -c:s copy \
    -metadata title="Gladiator (2000) [upscaled 1080p]" \
    "$MUXED_TMP"
FFMPEG_EXIT=$?

if [ $FFMPEG_EXIT -ne 0 ] || [ ! -f "$MUXED_TMP" ]; then
    echo ""
    echo "=== ERROR: Final concat failed (exit $FFMPEG_EXIT) — segments preserved in $SEGMENTS_DIR ==="
    exit 1
fi

ts "[Final] Rebuilding seek index with mkvmerge..."
mkvmerge -o "$OUTPUT" "$MUXED_TMP" 2>&1 | grep -E "Progress: 100%|Warning|Error" | tail -2
MKVMERGE_EXIT=${PIPESTATUS[0]}
rm -f "$MUXED_TMP"

if [ $MKVMERGE_EXIT -ne 0 ] || [ ! -f "$OUTPUT" ]; then
    echo "=== ERROR: mkvmerge failed — segments preserved in $SEGMENTS_DIR ==="
    exit 1
fi

# Verify
echo ""
ts "=== Done! ==="
ffprobe "$OUTPUT" 2>&1 | grep -E "Duration|Video:|Audio:"
ls -lh "$OUTPUT"

# Only after the output is verified-present do we clear /tmp segments
rm -rf "$SEGMENTS_DIR"
echo "Cleaned $SEGMENTS_DIR"
