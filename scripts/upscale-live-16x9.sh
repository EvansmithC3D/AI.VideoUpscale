#!/bin/bash
# Upscale a live-action widescreen (16:9) MKV to 1080p using SPAN (PyTorch/ROCm)
# Model: 2xNomosUni_span_multijpg — trained on real film/photography with JPEG
# degradations (maps well to MPEG-2 DVD noise); ~15x faster than the old
# RealESRGAN x2plus path.
# SPAN runs on the native source frame (720x480 for NTSC DVD → 1440x960); a single
# lanczos resize then lands the output at exactly 1920x1080 (square pixels, BT.709).
# Usage: ./upscale-live-16x9.sh "input.mkv" "output.mkv" [chunk_minutes=5] [denoise=none|spatial|full] [postfilter=atadenoise=s=5]
#
# Per chunk, decode → SPAN → x265 run concurrently as one raw-video pipe
# (ffmpeg | span-upscale.py | ffmpeg), so no frame touches disk. Each chunk leaves
# segment_NNNN.hevc (bare x265 stream) and segment_NNNN.pts (per-frame timestamps,
# seconds from the chunk start) in SEGMENTS_DIR; they survive a crash for resume.
#
# Timing: the pipe carries no timestamps, so the extract's showinfo records every
# frame's real pts and the final mkvmerge applies them all as one timestamp file.
# DVDs often mix 23.976 film with 29.97 video-rate sections; stamping each frame
# with its true time keeps those sections in sync (the old per-chunk average fps
# spread them evenly, causing stutter and multi-second mid-chunk audio drift).
# Chunks are cut with trim on those same timestamps, so they partition the film
# exactly — no frame is duplicated or lost at a boundary.
#
# denoise: pre-extract grain/noise handling. hqdn3d values mirror egvsr-upscale.py so the
#   1080p and 4K paths treat the same source identically. Defaults by year parsed from the
#   filename: pre-2000 → none (preserve grain), 2000+ → spatial.
#   "none"    — spp deblock only, no hqdn3d (preserve film grain; best for pre-2000 film)
#   "spatial" — spp deblock + hqdn3d=2:1.5:0:0 (per-frame spatial only)
#   "full"    — spp deblock + hqdn3d=2:1.5:6:4.5 (spatial + temporal)
#
# postfilter: ffmpeg -vf expression applied to upscaled frames before the final resize.
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

OUT_W=1920
OUT_H=1080
SCALE=2
SPAN_MODEL="/usr/local/share/span-models/2xNomosUni_span_multijpg.safetensors"
SPAN_PY="/home/evanna/.venvs/span-upscale/bin/python3"   # spandrel venv over the system ROCm torch
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
WORK_DIR="/tmp/upscale_work_$$"
SEGMENTS_DIR="/tmp/upscale_segments_$$"
SWS="lanczos+accurate_rnd+full_chroma_int"

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

SRC_W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width \
    -of default=noprint_wrappers=1:nokey=1 "$INPUT")
SRC_H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height \
    -of default=noprint_wrappers=1:nokey=1 "$INPUT")
SPAN_W=$((SRC_W * SCALE))
SPAN_H=$((SRC_H * SCALE))

echo "=== Live-Action 16:9 Upscaler: native → 1080p ==="
echo "Input:    $INPUT"
echo "Output:   $OUTPUT"
echo "Model:    SPAN 2xNomosUni_span_multijpg (2x, live-action, PyTorch/ROCm fp16)"
echo "Pipeline: ${SRC_W}x${SRC_H} → 2x → ${SPAN_W}x${SPAN_H} → lanczos → ${OUT_W}x${OUT_H} (raw pipe, VFR timestamps kept)"
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
# ffmpeg rebases timestamps to (start_time + -ss); mkvmerge keeps the source's
# audio at its original timestamps, so add start_time back when stamping video.
SRC_START=$(ffprobe -v error -show_entries format=start_time \
    -of default=noprint_wrappers=1:nokey=1 "$INPUT")
[[ "$SRC_START" =~ ^-?[0-9.]+$ ]] || SRC_START=0
CHUNK_SEC=$((CHUNK_MIN * 60))
TOTAL_CHUNKS=$(( (DURATION + CHUNK_SEC - 1) / CHUNK_SEC ))

echo "Duration: ${DURATION}s  FPS: $FPS_ROUNDED  Chunks: $TOTAL_CHUNKS  Start: ${SRC_START}s"

IVTC_CHAIN=$(detect_ivtc_chain "$INPUT" "$DURATION")
if [[ "$IVTC_CHAIN" == fieldmatch* ]]; then
    echo "Telecine: 3:2 pulldown detected — IVTC enabled"
else
    echo "Telecine: none — IVTC disabled, no frame decimation (progressive source)"
fi
echo ""

mkdir -p "$WORK_DIR" "$SEGMENTS_DIR"

