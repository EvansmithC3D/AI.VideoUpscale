#!/bin/bash
# Upscale a live-action widescreen (16:9) MKV to 1080p using SPAN (PyTorch/ROCm)
# Model: 2xNomosUni_span_multijpg — trained on real film/photography with JPEG
# degradations (maps well to MPEG-2 DVD noise); ~15x faster than the old
# RealESRGAN x2plus path (~19 fps vs ~1.3 fps GPU stage on the RX 6700 XT).
# Pre-scales to 960x540 so 2x output lands exactly at 1920x1080
# Usage: ./upscale-live-16x9.sh "input.mkv" "output.mkv" [chunk_minutes=5] [denoise=none|spatial|full] [postfilter=atadenoise=s=5]
#
# Per-chunk work is three-stage pipelined: the CPU frame-extract of chunk N+1 and the CPU
# x265 encode of chunk N-1 run in the background, overlapping the foreground GPU upscale of
# chunk N, so the GPU no longer idles through the two CPU phases. At most one background
# extract and one background encode run at once; per-chunk frames live in frames_N/upscaled_N
# and each chunk's segment is appended to the concat list only when its encode completes.
#
# denoise: pre-extract grain/noise handling. hqdn3d values mirror egvsr-upscale.py so the
#   1080p and 4K paths treat the same source identically. Defaults by year parsed from the
#   filename: pre-2000 → none (preserve grain), 2000+ → spatial.
#   "none"    — spp deblock only, no hqdn3d (preserve film grain; best for pre-2000 film)
#   "spatial" — spp deblock + hqdn3d=2:1.5:0:0 (per-frame spatial only)
#   "full"    — spp deblock + hqdn3d=2:1.5:6:4.5 (spatial + temporal)
#
# postfilter: ffmpeg -vf expression applied to upscaled frames before final encode.
#   "none"                   — skip
#   "atadenoise=s=5"         — 5-frame adaptive temporal avg; kills single-image-model flicker (default)
#   "atadenoise=s=9"         — stronger; risks mild motion blur
#   "deflicker=mode=am:size=5" — global-brightness deflicker
#   Any custom ffmpeg filter-chain string is passed through verbatim.

INPUT="$1"
OUTPUT="$2"
CHUNK_MIN="${3:-5}"
DENOISE="${4:-}"
POSTFILTER="${5:-atadenoise=s=5}"

# Year-based denoise default if not explicitly set (matches the 4K EGVSR path)
if [[ -z "$DENOISE" ]]; then
    YEAR=$(basename "$INPUT" .mkv | grep -oE '\([0-9]{4}\)' | tr -d '()' | tail -1)
    if [[ -n "$YEAR" && "$YEAR" -lt 2000 ]]; then
        DENOISE="none"
    else
        DENOISE="spatial"
    fi
fi

# Map denoise level to an hqdn3d filter segment appended after spp (empty for 'none').
case "$DENOISE" in
    none)    DENOISE_VF="" ;;
    spatial) DENOISE_VF=",hqdn3d=2:1.5:0:0" ;;
    full)    DENOISE_VF=",hqdn3d=2:1.5:6:4.5" ;;
    *)       echo "ERROR: denoise must be none|spatial|full (got '$DENOISE')" >&2; exit 1 ;;
esac

HALF_W=960
HALF_H=540
SCALE=2
SPAN_MODEL="/usr/local/share/span-models/2xNomosUni_span_multijpg.safetensors"
SPAN_PY="/home/evanna/.venvs/span-upscale/bin/python3"   # spandrel venv over the system ROCm torch
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
WORK_DIR="/tmp/upscale_work_$$"
SEGMENTS_DIR="/tmp/upscale_segments_$$"

if [[ -z "$INPUT" || -z "$OUTPUT" ]]; then
    echo "Usage: $0 <input.mkv> <output.mkv> [chunk_minutes=5] [denoise=none|spatial|full] [postfilter=atadenoise=s=5]"
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

echo "=== Live-Action 16:9 Upscaler: 540p → 1080p ==="
echo "Input:    $INPUT"
echo "Output:   $OUTPUT"
echo "Model:    SPAN 2xNomosUni_span_multijpg (2x, live-action, PyTorch/ROCm fp16)"
echo "Pipeline: ${HALF_W}x${HALF_H} → 2x → $((HALF_W * SCALE))x$((HALF_H * SCALE))"
echo "Chunk:    ${CHUNK_MIN} minutes"
echo "Denoise:  ${DENOISE}"
echo "Postfilter: ${POSTFILTER}"
echo ""

FPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate \
    -of default=noprint_wrappers=1:nokey=1 "$INPUT" | bc -l)
