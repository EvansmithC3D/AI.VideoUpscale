# AI.VideoUpscale — Agent Instructions

This server runs long-form video upscaling jobs. An agent working in this repo is responsible for selecting the right script for each file, launching jobs correctly, and monitoring progress.

## Hardware

- GPU: AMD Radeon RX 6700 XT, 12 GB VRAM (ROCm 6.4.4)
- RAM: 32 GB
- **PyTorch/ROCm requires `HSA_OVERRIDE_GFX_VERSION=10.3.0`** — the GPU is gfx1031 (RDNA2) but ROCm wheels only ship gfx1030 kernels. This env var is set automatically by all live-action scripts. Always include it when running Python inference manually.
- Anime scripts use ncnn-vulkan (Vulkan backend, no env var needed)

## Media library

- **Movies:** `/mnt/jellyfin-movies/` (flat — `Title (Year).mkv`)
- **Shows:** `/mnt/jellyfin-shows/` (nested — `Show Name/Season XX/Episode.mkv`; the queue daemon scans it recursively)
  - fstab entry exists (`nofail`), but as of 2026-07-19 the NFS server (192.168.40.200) does **not** export `/mnt/media/jellyfin/shows`. Once the export is added server-side, run `sudo mount /mnt/jellyfin-shows`; the daemon picks up episodes automatically on its next scan.
- Output naming convention: append `[upscaled]` before `.mkv`, in the same directory as the source
  - e.g. `Spirited Away (2001).mkv` → `Spirited Away (2001) [upscaled].mkv`
  - episodes: `…/Season 01/Show - S01E01.mkv` → `…/Season 01/Show - S01E01 [upscaled].mkv`
- Logs go in `/home/evanna/` named after the title, e.g. `upscale-spirited-away.log` (episodes get one log each, e.g. `upscale-breaking-bad-s01e01-pilot.log`)

## Installed model paths

| Model | Path |
|---|---|
| SPAN 2xNomosUni_span_multijpg (.safetensors) | `/usr/local/share/span-models/` |
| RealESRGAN x2plus / x4plus (.pth) | `/usr/local/share/realesrgan-pth/` |
| EGVSR weights (EGVSR_iter420000.pth) | `/usr/local/share/egvsr/` |
| EGVSR Python codes | `/usr/local/share/egvsr/codes/` |
| realesr-animevideov3-x2 (ncnn) | `/usr/local/share/realesrgan-models/` |
| waifu2x models (legacy) | `/usr/local/share/models-cunet/`, etc. |

---

## Step 1 — Confirm target resolution

**If the user did not specify a resolution (1080p or 4K), ask before proceeding.** Do not assume.

Supported targets:
- **1080p** — live: SPAN in a raw-video pipe, ~25fps end-to-end, CPU-bound on x265 (roughly 2–3hr/2hr film — switched from RealESRGAN x2plus (~1.3fps, ~35hr) July 2026, PNG-free pipe Sept 2026); anime: fast via ncnn
- **4K** — live: ~5.5fps via EGVSR (~8–9hr/2hr film); anime: two-pass ncnn (~2× slower than 1080p anime)

Note: EGVSR 4K amplifies MPEG-2 compression artifacts on some sources (GAN hallucination on block noise) — the SPAN 1080p path is both faster and cleaner for this DVD library.

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

**Live-action 1080p (SPAN, PyTorch/ROCm):**
- Model: `2xNomosUni_span_multijpg` (2x SPAN, JPEG-degradation-trained — handles MPEG-2 DVD noise) via `scripts/span-upscale.py`, fp16
- Runs in the dedicated venv `/home/evanna/.venvs/span-upscale` (spandrel over the system ROCm torch); the shell script sets `HSA_OVERRIDE_GFX_VERSION` automatically
- Replaced `realesrgan-x2plus` (ncnn) July 2026: ~15x faster GPU stage, fewer edge halos; an ncnn fallback (`2xNomosUni_compact_multijpg_ldl_fp32` in `/usr/local/share/realesrgan-models/`) exists if the PyTorch path breaks
- Live 16:9: native 720×480 → 2x → 1440×960 → lanczos → **1920×1080**
- Live 4:3: native 720×480 → 2x → 1440×960 → lanczos → **1440×1080**
- SPAN sees the real DVD pixels (no pre-upscale); one lanczos resize afterwards, BT.709 matrix, tagged bt709
- Chunk size: 5 minutes
- Pre-extract year-based `denoise` (none/spatial/full; `$4`, same logic as the 4K path), then an `atadenoise` postfilter (`$5`) to suppress single-image-model flicker
- Per chunk, decode → SPAN → x265 run concurrently as one raw-video pipe (`ffmpeg | span-upscale.py | ffmpeg`); no frames touch disk
- End-to-end ~25 fps (was ~15 fps with the PNG-based pipeline); CPU-bound on x265 medium (3700X)
- (The PyTorch `scripts/realesrgan-upscale.py` is legacy/unused and lives in `scripts/archive/`)

**Live-action 4K (PyTorch/ROCm):**
- Model: `EGVSR_iter420000.pth` via `scripts/egvsr-upscale.py`
- EGVSR is a frame-recurrent model (processes frames sequentially; `hr_prev`/`lr_prev` state carries across chunk boundaries — the Python process runs for the full film, so there are no warmup artifacts at segment joins)
- Live 16:9: 960×540 → 4x → **3840×2160**
- Live 4:3: 720×540 → 4x → **2880×2160**
- Chunk size: 10 minutes
- Resuming a 4K job cold-starts the recurrent state at the first redone chunk (same as a scene cut)

