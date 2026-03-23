# waifu2x-upscale — Agent Instructions

This server runs long-form video upscaling jobs. An agent working in this repo is responsible for selecting the right script for each file, launching jobs correctly, and monitoring progress.

## Hardware

- GPU: AMD Radeon RX 6700 XT, 12 GB VRAM (Vulkan via ROCm)
- RAM: 32 GB
- All upscaling tools use Vulkan — no CUDA/HIP needed

## Media library

- **Input/output location:** `/mnt/jellyfin-movies/`
- Output naming convention: append `[upscaled]` before `.mkv`
  - e.g. `Spirited Away (2001).mkv` → `Spirited Away (2001) [upscaled].mkv`
- Logs go in `/home/evanna/` named after the title, e.g. `upscale-spirited-away.log`

## Installed model paths (on the server)

| Model | Path |
|---|---|
| realesr-animevideov3-x2 | `/usr/local/share/realesrgan-models/` |
| realesrgan-x4plus | `/usr/local/share/realesrgan-models/` |
| waifu2x models (legacy) | `/usr/local/share/models-cunet/`, etc. |

---

## Step 1 — Confirm target resolution

**If the user did not specify a resolution (1080p or 4K), ask before proceeding.** Do not assume.

Supported targets:
- **1080p** — faster, ~6–10 hours for a 90-min film; recommended for general library upscaling
- **4K** — ~2× slower than 1080p; recommended for favourite titles on large screens

---

## Step 2 — Choose the right script

Pick based on **resolution**, **content type**, and **aspect ratio**.

### Determine aspect ratio

Run this to get the Display Aspect Ratio (DAR) of any file:

```bash
ffprobe -v error -select_streams v:0 \
  -show_entries stream=display_aspect_ratio \
  -of default=noprint_wrappers=1:nokey=1 "input.mkv"
```

- `16:9` (or close: `1.78:1`, `1.77:1`) → use a **16x9** script
- `4:3` (or close: `1.33:1`) → use a **4x3** script
- If DAR is missing or `N/A`, probe SAR and calculate: `ffprobe -show_entries stream=width,height`

### Determine content type

- **Anime/animated:** hand-drawn animation, cel-shaded, classic cartoons, anime series/films
- **Live-action:** real-world footage, CGI-heavy films, documentary

When in doubt about a title, ask the user before starting a long job.

### Script selection

| Resolution | Content type | Aspect ratio | Script |
|---|---|---|---|
| 1080p | Animated | 16:9 | `scripts/upscale-anime-16x9.sh` |
| 1080p | Animated | 4:3 | `scripts/upscale-anime-4x3.sh` |
| 1080p | Live-action | 16:9 | `scripts/upscale-live-16x9.sh` |
| 1080p | Live-action | 4:3 | `scripts/upscale-live-4x3.sh` |
| 4K | Animated | 16:9 | `scripts/upscale-anime-16x9-4k.sh` |
| 4K | Animated | 4:3 | `scripts/upscale-anime-4x3-4k.sh` |
| 4K | Live-action | 16:9 | `scripts/upscale-live-16x9-4k.sh` |
| 4K | Live-action | 4:3 | `scripts/upscale-live-4x3-4k.sh` |

### What each script does internally

**1080p scripts:**
- Anime: `realesr-animevideov3-x2` (2x, trained on video frames)
- Live-action: `realesrgan-x2plus` (2x, live-action tailored)
- Pre-scale → upscale pipelines:
  - Anime 16:9: 960×540 → 2x → **1920×1080**
  - Anime 4:3: 720×540 → 2x → **1440×1080**
  - Live 16:9: 960×540 → 2x → **1920×1080**
  - Live 4:3: 720×540 → 2x → **1440×1080**

**4K scripts:**
- Anime: two-pass with `realesr-animevideov3-x2` (2x × 2 passes)
  - Anime 16:9: 960×540 → 2x → 1920×1080 → 2x → **3840×2160**
  - Anime 4:3: 720×540 → 2x → 1440×1080 → 2x → **2880×2160**
- Live-action: single-pass with `realesrgan-x4plus` (4x from double the 1080p input res)
  - Live 16:9: 960×540 → 4x → **3840×2160**
  - Live 4:3: 720×540 → 4x → **2880×2160**
- Default chunk size is **2 minutes** (4K output frames are ~4× larger than 1080p; needs more /tmp headroom)
- Anime 4K scripts create a video-only intermediate MKV in `/tmp` between passes; audio is muxed from the original source in the final step

---

## Step 3 — Launch a job

Always use `nohup` so the job survives SSH disconnects:

```bash
nohup bash scripts/upscale-anime-16x9.sh \
  "/mnt/jellyfin-movies/Title (Year).mkv" \
  "/mnt/jellyfin-movies/Title (Year) [upscaled].mkv" \
  >> /home/evanna/upscale-title.log 2>&1 &

echo "PID: $!"
```

