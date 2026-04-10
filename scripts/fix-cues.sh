#!/bin/bash
# Rebuild MKV cue index on upscaled files using mkvmerge.
# No re-encoding — pure container remux. Fixes seeking/audio dropout in Infuse.
# Usage: ./fix-cues.sh [directory]   (default: /mnt/jellyfin-movies)

DIR="${1:-/mnt/jellyfin-movies}"
FIXED=0
SKIPPED=0
FAILED=0

ts() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

echo "=== MKV Cue Rebuild: remux [upscaled] files with mkvmerge ==="
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
    TMPFILE="${INPUT%.mkv}.remuxing.mkv"

    if fuser "$INPUT" &>/dev/null; then
        ts "SKIP (file in use): $BASENAME"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Check if already remuxed by mkvmerge (writing app contains "mkvmerge")
    WRITING_APP=$(mkvinfo "$INPUT" 2>/dev/null | grep "Writing application" | head -1)
    if echo "$WRITING_APP" | grep -q "mkvmerge"; then
        ts "SKIP (already mkvmerge-remuxed): $BASENAME"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    ts "Processing (ffmpeg concat cues are empty → rebuilding): $BASENAME"
    START_T=$(date +%s)

    mkvmerge -o "$TMPFILE" "$INPUT" 2>&1 | grep -E "Progress|Warning|Error" | tail -5

    RC=$?
    ELAPSED=$(( $(date +%s) - START_T ))

    if [ $RC -ne 0 ] || [ ! -s "$TMPFILE" ]; then
        ts "  ERROR: mkvmerge failed (rc=$RC) — original untouched"
        rm -f "$TMPFILE"
        FAILED=$((FAILED + 1))
        continue
    fi

    # Verify mkvmerge wrote the cues by checking the writing application
    NEW_WRITING_APP=$(mkvinfo "$TMPFILE" 2>/dev/null | grep "Writing application" | head -1)
    if ! echo "$NEW_WRITING_APP" | grep -q "mkvmerge"; then
        ts "  ERROR: output was not written by mkvmerge — original untouched"
        rm -f "$TMPFILE"
        FAILED=$((FAILED + 1))
        continue
    fi

    mv "$TMPFILE" "$INPUT"
    ts "  Done in ${ELAPSED}s"
    FIXED=$((FIXED + 1))
done

echo ""
echo "=== Summary ==="
echo "  Fixed:   $FIXED"
echo "  Skipped: $SKIPPED"
echo "  Failed:  $FAILED"
