# AI.VideoUpscale — Agent Instructions

This server runs long-form video upscaling jobs. An agent working in this repo is responsible for selecting the right script for each file, launching jobs correctly, and monitoring progress.

## Hardware

- GPU: AMD Radeon RX 6700 XT, 12 GB VRAM (ROCm 6.4.4)
- RAM: 32 GB
- **PyTorch/ROCm requires `HSA_OVERRIDE_GFX_VERSION=10.3.0`** — the GPU is gfx1031 (RDNA2) but ROCm wheels only ship gfx1030 kernels. This env var is set automatically by all live-action scripts. Always include it when running Python inference manually.
- Anime scripts use ncnn-vulkan (Vulkan backend, no env var needed)

## Media library

- **Input/output location:** `/mnt/jellyfin-movies/`
- Output naming convention: append `[upscaled]` before `.mkv`
  - e.g. `Spirited Away (2001).mkv` → `Spirited Away (2001) [upscaled].mkv`
- Logs go in `/home/evanna/` named after the title, e.g. `upscale-spirited-away.log`

## Installed model paths

| Model | Path |
|---|---|
| RealESRGAN x2plus / x4plus (.pth) | `/usr/local/share/realesrgan-pth/` |
| EGVSR weights (EGVSR_iter420000.pth) | `/usr/local/share/egvsr/` |
| EGVSR Python codes | `/usr/local/share/egvsr/codes/` |
| realesr-animevideov3-x2 (ncnn) | `/usr/local/share/realesrgan-models/` |
| waifu2x models (legacy) | `/usr/local/share/models-cunet/`, etc. |

---

## Step 1 — Confirm target resolution

**If the user did not specify a resolution (1080p or 4K), ask before proceeding.** Do not assume.

Supported targets:
- **1080p** — live: ~3.7fps (~16hr/2hr film); anime: faster via ncnn
- **4K** — live: ~7.8fps via EGVSR (~6–8hr/2hr film); anime: two-pass ncnn (~2× slower than 1080p anime)

Note: live-action 4K (EGVSR) is *faster* than live-action 1080p (x2plus) due to EGVSR's efficient architecture.

---

## Step 2 — Choose the right script

Pick based on **resolution**, **content type**, and **aspect ratio**.

### Determine aspect ratio

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

**Live-action 1080p (PyTorch/ROCm):**
- Model: `RealESRGAN_x2plus.pth` via `scripts/realesrgan-upscale.py`
- Live 16:9: 960×540 → 2x → **1920×1080**
- Live 4:3: 720×540 → 2x → **1440×1080**
- Chunk size: 5 minutes

**Live-action 4K (PyTorch/ROCm):**
- Model: `EGVSR_iter420000.pth` via `scripts/egvsr-upscale.py`
- EGVSR is a frame-recurrent model (processes frames sequentially; `hr_prev` state resets at each chunk boundary — first ~10 frames of each chunk are slightly softer)
- Live 16:9: 960×540 → 4x → **3840×2160**
- Live 4:3: 720×540 → 4x → **2880×2160**
- Chunk size: 2 minutes

**Anime 1080p (ncnn-vulkan):**
- Model: `realesr-animevideov3-x2` (2x, trained on video frames)
- Anime 16:9: 960×540 → 2x → **1920×1080**
- Anime 4:3: 720×540 → 2x → **1440×1080**
- Chunk size: 5 minutes

**Anime 4K (ncnn-vulkan, two-pass):**
- Anime 16:9: 960×540 → 2x → 1920×1080 → 2x → **3840×2160**
- Anime 4:3: 720×540 → 2x → 1440×1080 → 2x → **2880×2160**
- Chunk size: 2 minutes
- Creates a video-only intermediate MKV in `/tmp` between passes; audio muxed from source in final step

---

## Step 3 — Launch a job

Always use `nohup` so the job survives SSH disconnects:

```bash
nohup bash scripts/upscale-live-16x9-4k.sh \
  "/mnt/jellyfin-movies/Title (Year).mkv" \
  "/mnt/jellyfin-movies/Title (Year) [upscaled].mkv" \
  >> /home/evanna/upscale-title.log 2>&1 &

echo "PID: $!"
```

### Using the queue daemon

Preferred for batch processing. Add entries to `queue.txt`, then:

```bash
nohup bash scripts/queue-daemon.sh >> /home/evanna/upscale-queue.log 2>&1 &
```

