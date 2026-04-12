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

# Per-pixel diff at which the bicubic replacement weight reaches 1.0 (full
# replacement).  Applied to an EMA-smoothed diff map so blend weights change
# gradually rather than frame-to-frame, eliminating shimmer.
MOTION_ALPHA_SCALE = 0.06

# EMA decay for the per-pixel diff map.  0.4 = fairly responsive to new motion;
# background MPEG noise (~1-3% per-frame flicker) averages toward zero.
EMA_ALPHA = 0.4


def ts(msg):
    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {msg}",
          file=sys.stderr, flush=True)


def extract_frames(input_mkv, start, duration, in_w, in_h, frames_dir):
    """Extract IVTC'd, scaled frames for one chunk. Returns frame count."""
    cmd = [
        'ffmpeg', '-y',
        '-ss', str(start),
        '-t', str(duration),
        '-i', input_mkv,
        '-vf', f'fieldmatch=order=auto:combmatch=full,yadif=mode=0:parity=-1:deint=all,decimate,scale={in_w}:{in_h}:flags=lanczos',
        '-vsync', 'vfr', '-q:v', '1',
        os.path.join(frames_dir, 'frame_%08d.png'),
        '-an',
    ]
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return len(glob.glob(os.path.join(frames_dir, '*.png')))


def motion_blend_hr_prev(hr_prev, lr_cur, diff_map_f32):
    """Blend hr_prev toward a bicubic upscale of lr_cur proportionally to per-pixel
    motion magnitude.  Moving regions get bicubic (no ghost from wrong position);
    static regions keep the real temporal state.  diff_map_f32 is (H, W, 3) in [0,1]."""
    # Per-pixel weight: 0 = keep hr_prev, 1 = use bicubic
    weight = np.clip(diff_map_f32 / MOTION_ALPHA_SCALE, 0.0, 1.0)          # (H, W, 3)
    weight_t = torch.from_numpy(weight).permute(2, 0, 1).unsqueeze(0).cuda()  # (1,3,H,W)
    weight_4x = torch.nn.functional.interpolate(
        weight_t, scale_factor=4, mode='bilinear', align_corners=False
    )
    bicubic = torch.nn.functional.interpolate(
        lr_cur, scale_factor=4, mode='bicubic', align_corners=False
    ).clamp(0, 1)
    return ((1.0 - weight_4x) * hr_prev + weight_4x * bicubic).clamp(0, 1).detach()


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

    prev_img_f32 = None  # previous frame as float32 [0,1] BGR
    ema_diff = None      # EMA-smoothed per-pixel diff map, float32 (H,W,3)
    scene_changes = 0
    motion_blends = 0

    for i, f in enumerate(frames):
        img = cv2.imread(f)
        img_f32 = img.astype(np.float32) / 255.0

        lr_cur = torch.from_numpy(
            cv2.cvtColor(img, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0
        ).permute(2, 0, 1).unsqueeze(0).cuda()

        # Temporal state management:
        #   cold start / hard cut → full bicubic reset; EMA diff reset to zero
        #   intra-scene motion    → EMA-smoothed per-pixel blend: moving regions
        #                           get bicubic, static regions keep temporal state
        if cold_start and i == 0:
            hr_prev = torch.nn.functional.interpolate(
                lr_cur, scale_factor=4, mode='bicubic', align_corners=False
            ).clamp(0, 1).detach()
            lr_prev = lr_cur.detach()
            ema_diff = None
        elif prev_img_f32 is not None:
            diff_map = np.abs(img_f32 - prev_img_f32)
            global_diff = diff_map.mean()
            if global_diff > SCENE_CHANGE_THRESHOLD:
                scene_changes += 1
                hr_prev = torch.nn.functional.interpolate(
                    lr_cur, scale_factor=4, mode='bicubic', align_corners=False
                ).clamp(0, 1).detach()
                lr_prev = lr_cur.detach()
                ema_diff = None
            else:
                # Update EMA diff: seed with raw diff on first frame after cut
                if ema_diff is None:
                    ema_diff = diff_map
                else:
                    ema_diff = EMA_ALPHA * diff_map + (1.0 - EMA_ALPHA) * ema_diff
                if ema_diff.max() > MOTION_ALPHA_SCALE * 0.5:
                    motion_blends += 1
                    hr_prev = motion_blend_hr_prev(hr_prev, lr_cur, ema_diff)

        prev_img_f32 = img_f32

        with torch.no_grad():
            hr = model(lr_cur, lr_prev, hr_prev)
        hr_prev = hr.detach()
        lr_prev = lr_cur.detach()

        out = (hr.squeeze(0).clamp(0, 1) * 255).byte()
        out = out.flip(0).permute(1, 2, 0).contiguous()
        ffmpeg_proc.stdin.write(out.cpu().numpy().tobytes())
        ffmpeg_proc.stdin.flush()

        if (i + 1) % 100 == 0 or i == total - 1:
            print(f'  Frame {i + 1}/{total}', file=sys.stderr, flush=True)

    ffmpeg_proc.stdin.close()
    ffmpeg_proc.wait()

    if ffmpeg_proc.returncode != 0:
        raise RuntimeError(f'ffmpeg VAAPI encode failed (exit {ffmpeg_proc.returncode})')
    if not os.path.exists(segment_path) or os.path.getsize(segment_path) == 0:
        raise RuntimeError(f'segment missing or empty: {segment_path}')

    return hr_prev, lr_prev, scene_changes, motion_blends


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
    parser.add_argument('--scene-warmup', type=int, default=30,
                        help='Model passes (no output) run at hard scene cuts and '
                             'cold start to flush stale temporal state (default: 8)')
    args = parser.parse_args()

    torch.backends.cudnn.benchmark = True

    sys.path.insert(0, os.path.join(EGVSR_ROOT, 'codes'))
    from models.networks.egvsr_nets import FRNet

    model = FRNet(in_nc=3, out_nc=3, nf=64, nb=10, degradation='BI', scale=4)
    ckpt = torch.load(WEIGHTS, map_location='cpu', weights_only=False)
    ckpt = {k: v for k, v in ckpt.items() if 'upsample_func.kernels' not in k}
    model.load_state_dict(ckpt, strict=False)
    model = model.cuda().eval()

    try:
        model = torch.compile(model)
        print('  torch.compile: enabled', file=sys.stderr, flush=True)
    except Exception as e:
        print(f'  torch.compile: skipped ({e})', file=sys.stderr, flush=True)

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
                        args.in_width, args.in_height, frames_dir
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

                hr_prev, lr_prev, scene_changes, motion_blends = process_chunk(
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
            if motion_blends:
                notes.append(f'motion blends: {motion_blends}')
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