# cleanup must NEVER touch SEGMENTS_DIR (per-chunk segments there survive a
# crash and drive a resume).
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# One "segment_NNNN <chunk start seconds>" line per finished chunk, in order.
SEGMENT_LIST="$SEGMENTS_DIR/segments.txt"
> "$SEGMENT_LIST"

POSTFILTER_VF=""
if [[ "$POSTFILTER" != "none" ]]; then
    POSTFILTER_VF="${POSTFILTER},"
fi

fail() {
    echo "  ERROR: $*"
    echo "=== segments preserved in $SEGMENTS_DIR ==="
    exit 1
}

CHUNK=0
START=0

while [ "$START" -lt "$DURATION" ]; do
    CHUNK=$((CHUNK + 1))
    END=$((START + CHUNK_SEC))
    [ "$END" -gt "$DURATION" ] && END=$DURATION
    SEG="$SEGMENTS_DIR/segment_$(printf '%04d' $CHUNK)"

    CHUNK_START=$(date +%s)
    ts "[Chunk $CHUNK/$TOTAL_CHUNKS] ${START}s → ${END}s"

    # Decode → SPAN → x265 as one pipe. Extract: IVTC only if telecined (see
    # detect_ivtc_chain), trim to [0, CHUNK_SEC) of chunk-relative time (input -t
    # overshoots by 2s so yadif/decimate see the boundary frames), spp DCT-aware
    # deblock + year-gated hqdn3d, showinfo to log each frame's pts, then rgb24
    # (BT.601 source matrix). Encode: postfilter at SPAN resolution (cheaper), one
    # lanczos resize to the target with an explicit BT.709 matrix, x265 to a bare
    # HEVC stream — the -framerate is nominal; real timestamps are applied at mux.
    ffmpeg -nostdin -hide_banner -nostats -ss "$START" -t "$((CHUNK_SEC + 2))" -i "$INPUT" \
        -map 0:v:0 -an -sn \
        -vf "${IVTC_CHAIN}trim=end=${CHUNK_SEC},spp=quality=4${DENOISE_VF},showinfo" \
        -fps_mode passthrough -sws_flags "$SWS" \
        -f rawvideo -pix_fmt rgb24 - \
        2> "$WORK_DIR/extract_$CHUNK.log" \
    | HSA_OVERRIDE_GFX_VERSION=10.3.0 "$SPAN_PY" "$SCRIPT_DIR/span-upscale.py" \
        --width "$SRC_W" --height "$SRC_H" \
        --model "$SPAN_MODEL" --fp16 \
        --count-file "$WORK_DIR/count_$CHUNK" \
        2> "$WORK_DIR/upscale_$CHUNK.log" \
    | ffmpeg -nostdin -hide_banner -y \
        -f rawvideo -pix_fmt rgb24 -s "${SPAN_W}x${SPAN_H}" -framerate 24000/1001 -i - \
        -vf "${POSTFILTER_VF}scale=${OUT_W}:${OUT_H}:flags=lanczos:out_color_matrix=bt709:out_range=tv,setsar=1" \
        -sws_flags "$SWS" \
        -c:v libx265 -crf 18 -preset medium -pix_fmt yuv420p \
        -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
        -f hevc "$SEG.hevc" \
        2> "$WORK_DIR/encode_$CHUNK.log"
    RCS=("${PIPESTATUS[@]}")

    grep -oE 'showinfo.* pts_time:-?[0-9.e+-]+' "$WORK_DIR/extract_$CHUNK.log" \
        | sed 's/.*pts_time://' > "$SEG.pts"
    PTS_COUNT=$(wc -l < "$SEG.pts")
    grep -E "SPAN|Done:|ERROR" "$WORK_DIR/upscale_$CHUNK.log"

    if [ "${RCS[0]}" -eq 0 ] && [ "$PTS_COUNT" -eq 0 ]; then
        echo "  No frames in chunk, skipping."
        rm -f "$SEG.hevc" "$SEG.pts"
        START=$END
        continue
    fi
    if [ "${RCS[0]}" -ne 0 ] || [ "${RCS[1]}" -ne 0 ] || [ "${RCS[2]}" -ne 0 ]; then
        echo "  --- tail of extract_$CHUNK.log ---"; grep -v showinfo "$WORK_DIR/extract_$CHUNK.log" | tail -8
        echo "  --- tail of upscale_$CHUNK.log ---"; tail -8 "$WORK_DIR/upscale_$CHUNK.log"
        echo "  --- tail of encode_$CHUNK.log ---"; tail -8 "$WORK_DIR/encode_$CHUNK.log"
        rm -f "$SEG.hevc" "$SEG.pts"
        fail "chunk $CHUNK pipeline failed (extract=${RCS[0]} span=${RCS[1]} encode=${RCS[2]})"
    fi

    # Every stage must agree on the frame count — a mismatch means the timestamp
    # file no longer lines up with the encoded frames.
    SPAN_COUNT=$(cat "$WORK_DIR/count_$CHUNK" 2>/dev/null || echo 0)
    ENC_COUNT=$(ffprobe -v error -select_streams v:0 -count_packets \
        -show_entries stream=nb_read_packets -of default=noprint_wrappers=1:nokey=1 "$SEG.hevc")
    echo "  Frames: $PTS_COUNT decoded, $SPAN_COUNT upscaled, $ENC_COUNT encoded"
    if [ "$PTS_COUNT" -ne "$SPAN_COUNT" ] || [ "$PTS_COUNT" -ne "$ENC_COUNT" ]; then
        rm -f "$SEG.hevc" "$SEG.pts"
        fail "frame count mismatch in chunk $CHUNK"
    fi

    echo "$(basename "$SEG") $START" >> "$SEGMENT_LIST"
    ts "  Chunk $CHUNK done in $(( $(date +%s) - CHUNK_START ))s ($(echo "scale=2; $PTS_COUNT / ($(date +%s) - $CHUNK_START + 1)" | bc) fps) — segment saved: $(basename "$SEG").hevc"

    START=$END
