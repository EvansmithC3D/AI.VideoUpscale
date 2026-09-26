#!/bin/bash
# Upscale animated widescreen (16:9) MKV to 4K (3840x2160) via two Real-ESRGAN animevideov3 passes
# Per chunk: source → 960x540 → 2x → 1920x1080 → 2x → 3840x2160, both passes on the same
# extracted frames (no intermediate file, no lossy re-encode between passes)
# Preprocessing: IVTC (3:2 pulldown) or yadif deinterlace (DVD sources). (The old spp
# deblock was a silent no-op — ffmpeg gives it no QP tables — and has been removed.)
# Timing: every frame keeps its real timestamp (lib/vfr-timing.sh); rerunning the
# same job resumes after the last finished chunk.
# Usage: ./upscale-anime-16x9-4k.sh "input.mkv" "output.mkv" [chunk_minutes=2]

INPUT="$1"
OUTPUT="$2"
CHUNK_MIN="${3:-2}"   # 2-min chunks: 4K PNGs are large (~25 GB /tmp per chunk in flight)

HALF_W=960
HALF_H=540
SCALE=2
MODEL="realesr-animevideov3-x2"
MODEL_PATH="/usr/local/share/realesrgan-models"
WORK_DIR="/tmp/upscale_work_$$"
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
. "$SCRIPT_DIR/lib/vfr-timing.sh"
SEGMENTS_DIR=$(vfr_segments_dir "$INPUT")

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
        if vfr_has_soft_pulldown "$input" "$dur"; then
            # Mixed soft/hard telecine: decimate would drop real frames and
            # re-time them (see vfr_has_soft_pulldown); deinterlace only.
            echo "Telecine: repeated fields found, but soft pulldown present — IVTC skipped" >&2
            echo "yadif=mode=0:parity=-1:deint=all,"
            return
        fi
        echo "fieldmatch=order=auto:combmatch=sc,yadif=mode=0:parity=-1:deint=all,decimate,"
    else
        echo "yadif=mode=0:parity=-1:deint=all,"
    fi
}

echo "=== Anime 16:9 4K Upscaler: source → 1920x1080 → 3840x2160 (two 2x passes per chunk) ==="
echo "Input:    $INPUT"
echo "Output:   $OUTPUT"
echo "Model:    $MODEL (2x × 2 passes, anime video)"
echo "Pipeline: ${HALF_W}x${HALF_H} → 2x → $((HALF_W * 2))x$((HALF_H * 2)) → 2x → $((HALF_W * 4))x$((HALF_H * 4))"
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

echo "Duration: ${DURATION}s  FPS: $FPS_ROUNDED  Chunks: $TOTAL_CHUNKS"

IVTC_CHAIN=$(detect_ivtc_chain "$INPUT" "$DURATION")
if [[ "$IVTC_CHAIN" == fieldmatch* ]]; then
    echo "Telecine: 3:2 pulldown detected — IVTC enabled"
else
    echo "Telecine: none — IVTC disabled, no frame decimation (progressive source)"
fi
echo ""

SRC_START=$(vfr_src_start "$INPUT")
mkdir -p "$WORK_DIR/frames" "$WORK_DIR/upscaled" "$WORK_DIR/upscaled4k"
FINGERPRINT="$(basename "$0")|$(stat -c '%s %Y' "$INPUT")|$CHUNK_SEC|$IVTC_CHAIN|$MODEL|${HALF_W}x${HALF_H}"
DONE_CHUNKS=$(vfr_resume_init "$SEGMENTS_DIR" "$FINGERPRINT")
[ "$DONE_CHUNKS" -gt 0 ] && echo "Resuming: $DONE_CHUNKS chunk(s) already done in $SEGMENTS_DIR"

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

CHUNK=0
START=0
SEGMENT_LIST="$SEGMENTS_DIR/segments.txt"

