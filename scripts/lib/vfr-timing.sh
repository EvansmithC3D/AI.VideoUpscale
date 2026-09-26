# Shared per-frame timing, resume and final mux for the chunked upscale scripts.
# Source it:  . "$SCRIPT_DIR/lib/vfr-timing.sh"
#
# Why: DVDs mix 23.976 film with 29.97 video-rate sections. Re-timing each chunk
# at (frames / chunk seconds) fps — what every script did before Sept 2026 —
# spreads those frames evenly, which stutters and drifts the picture seconds off
# the audio mid-chunk. Instead each chunk's extract logs every frame's real pts
# (showinfo) and the final mux stamps them back with mkvmerge.
#
# Extract contract for callers (per chunk, source seeked with -ss START):
#   -t $((CHUNK_LIMIT + 2))                        overshoot so filters see the boundary
#   -vf "<ivtc/deint>,trim=end=$CHUNK_LIMIT,...,showinfo"  trim partitions chunks exactly
#   (CHUNK_LIMIT = CHUNK_SEC, or effectively unlimited on the final chunk)
#   -fps_mode passthrough                          one output frame per filtered frame
# then: vfr_save_pts <extract log> <segment>.pts
#
# Segments dir layout (stable per input, so a rerun of the same job resumes):
#   segments.txt        "segment_NNNN <chunk start seconds>" per finished chunk, in order
#   segment_NNNN.pts    frame pts in seconds, relative to the chunk start
#   segment_NNNN.<ext>  HEVC video for that chunk (.hevc bare stream or .mkv)
#   fingerprint         settings the segments were made with; a mismatch restarts

# Stable segments dir for an input file (callers may add a suffix per pass).
vfr_segments_dir() {
    echo "/tmp/upscale_segments_$(printf '%s' "$1" | md5sum | cut -c1-12)${2:+_$2}"
}

# Container start_time of a file in seconds (0 if unknown). ffmpeg rebases pts to
# (start_time + -ss) when seeking; mkvmerge keeps the source's audio at its
# original timestamps, so this is added back when stamping.
vfr_src_start() {
    local s
    s=$(ffprobe -v error -show_entries format=start_time \
        -of default=noprint_wrappers=1:nokey=1 "$1")
    [[ "$s" =~ ^-?[0-9.]+$ ]] && echo "$s" || echo 0
}

# vfr_save_pts <extract log> <out.pts> — writes one pts per frame, echoes the count.
vfr_save_pts() {
    grep -oE 'showinfo.* pts_time:-?[0-9.e+-]+' "$1" | sed 's/.*pts_time://' > "$2"
    wc -l < "$2"
}

# vfr_resume_init <segments dir> <fingerprint string>
# Echoes how many leading chunks are already done (0 for a fresh start). Keeps the
# dir only if its fingerprint matches and every listed segment + pts file exists;
# otherwise wipes it and starts clean.
vfr_resume_init() {
    local dir="$1" fp="$2" list="$1/segments.txt" seg start ok=1 n=0
    if [ -f "$dir/fingerprint" ] && [ "$(cat "$dir/fingerprint")" = "$fp" ] && [ -f "$list" ]; then
        while read -r seg start; do
            [ -f "$dir/$seg.pts" ] || ok=0
            [ -f "$dir/$seg.hevc" ] || [ -f "$dir/$seg.mkv" ] || ok=0
            n=$((n + 1))
        done < "$list"
    else
        ok=0
    fi
    if [ "$ok" -ne 1 ]; then
        rm -rf "$dir"
        n=0
    fi
    mkdir -p "$dir"
    echo "$fp" > "$dir/fingerprint"
    touch "$list"
    echo "$n"
}

