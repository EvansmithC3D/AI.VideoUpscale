#!/bin/bash
# Upscale Queue Daemon
# Continuously scans MEDIA_DIR for unupscaled MKVs and processes them one at a time.
#
# Queue file format (one entry per line):
#   STATUS|TYPE|RESOLUTION|/absolute/path/to/file.mkv[|DENOISE]
#   STATUS     : pending, done, error, skip
#   TYPE       : live, anime
#   RESOLUTION : 1080p, 4k
#   DENOISE    : none, spatial, full  (optional; live 4k only — omit to use year-based default)
#
# New files are auto-discovered; TYPE is detected automatically (live/anime).
# Override TYPE, RESOLUTION, or DENOISE in queue.txt before the daemon picks up an entry.
# DENOISE year-based default: pre-2000 film → none (preserve grain), 2000+ → spatial.
#
# Usage:
#   nohup bash scripts/queue-daemon.sh >> /home/evanna/upscale-queue.log 2>&1 &

QUEUE_FILE="$(dirname "$(realpath "$0")")/../queue.txt"
MEDIA_DIR="/mnt/jellyfin-movies"
LOG_DIR="/home/evanna"
SCRIPTS_DIR="$(dirname "$(realpath "$0")")"
SCAN_INTERVAL=120   # seconds between idle scans

# Optional: set TMDB_API_KEY in environment to enable TMDB genre lookups.
# e.g. export TMDB_API_KEY=your_key_here  (add to ~/.bashrc or ~/.profile)
# Without it the daemon falls back to MKV tags then Japanese-audio heuristic.
TMDB_API_KEY="${TMDB_API_KEY:-}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ---------------------------------------------------------------------------
# Ensure queue file exists
# ---------------------------------------------------------------------------
if [ ! -f "$QUEUE_FILE" ]; then
    cat > "$QUEUE_FILE" <<'EOF'
# Upscale queue — edit TYPE, RESOLUTION, or DENOISE before the daemon picks up a title
# STATUS|TYPE|RESOLUTION|/absolute/path/to/file.mkv[|DENOISE]
# STATUS     : pending, done, error, skip
# TYPE       : live, anime
# RESOLUTION : 1080p, 4k
# DENOISE    : none, spatial, full  (optional; live 4k only; omit for year-based default)
EOF
    log "Created queue file: $QUEUE_FILE"
fi

# ---------------------------------------------------------------------------
# Derive a short log-friendly slug from a file path
#   /mnt/jellyfin-movies/Manhunter (1986).mkv → upscale-manhunter-1986
# ---------------------------------------------------------------------------
log_slug() {
    local path="$1"
    basename "$path" .mkv \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9]/-/g' \
        | sed 's/-\+/-/g' \
        | sed 's/^-//;s/-$//'
}