while [ "$START" -lt "$DURATION" ]; do
    CHUNK=$((CHUNK + 1))
    END=$((START + CHUNK_SEC))
    [ "$END" -gt "$DURATION" ] && END=$DURATION
    # Chunks are cut at CHUNK_SEC; the final chunk runs uncapped to EOF (DURATION is
    # truncated to whole seconds, so a cap there could drop the last frames).
    CHUNK_LIMIT=$CHUNK_SEC
    [ "$END" -ge "$DURATION" ] && CHUNK_LIMIT=$((CHUNK_SEC + 86400))
    SEG="$SEGMENTS_DIR/segment_$(printf '%04d' $CHUNK)"
    if [ "$CHUNK" -le "$DONE_CHUNKS" ]; then
        START=$END
        continue
    fi

    CHUNK_START=$(date +%s)
    ts "[Chunk $CHUNK/$TOTAL_CHUNKS] ${START}s → ${END}s"

    rm -rf "$WORK_DIR/frames" "$WORK_DIR/upscaled" "$WORK_DIR/upscaled4k"
    mkdir -p "$WORK_DIR/frames" "$WORK_DIR/upscaled" "$WORK_DIR/upscaled4k"

    # Extract frames: IVTC only if telecined (see detect_ivtc_chain), trim to this
    # chunk's [0, CHUNK_SEC) (input -t overshoots 2s so yadif/decimate see the
    # boundary), scale to ${HALF_W}x${HALF_H} (corrects the anamorphic DAR), and log each
    # frame's real pts via showinfo — the encode's frame rate is nominal; real
    # timestamps are stamped back at the final mux.
    ffmpeg -y -nostdin -nostats -ss "$START" -t "$((CHUNK_LIMIT + 2))" -i "$INPUT" \
        -map 0:v:0 -an -sn \
        -vf "${IVTC_CHAIN}trim=end=${CHUNK_LIMIT},scale=${HALF_W}:${HALF_H}:flags=lanczos,showinfo" \
        -fps_mode passthrough -q:v 1 -compression_level 1 \
        "$WORK_DIR/frames/frame_%08d.png" > "$WORK_DIR/extract_$CHUNK.log" 2>&1
    EXTRACT_EXIT=$?
    PTS_COUNT=$(vfr_save_pts "$WORK_DIR/extract_$CHUNK.log" "$SEG.pts")

    FRAME_COUNT=$(ls "$WORK_DIR/frames" | wc -l)
    echo "  Frames: $FRAME_COUNT"

    if [ "$EXTRACT_EXIT" -ne 0 ]; then
        echo "  ERROR: frame extraction failed (exit $EXTRACT_EXIT) — segments preserved in $SEGMENTS_DIR"
        grep -v showinfo "$WORK_DIR/extract_$CHUNK.log" | tail -5
        rm -f "$SEG.pts"
        exit 1
    fi
    if [ "$FRAME_COUNT" -eq 0 ]; then
        echo "  No frames extracted, skipping."
        rm -f "$SEG.pts"
        START=$END
        continue
    fi
    if [ "$PTS_COUNT" -ne "$FRAME_COUNT" ]; then
        echo "  ERROR: $PTS_COUNT timestamps for $FRAME_COUNT frames — segments preserved in $SEGMENTS_DIR"
        rm -f "$SEG.pts"
        exit 1
    fi

    # Upscale — animevideov3 is purpose-built for video frames (better temporal consistency than cunet)
    UPSCALE_LOG="$WORK_DIR/upscale_$CHUNK.log"
    realesrgan-ncnn-vulkan \
        -i "$WORK_DIR/frames" \
        -o "$WORK_DIR/upscaled" \
        -n "$MODEL" \
        -m "$MODEL_PATH" \
        -s "$SCALE" \
        -t 0 \
        -g 0 -j 2:4:4 \
        -f png > "$UPSCALE_LOG" 2>&1
    UPSCALE_EXIT=$?
    tail -3 "$UPSCALE_LOG"

    if [ "$UPSCALE_EXIT" -ne 0 ]; then
        echo "  ERROR: realesrgan failed (exit $UPSCALE_EXIT) — segments preserved in $SEGMENTS_DIR"
        exit 1
    fi

    UPSCALED_COUNT=$(ls "$WORK_DIR/upscaled" | wc -l)
    echo "  Upscaled frames: $UPSCALED_COUNT"
    if [ "$UPSCALED_COUNT" -ne "$FRAME_COUNT" ]; then
        echo "  ERROR: upscaled count ($UPSCALED_COUNT) != extracted ($FRAME_COUNT) — segments preserved in $SEGMENTS_DIR"
        exit 1
    fi
    rm -rf "$WORK_DIR/frames"

    # Pass 2 on the pass-1 PNGs. -t 0: no tile limit — 12GB VRAM handles 1080p input in one shot.
    UPSCALE2_LOG="$WORK_DIR/upscale2_$CHUNK.log"
    realesrgan-ncnn-vulkan \
        -i "$WORK_DIR/upscaled" \
        -o "$WORK_DIR/upscaled4k" \
        -n "$MODEL" \
        -m "$MODEL_PATH" \
        -s "$SCALE" \
        -t 0 \
        -g 0 -j 2:4:4 \
        -f png > "$UPSCALE2_LOG" 2>&1
    UPSCALE2_EXIT=$?
    tail -3 "$UPSCALE2_LOG"
    UPSCALED4K_COUNT=$(ls "$WORK_DIR/upscaled4k" | wc -l)
    echo "  Pass 2 frames: $UPSCALED4K_COUNT"
    if [ "$UPSCALE2_EXIT" -ne 0 ] || [ "$UPSCALED4K_COUNT" -ne "$FRAME_COUNT" ]; then
        echo "  ERROR: pass 2 failed (exit $UPSCALE2_EXIT; $UPSCALED4K_COUNT/$FRAME_COUNT frames) — segments preserved in $SEGMENTS_DIR"
        exit 1
    fi
    rm -rf "$WORK_DIR/upscaled"

    # RGB → BT.709 matrix (HD), tagged; bare HEVC stream, nominal rate (see extract).
    ENCODE_LOG="$WORK_DIR/encode_$CHUNK.log"
    ffmpeg -y -nostdin \
        -framerate 24000/1001 \
        -i "$WORK_DIR/upscaled4k/frame_%08d.png" \
        -vf "scale=out_color_matrix=bt709:out_range=tv" \
        -c:v libx265 -crf 18 -preset medium -pix_fmt yuv420p \
        -x265-params "keyint=48:min-keyint=24" \
        -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
        -f hevc "$SEG.hevc" > "$ENCODE_LOG" 2>&1
    ENCODE_EXIT=$?
    ENC_COUNT=$(ffprobe -v error -select_streams v:0 -count_packets \
        -show_entries stream=nb_read_packets -of default=noprint_wrappers=1:nokey=1 "$SEG.hevc" 2>/dev/null)

    if [ "$ENCODE_EXIT" -ne 0 ] || [ "$ENC_COUNT" != "$FRAME_COUNT" ]; then
        echo "  ERROR: segment encoding failed (ffmpeg exit $ENCODE_EXIT, $ENC_COUNT/$FRAME_COUNT frames) — segments preserved in $SEGMENTS_DIR"
        tail -5 "$ENCODE_LOG"
        rm -f "$SEG.hevc" "$SEG.pts"
        exit 1
    fi

    echo "$(basename "$SEG") $START" >> "$SEGMENT_LIST"
    CHUNK_ELAPSED=$(( $(date +%s) - CHUNK_START ))
    ts "  Chunk $CHUNK done in ${CHUNK_ELAPSED}s — segment saved: $(basename "$SEG").hevc"
    START=$END