Queue format:
```
# STATUS|TYPE|RESOLUTION|/absolute/path/to/file.mkv
pending|live|4k|/mnt/jellyfin-movies/Title (Year).mkv
pending|anime|1080p|/mnt/jellyfin-movies/Title (Year).mkv
```

---

## Step 4 — Monitor progress

### Check if job is running

```bash
ps aux | grep -E "upscale|egvsr|realesrgan"
```

### Tail the log

```bash
tail -f /home/evanna/upscale-title.log
```

### Read chunk progress (timestamped)

```bash
grep "^\[20" /home/evanna/upscale-title.log | tail -10
```

Each chunk logs start time and elapsed seconds at completion:
```
[2026-04-04 22:07:55] [Chunk 1/61] 0s → 120s
[2026-04-04 22:10:12] Chunk 1 done in 137s — segment saved: segment_0001.mkv
```

### Check disk space

```bash
df -h /tmp /mnt/jellyfin-movies
```

**Minimum free space in `/tmp` before starting:**
- 1080p jobs: at least 5 GB (5-min chunks at 960×540)
- 4K jobs: at least 25 GB (2-min chunks; 4K output frames are much larger)

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

**4:3 output is intentionally narrower** — preserves aspect ratio at 4K height. Pillarboxing is the player's job.

---

## Handling failures and resuming

If a job dies mid-run, segment files in `/tmp/upscale_segments_<PID>/` may still exist:

```bash
ls /tmp/upscale_segments_*/
```

For 4K anime jobs, also check for the intermediate MKV:

```bash
ls /tmp/upscale_intermediate_*.mkv
ls /tmp/upscale_p1_segments_*/
ls /tmp/upscale_p2_segments_*/
```

Find where it stopped:

```bash
grep "Chunk.*done in" /home/evanna/upscale-title.log | tail -5
```

To resume, write a targeted resume script modelled on `scripts/upscale-resume.sh`. Key values to extract:
- `SEGMENTS_DIR` (the `/tmp/upscale_segments_<PID>` path — must still exist)
- Last completed chunk number and its end timestamp
- `FPS_ROUNDED` and `DURATION` (printed near the top of the log)

Do **not** delete `/tmp/upscale_segments_*` or `/tmp/upscale_intermediate_*` unless the job completed successfully and the output is verified.

---

## Important constraints

- **Only one GPU job at a time.** Always check before launching:
  ```bash
  ps aux | grep -E "realesrgan|egvsr-upscale|waifu2x"
  ```
- **Do not skip verification.** Always ffprobe the output before considering a job done.
- **Do not delete the input file** until the output is verified correct.
- **4:3 output is intentionally narrower**, not 1920×1080 or 3840×2160. This is correct.
- **EGVSR is at `/usr/local/share/egvsr/`** — not `/tmp/EGVSR/`. The `/tmp` location does not survive reboots.

---

## Quick reference — full example

```bash
# 0. Confirm resolution with user if not specified

# 1. Check aspect ratio
ffprobe -v error -select_streams v:0 \
  -show_entries stream=display_aspect_ratio \
  -of default=noprint_wrappers=1:nokey=1 \
  "/mnt/jellyfin-movies/Spirited Away (2001).mkv"
# → 16:9, animated → upscale-anime-16x9.sh (1080p) or upscale-anime-16x9-4k.sh (4K)
# → 16:9, live-action → upscale-live-16x9.sh (1080p) or upscale-live-16x9-4k.sh (4K EGVSR)

# 2. Check nothing is already running
ps aux | grep -E "realesrgan|egvsr|waifu2x"

# 3. Check disk space (25 GB free in /tmp for 4K jobs)
df -h /tmp /mnt/jellyfin-movies

# 4. Launch via queue (recommended)
echo "pending|live|4k|/mnt/jellyfin-movies/Spirited Away (2001).mkv" >> queue.txt
# (daemon picks it up automatically)

# 4. Or launch directly
nohup bash scripts/upscale-live-16x9-4k.sh \
  "/mnt/jellyfin-movies/Spirited Away (2001).mkv" \
  "/mnt/jellyfin-movies/Spirited Away (2001) [upscaled].mkv" \
  >> /home/evanna/upscale-spirited-away.log 2>&1 &
echo "PID: $!"

# 5. Monitor
tail -f /home/evanna/upscale-spirited-away.log
grep "Chunk.*done in" /home/evanna/upscale-spirited-away.log | tail -5
```
