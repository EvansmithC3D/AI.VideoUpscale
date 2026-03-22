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

## Step 1 — Choose the right script

There are four purpose-built scripts. Pick based on **content type** and **aspect ratio**.

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

| Content type | Aspect ratio | Script |
|---|---|---|
| Animated | 16:9 | `scripts/upscale-anime-16x9.sh` |
| Animated | 4:3 | `scripts/upscale-anime-4x3.sh` |
| Live-action | 16:9 | `scripts/upscale-live-16x9.sh` |
| Live-action | 4:3 | `scripts/upscale-live-4x3.sh` |

### What each script does internally

- **Anime scripts** use `realesr-animevideov3-x2` (2x, trained on video frames — better temporal consistency than waifu2x cunet)
- **Live-action scripts** use `realesrgan-x4plus` (4x)
- All scripts pre-scale frames to the exact half/quarter resolution before upscaling so output lands at the target without a lossy post-downscale
  - Anime 16:9: 960×540 → 2x → **1920×1080**
  - Anime 4:3: 720×540 → 2x → **1440×1080**
  - Live 16:9: 480×270 → 4x → **1920×1080**
  - Live 4:3: 360×270 → 4x → **1440×1080**

---

## Step 2 — Launch a job

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

## Step 3 — Monitor progress

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
grep "^\[Chunk" /home/evanna/upscale-title.log | tail -5
```

### Check disk space before/during (temp frames use /tmp)

```bash
df -h /tmp /mnt/jellyfin-movies
```

A 5-minute chunk of PNG frames at 960×540 is roughly 1–3 GB. Ensure `/tmp` has at least 5 GB free before starting.

---

## Step 4 — After completion

The script prints `=== Done! ===` and runs ffprobe on the output. Verify:

```bash
ffprobe "/mnt/jellyfin-movies/Title (Year) [upscaled].mkv" 2>&1 | grep -E "Duration|Video:|Audio:"
ls -lh "/mnt/jellyfin-movies/Title (Year) [upscaled].mkv"
```

Expected output resolution:
- 1920×1080 for 16:9 content
- 1440×1080 for 4:3 content

---

## Handling failures and resuming

If a job dies mid-run, the segment files in `/tmp/upscale_segments_<PID>/` may still exist. Check:

```bash
ls /tmp/upscale_segments_*/
```

The last complete segment number and timestamp in the log tells you where it stopped:

```bash
grep "Segment saved" /home/evanna/upscale-title.log | tail -5
```

To resume, write a targeted resume script modelled on `scripts/upscale-resume.sh`. Key values to extract from the log before writing the resume script:
- `SEGMENTS_DIR` (the `/tmp/upscale_segments_<PID>` path — must still exist on disk)
- Last completed chunk number and its end timestamp
- `FPS_ROUNDED` and `DURATION` (printed near the top of the log)

Do **not** delete `/tmp/upscale_segments_*` dirs unless the job completed successfully and the output file is verified.

---

## Important constraints

- **Only one GPU job at a time.** `realesrgan-ncnn-vulkan` and `waifu2x-ncnn-vulkan` both claim the full GPU. Running two simultaneously will cause OOM or severe slowdown. Always check `ps aux | grep -E "realesrgan|waifu2x"` before launching.
- **Do not skip verification.** Always ffprobe the output before considering a job done.
- **Do not delete the input file** until the output is verified correct.
- **4:3 output is intentionally 1440×1080**, not 1920×1080. This is correct — pillarboxing is the player's job.

---

## Quick reference — full example

```bash
# 1. Check aspect ratio
ffprobe -v error -select_streams v:0 \
  -show_entries stream=display_aspect_ratio \
  -of default=noprint_wrappers=1:nokey=1 \
  "/mnt/jellyfin-movies/Spirited Away (2001).mkv"
# → 16:9, animated content → use upscale-anime-16x9.sh

# 2. Check nothing is already running
ps aux | grep -E "realesrgan|waifu2x"

# 3. Check disk space
df -h /tmp /mnt/jellyfin-movies

# 4. Launch
nohup bash /home/evanna/waifu2x-upscale/scripts/upscale-anime-16x9.sh \
  "/mnt/jellyfin-movies/Spirited Away (2001).mkv" \
  "/mnt/jellyfin-movies/Spirited Away (2001) [upscaled].mkv" \
  >> /home/evanna/upscale-spirited-away.log 2>&1 &
echo "PID: $!"

# 5. Monitor
tail -f /home/evanna/upscale-spirited-away.log
```