done

echo ""
FINAL_TMP="/tmp/upscale_final_$$.mkv"
ts "[Final] Joining $(wc -l < "$SEGMENT_LIST") segments + stamping per-frame timestamps..."
if ! vfr_build_video "$SEGMENTS_DIR" "$SRC_START" "$WORK_DIR/video.hevc" "$WORK_DIR/timestamps.txt"; then
    echo "=== ERROR: joining segments failed — segments preserved in $SEGMENTS_DIR ==="
    exit 1
fi
ts "[Final] Muxing video + source audio/subtitles/chapters with mkvmerge..."
if ! vfr_mux "$WORK_DIR/video.hevc" "$WORK_DIR/timestamps.txt" "$INPUT" \
        "$(basename "$INPUT" .mkv) [anime 16:9 upscaled 4K]" "$FINAL_TMP"; then
    rm -f "$FINAL_TMP"
    echo "=== ERROR: mkvmerge failed — segments preserved in $SEGMENTS_DIR ==="
    exit 1
fi
ts "[Final] Copying to destination..."
vfr_install "$FINAL_TMP" "$OUTPUT" || exit 1
rm -rf "$SEGMENTS_DIR"

echo ""
ts "=== Done! ==="
ffprobe "$OUTPUT" 2>&1 | grep -E "Duration|Video:|Audio:"
ls -lh "$OUTPUT"
