# waifu2x-upscale

Chunked video upscaling scripts using waifu2x-ncnn-vulkan.

## Scripts

### Purpose-built scripts (recommended)

Pick the script that matches your content type and source aspect ratio:

| Script | Content | AR | Output | Model |
|---|---|---|---|---|
| `scripts/upscale-anime-16x9.sh` | Animated | 16:9 | 1920×1080 | realesr-animevideov3-x2 |
| `scripts/upscale-anime-4x3.sh` | Animated | 4:3 | 1440×1080 | realesr-animevideov3-x2 |
| `scripts/upscale-live-16x9.sh` | Live-action | 16:9 | 1920×1080 | realesrgan-x4plus |
| `scripts/upscale-live-4x3.sh` | Live-action | 4:3 | 1440×1080 | realesrgan-x4plus |

Usage (all scripts share the same signature):
```
./upscale-anime-16x9.sh "input.mkv" "output.mkv" [chunk_minutes=5]
```

All scripts pre-scale frames to the correct quarter/half resolution before upscaling so the output lands exactly on the target resolution without any post-downscale step.

### Legacy scripts

- `scripts/upscale-video.sh` — general purpose waifu2x upscaler (cunet, configurable scale/noise/model)
- `scripts/upscale-realesrgan.sh` — general purpose Real-ESRGAN upscaler
- `scripts/upscale-watcher.sh` — watches a log file and records completion/errors
- `scripts/upscale-resume.sh` / `scripts/upscale-challengers-resume.sh` — resume scripts for interrupted jobs

## Models

| Directory | Best for |
|---|---|
| `models/realesrgan-models/realesr-animevideov3-x2` | Animated video (best for video, handles temporal consistency) |
| `models/realesrgan-models/realesrgan-x4plus` | Live-action / photo (4x) |
| `models/realesrgan-models/realesrgan-x4plus-anime` | Animated (4x, alternative) |
| `models/models-cunet` | Anime stills (high quality, slower) |
| `models/models-upconv_7_photo` | Live-action stills (waifu2x) |
| `models/models-upconv_7_anime_style_art_rgb` | Anime stills (fast, waifu2x) |

## Usage notes

- Always launch with `nohup ... &` to survive SSH disconnects:
  ```
  nohup bash scripts/upscale-video.sh "input.mkv" "output.mkv" >> upscale.log 2>&1 &
  ```
- Models should be placed in `/usr/local/share/` on the target machine.
