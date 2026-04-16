#!/usr/bin/env python3
"""EGVSR 4x upscaler for live-action video. Processes an entire MKV in chunks,
keeping model and recurrent state (hr_prev/lr_prev) alive across chunk boundaries.
Writes hevc_vaapi segment MKVs to --segments-dir; shell handles final concat + mux.

Usage:
    HSA_OVERRIDE_GFX_VERSION=10.3.0 python3 egvsr-upscale.py \
        --input /mnt/jellyfin-movies/Title.mkv \
        --segments-dir /tmp/upscale_segments_$$ \
        --in-width 960 --in-height 540 \
        --out-width 3840 --out-height 2160 \
        --duration 7200 \
        --chunk-sec 600
"""
import argparse
import glob
import os
import subprocess
import sys
import tempfile
import time
from datetime import datetime

import cv2
import numpy as np
import torch

EGVSR_ROOT = '/usr/local/share/egvsr'
WEIGHTS = os.path.join(EGVSR_ROOT, 'EGVSR_iter420000.pth')

# Mean absolute pixel difference (in [0,1]) above which a frame is treated as a
# hard cut.  0.10 catches most DVD scene changes while ignoring busy motion.
SCENE_CHANGE_THRESHOLD = 0.10


def ts(msg):
    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {msg}",
          file=sys.stderr, flush=True)


def extract_frames(input_mkv, start, duration, in_w, in_h, frames_dir, denoise='none'):
    """Extract IVTC'd, scaled frames for one chunk. Returns frame count.

    denoise: 'none'    — no denoising (preserve film grain; best for pre-2000 film)
             'spatial' — per-frame spatial denoising only (hqdn3d luma/chroma, no temporal)
             'full'    — spatial + temporal denoising (hqdn3d with temporal smoothing)
    deint=all ensures every frame is deinterlaced regardless of stream flags, which is
    important for DVD sources where progressive-flagged frames can still carry combing."""
    vf = [
        # combmatch=sc: full field-analysis only on scene changes (valid values: none/sc/full).
        # combmatch=full was too aggressive on MPEG-2 sources — block-edge patterns triggered
        # false-positive field matches → horizontal blending artifacts.
        'fieldmatch=order=auto:combmatch=sc',
        'yadif=mode=0:parity=-1:deint=all',
        'decimate',
        # MPEG-2 postprocessing: removes 8x8 DCT block edges before EGVSR sees the frame.
        # Without this, EGVSR (trained on bicubic degradation) interprets block boundaries
        # as real structure and hallucinates a screendoor/grid artifact.
        # Uses ffmpeg's built-in deblock filter (libpostproc/pp not available in this build).
        # Per-frame only — no temporal smearing. Applied regardless of denoise setting.
        'deblock',
    ]
    if denoise == 'spatial':
        vf.append('hqdn3d=4:3:0:0')
    elif denoise == 'full':
        vf.append('hqdn3d=4:3:6:4.5')
    vf.append(f'scale={in_w}:{in_h}:flags=lanczos')
    cmd = [
        'ffmpeg', '-y',
        '-ss', str(start),
        '-t', str(duration),
        '-i', input_mkv,
        '-vf', ','.join(vf),
        '-vsync', 'vfr', '-q:v', '1',
        os.path.join(frames_dir, 'frame_%08d.png'),
        '-an',
    ]
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return len(glob.glob(os.path.join(frames_dir, '*.png')))


def warmup_state(model, lr_cur, lr_prev, hr_prev, n):
    """Run model n times on lr_cur (no output) to flush stale temporal state.
    Returns updated (hr_prev, lr_prev)."""
    for _ in range(n):
        with torch.no_grad():
            hr_prev = model(lr_cur, lr_cur, hr_prev).detach()
    return hr_prev, lr_cur.detach()


