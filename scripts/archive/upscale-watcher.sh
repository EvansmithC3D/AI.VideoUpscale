#!/bin/bash
LOGFILE="/home/evanna/upscale-pokemon.log"
OUTPUT="/mnt/jellyfin-movies/Pokemon The First Movie (1998) [upscaled].mkv"
RESULTFILE="/home/evanna/upscale-result.txt"

echo "Watcher started at $(date)" > "$RESULTFILE"

while true; do
    if grep -q "=== Done! ===" "$LOGFILE" 2>/dev/null; then
        echo "=== UPSCALE COMPLETE at $(date) ===" >> "$RESULTFILE"
        ffprobe "$OUTPUT" 2>&1 | grep -E "Duration|Video:|Audio:" >> "$RESULTFILE"
        ls -lh "$OUTPUT" >> "$RESULTFILE"
        echo "File written to Jellyfin successfully." >> "$RESULTFILE"
        break
    elif grep -q "Error\|error\|failed" "$LOGFILE" 2>/dev/null; then
        echo "=== ERROR DETECTED at $(date) ===" >> "$RESULTFILE"
        tail -20 "$LOGFILE" >> "$RESULTFILE"
        break
    fi
    sleep 60
done