# ---------------------------------------------------------------------------
# Detect content type: "anime" or "live"
# Priority: MKV genre tag → TMDB API → Japanese audio → default live
# ---------------------------------------------------------------------------
detect_type() {
    local input="$1"

    # 1. MKV embedded genre tag
    local genre
    genre=$(ffprobe -v quiet -print_format json -show_format "$input" 2>/dev/null \
        | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('format', {}).get('tags', {}).get('genre', '').lower())
" 2>/dev/null)
    if echo "$genre" | grep -qiE "anim"; then
        echo "anime"; return
    fi

    # 2. TMDB lookup (requires TMDB_API_KEY)
    local filename="${1##*/}"   # basename
    filename="${filename%.mkv}"
    if [[ -n "$TMDB_API_KEY" && "$filename" =~ ^(.+)\ \(([0-9]{4})\)$ ]]; then
        local title="${BASH_REMATCH[1]}" year="${BASH_REMATCH[2]}"
        local encoded_title
        encoded_title=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$title" 2>/dev/null)
        local response
        response=$(curl -sf --max-time 10 \
            "https://api.themoviedb.org/3/search/movie?api_key=${TMDB_API_KEY}&query=${encoded_title}&year=${year}" \
            2>/dev/null)
        if [[ -n "$response" ]]; then
            local result
            result=$(echo "$response" | python3 -c "
import sys, json
d = json.load(sys.stdin)
results = d.get('results', [])
# genre_id 16 = Animation in TMDB
print('anime' if results and 16 in results[0].get('genre_ids', []) else 'live')
" 2>/dev/null)
            if [[ "$result" == "anime" || "$result" == "live" ]]; then
                echo "$result"; return
            fi
        fi
    fi

    # 3. Japanese audio track heuristic
    local has_jpn
    has_jpn=$(ffprobe -v quiet -print_format json -show_streams "$input" 2>/dev/null \
        | python3 -c "
import sys, json
d = json.load(sys.stdin)
jpn = any(s.get('tags', {}).get('language', '') in ('jpn', 'ja')
          for s in d.get('streams', []))
print('yes' if jpn else 'no')
" 2>/dev/null)
    if [[ "$has_jpn" == "yes" ]]; then
        echo "anime"; return
    fi

    echo "live"
}

# ---------------------------------------------------------------------------
# Determine aspect ratio category: "16x9" or "4x3"
# ---------------------------------------------------------------------------
aspect_category() {
    local input="$1"
    local dar
    dar=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=display_aspect_ratio \
        -of default=noprint_wrappers=1:nokey=1 "$input" 2>/dev/null)

    # Parse DAR as a decimal ratio
    local ratio
    if [[ "$dar" =~ ^([0-9]+):([0-9]+)$ ]]; then
        local w=${BASH_REMATCH[1]} h=${BASH_REMATCH[2]}
        ratio=$(awk "BEGIN { printf \"%.4f\", $w/$h }")
    else
        # Fall back to stream dimensions
        local dims
        dims=$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=width,height \
            -of csv=p=0 "$input" 2>/dev/null)
        local w h
        IFS=',' read -r w h <<< "$dims"
        if [[ -z "$w" || -z "$h" || "$h" -eq 0 ]]; then
            echo "unknown"
            return
        fi
        ratio=$(awk "BEGIN { printf \"%.4f\", $w/$h }")
    fi

    # 16:9 ≈ 1.778 ± 0.1, 4:3 ≈ 1.333 ± 0.1
    if awk "BEGIN { exit !($ratio > 1.6) }"; then
        echo "16x9"
    elif awk "BEGIN { exit !($ratio > 1.2 && $ratio <= 1.6) }"; then
        echo "4x3"
    else
        echo "unknown"
    fi
}

# ---------------------------------------------------------------------------
# Select script path given type, resolution, aspect
# ---------------------------------------------------------------------------
select_script() {
    local type="$1" res="$2" aspect="$3"
    local script=""
    if   [ "$type" = "anime"  ] && [ "$res" = "1080p" ] && [ "$aspect" = "16x9" ]; then script="upscale-anime-16x9.sh"
    elif [ "$type" = "anime"  ] && [ "$res" = "1080p" ] && [ "$aspect" = "4x3"  ]; then script="upscale-anime-4x3.sh"
    elif [ "$type" = "anime"  ] && [ "$res" = "4k"    ] && [ "$aspect" = "16x9" ]; then script="upscale-anime-16x9-4k.sh"
    elif [ "$type" = "anime"  ] && [ "$res" = "4k"    ] && [ "$aspect" = "4x3"  ]; then script="upscale-anime-4x3-4k.sh"
    elif [ "$type" = "live"   ] && [ "$res" = "1080p" ] && [ "$aspect" = "16x9" ]; then script="upscale-live-16x9.sh"
    elif [ "$type" = "live"   ] && [ "$res" = "1080p" ] && [ "$aspect" = "4x3"  ]; then script="upscale-live-4x3.sh"
    elif [ "$type" = "live"   ] && [ "$res" = "4k"    ] && [ "$aspect" = "16x9" ]; then script="upscale-live-16x9-4k.sh"
    elif [ "$type" = "live"   ] && [ "$res" = "4k"    ] && [ "$aspect" = "4x3"  ]; then script="upscale-live-4x3-4k.sh"
    fi
    echo "$SCRIPTS_DIR/$script"
}

