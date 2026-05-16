#!/bin/bash
# Upscale a live-action widescreen (16:9) MKV to 1080p using Real-ESRGAN x2plus (ncnn-vulkan)
# Pre-scales to 960x540 so 2x output lands exactly at 1920x1080
# Usage: ./upscale-live-16x9.sh "input.mkv" "output.mkv" [chunk_minutes=5] [postfilter=atadenoise=s=5]
#
# postfilter: ffmpeg -vf expression applied to upscaled frames before final encode.
#   "none"                   — skip (original behaviour)
#   "atadenoise=s=5"         — 5-frame adaptive temporal avg; kills single-image-model flicker (default)
#   "atadenoise=s=9"         — stronger; risks mild motion blur
#   "deflicker=mode=am:size=5" — global-brightness deflicker
#   Any custom ffmpeg filter-chain string is passed through verbatim.

INPUT="$1"
OUTPUT="$2"
CHUNK_MIN="${3:-5}"
POSTFILTER="${4:-atadenoise=s=5}"

HALF_W=960
HALF_H=540
SCALE=2
MODEL="realesrgan-x2plus"
MODEL_PATH="/usr/local/share/realesrgan-models"
WORK_DIR="/tmp/upscale_work_$$"
SEGMENTS_DIR="/tmp/upscale_segments_$$"

if [[ -z "$INPUT" || -z "$OUTPUT" ]]; then
    echo "Usage: $0 <input.mkv> <output.mkv> [chunk_minutes=5]"
    exit 1
fi

ts() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Detect 3:2 pulldown and echo the IVTC filter prefix for the extract chain.
# fieldmatch+decimate must run ONLY on genuinely telecined sources: `decimate`
# drops 1 of every 5 frames unconditionally, so on progressive video it destroys
# 20% of real frames and desyncs the output against the untouched audio. idet
# reports repeated fields — ~20% on true 3:2 pulldown, ~0 on progressive.
detect_ivtc_chain() {
    local stats neither top bottom total
    stats=$(ffmpeg -nostdin -ss 600 -t 120 -i "$1" -map 0:v:0 -vf idet -an \
        -f null - 2>&1 | grep "Repeated Fields:" | tail -1)
    neither=$(sed -n 's/.*Neither:[[:space:]]*\([0-9]*\).*/\1/p' <<<"$stats")
    top=$(sed -n 's/.*Top:[[:space:]]*\([0-9]*\).*/\1/p' <<<"$stats")
    bottom=$(sed -n 's/.*Bottom:[[:space:]]*\([0-9]*\).*/\1/p' <<<"$stats")
    total=$(( ${neither:-0} + ${top:-0} + ${bottom:-0} ))
    if [ "$total" -gt 0 ] && awk -v r=$(( ${top:-0} + ${bottom:-0} )) -v t="$total" \
            'BEGIN { exit !(r / t > 0.05) }'; then
        echo "fieldmatch=order=auto:combmatch=full,yadif=mode=0:parity=-1:deint=interlaced,decimate,"
    else
        echo "yadif=mode=0:parity=-1:deint=interlaced,"
    fi
}

echo "=== Live-Action 16:9 Upscaler: 540p → 1080p ==="
echo "Input:    $INPUT"
echo "Output:   $OUTPUT"
echo "Model:    RealESRGAN-$MODEL (2x, live-action, ncnn-vulkan)"
echo "Pipeline: ${HALF_W}x${HALF_H} → 2x → $((HALF_W * SCALE))x$((HALF_H * SCALE))"
echo "Chunk:    ${CHUNK_MIN} minutes"
echo "Postfilter: ${POSTFILTER}"
echo ""

FPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate \
    -of default=noprint_wrappers=1:nokey=1 "$INPUT" | bc -l)
FPS_ROUNDED=$(printf "%.3f" "$FPS")
DURATION=$(ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$INPUT" | cut -d. -f1)
CHUNK_SEC=$((CHUNK_MIN * 60))
TOTAL_CHUNKS=$(( (DURATION + CHUNK_SEC - 1) / CHUNK_SEC ))

echo "Duration: ${DURATION}s  FPS: $FPS_ROUNDED  Chunks: $TOTAL_CHUNKS"

IVTC_CHAIN=$(detect_ivtc_chain "$INPUT")
if [[ "$IVTC_CHAIN" == fieldmatch* ]]; then
    echo "Telecine: 3:2 pulldown detected — IVTC enabled"
else
    echo "Telecine: none — IVTC disabled, no frame decimation (progressive source)"
fi
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

    # Extract frames: IVTC only if the source is telecined (see detect_ivtc_chain),
    # then deblock/denoise and scale to 960x540
    ffmpeg -y -ss "$START" -t "$CHUNK_SEC" -i "$INPUT" \
        -vf "${IVTC_CHAIN}deblock,hqdn3d=4:3:6:4.5,scale=${HALF_W}:${HALF_H}:flags=lanczos" -vsync vfr -q:v 1 \
        "$WORK_DIR/frames/frame_%08d.png" -an \
        2>&1 | grep -E "^frame=" | tail -1

    FRAME_COUNT=$(ls "$WORK_DIR/frames" | wc -l)
    echo "  Frames: $FRAME_COUNT"

    if [ "$FRAME_COUNT" -eq 0 ]; then
        echo "  No frames extracted, skipping."
        START=$END
        continue
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
        echo "  ERROR: realesrgan produced no output frames — aborting"
        exit 1
    fi

    POSTFILTER_ARGS=()
    if [[ "$POSTFILTER" != "none" ]]; then
        POSTFILTER_ARGS=(-vf "$POSTFILTER")
    fi

    ffmpeg -y \
        -framerate "$CHUNK_FPS" \
        -i "$WORK_DIR/upscaled/frame_%08d.png" \
        "${POSTFILTER_ARGS[@]}" \
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