**Anime 1080p (ncnn-vulkan):**
- Model: `realesr-animevideov3-x2` (2x, trained on video frames)
- Anime 16:9: 960×540 → 2x → **1920×1080**
- Anime 4:3: 720×540 → 2x → **1440×1080**
- Chunk size: 5 minutes

**Anime 4K (ncnn-vulkan, two-pass):**
- Anime 16:9: 960×540 → 2x → 1920×1080 → 2x → **3840×2160**
- Anime 4:3: 720×540 → 2x → 1440×1080 → 2x → **2880×2160**
- Chunk size: 2 minutes
- Both 2x passes run back to back on each chunk's frames (no intermediate MKV, no lossy re-encode between passes — rebuilt Sept 2026; the old design re-cut the intermediate by time and could drift)

**All scripts — timing, resume, deblock (Sept 2026, `scripts/lib/vfr-timing.sh`):**
- **Real per-frame timestamps (VFR).** The extract logs each frame's pts (`showinfo`, `-fps_mode passthrough`) and the final `mkvmerge --timestamps` stamps them back, with [1,2,1] smoothing that evens the 3:2 soft-telecine 33/50 ms cadence to 41.7 ms (players report 23.976). DVDs mix 23.976 film with 29.97 video sections; the old per-chunk `frames/seconds` fps spread them evenly → stutter and seconds of mid-chunk A/V drift (found on Casino). Chunks are cut with `trim` so they partition the film exactly; the final chunk is uncapped
- **Automatic resume.** Segments live in `/tmp/upscale_segments_<md5 of input path>` with a settings fingerprint; rerunning the same job (or the daemon retrying it) skips finished chunks. A settings/input change restarts cleanly
- **No MPEG-2 deblock.** The old `spp=quality=4` was a silent no-op (ffmpeg only gives it QP tables with `-export_side_data venc_params`); tested for real it softened texture with no visible gain on SPAN, so it was removed everywhere
- **IVTC only on uniform hard telecine.** `fieldmatch+decimate` runs only when idet finds 3:2 repeated fields *and* the packets show no soft-pulldown (33/50 ms) spacing; `decimate` re-times its output as even 23.976 and on mixed discs drops real frames and squeezes the timeline. Mixed discs get `yadif` only (see `docs/future-enhancements.md` item i). No library title has used IVTC as of Sept 2026
- **Colour:** upscaled output is converted with the BT.709 matrix and tagged bt709 (previously SD BT.601 math, untagged)
- **Outputs are replaced atomically** (copy to `<output>.part`, then rename)
- `scripts/scan-timing-drift.py [--chunk S] file.mkv…` replays the old re-timing against a source's packet timestamps and reports the worst drift an old (pre-Sept-2026) upscale of it has

**Audio/subtitles (all scripts):** the final `mkvmerge` takes every audio, subtitle and chapter track from the source untouched (language tags intact). Nothing is re-encoded.

**Experimental: BasicVSR alternatives (live 1080p only, manual launch).** `scripts/upscale-live-16x9-basicvsr.sh` / `upscale-live-4x3-basicvsr.sh` use bidirectional temporal SR (BasicVSR, PyTorch/ROCm) instead of single-image RealESRGAN, which suppresses per-frame flicker without the `atadenoise` postfilter. They are **not** wired into the queue daemon's script selection — run them by hand. Much slower than the ncnn x2plus path (~3.3 fps at 270p input) and reset temporal state at sub-sequence boundaries. Treat as opt-in for titles where flicker is objectionable.

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
pending|live|1080p|/mnt/jellyfin-shows/Show Name/Season 01/Show - S01E01.mkv
```

The daemon auto-discovers new files on every scan: movies from `/mnt/jellyfin-movies/` (top level only) and show episodes from `/mnt/jellyfin-shows/` (recursive), queued as `pending|<detected type>|1080p`. Show type detection runs once per series (MKV genre tag → TMDB `/search/tv` on the series folder name if `TMDB_API_KEY` is set → Japanese-audio heuristic) and every episode of that series inherits it — override TYPE in `queue.txt` before pickup if it guesses wrong.

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
- live 1080p jobs: at least 15 GB (no frames on disk — only HEVC segments plus the final mux)
- anime 1080p jobs: at least 35 GB
- 4K jobs: at least 25 GB for live EGVSR, ~50 GB for anime 4K (one 2-min chunk of 1080p + 4K PNGs)

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

If a job dies mid-run, its finished chunks stay in `/tmp/upscale_segments_<hash>/` (one dir per input file; `segments.txt` lists finished chunks as `segment_NNNN <chunk start s>`, with `segment_NNNN.hevc|.mkv` + `segment_NNNN.pts` each).

**To resume, just rerun the same job** — same script, same input, same settings (reset its queue line to `pending` and the daemon does this). The script prints `Resuming: N chunk(s) already done` and continues. If the input file or settings changed, it discards the old segments and starts over.

Find where it stopped:

```bash
grep "Chunk.*done in" /home/evanna/upscale-title.log | tail -5
ls /tmp/upscale_segments_*/
```

Do **not** delete `/tmp/upscale_segments_*` unless the job completed successfully and the output is verified (a successful run removes its own).

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

## Periodic tech re-review

When the user asks for a re-review, a review of new models/efficiency enhancements, or
"what's new for ROCm", first read `docs/future-enhancements.md`. Work through its
revisit triggers plus fresh web research, then update that file (last-reviewed date,
findings, moved/adjusted items) and report back to the user.
