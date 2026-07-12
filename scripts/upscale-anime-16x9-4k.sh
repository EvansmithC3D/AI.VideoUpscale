#!/bin/bash
# Upscale animated widescreen (16:9) MKV to 4K (3840x2160) via two-pass Real-ESRGAN animevideov3
# Pass 1: source → IVTC/deinterlace + spp deblock → 960x540 → 2x → 1920x1080 (temp intermediate, video-only)
# Pass 2: 1920x1080 → 2x → 3840x2160 (final output, audio/subs muxed from source)
# Usage: ./upscale-anime-16x9-4k.sh "input.mkv" "output.mkv" [chunk_minutes=2]

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

ts() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Detect 3:2 pulldown and echo the IVTC filter prefix for the extract chain.
# fieldmatch+decimate must run ONLY on genuinely telecined sources: `decimate`
# drops 1 of every 5 frames unconditionally, so on progressive video it destroys
# 20% of real frames and desyncs the output against the untouched audio. idet
# reports repeated fields — ~20% on true 3:2 pulldown, ~0 on progressive.
# Samples up to three 120s windows (10%, 50%, 85% of runtime) so mixed-cadence
# discs and short files still get a representative vote.
detect_ivtc_chain() {
    local input="$1" dur="$2"
    local starts=() s stats neither top bottom
    local n_total=0 t_total=0 b_total=0
    if [ "$dur" -lt 300 ]; then
        starts=(0)
    else
        starts=($((dur / 10)) $((dur / 2)) $((dur * 85 / 100)))
    fi
    for s in "${starts[@]}"; do
        [ $((s + 120)) -gt "$dur" ] && s=$(( dur > 120 ? dur - 120 : 0 ))
        stats=$(ffmpeg -nostdin -ss "$s" -t 120 -i "$input" -map 0:v:0 -vf idet -an \
            -f null - 2>&1 | grep "Repeated Fields:" | tail -1)
        neither=$(sed -n 's/.*Neither:[[:space:]]*\([0-9]*\).*/\1/p' <<<"$stats")
        top=$(sed -n 's/.*Top:[[:space:]]*\([0-9]*\).*/\1/p' <<<"$stats")
        bottom=$(sed -n 's/.*Bottom:[[:space:]]*\([0-9]*\).*/\1/p' <<<"$stats")
        n_total=$((n_total + ${neither:-0}))
        t_total=$((t_total + ${top:-0}))
        b_total=$((b_total + ${bottom:-0}))
    done
    local total=$((n_total + t_total + b_total))
    if [ "$total" -gt 0 ] && awk -v r=$((t_total + b_total)) -v t="$total" \
            'BEGIN { exit !(r / t > 0.05) }'; then
        echo "fieldmatch=order=auto:combmatch=sc,yadif=mode=0:parity=-1:deint=all,decimate,"
    else
        echo "yadif=mode=0:parity=-1:deint=all,"
    fi
}

echo "=== Anime 16:9 4K Upscaler: source → 1080p → 3840x2160 (two-pass) ==="
echo "Input:    $INPUT"
echo "Output:   $OUTPUT"
echo "Model:    $MODEL (2x × 2 passes)"
echo "Chunk:    ${CHUNK_MIN} minutes"
echo ""

FPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate \
    -of default=noprint_wrappers=1:nokey=1 "$INPUT" | bc -l)