# ---------------------------------------------------------------------------
# Push queue.txt to GitHub after a status change so the remote monitor agent
# can read current state and reset errors to pending.
# Silently no-ops if git isn't configured or the push fails.
# ---------------------------------------------------------------------------
git_push_status() {
    local msg="$1"
    local repo_dir
    repo_dir=$(dirname "$QUEUE_FILE")
    git -C "$repo_dir" add queue.txt 2>/dev/null || return
    git -C "$repo_dir" diff --cached --quiet 2>/dev/null && return  # nothing new to commit
    git -C "$repo_dir" commit -m "$msg" --quiet 2>/dev/null || return
    git -C "$repo_dir" push --quiet 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Commit the tail of a failed job's log to errors/<slug>-<timestamp>.txt so
# the remote monitor agent can read it and diagnose the failure.
# ---------------------------------------------------------------------------
commit_error_log() {
    local input="$1" title_log="$2"
    local repo_dir slug timestamp error_dir error_file
    repo_dir=$(dirname "$QUEUE_FILE")
    slug=$(log_slug "$input")
    timestamp=$(date '+%Y%m%d-%H%M%S')
    error_dir="$repo_dir/errors"
    error_file="$error_dir/${slug}-${timestamp}.txt"

    mkdir -p "$error_dir"
    {
        echo "File   : $input"
        echo "Time   : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Log    : $title_log"
        echo "---"
        tail -60 "$title_log" 2>/dev/null || echo "(log not found)"
    } > "$error_file"

    git -C "$repo_dir" add "$error_file" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Update a queue entry's status in-place
#   update_status "/path/to/file.mkv" "done"
# ---------------------------------------------------------------------------
update_status() {
    local input="$1" new_status="$2"
    local tmp
    tmp=$(mktemp)
    while IFS= read -r line; do
        # Match path as 4th field — may be followed by more fields (e.g. |denoise) or end of line
        if [[ "$line" == *"|${input}|"* || "$line" == *"|${input}" ]]; then
            echo "${new_status}|${line#*|}"
        else
            echo "$line"
        fi
    done < "$QUEUE_FILE" > "$tmp"
    mv "$tmp" "$QUEUE_FILE"
}

# ---------------------------------------------------------------------------
# Scan MEDIA_DIR for MKVs that have no [upscaled] counterpart and are not
# already in the queue; add them as pending|live|1080p
# ---------------------------------------------------------------------------
scan_new_files() {
    local added=0
    while IFS= read -r -d '' mkv; do
        # Skip already-upscaled files
        [[ "$mkv" == *"[upscaled]"* ]] && continue

        # Skip if already in queue (any status)
        if grep -qF "|$mkv" "$QUEUE_FILE" 2>/dev/null; then
            continue
        fi

        # Check that a corresponding upscaled file doesn't already exist
        local dir base upscaled
        dir=$(dirname "$mkv")
        base=$(basename "$mkv" .mkv)
        upscaled="$dir/$base [upscaled].mkv"
        if [ -f "$upscaled" ]; then
            continue
        fi

        local detected_type
        detected_type=$(detect_type "$mkv")
        echo "pending|${detected_type}|1080p|$mkv" >> "$QUEUE_FILE"
        log "Queued (new, type=${detected_type}): $mkv"
        added=$((added + 1))
    done < <(find "$MEDIA_DIR" -maxdepth 1 -name "*.mkv" -print0 | sort -z)

    [ "$added" -gt 0 ] && log "Added $added new file(s) to queue."
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
log "=== Queue daemon starting ==="
log "Queue file : $QUEUE_FILE"
log "Media dir  : $MEDIA_DIR"

while true; do
    # 0. Sync with remote — picks up error→pending resets from the remote monitor agent
    git -C "$(dirname "$QUEUE_FILE")" pull --rebase --autostash --quiet 2>/dev/null || true

    # 1. Discover new files
    scan_new_files

    # 2. Check no upscale job is already running (check the script, not just realesrgan,
    #    since the GPU is also held between chunks during ffmpeg extract/encode phases)
    if pgrep -f "upscale-.*\.sh" > /dev/null || pgrep -f realesrgan-ncnn-vulkan > /dev/null || pgrep -f waifu2x-ncnn-vulkan > /dev/null || pgrep -f "realesrgan-upscale.py" > /dev/null; then
        log "Job already running — waiting..."
        sleep "$SCAN_INTERVAL"
        continue
    fi

    # 3. Find next pending entry
    NEXT_LINE=$(grep -m1 '^pending|' "$QUEUE_FILE" 2>/dev/null)
    if [ -z "$NEXT_LINE" ]; then
        log "Queue empty — sleeping ${SCAN_INTERVAL}s"
        sleep "$SCAN_INTERVAL"
        continue
    fi

    IFS='|' read -r _status TYPE RESOLUTION INPUT_FILE DENOISE_OVERRIDE <<< "$NEXT_LINE"

    # Validate
    if [ ! -f "$INPUT_FILE" ]; then
        log "ERROR: File not found: $INPUT_FILE — marking error"
        update_status "$INPUT_FILE" "error"
        git_push_status "queue: error - $(basename "$INPUT_FILE")"
        continue
    fi

    DIR=$(dirname "$INPUT_FILE")
    BASE=$(basename "$INPUT_FILE" .mkv)
    OUTPUT_FILE="$DIR/$BASE [upscaled].mkv"

    # 4. Detect aspect ratio
    ASPECT=$(aspect_category "$INPUT_FILE")
    if [ "$ASPECT" = "unknown" ]; then
        log "ERROR: Could not determine aspect ratio for $INPUT_FILE — marking error"
        update_status "$INPUT_FILE" "error"
        git_push_status "queue: error - $(basename "$INPUT_FILE")"
        continue
    fi

    # 5. Select script
    SCRIPT=$(select_script "$TYPE" "$RESOLUTION" "$ASPECT")
    if [ ! -f "$SCRIPT" ]; then
        log "ERROR: No script for type=$TYPE res=$RESOLUTION aspect=$ASPECT — marking error"
        update_status "$INPUT_FILE" "error"
        git_push_status "queue: error - $(basename "$INPUT_FILE")"
        continue
    fi

    # 6. Build log path
    SLUG=$(log_slug "$INPUT_FILE")
    TITLE_LOG="$LOG_DIR/upscale-${SLUG}.log"

    log "--- Starting job ---"
    log "Input    : $INPUT_FILE"
    log "Output   : $OUTPUT_FILE"
    log "Script   : $(basename "$SCRIPT")"
    log "Aspect   : $ASPECT"
    [[ -n "$DENOISE_OVERRIDE" ]] && log "Denoise  : $DENOISE_OVERRIDE (override)"
    log "Job log  : $TITLE_LOG"

    # 7. Run job (blocking — daemon waits for completion)
    # $4 = denoise override (empty = script applies year-based default; ignored by non-EGVSR scripts)
    bash "$SCRIPT" "$INPUT_FILE" "$OUTPUT_FILE" "" "$DENOISE_OVERRIDE" >> "$TITLE_LOG" 2>&1
    JOB_EXIT=$?

    # 8. Verify output
    if [ $JOB_EXIT -eq 0 ] && [ -f "$OUTPUT_FILE" ]; then
        update_status "$INPUT_FILE" "done"
        log "DONE: $INPUT_FILE"
        git_push_status "queue: done - $(basename "$INPUT_FILE")"
    else
        update_status "$INPUT_FILE" "error"
        log "ERROR: Job failed (exit $JOB_EXIT) for $INPUT_FILE — check $TITLE_LOG"
        commit_error_log "$INPUT_FILE" "$TITLE_LOG"
        git_push_status "queue: error - $(basename "$INPUT_FILE")"
    fi
done
