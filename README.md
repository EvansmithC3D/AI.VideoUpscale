# AI.VideoUpscale

Chunked video upscaling pipeline for a Jellyfin media server.
- **Live-action 1080p** — RealESRGAN x2plus (PyTorch/ROCm)
- **Live-action 4K** — EGVSR 4x (PyTorch/ROCm), ~7.8fps, ~6–8hr per 2hr film
- **Anime 1080p/4K** — realesr-animevideov3-x2 (ncnn-vulkan)

Jobs are managed by a queue daemon that reads `queue.txt` and processes one film at a time.

## Scripts

| Script | Content | AR | Output | Model | Backend |
|---|---|---|---|---|---|
| `upscale-anime-16x9.sh` | Animated | 16:9 | 1920×1080 | animevideov3-x2 | ncnn-vulkan |
| `upscale-anime-4x3.sh` | Animated | 4:3 | 1440×1080 | animevideov3-x2 | ncnn-vulkan |
| `upscale-anime-16x9-4k.sh` | Animated | 16:9 | 3840×2160 | animevideov3-x2 ×2 | ncnn-vulkan |
| `upscale-anime-4x3-4k.sh` | Animated | 4:3 | 2880×2160 | animevideov3-x2 ×2 | ncnn-vulkan |
| `upscale-live-16x9.sh` | Live-action | 16:9 | 1920×1080 | RealESRGAN-x2plus | ncnn-vulkan |
| `upscale-live-4x3.sh` | Live-action | 4:3 | 1440×1080 | RealESRGAN-x2plus | ncnn-vulkan |
| `upscale-live-16x9-4k.sh` | Live-action | 16:9 | 3840×2160 | EGVSR | PyTorch/ROCm |
| `upscale-live-4x3-4k.sh` | Live-action | 4:3 | 2880×2160 | EGVSR | PyTorch/ROCm |

All scripts share the same signature. Always use `nohup` so the job survives SSH disconnects:
```bash
nohup bash scripts/upscale-live-16x9.sh "input.mkv" "output.mkv" [chunk_minutes] \
  >> /home/evanna/upscale-title.log 2>&1 &
echo "PID: $!"
```

## Queue

Add entries to `queue.txt`:
```
pending|live|4k|/mnt/jellyfin-movies/Title (Year).mkv
pending|anime|1080p|/mnt/jellyfin-movies/Title (Year).mkv
```

Start the daemon:
```bash
nohup bash scripts/queue-daemon.sh >> /home/evanna/upscale-queue.log 2>&1 &
```

## Python helpers

| Script | Used by |
|---|---|
| `scripts/egvsr-upscale.py` | Live 4K scripts (EGVSR 4x) |
| `scripts/basicvsr-upscale.py` | Experimental live 1080p (manual launch) |

Both require `HSA_OVERRIDE_GFX_VERSION=10.3.0` (set by the shell scripts automatically). These are the PyTorch/ROCm helpers — the live 1080p path itself (`upscale-live-16x9.sh` / `upscale-live-4x3.sh`) uses ncnn-vulkan and needs no such helper.

## Model paths

| Model | Path |
|---|---|
| RealESRGAN PyTorch weights (.pth) | `/usr/local/share/realesrgan-pth/` |
| EGVSR weights + codes | `/usr/local/share/egvsr/` |
| animevideov3-x2 (ncnn) | `/usr/local/share/realesrgan-models/` |

## Hardware

- GPU: AMD Radeon RX 6700 XT, 12 GB VRAM
- ROCm 6.4.4 — requires `HSA_OVERRIDE_GFX_VERSION=10.3.0` for PyTorch (gfx1031 → gfx1030 spoof)
- Only one GPU job at a time
