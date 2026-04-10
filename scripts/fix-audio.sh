#!/bin/bash
# Re-mux upscaled MKV files: copy video, transcode audio to EAC3 for Infuse seek compatibility.
# Video stream is copied bit-for-bit — no quality loss, no GPU needed.
# Usage: ./fix-audio.sh [directory]   (default: /mnt/jellyfin-movies)

DIR="${1:-/mnt/jellyfin-movies}"
FIXED=0
SKIPPED=0
FAILED=0

ts() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

echo "=== Audio Fix: re-mux [upscaled] files with EAC3 ==="
echo "Directory: $DIR"
echo ""

mapfile -t FILES < <(find "$DIR" -maxdepth 2 -name "*\[upscaled\].mkv" | sort)

if [ ${#FILES[@]} -eq 0 ]; then
    echo "No [upscaled].mkv files found in $DIR"
    exit 0
fi

echo "Found ${#FILES[@]} file(s):"
for f in "${FILES[@]}"; do
    echo "  $f"
done
echo ""

for INPUT in "${FILES[@]}"; do
    BASENAME=$(basename "$INPUT")
    TMPFILE="${INPUT%.mkv}.fixing.mkv"

    # Skip if another process has the file open for writing (e.g. an active upscale job)
    if fuser "$INPUT" &>/dev/null; then
        ts "SKIP (file in use): $BASENAME"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    ts "Processing: $BASENAME"

    # Probe existing audio codec
    AUDIO_CODEC=$(ffprobe -v error -select_streams a:0 \
        -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 "$INPUT" 2>/dev/null)
    echo "  Audio codec: ${AUDIO_CODEC:-unknown}"

    if [ "$AUDIO_CODEC" = "eac3" ]; then
        ts "  Already EAC3 — skipping"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    START_T=$(date +%s)

    ffmpeg -y -i "$INPUT" \
        -c:v copy \
        -c:a eac3 \
        -c:s copy \
        "$TMPFILE" 2>&1 | grep -E "time=|Error" | tail -3

    RC=$?
    ELAPSED=$(( $(date +%s) - START_T ))

    if [ $RC -ne 0 ] || [ ! -s "$TMPFILE" ]; then
        ts "  ERROR: ffmpeg failed (rc=$RC) — original untouched"
        rm -f "$TMPFILE"
        FAILED=$((FAILED + 1))
        continue
    fi

    # Verify output has video + audio
    OUT_VIDEO=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 "$TMPFILE" 2>/dev/null)
    OUT_AUDIO=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 "$TMPFILE" 2>/dev/null)

    if [ -z "$OUT_VIDEO" ] || [ -z "$OUT_AUDIO" ]; then
        ts "  ERROR: output missing streams (video=$OUT_VIDEO audio=$OUT_AUDIO) — original untouched"
        rm -f "$TMPFILE"
        FAILED=$((FAILED + 1))
        continue
    fi

    mv "$TMPFILE" "$INPUT"
    ts "  Done in ${ELAPSED}s  (video=$OUT_VIDEO  audio=$OUT_AUDIO)"
    FIXED=$((FIXED + 1))
done

echo ""
echo "=== Summary ==="
echo "  Fixed:   $FIXED"
echo "  Skipped: $SKIPPED"
echo "  Failed:  $FAILED"