Save the PID. Log file captures all output for monitoring.

---

## Step 4 — Monitor progress

### Check if job is running

```bash
ps aux | grep upscale
```

### Tail the log

```bash
tail -f /home/evanna/upscale-title.log
```

### Read current chunk progress from log

```bash
grep "^\[" /home/evanna/upscale-title.log | tail -5
```

### Check disk space before/during (temp frames use /tmp)

```bash
df -h /tmp /mnt/jellyfin-movies
```

**Minimum free space in `/tmp` before starting:**
- 1080p jobs: at least 5 GB (5-min chunks at 960×540)
- 4K jobs: at least 25 GB (2-min chunks; 4K output frames are much larger)

For 4K anime jobs, also account for the intermediate 1080p MKV in `/tmp` (~3–6 GB for a feature film).

---

## Step 5 — After completion

The script prints `=== Done! ===` and runs ffprobe on the output. Verify:

```bash
ffprobe "/mnt/jellyfin-movies/Title (Year) [upscaled].mkv" 2>&1 | grep -E "Duration|Video:|Audio:"
ls -lh "/mnt/jellyfin-movies/Title (Year) [upscaled].mkv"
```

Expected output resolutions:

| Resolution | 16:9 | 4:3 |
|---|---|---|
| 1080p | 1920×1080 | 1440×1080 |
| 4K | 3840×2160 | 2880×2160 |

**4:3 output is intentionally narrower than 3840×2160** — this is correct. It preserves the 4:3 aspect ratio at 4K height. Pillarboxing is the player's job.

---

## Handling failures and resuming

If a job dies mid-run, the segment files in `/tmp/upscale_segments_<PID>/` may still exist. Check:

```bash
ls /tmp/upscale_segments_*/
```

For 4K anime jobs, also check for the intermediate MKV:

```bash
ls /tmp/upscale_intermediate_*.mkv
ls /tmp/upscale_p1_segments_*/
ls /tmp/upscale_p2_segments_*/
```

The last complete segment number and timestamp in the log tells you where it stopped:

```bash
grep "Segment saved" /home/evanna/upscale-title.log | tail -5
```

To resume, write a targeted resume script modelled on `scripts/upscale-resume.sh`. Key values to extract from the log before writing the resume script:
- `SEGMENTS_DIR` (the `/tmp/upscale_segments_<PID>` path — must still exist on disk)
- Last completed chunk number and its end timestamp
- `FPS_ROUNDED` and `DURATION` (printed near the top of the log)

If a 4K anime job failed partway through pass 2, the intermediate MKV may still be intact in `/tmp`. Check it with ffprobe before deciding whether to restart from pass 1 or pass 2.

Do **not** delete `/tmp/upscale_segments_*` or `/tmp/upscale_intermediate_*` unless the job completed successfully and the output file is verified.

---

## Important constraints

- **Only one GPU job at a time.** `realesrgan-ncnn-vulkan` and `waifu2x-ncnn-vulkan` both claim the full GPU. Running two simultaneously will cause OOM or severe slowdown. Always check `ps aux | grep -E "realesrgan|waifu2x"` before launching.
- **Do not skip verification.** Always ffprobe the output before considering a job done.
- **Do not delete the input file** until the output is verified correct.
- **4:3 output is intentionally narrower**, not 1920×1080 or 3840×2160. This is correct.

---

## Quick reference — full example

```bash
# 0. Confirm resolution with user if not specified

# 1. Check aspect ratio
ffprobe -v error -select_streams v:0 \
  -show_entries stream=display_aspect_ratio \
  -of default=noprint_wrappers=1:nokey=1 \
  "/mnt/jellyfin-movies/Spirited Away (2001).mkv"
# → 16:9, animated content → upscale-anime-16x9.sh (1080p) or upscale-anime-16x9-4k.sh (4K)

# 2. Check nothing is already running
ps aux | grep -E "realesrgan|waifu2x"

# 3. Check disk space (25 GB free in /tmp for 4K jobs)
df -h /tmp /mnt/jellyfin-movies

# 4. Launch (example: 1080p)
nohup bash /home/evanna/waifu2x-upscale/scripts/upscale-anime-16x9.sh \
  "/mnt/jellyfin-movies/Spirited Away (2001).mkv" \
  "/mnt/jellyfin-movies/Spirited Away (2001) [upscaled].mkv" \
  >> /home/evanna/upscale-spirited-away.log 2>&1 &
echo "PID: $!"

# 4. Launch (example: 4K)
nohup bash /home/evanna/waifu2x-upscale/scripts/upscale-anime-16x9-4k.sh \
  "/mnt/jellyfin-movies/Spirited Away (2001).mkv" \
  "/mnt/jellyfin-movies/Spirited Away (2001) [upscaled].mkv" \
  >> /home/evanna/upscale-spirited-away.log 2>&1 &
echo "PID: $!"

# 5. Monitor
tail -f /home/evanna/upscale-spirited-away.log
```
