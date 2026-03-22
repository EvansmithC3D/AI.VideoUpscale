# waifu2x-upscale

Chunked video upscaling scripts using waifu2x-ncnn-vulkan.

## Scripts

- `scripts/upscale-video.sh` — general purpose upscaler. Usage:
  ```
  ./upscale-video.sh "input.mkv" "output.mkv" [scale=2] [noise=1] [chunk_minutes=5] [model]
  ```
  Frames are pre-scaled to 960x540 before waifu2x so 2x output is a clean 1920x1080.

- `scripts/upscale-realesrgan.sh` — same workflow using Real-ESRGAN instead of waifu2x.
- `scripts/upscale-watcher.sh` — watches a log file and records completion/errors.
- `scripts/upscale-resume.sh` / `scripts/upscale-challengers-resume.sh` — resume scripts for interrupted jobs.

## Models

| Directory | Best for |
|---|---|
| `models/models-upconv_7_photo` | Live-action / photo |
| `models/models-upconv_7_anime_style_art_rgb` | Anime (fast) |
| `models/models-cunet` | Anime (high quality) |
| `models/realesrgan-models` | Real-ESRGAN |

## Usage notes

- Always launch with `nohup ... &` to survive SSH disconnects:
  ```
  nohup bash scripts/upscale-video.sh "input.mkv" "output.mkv" >> upscale.log 2>&1 &
  ```
- Models should be placed in `/usr/local/share/` on the target machine.
