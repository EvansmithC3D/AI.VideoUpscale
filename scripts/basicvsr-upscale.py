#!/usr/bin/env python3
"""BasicVSR 4x upscaler (bidirectional temporal SR) with 1080p output.

Unlike EGVSR (causal, frame-recurrent), BasicVSR propagates features forward
AND backward over a sequence, so it needs a sub-sequence loaded at once.
Each chunk is split into non-overlapping sub-sequences of --sub-seq-len frames.
Temporal state resets at sub-sequence boundaries; within a sub-sequence the
bidirectional propagation gives strong flicker suppression.

BasicVSR is a 4x model; we output at 4x input then downscale to --out-width/-height
in the ffmpeg encoder (no-op when 4*in_w == out_w, i.e. 270p in → 1080p out).

Measured on RX 6700 XT / 12 GB / ROCm 6.4.4:
  in 480x270, sub_seq=30 → ~3.3 fps warm, ~2.2 GB peak VRAM
  in 960x540, sub_seq=10 → ~1.0 fps warm, ~9.0 GB peak VRAM
  in 960x540, sub_seq=15 → OOM (needs expandable_segments)

Usage (default 270p mode, 16:9):
    HSA_OVERRIDE_GFX_VERSION=10.3.0 python3 basicvsr-upscale.py \
        --input /mnt/jellyfin-movies/Title.mkv \
        --segments-dir /tmp/upscale_segments_$$ \
        --in-width 480 --in-height 270 \
        --out-width 1920 --out-height 1080 \
        --duration 7200 \
        --chunk-sec 300 \
        --sub-seq-len 30
"""
import argparse
import glob
import os
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime

import cv2
import numpy as np
import torch

BASICVSR_WEIGHTS = '/usr/local/share/realesrgan-pth/basicvsr_reds4.pth'


def ts(msg):
    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {msg}",
          file=sys.stderr, flush=True)


def detect_telecine(input_mkv):
    """Probe the source for 3:2 pulldown. True telecine repeats one field
    roughly once every five frames; progressive and true-interlaced sources
    repeat none. fieldmatch+decimate must run ONLY when that cadence is
    present — `decimate` drops 1 of every 5 frames unconditionally, so on a
    progressive source it silently destroys 20% of real film frames (and
    desyncs the result against the untouched audio).

    Samples 120s starting 600s in, past credits/black. Returns False (the
    safe default — no decimation) if idet produces no usable stats."""
    cmd = [
        'ffmpeg', '-nostdin', '-ss', '600', '-t', '120',
        '-i', input_mkv, '-map', '0:v:0', '-vf', 'idet', '-an',
        '-f', 'null', '-',
    ]
    out = subprocess.run(cmd, capture_output=True, text=True).stderr
    rep = {'Neither': 0, 'Top': 0, 'Bottom': 0}
    for line in out.splitlines():
        if 'Repeated Fields:' in line:
            for key in rep:
                m = re.search(rf'{key}:\s*(\d+)', line)
                if m:
                    rep[key] = int(m.group(1))
    total = sum(rep.values())
    if total == 0:
        return False
    # 3:2 pulldown repeats ~20% of fields; 5% clears noise/false positives.
    return (rep['Top'] + rep['Bottom']) / total > 0.05


def extract_frames(input_mkv, start, duration, in_w, in_h, frames_dir,
                   denoise='none', telecined=False):
    """Extract scaled frames for one chunk. Returns frame count.
    Preprocessing mirrors egvsr-upscale.py: combmatch=sc (safe on MPEG-2),
    deint=all, spp DCT-aware block cleanup, optional hqdn3d.

    telecined: when True, fieldmatch+decimate reverse 3:2 pulldown. When False
               they are skipped — `decimate` on a non-telecined source drops
               1 of every 5 real frames."""
    vf = []
    if telecined:
        vf.append('fieldmatch=order=auto:combmatch=sc')
    vf.append('yadif=mode=0:parity=-1:deint=all')
    if telecined:
        vf.append('decimate')
    vf.append('spp=quality=4')
    if denoise == 'spatial':
        vf.append('hqdn3d=2:1.5:0:0')
    elif denoise == 'full':
        vf.append('hqdn3d=2:1.5:6:4.5')
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