def process_chunk(frames_dir, chunk_fps, out_w, out_h, segment_path,
                  model, hr_prev, lr_prev, scene_warmup=8, cold_start=False):
    """Run EGVSR on extracted frames, encode to VAAPI segment.
    Returns updated (hr_prev, lr_prev) — state is NOT reset between chunks.

    scene_warmup: number of model passes (no output) run at hard cuts and cold
                  start to flush stale hr_prev before writing real frames.
    cold_start:   True for the very first chunk — forces warmup on frame 0."""
    frames = sorted(glob.glob(os.path.join(frames_dir, '*.png')))
    total = len(frames)

    ffmpeg_proc = subprocess.Popen([
        'ffmpeg', '-y',
        '-vaapi_device', '/dev/dri/renderD128',
        '-f', 'rawvideo', '-pixel_format', 'bgr24',
        '-video_size', f'{out_w}x{out_h}',
        '-framerate', str(chunk_fps),
        '-i', 'pipe:0',
        '-vf', 'format=nv12,hwupload',
        '-c:v', 'hevc_vaapi', '-qp', '20', '-g', '48',
        segment_path,
    ], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    print(f'  Processing {total} frames with EGVSR (4x → {out_w}x{out_h})...',
          file=sys.stderr, flush=True)

    scene_changes = 0
    prev_img_f32 = None  # previous frame as float32 [0,1] BGR

    for i, f in enumerate(frames):
        img = cv2.imread(f)
        img_f32 = img.astype(np.float32) / 255.0

        lr_cur = torch.from_numpy(
            cv2.cvtColor(img, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0
        ).permute(2, 0, 1).unsqueeze(0).cuda()

        # Temporal state management:
        #   cold start / hard cut → bicubic seed for hr_prev, then N warmup passes
        #   (warmup runs model on the current frame without writing output so the
        #   recurrent state settles before the first real output frame)
        if cold_start and i == 0:
            hr_prev = torch.nn.functional.interpolate(
                lr_cur, scale_factor=4, mode='bicubic', align_corners=False
            ).clamp(0, 1).detach()
            lr_prev = lr_cur.detach()
            if scene_warmup > 0:
                hr_prev, lr_prev = warmup_state(model, lr_cur, lr_prev, hr_prev, scene_warmup)
        elif prev_img_f32 is not None:
            global_diff = np.abs(img_f32 - prev_img_f32).mean()
            if global_diff > SCENE_CHANGE_THRESHOLD:
                scene_changes += 1
                hr_prev = torch.nn.functional.interpolate(
                    lr_cur, scale_factor=4, mode='bicubic', align_corners=False
                ).clamp(0, 1).detach()
                lr_prev = lr_cur.detach()
                if scene_warmup > 0:
                    hr_prev, lr_prev = warmup_state(model, lr_cur, lr_prev, hr_prev, scene_warmup)

        prev_img_f32 = img_f32

        with torch.no_grad():
            hr = model(lr_cur, lr_prev, hr_prev)
        hr_prev = hr.detach()
        lr_prev = lr_cur.detach()

        out = (hr.squeeze(0).clamp(0, 1) * 255).byte()
        out = out.flip(0).permute(1, 2, 0).contiguous()
        ffmpeg_proc.stdin.write(out.cpu().numpy().tobytes())
        ffmpeg_proc.stdin.flush()
        del out

        # Periodically release the HIP/ROCm memory pool to prevent fragmentation.
        if (i + 1) % 100 == 0:
            torch.cuda.empty_cache()

        if (i + 1) % 100 == 0 or i == total - 1:
            print(f'  Frame {i + 1}/{total}', file=sys.stderr, flush=True)

    ffmpeg_proc.stdin.close()
    ffmpeg_proc.wait()

    if ffmpeg_proc.returncode != 0:
        raise RuntimeError(f'ffmpeg VAAPI encode failed (exit {ffmpeg_proc.returncode})')
    if not os.path.exists(segment_path) or os.path.getsize(segment_path) == 0:
        raise RuntimeError(f'segment missing or empty: {segment_path}')

    return hr_prev, lr_prev, scene_changes


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--input', required=True, help='Source MKV file')
    parser.add_argument('--segments-dir', required=True,
                        help='Directory for per-chunk segment MKVs (shell-managed, survives crashes)')
    parser.add_argument('--in-width', type=int, required=True)
    parser.add_argument('--in-height', type=int, required=True)
    parser.add_argument('--out-width', type=int, required=True)
    parser.add_argument('--out-height', type=int, required=True)
    parser.add_argument('--duration', type=int, required=True,
                        help='Total source duration in integer seconds')
    parser.add_argument('--chunk-sec', type=int, default=600)
    parser.add_argument('--scene-warmup', type=int, default=3,
                        help='Model passes (no output) run at cold start and hard scene '
                             'cuts to settle temporal state before writing frames (default: 3)')
    parser.add_argument('--denoise', choices=['none', 'spatial', 'full'], default='none',
                        help='Pre-EGVSR denoising: none=preserve grain (pre-2000 film), '
                             'spatial=per-frame only (hqdn3d luma/chroma, no temporal), '
                             'full=spatial+temporal (default: none)')
    args = parser.parse_args()

    torch.backends.cudnn.benchmark = True

    sys.path.insert(0, os.path.join(EGVSR_ROOT, 'codes'))
    from models.networks.egvsr_nets import FRNet

    model = FRNet(in_nc=3, out_nc=3, nf=64, nb=10, degradation='BI', scale=4)
    ckpt = torch.load(WEIGHTS, map_location='cpu', weights_only=False)
    ckpt = {k: v for k, v in ckpt.items() if 'upsample_func.kernels' not in k}
    model.load_state_dict(ckpt, strict=False)
    model = model.cuda().eval()

    # torch.compile is disabled: on ROCm/gfx1031 it caches a new compiled graph
    # variant on each scene-change warmup, silently growing VRAM by ~1 GB per
    # 1000 frames until OOM. The uncompiled model is fast enough on this GPU.
    print('  torch.compile: disabled (ROCm graph-cache leak)', file=sys.stderr, flush=True)

    total_chunks = (args.duration + args.chunk_sec - 1) // args.chunk_sec
    segment_list_path = os.path.join(args.segments_dir, 'segments.txt')

    hr_prev = None
    lr_prev = None
    cold_start = True

    segments_txt = open(segment_list_path, 'w')
    try:
        for chunk_idx in range(total_chunks):
            start = chunk_idx * args.chunk_sec
            end = min(start + args.chunk_sec, args.duration)
            chunk_dur = end - start
            segment_path = os.path.join(args.segments_dir,
                                        f'segment_{chunk_idx + 1:04d}.mkv')

            chunk_wall_start = time.time()
            ts(f'[Chunk {chunk_idx + 1}/{total_chunks}] {start}s → {end}s')

            with tempfile.TemporaryDirectory() as frames_dir:
                try:
                    frame_count = extract_frames(
                        args.input, start, chunk_dur,
                        args.in_width, args.in_height, frames_dir,
                        denoise=args.denoise,
                    )
                except subprocess.CalledProcessError as e:
                    raise RuntimeError(f'Frame extraction failed: {e}')

                if frame_count == 0:
                    ts('  No frames extracted, skipping.')
                    continue

                chunk_fps = frame_count / chunk_dur
                print(f'  Frames: {frame_count}  FPS (post-IVTC): {chunk_fps:.6f}',
                      file=sys.stderr, flush=True)

                if hr_prev is None:
                    img0 = cv2.imread(
                        sorted(glob.glob(os.path.join(frames_dir, '*.png')))[0]
                    )
                    h, w = img0.shape[:2]
                    hr_prev = torch.zeros(1, 3, h * 4, w * 4,
                                         dtype=torch.float32).cuda()
                    lr_prev = torch.zeros(1, 3, h, w,
                                         dtype=torch.float32).cuda()

                hr_prev, lr_prev, scene_changes = process_chunk(
                    frames_dir, chunk_fps,
                    args.out_width, args.out_height,
                    segment_path, model, hr_prev, lr_prev,
                    scene_warmup=args.scene_warmup,
                    cold_start=cold_start,
                )
                cold_start = False

            segments_txt.write(f"file '{segment_path}'\n")
            segments_txt.flush()

            elapsed = int(time.time() - chunk_wall_start)
            notes = []
            if scene_changes:
                notes.append(f'scene cuts: {scene_changes}')
            ts(f'  Chunk {chunk_idx + 1} done in {elapsed}s'
               f' @ {chunk_fps:.3f} fps'
               f' — segment saved: {os.path.basename(segment_path)}'
               + (f'  [{", ".join(notes)}]' if notes else ''))

    except (RuntimeError, KeyboardInterrupt) as e:
        ts(f'ERROR: {e}')
        segments_txt.flush()
        segments_txt.close()
        sys.exit(1)

    segments_txt.close()


if __name__ == '__main__':
    main()