FPS_ROUNDED=$(printf "%.3f" "$FPS")
DURATION_F=$(ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$INPUT")
DURATION=${DURATION_F%.*}
CHUNK_SEC=$((CHUNK_MIN * 60))
TOTAL_CHUNKS=$(( (DURATION + CHUNK_SEC - 1) / CHUNK_SEC ))

echo "Duration: ${DURATION}s  FPS: $FPS_ROUNDED  Chunks: $TOTAL_CHUNKS"

IVTC_CHAIN=$(detect_ivtc_chain "$INPUT" "$DURATION")
if [[ "$IVTC_CHAIN" == fieldmatch* ]]; then
    echo "Telecine: 3:2 pulldown detected — IVTC enabled"
else
    echo "Telecine: none — IVTC disabled, no frame decimation (progressive source)"
fi
echo ""

mkdir -p "$WORK_DIR" "$SEGMENTS_DIR"

# Background stage pids — empty when nothing is pending. cleanup kills any live
# background stage before removing WORK_DIR; it must NEVER touch SEGMENTS_DIR
# (per-chunk segments there survive a crash and drive a resume).
EXTRACT_PID=""
EXTRACT_CHUNK=""
ENCODE_PID=""
ENCODE_CHUNK=""
ENCODE_SEGMENT=""
ENCODE_WALL_START=""

cleanup() {
    [ -n "$EXTRACT_PID" ] && kill "$EXTRACT_PID" 2>/dev/null
    [ -n "$ENCODE_PID" ] && kill "$ENCODE_PID" 2>/dev/null
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

SEGMENT_LIST="$SEGMENTS_DIR/segments.txt"
> "$SEGMENT_LIST"

POSTFILTER_ARGS=()
if [[ "$POSTFILTER" != "none" ]]; then
    POSTFILTER_ARGS=(-vf "$POSTFILTER")
fi

# --- Background stage workers ---

# Extract one chunk's frames into frames_$1 (scaled to HALF_WxHALF_H). Logs to extract_$1.log.
# IVTC only if telecined (see detect_ivtc_chain), then spp DCT-aware 8x8 deblock +
# year/denoise-gated hqdn3d (see DENOISE_VF) and a lanczos downscale to ${HALF_W}x${HALF_H}.
extract_chunk() {
    local chunk="$1" start="$2"
    local fdir="$WORK_DIR/frames_$chunk"
    mkdir -p "$fdir"
    ffmpeg -y -nostdin -ss "$start" -t "$CHUNK_SEC" -i "$INPUT" \
        -vf "${IVTC_CHAIN}spp=quality=4${DENOISE_VF},scale=${HALF_W}:${HALF_H}:flags=lanczos" \
        -vsync vfr -q:v 1 \
        "$fdir/frame_%08d.png" -an \
        > "$WORK_DIR/extract_$chunk.log" 2>&1
}

# Encode one chunk's upscaled frames into its segment MKV. Logs to encode_$1.log.
encode_chunk() {
    local chunk="$1" fps="$2" segment="$3"
    ffmpeg -y -nostdin \
        -framerate "$fps" \
        -i "$WORK_DIR/upscaled_$chunk/frame_%08d.png" \
        "${POSTFILTER_ARGS[@]}" \
        -c:v libx265 -crf 18 -preset medium -pix_fmt yuv420p \
        "$segment" \
        > "$WORK_DIR/encode_$chunk.log" 2>&1
}

# Prefetch: start the background extract of the next chunk if any runtime remains.
start_prefetch() {
    local next_chunk=$((CHUNK + 1))
    NEXT_START=$END
    if [ "$NEXT_START" -lt "$DURATION" ]; then
        extract_chunk "$next_chunk" "$NEXT_START" &
        EXTRACT_PID=$!
        EXTRACT_CHUNK=$next_chunk
    fi
}

# Finish the pending background encode (chunk N-1): wait, verify, append its
# segment to the ordered concat list, drop its upscaled frames, and log the
# chunk-done line. Appending only here keeps SEGMENT_LIST in chunk order.
finish_encode() {
    [ -z "$ENCODE_PID" ] && return 0
    wait "$ENCODE_PID"
    local rc=$?
    local chunk="$ENCODE_CHUNK" segment="$ENCODE_SEGMENT" wall="$ENCODE_WALL_START"
    if [ $rc -ne 0 ] || [ ! -s "$segment" ]; then
        echo "  ERROR: Segment encode for chunk $chunk failed (exit $rc)"
        echo "  --- tail of encode_$chunk.log ---"
        tail -20 "$WORK_DIR/encode_$chunk.log"
        echo "=== segments preserved in $SEGMENTS_DIR ==="
        exit 1
    fi
    echo "file '$segment'" >> "$SEGMENT_LIST"
    rm -rf "$WORK_DIR/upscaled_$chunk"
    ENCODE_PID=""
    ENCODE_CHUNK=""
    ENCODE_SEGMENT=""
    ENCODE_WALL_START=""
    ts "  Chunk $chunk done in $(( $(date +%s) - wall ))s — segment saved: $(basename "$segment")"
}

CHUNK=0
START=0

while [ "$START" -lt "$DURATION" ]; do
    CHUNK=$((CHUNK + 1))
    END=$((START + CHUNK_SEC))
    [ "$END" -gt "$DURATION" ] && END=$DURATION
    SEGMENT="$SEGMENTS_DIR/segment_$(printf '%04d' $CHUNK).mkv"

    CHUNK_START=$(date +%s)
    ts "[Chunk $CHUNK/$TOTAL_CHUNKS] ${START}s → ${END}s"

    # Step 1: ensure chunk N's extract is running (chunk 1 starts it synchronously;
    # later chunks were prefetched during the previous iteration), then wait for it.
    if [ -z "$EXTRACT_PID" ]; then
        extract_chunk "$CHUNK" "$START" &
        EXTRACT_PID=$!
        EXTRACT_CHUNK=$CHUNK
    fi
    wait "$EXTRACT_PID"
    EXTRACT_RC=$?
    EXTRACT_PID=""
    if [ $EXTRACT_RC -ne 0 ]; then
        finish_encode
        echo "  ERROR: frame extraction for chunk $CHUNK failed (exit $EXTRACT_RC)"
        echo "  --- tail of extract_$CHUNK.log ---"
        tail -20 "$WORK_DIR/extract_$CHUNK.log"
        echo "=== segments preserved in $SEGMENTS_DIR ==="
        exit 1
    fi

    # Step 2: count the extracted frames.
    FRAME_COUNT=$(ls "$WORK_DIR/frames_$CHUNK" 2>/dev/null | wc -l)
    echo "  Frames: $FRAME_COUNT"
    if [ "$FRAME_COUNT" -eq 0 ]; then
        echo "  No frames extracted, skipping."
        rm -rf "$WORK_DIR/frames_$CHUNK"
        start_prefetch
        START=$END
        continue
    fi

    # Step 3: prefetch the next chunk's extract before starting the GPU run.
    start_prefetch

    # Step 4: GPU upscale (foreground). Log to a file so we keep $? intact. A
    # partial upscale (fewer frames out than in) from a mid-chunk GPU failure must
    # abort — otherwise a short chunk silently desyncs the whole rest of the film.
    mkdir -p "$WORK_DIR/upscaled_$CHUNK"
    HSA_OVERRIDE_GFX_VERSION=10.3.0 "$SPAN_PY" "$SCRIPT_DIR/span-upscale.py" \
        --input "$WORK_DIR/frames_$CHUNK" \
        --output "$WORK_DIR/upscaled_$CHUNK" \
        --model "$SPAN_MODEL" \
        --fp16 \
        > "$WORK_DIR/upscale_$CHUNK.log" 2>&1
    UPSCALE_RC=$?
    grep -v "^$" "$WORK_DIR/upscale_$CHUNK.log" | tail -3
    UPSCALED_COUNT=$(ls "$WORK_DIR/upscaled_$CHUNK" 2>/dev/null | wc -l)
    echo "  Upscaled frames: $UPSCALED_COUNT"
    if [ $UPSCALE_RC -ne 0 ] || [ "$UPSCALED_COUNT" -ne "$FRAME_COUNT" ]; then
        finish_encode
        echo "  ERROR: SPAN upscale failed for chunk $CHUNK (exit $UPSCALE_RC; upscaled $UPSCALED_COUNT / $FRAME_COUNT frames)"
        echo "=== segments preserved in $SEGMENTS_DIR ==="
        exit 1
    fi

    # Step 5: extracted frames are no longer needed.
    rm -rf "$WORK_DIR/frames_$CHUNK"

    # Step 6: finish the previous chunk's encode (appends its segment in order).
    finish_encode

    # Step 7: compute this chunk's fps, then start its encode in the background.
    # Final chunk: -t runs to true EOF, so use the full-precision duration for the
    # span — the integer DURATION would overstate fps and play the tail fast.
    if [ "$END" -eq "$DURATION" ]; then
        SPAN=$(echo "$DURATION_F - $START" | bc)
    else
        SPAN=$((END - START))
    fi
    CHUNK_FPS=$(echo "scale=6; $FRAME_COUNT / $SPAN" | bc)
    echo "  FPS: $CHUNK_FPS"

    encode_chunk "$CHUNK" "$CHUNK_FPS" "$SEGMENT" &
    ENCODE_PID=$!
    ENCODE_CHUNK=$CHUNK
    ENCODE_SEGMENT=$SEGMENT
    ENCODE_WALL_START=$CHUNK_START

    START=$END
done

# Finish the final pending encode.
finish_encode

echo ""
MUXED_TMP="/tmp/upscale_muxed_$$.mkv"
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
MKVMERGE_EXIT=${PIPESTATUS[0]}
if [ "$MKVMERGE_EXIT" -ge 2 ]; then
    echo ""
    echo "=== ERROR: mkvmerge failed (exit $MKVMERGE_EXIT) — intermediate preserved at $MUXED_TMP ==="
    exit 1
fi
rm -f "$MUXED_TMP"

echo ""
ts "=== Done! ==="
ffprobe "$OUTPUT" 2>&1 | grep -E "Duration|Video:|Audio:"
ls -lh "$OUTPUT"