done

echo ""
FINAL_TMP="/tmp/upscale_final_$$.mkv"
ALL_HEVC="$WORK_DIR/video.hevc"
ALL_TS="$WORK_DIR/timestamps.txt"
ts "[Final] Joining $(wc -l < "$SEGMENT_LIST") segments + stamping per-frame timestamps..."

# Each segment starts with an IDR + parameter sets, so the bare streams concatenate
# into one valid HEVC stream. Timestamps become absolute ms (chunk start + frame
# pts + source start_time), then get a [1,2,1]/4 smoothing: soft-telecined DVD film
# decodes with alternating 33/50 ms frame spacing (the 3:2 field cadence), which the
# smoothing turns into an even 41.7 ms (true 23.976 — smooth playback, and players
# report 23.976 fps) while uniformly spaced 29.97 video sections pass through
# unchanged. It preserves order and moves a frame by at most a quarter of the
# local spacing difference (~4 ms on 3:2 cadence), far inside lip-sync tolerance.
# Any frame not strictly after its predecessor is nudged 1 µs forward (there
# should be none — logged if it happens).
> "$ALL_HEVC"
echo "# timestamp format v2" > "$ALL_TS"
while read -r seg start; do
    cat "$SEGMENTS_DIR/$seg.hevc" >> "$ALL_HEVC" || fail "joining $seg.hevc"
    awk -v off="$start" -v s0="$SRC_START" '{ printf "%.6f\n", (off + s0 + $1) * 1000 }' \
        "$SEGMENTS_DIR/$seg.pts" >> "$ALL_TS"
done < "$SEGMENT_LIST"
awk 'NR == 1 { print; next }
     { t[++n] = $1 }
     END {
         for (i = 1; i <= n; i++) {
             s = (i == 1 || i == n) ? t[i] : (t[i-1] + 2 * t[i] + t[i+1]) / 4
             if (i > 1 && s <= prev) { s = prev + 0.001; fixed++ }
             printf "%.6f\n", s; prev = s
         }
         if (fixed) print "  WARNING: nudged " fixed " non-increasing timestamps" > "/dev/stderr"
     }' "$ALL_TS" > "$ALL_TS.fixed" && mv "$ALL_TS.fixed" "$ALL_TS"

ts "[Final] Muxing video + source audio/subtitles/chapters with mkvmerge..."
mkvmerge -o "$FINAL_TMP" \
    --title "$(basename "$INPUT" .mkv) [upscaled 1080p]" \
    --timestamps "0:$ALL_TS" "$ALL_HEVC" \
    -D "$INPUT" 2>&1 | grep -E "Progress: 100%|Warning|Error" | tail -3
MKVMERGE_EXIT=${PIPESTATUS[0]}
if [ "$MKVMERGE_EXIT" -ge 2 ] || [ ! -s "$FINAL_TMP" ]; then
    rm -f "$FINAL_TMP"
    fail "mkvmerge failed (exit $MKVMERGE_EXIT)"
fi

# Copy beside the destination, then rename: the old output is only replaced once
# the new one is fully written.
ts "[Final] Copying to destination..."
if ! cp "$FINAL_TMP" "$OUTPUT.part" || ! mv -f "$OUTPUT.part" "$OUTPUT"; then
    rm -f "$OUTPUT.part"
    echo "=== ERROR: copy to $OUTPUT failed — muxed file preserved at $FINAL_TMP ==="
    exit 1
fi
rm -f "$FINAL_TMP"
rm -rf "$SEGMENTS_DIR"

echo ""
ts "=== Done! ==="
ffprobe "$OUTPUT" 2>&1 | grep -E "Duration|Video:|Audio:"
ls -lh "$OUTPUT"