FPS_ROUNDED=$(printf "%.3f" "$FPS")
DURATION_F=$(ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$INPUT")
DURATION=${DURATION_F%.*}
CHUNK_SEC=$((CHUNK_MIN * 60))
TOTAL_CHUNKS=$(( (DURATION + CHUNK_SEC - 1) / CHUNK_SEC ))

echo "Duration: ${DURATION}s  FPS: $FPS_ROUNDED  Chunks per pass: $TOTAL_CHUNKS"

IVTC_CHAIN=$(detect_ivtc_chain "$INPUT" "$DURATION")
if [[ "$IVTC_CHAIN" == fieldmatch* ]]; then
    echo "Telecine: 3:2 pulldown detected — IVTC enabled"
else
    echo "Telecine: none — IVTC disabled, no frame decimation (progressive source)"
fi
echo ""

cleanup_work() { rm -rf "$WORK_DIR"; }
trap cleanup_work EXIT

# ── Pass 1: source → 960x540 → 2x → 1920x1080 ──────────────────────────────

echo "=== Pass 1 of 2: source → 960x540 → 2x → 1920x1080 ==="
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

    CHUNK_START=$(date +%s)
    ts "[Pass 1 — Chunk $CHUNK/$TOTAL_CHUNKS] ${START}s → ${END}s"

    rm -rf "$WORK_DIR/frames" "$WORK_DIR/upscaled"
    mkdir -p "$WORK_DIR/frames" "$WORK_DIR/upscaled"

    # Extract frames: IVTC only if telecined (see detect_ivtc_chain), then DCT-aware
    # MPEG-2 deblock (spp) and scale to 960x540. No fps filter — IVTC changes the frame
    # rate, so encode fps is measured per chunk below.
    ffmpeg -y -ss "$START" -t "$CHUNK_SEC" -i "$INPUT" \
        -vf "${IVTC_CHAIN}spp=quality=4,scale=960:540:flags=lanczos" -vsync vfr -q:v 1 -compression_level 1 \
        "$WORK_DIR/frames/frame_%08d.png" -an \
        2>&1 | grep -E "^frame=" | tail -1

    FRAME_COUNT=$(ls "$WORK_DIR/frames" | wc -l)
    echo "  Frames: $FRAME_COUNT"

    if [ "$FRAME_COUNT" -eq 0 ]; then
        echo "  No frames extracted, skipping."
        START=$END
        continue
    fi

    # Per-chunk fps: decimate changes frame count, so encode fps must be measured, not fixed.
    # Final chunk uses full-precision duration (integer DURATION truncates and plays fast).
    if [ "$END" -eq "$DURATION" ]; then
        SPAN=$(echo "$DURATION_F - $START" | bc)
    else
        SPAN=$((END - START))
    fi
    CHUNK_FPS=$(echo "scale=6; $FRAME_COUNT / $SPAN" | bc)
    echo "  FPS: $CHUNK_FPS"

    UPSCALE_LOG="$WORK_DIR/upscale_p1_$CHUNK.log"
    realesrgan-ncnn-vulkan \
        -i "$WORK_DIR/frames" \
        -o "$WORK_DIR/upscaled" \
        -n "$MODEL" \
        -m "$MODEL_PATH" \
        -s 2 \
        -t 0 \
        -g 0 -j 2:4:4 \
        -f png > "$UPSCALE_LOG" 2>&1
    UPSCALE_EXIT=$?
    tail -3 "$UPSCALE_LOG"

    if [ "$UPSCALE_EXIT" -ne 0 ]; then
        echo "  ERROR: realesrgan failed (exit $UPSCALE_EXIT) — segments preserved in $P1_SEGMENTS"
        exit 1
    fi

    UPSCALED_COUNT=$(ls "$WORK_DIR/upscaled" | wc -l)
    echo "  Upscaled frames: $UPSCALED_COUNT"
    if [ "$UPSCALED_COUNT" -ne "$FRAME_COUNT" ]; then
        echo "  ERROR: upscaled count ($UPSCALED_COUNT) != extracted ($FRAME_COUNT) — segments preserved in $P1_SEGMENTS"
        exit 1
    fi

    # Near-lossless intermediate (crf 10): pass 2 re-runs the AI model over these frames,
    # which would amplify any crf-18 compression artifacts baked in here.
    ENCODE_LOG="$WORK_DIR/encode_p1_$CHUNK.log"
    ffmpeg -y \
        -framerate "$CHUNK_FPS" \
        -i "$WORK_DIR/upscaled/frame_%08d.png" \
        -c:v libx265 -crf 10 -preset fast -pix_fmt yuv420p \
        "$SEGMENT" > "$ENCODE_LOG" 2>&1
    ENCODE_EXIT=$?

    if [ "$ENCODE_EXIT" -ne 0 ] || [ ! -s "$SEGMENT" ]; then
        echo "  ERROR: segment encoding failed (ffmpeg exit $ENCODE_EXIT) — segments preserved in $P1_SEGMENTS"
        tail -5 "$ENCODE_LOG"
        exit 1
    fi

    echo "file '$SEGMENT'" >> "$P1_SEGMENT_LIST"
    CHUNK_ELAPSED=$(( $(date +%s) - CHUNK_START ))
    ts "  Pass 1 Chunk $CHUNK done in ${CHUNK_ELAPSED}s — segment saved: $(basename "$SEGMENT")"
    START=$END
done

echo ""
ts "[Pass 1 — Final] Concatenating segments → intermediate 1080p (video only)..."
ffmpeg -y \
    -f concat -safe 0 -i "$P1_SEGMENT_LIST" \
    -c:v copy \
    "$INTERMEDIATE"
P1_CONCAT_EXIT=$?

if [ "$P1_CONCAT_EXIT" -ne 0 ] || [ ! -f "$INTERMEDIATE" ]; then
    echo ""
    echo "=== ERROR: Pass 1 concat failed (exit $P1_CONCAT_EXIT) — segments preserved in $P1_SEGMENTS ==="
    exit 1
fi

rm -rf "$P1_SEGMENTS"
echo "  Intermediate: $INTERMEDIATE ($(du -sh "$INTERMEDIATE" | cut -f1))"
echo ""

# ── Pass 2: 1920x1080 → 2x → 3840x2160 ─────────────────────────────────────

DURATION2_F=$(ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$INTERMEDIATE")
DURATION2=${DURATION2_F%.*}
TOTAL_CHUNKS2=$(( (DURATION2 + CHUNK_SEC - 1) / CHUNK_SEC ))

echo "=== Pass 2 of 2: 1920x1080 → 2x → 3840x2160 ==="
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

    CHUNK_START=$(date +%s)
    ts "[Pass 2 — Chunk $CHUNK/$TOTAL_CHUNKS2] ${START}s → ${END}s"

    rm -rf "$WORK_DIR/frames" "$WORK_DIR/upscaled"
    mkdir -p "$WORK_DIR/frames" "$WORK_DIR/upscaled"

    # Extract frames from intermediate at native 1920x1080 — already clean and progressive,
    # so no IVTC, no spp, no fps filter, no rescale.
    ffmpeg -y -ss "$START" -t "$CHUNK_SEC" -i "$INTERMEDIATE" \
        -vsync vfr -q:v 1 -compression_level 1 \
        "$WORK_DIR/frames/frame_%08d.png" -an \
        2>&1 | grep -E "^frame=" | tail -1

    FRAME_COUNT=$(ls "$WORK_DIR/frames" | wc -l)
    echo "  Frames: $FRAME_COUNT"

    if [ "$FRAME_COUNT" -eq 0 ]; then
        echo "  No frames extracted, skipping."
        START=$END
        continue
    fi

    # Final chunk uses full-precision intermediate duration (integer DURATION2 truncates).
    if [ "$END" -eq "$DURATION2" ]; then
        SPAN=$(echo "$DURATION2_F - $START" | bc)
    else
        SPAN=$((END - START))
    fi
    CHUNK_FPS=$(echo "scale=6; $FRAME_COUNT / $SPAN" | bc)
    echo "  FPS: $CHUNK_FPS"

    # -t 0: no tile limit — 12GB VRAM handles 1920x1080 input in one shot
    UPSCALE_LOG="$WORK_DIR/upscale_p2_$CHUNK.log"
    realesrgan-ncnn-vulkan \
        -i "$WORK_DIR/frames" \
        -o "$WORK_DIR/upscaled" \
        -n "$MODEL" \
        -m "$MODEL_PATH" \
        -s 2 \
        -t 0 \
        -g 0 -j 2:4:4 \
        -f png > "$UPSCALE_LOG" 2>&1
    UPSCALE_EXIT=$?
    tail -3 "$UPSCALE_LOG"

    if [ "$UPSCALE_EXIT" -ne 0 ]; then
        echo "  ERROR: realesrgan failed (exit $UPSCALE_EXIT) — segments preserved in $P2_SEGMENTS"
        exit 1
    fi

    UPSCALED_COUNT=$(ls "$WORK_DIR/upscaled" | wc -l)
    echo "  Upscaled frames: $UPSCALED_COUNT"
    if [ "$UPSCALED_COUNT" -ne "$FRAME_COUNT" ]; then
        echo "  ERROR: upscaled count ($UPSCALED_COUNT) != extracted ($FRAME_COUNT) — segments preserved in $P2_SEGMENTS"
        exit 1
    fi

    ENCODE_LOG="$WORK_DIR/encode_p2_$CHUNK.log"
    ffmpeg -y \
        -framerate "$CHUNK_FPS" \
        -i "$WORK_DIR/upscaled/frame_%08d.png" \
        -c:v libx265 -crf 18 -preset medium -pix_fmt yuv420p \
        -x265-params "keyint=48:min-keyint=24" \
        "$SEGMENT" > "$ENCODE_LOG" 2>&1
    ENCODE_EXIT=$?

    if [ "$ENCODE_EXIT" -ne 0 ] || [ ! -s "$SEGMENT" ]; then
        echo "  ERROR: segment encoding failed (ffmpeg exit $ENCODE_EXIT) — segments preserved in $P2_SEGMENTS"
        tail -5 "$ENCODE_LOG"
        exit 1
    fi

    echo "file '$SEGMENT'" >> "$P2_SEGMENT_LIST"
    CHUNK_ELAPSED=$(( $(date +%s) - CHUNK_START ))
    ts "  Pass 2 Chunk $CHUNK done in ${CHUNK_ELAPSED}s — segment saved: $(basename "$SEGMENT")"
    START=$END
done

echo ""
MUXED_TMP="/tmp/upscale_muxed_$$.mkv"
ts "[Final] Concatenating pass-2 segments + muxing audio/subtitles from source..."
ffmpeg -y \
    -f concat -safe 0 -i "$P2_SEGMENT_LIST" \
    -i "$INPUT" \
    -map 0:v \
    -map 1:a \
    -map 1:s? \
    -c:v copy \
    -c:a copy \
    -c:s copy \
    -metadata title="$(basename "$INPUT" .mkv) [anime 16:9 upscaled 4K]" \
    "$MUXED_TMP"
CONCAT_EXIT=$?

if [ "$CONCAT_EXIT" -ne 0 ] || [ ! -f "$MUXED_TMP" ]; then
    echo ""
    echo "=== ERROR: Final concat failed (exit $CONCAT_EXIT) — segments preserved in $P2_SEGMENTS, intermediate at $INTERMEDIATE ==="
    exit 1
fi

rm -rf "$P2_SEGMENTS"
rm -f "$INTERMEDIATE"

ts "[Final] Rebuilding seek index with mkvmerge..."
mkvmerge -o "$OUTPUT" "$MUXED_TMP" 2>&1 | grep -E "Progress: 100%|Warning|Error" | tail -2
MKVMERGE_EXIT=${PIPESTATUS[0]}
if [ "$MKVMERGE_EXIT" -ge 2 ]; then
    echo "=== ERROR: mkvmerge failed (exit $MKVMERGE_EXIT) — muxed file preserved at $MUXED_TMP ==="
    exit 1
fi
rm -f "$MUXED_TMP"

echo ""
ts "=== Done! ==="
ffprobe "$OUTPUT" 2>&1 | grep -E "Duration|Video:|Audio:"
ls -lh "$OUTPUT"