# vfr_build_video <segments dir> <src start s> <out.hevc> <out timestamps>
# Joins the listed segments into one bare HEVC stream and writes the matching
# mkvmerge v2 timestamp file (absolute ms). Every segment starts with an IDR +
# parameter sets, so the streams concatenate cleanly. Timestamps get a [1,2,1]/4
# smoothing: soft-telecined film decodes with alternating 33/50 ms spacing (the
# 3:2 field cadence), which this evens to 41.7 ms (true 23.976 — smooth, and
# players report 23.976 fps) while uniformly spaced 29.97 sections pass through
# unchanged; it preserves order and moves a frame by ~4 ms on 3:2 cadence.
# Returns non-zero (with a message) if frame and timestamp counts disagree.
vfr_build_video() {
    local dir="$1" s0="$2" out="$3" tsf="$4" seg start f
    : > "$out"
    echo "# timestamp format v2" > "$tsf.raw"
    while read -r seg start; do
        if [ -f "$dir/$seg.hevc" ]; then
            cat "$dir/$seg.hevc" >> "$out" || return 1
        else
            ffmpeg -nostdin -v error -i "$dir/$seg.mkv" -map 0:v:0 -c:v copy -f hevc - >> "$out" \
                || { echo "  ERROR: could not extract video from $seg.mkv"; return 1; }
        fi
        awk -v off="$start" -v s0="$s0" '{ printf "%.6f\n", (off + s0 + $1) * 1000 }' \
            "$dir/$seg.pts" >> "$tsf.raw"
    done < "$dir/segments.txt"
    awk 'NR == 1 { print; next }
         { t[++n] = $1 }
         END {
             for (i = 1; i <= n; i++) {
                 s = (i == 1 || i == n) ? t[i] : (t[i-1] + 2 * t[i] + t[i+1]) / 4
                 if (i > 1 && s <= prev) { s = prev + 0.001; fixed++ }
                 printf "%.6f\n", s; prev = s
             }
             if (fixed) print "  WARNING: nudged " fixed " non-increasing timestamps" > "/dev/stderr"
         }' "$tsf.raw" > "$tsf"
    rm -f "$tsf.raw"
    local frames stamps
    frames=$(ffprobe -v error -select_streams v:0 -count_packets \
        -show_entries stream=nb_read_packets -of default=noprint_wrappers=1:nokey=1 "$out")
    stamps=$(( $(wc -l < "$tsf") - 1 ))
    echo "  Joined video: $frames frames, $stamps timestamps"
    if [ "$frames" != "$stamps" ]; then
        echo "  ERROR: frame/timestamp count mismatch ($frames vs $stamps)"
        return 1
    fi
}

# vfr_mux <video.hevc> <timestamps> <audio/subs source or ""> <title> <out.mkv>
# Stamps the video and (if a source is given) adds its audio, subtitles and
# chapters untouched. mkvmerge exit 1 = warnings only.
vfr_mux() {
    local video="$1" tsf="$2" src="$3" title="$4" out="$5" rc
    if [ -n "$src" ]; then
        mkvmerge -o "$out" --title "$title" --timestamps "0:$tsf" "$video" -D "$src" \
            2>&1 | grep -E "Warning|Error" | tail -3
    else
        mkvmerge -o "$out" --title "$title" --timestamps "0:$tsf" "$video" \
            2>&1 | grep -E "Warning|Error" | tail -3
    fi
    rc=${PIPESTATUS[0]}
    [ "$rc" -lt 2 ] && [ -s "$out" ]
}

# vfr_install <muxed tmp> <final output> — copy beside the destination, then
# rename, so an existing output is only replaced once the new one is complete.
vfr_install() {
    if cp "$1" "$2.part" && mv -f "$2.part" "$2"; then
        rm -f "$1"
        return 0
    fi
    rm -f "$2.part"
    echo "=== ERROR: copy to $2 failed — muxed file preserved at $1 ==="
    return 1
}

# vfr_has_soft_pulldown <input> <duration s> — succeeds if the video has
# soft-pulldown film (packets at 33/50 ms spacing) in any of the idet sample
# windows. `decimate` assumes a uniform 29.97 input and re-times its output as
# even 23.976, so on discs mixing soft-pulldown film with hard-telecined
# sections it drops real frames and compresses the timeline (a 75 s Casino clip
# came out as 63.9 s). IVTC is only safe when the video is uniformly 29.97.
vfr_has_soft_pulldown() {
    local input="$1" dur="$2" starts=() s
    if [ "$dur" -lt 300 ]; then starts=(0); else starts=($((dur / 10)) $((dur / 2)) $((dur * 85 / 100))); fi
    for s in "${starts[@]}"; do
        ffprobe -v error -select_streams v:0 -read_intervals "${s}%+60" \
            -show_entries packet=pts_time -of csv=p=0 "$input" | sort -n
    done | awk 'NR > 1 { d = $1 - p; if (d > 0.045 && d < 0.1) soft++; n++ } { p = $1 }
                END { exit !(n && soft / n > 0.01) }'
}