def load_basicvsr(weights_path, device='cuda'):
    """Load BasicVSRNet from the official mmedit/mmagic checkpoint.
    Strips the 'generator.' prefix wrapping every state_dict key."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from realbasicvsr_arch import BasicVSRNet

    ckpt = torch.load(weights_path, map_location='cpu', weights_only=False)
    sd = ckpt.get('state_dict', ckpt)
    sd = {k[len('generator.'):]: v for k, v in sd.items() if k.startswith('generator.')}

    model = BasicVSRNet(mid_channels=64, num_blocks=30)
    missing, unexpected = model.load_state_dict(sd, strict=False)
    if missing:
        print(f'  [warn] missing keys ({len(missing)}): {missing[:3]}...',
              file=sys.stderr, flush=True)
    if unexpected:
        print(f'  [warn] unexpected keys ({len(unexpected)}): {unexpected[:3]}...',
              file=sys.stderr, flush=True)
    return model.to(device).eval()


def run_subseq(model, frames_bgr):
    """Run BasicVSR on one sub-sequence.
    frames_bgr: list of H×W×3 uint8 BGR arrays.
    Returns: [T, 4H, 4W, 3] uint8 BGR numpy array."""
    arr = np.stack(frames_bgr, axis=0)[..., ::-1].copy()  # BGR→RGB
    tensor = (torch.from_numpy(arr).float()
              .div(255.0)
              .permute(0, 3, 1, 2)
              .unsqueeze(0)
              .cuda())  # [1, T, 3, H, W] RGB
    with torch.no_grad():
        out = model(tensor)  # [1, T, 3, 4H, 4W] RGB in [0,1]
    out = (out.squeeze(0).clamp(0, 1) * 255).byte()
    # [T, 3, 4H, 4W] RGB → [T, 4H, 4W, 3] BGR
    out = out.flip(1).permute(0, 2, 3, 1).contiguous()
    return out.cpu().numpy()


def process_chunk(frames_dir, chunk_fps, in_w, in_h, out_w, out_h,
                  segment_path, model, sub_seq_len):
    """Run BasicVSR on all frames in frames_dir, encoding to VAAPI segment.
    Sub-sequences are non-overlapping; temporal state resets at each boundary."""
    frame_paths = sorted(glob.glob(os.path.join(frames_dir, '*.png')))
    total = len(frame_paths)
    if total == 0:
        return

    model_out_w = in_w * 4
    model_out_h = in_h * 4
    ffmpeg_proc = subprocess.Popen([
        'ffmpeg', '-y',
        '-vaapi_device', '/dev/dri/renderD128',
        '-f', 'rawvideo', '-pixel_format', 'bgr24',
        '-video_size', f'{model_out_w}x{model_out_h}',
        '-framerate', str(chunk_fps),
        '-i', 'pipe:0',
        '-vf', f'scale={out_w}:{out_h}:flags=lanczos,format=nv12,hwupload',
        '-c:v', 'hevc_vaapi', '-qp', '20', '-g', '48',
        segment_path,
    ], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    print(f'  Processing {total} frames with BasicVSR '
          f'(sub-seq {sub_seq_len}, 4x → {model_out_w}x{model_out_h}, '
          f'downscale → {out_w}x{out_h})...',
          file=sys.stderr, flush=True)

    try:
        written = 0
        i = 0
        while i < total:
            end = min(i + sub_seq_len, total)
            # BasicVSR flow computation needs t>=2; absorb a lone trailing frame
            # into the current sub-seq rather than leaving it stranded.
            if total - end == 1:
                end = total

            frames_bgr = [cv2.imread(frame_paths[j]) for j in range(i, end)]
            if len(frames_bgr) < 2:
                # Pathological: chunk is a single frame. Duplicate so flow runs,
                # keep only one output.
                frames_bgr = frames_bgr + frames_bgr
                out_arr = run_subseq(model, frames_bgr)[:1]
            else:
                out_arr = run_subseq(model, frames_bgr)

            for k in range(out_arr.shape[0]):
                ffmpeg_proc.stdin.write(out_arr[k].tobytes())
            written += out_arr.shape[0]
            i = end

            torch.cuda.empty_cache()
            if written >= total or written % (sub_seq_len * 4) < sub_seq_len:
                print(f'  Frame {written}/{total}', file=sys.stderr, flush=True)
    finally:
        ffmpeg_proc.stdin.close()
        ffmpeg_proc.wait()

    if ffmpeg_proc.returncode != 0:
        raise RuntimeError(f'ffmpeg VAAPI encode failed (exit {ffmpeg_proc.returncode})')
    if not os.path.exists(segment_path) or os.path.getsize(segment_path) == 0:
        raise RuntimeError(f'segment missing or empty: {segment_path}')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--input', required=True, help='Source MKV file')
    parser.add_argument('--segments-dir', required=True,
                        help='Directory for per-chunk segment MKVs')
    parser.add_argument('--in-width', type=int, required=True)
    parser.add_argument('--in-height', type=int, required=True)
    parser.add_argument('--out-width', type=int, required=True,
                        help='Final output width (model runs at 4x input, downscaled here)')
    parser.add_argument('--out-height', type=int, required=True)
    parser.add_argument('--duration', type=int, required=True,
                        help='Total source duration in integer seconds')
    parser.add_argument('--chunk-sec', type=int, default=300)
    parser.add_argument('--sub-seq-len', type=int, default=30,
                        help='Frames per bidirectional sub-sequence. Higher = better '
                             'temporal consistency but more VRAM. Safe caps on 12GB: '
                             '~30 at 270p, ~10 at 540p. Shell wrappers pick per --in-res.')
    parser.add_argument('--denoise', choices=['none', 'spatial', 'full'], default='none',
                        help='Pre-BasicVSR denoising (default: none)')
    args = parser.parse_args()

    torch.backends.cudnn.benchmark = True

    ts('Loading BasicVSR (REDS4 weights)...')
    model = load_basicvsr(BASICVSR_WEIGHTS)
    ts('  Ready.')

    total_chunks = (args.duration + args.chunk_sec - 1) // args.chunk_sec
    segment_list_path = os.path.join(args.segments_dir, 'segments.txt')

    telecined = detect_telecine(args.input)
    ts('Telecine: 3:2 pulldown detected — IVTC (fieldmatch+decimate) enabled'
       if telecined else
       'Telecine: none — IVTC disabled, no frame decimation (progressive source)')

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
                        denoise=args.denoise, telecined=telecined,
                    )
                except subprocess.CalledProcessError as e:
                    raise RuntimeError(f'Frame extraction failed: {e}')

                if frame_count == 0:
                    ts('  No frames extracted, skipping.')
                    continue

                chunk_fps = frame_count / chunk_dur
                print(f'  Frames: {frame_count}  FPS: {chunk_fps:.6f}',
                      file=sys.stderr, flush=True)

                process_chunk(
                    frames_dir, chunk_fps,
                    args.in_width, args.in_height,
                    args.out_width, args.out_height,
                    segment_path, model, args.sub_seq_len,
                )

            segments_txt.write(f"file '{segment_path}'\n")
            segments_txt.flush()

            elapsed = int(time.time() - chunk_wall_start)
            ts(f'  Chunk {chunk_idx + 1} done in {elapsed}s'
               f' @ {chunk_fps:.3f} fps'
               f' — segment saved: {os.path.basename(segment_path)}')

    except (RuntimeError, KeyboardInterrupt) as e:
        ts(f'ERROR: {e}')
        segments_txt.flush()
        segments_txt.close()
        sys.exit(1)

    segments_txt.close()


if __name__ == '__main__':
    main()
