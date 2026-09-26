#!/usr/bin/env python3
"""EGVSR 4x upscaler for live-action video. Processes an entire MKV in chunks,
keeping model and recurrent state (hr_prev/lr_prev) alive across chunk boundaries.
Writes hevc_vaapi segment MKVs plus per-frame pts files (segment_NNNN.pts) to
--segments-dir; the shell stamps the real timestamps back at the final mux
(lib/vfr-timing.sh — mixed 23.976/29.97 DVDs used to stutter and drift).

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
import re
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


def probe_duration(input_mkv):
    """Return the source's true float duration in seconds via ffprobe, or None
    on failure. --duration arrives truncated to whole seconds; the real value is
    needed so the final chunk's fps isn't computed against a short denominator."""
    cmd = [
        'ffprobe', '-v', 'error', '-show_entries', 'format=duration',
        '-of', 'default=noprint_wrappers=1:nokey=1', input_mkv,
    ]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True,
                             check=True).stdout.strip()
        return float(out)
    except (subprocess.CalledProcessError, ValueError):
        return None


def _idet_repeated_fields(input_mkv, start, dur):
    """Run ffmpeg idet on one [start, start+dur] window and return its
    repeated-field counts {Neither, Top, Bottom} (all 0 if idet emits none)."""
    cmd = [
        'ffmpeg', '-nostdin', '-ss', str(start), '-t', str(dur),
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
    return rep


def detect_telecine(input_mkv, duration):
    """Probe the source for 3:2 pulldown. True telecine repeats one field
    roughly once every five frames; progressive and true-interlaced sources
    repeat none. fieldmatch+decimate must run ONLY when that cadence is
    present — `decimate` drops 1 of every 5 frames unconditionally, so on a
    progressive source it silently destroys 20% of real film frames (and
    desyncs the result against the untouched audio).

    Samples several 120s windows and aggregates idet's repeated-field counts:
    one window at the start for shorts (< 300s), otherwise three windows at
    10%/50%/85% of the runtime. A single fixed window gives mixed-cadence discs
    a wrong global answer and left files shorter than ~12 min with no stats.
    Returns False (the safe default — no decimation) if idet produces none."""
    if duration < 300:
        starts = [0]
    else:
        starts = []
        for frac in (0.10, 0.50, 0.85):
            start = int(duration * frac)
            start = min(start, int(duration) - 120)
            start = max(start, 0)
            starts.append(start)

    agg = {'Neither': 0, 'Top': 0, 'Bottom': 0}
    for start in starts:
        rep = _idet_repeated_fields(input_mkv, start, 120)
        for key in agg:
            agg[key] += rep[key]

    total = sum(agg.values())
    if total == 0:
        return False
    # 3:2 pulldown repeats ~20% of fields; 5% clears noise/false positives.
    if (agg['Top'] + agg['Bottom']) / total <= 0.05:
        return False
    # decimate assumes a uniform 29.97 input and re-times its output as even
    # 23.976; on discs mixing soft-pulldown film (packets at 33/50 ms) with
    # hard-telecined sections it drops real frames and compresses the timeline.
    if _has_soft_pulldown(input_mkv, starts):
        ts('Telecine: repeated fields found, but soft pulldown present — IVTC skipped')
        return False
    return True


def _has_soft_pulldown(input_mkv, starts):
    """True if >1% of packet gaps in the sampled windows are 45-100 ms (soft pulldown)."""
    pts = []
    for start in starts:
        out = subprocess.run(
            ['ffprobe', '-v', 'error', '-select_streams', 'v:0',
             '-read_intervals', f'{start}%+60', '-show_entries', 'packet=pts_time',
             '-of', 'csv=p=0', input_mkv],
            capture_output=True, text=True).stdout
        pts.extend(float(x) for x in out.split() if x not in ('', 'N/A'))
    pts.sort()
    gaps = [b - a for a, b in zip(pts, pts[1:])]
    return bool(gaps) and sum(0.045 < g < 0.1 for g in gaps) / len(gaps) > 0.01


def extract_frames(input_mkv, start, limit, in_w, in_h, frames_dir, pts_path,
                   denoise='none', telecined=False):
    """Extract scaled frames for one chunk; write each frame's pts (seconds from
    the chunk start) to pts_path. Returns frame count.

    limit: chunk length in seconds; trim cuts at exactly this chunk-relative time
           so chunks partition the film (input -t overshoots 2s so yadif/decimate
           see the boundary). Pass a huge value for the final chunk (to EOF).

    telecined: when True the source carries 3:2 pulldown and fieldmatch+decimate
               reverse it to clean 23.976fps film. When False (progressive or
               true-interlaced source) those two filters are skipped — running
               `decimate` on non-telecined video drops 1 of every 5 real frames.
    denoise: 'none'    — no denoising (preserve film grain; best for pre-2000 film)
             'spatial' — per-frame spatial denoising only (hqdn3d luma/chroma, no temporal)
             'full'    — spatial + temporal denoising (hqdn3d with temporal smoothing)
    deint=all ensures every frame is deinterlaced regardless of stream flags, which is
    important for DVD sources where progressive-flagged frames can still carry combing."""
    vf = []
    if telecined:
        # combmatch=sc: full field-analysis only on scene changes (valid values: none/sc/full).
        # combmatch=full was too aggressive on MPEG-2 sources — block-edge patterns triggered
        # false-positive field matches → horizontal blending artifacts.
        vf.append('fieldmatch=order=auto:combmatch=sc')
    vf.append('yadif=mode=0:parity=-1:deint=all')
    if telecined:
        vf.append('decimate')
    vf.append(f'trim=end={limit}')
    # (An spp deblock sat here until Sept 2026 but was a silent no-op: ffmpeg only
    # hands it QP tables with -export_side_data venc_params.)
    if denoise == 'spatial':
        # Mild spatial denoise only — full-strength hqdn3d causes mushiness on
        # clean digital sources.
        vf.append('hqdn3d=2:1.5:0:0')
    elif denoise == 'full':
        vf.append('hqdn3d=2:1.5:6:4.5')
    vf.append(f'scale={in_w}:{in_h}:flags=lanczos')
    vf.append('showinfo')
    cmd = [
        'ffmpeg', '-y', '-nostdin', '-nostats',
        '-ss', str(start),
        '-t', str(limit + 2),
        '-i', input_mkv,
        '-map', '0:v:0',
        '-vf', ','.join(vf),
        # compression_level 1: extraction is serial with the GPU, so minimise
        # PNG deflate CPU cost (default level burns real time on the critical path).
        '-fps_mode', 'passthrough', '-q:v', '1', '-compression_level', '1',
        '-an', '-sn',
        os.path.join(frames_dir, 'frame_%08d.png'),
    ]
    res = subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL,
                         stderr=subprocess.PIPE, text=True, errors='replace')
    pts = re.findall(r'showinfo.* pts_time:(-?[0-9.e+-]+)', res.stderr)
    with open(pts_path, 'w') as f:
        f.writelines(p + '\n' for p in pts)
    count = len(glob.glob(os.path.join(frames_dir, '*.png')))
    if count != len(pts):
        raise RuntimeError(f'{len(pts)} timestamps for {count} frames')
    return count


def warmup_state(model, lr_cur, lr_prev, hr_prev, n):
    """Run model n times on lr_cur (no output) to flush stale temporal state.
    Returns updated (hr_prev, lr_prev)."""
    for _ in range(n):
        with torch.no_grad():
            hr_prev = model(lr_cur, lr_cur, hr_prev).detach()
    return hr_prev, lr_cur.detach()


def process_chunk(frames_dir, out_w, out_h, segment_path,
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
        # Nominal rate — real per-frame timestamps are stamped at the final mux.
        '-framerate', '24000/1001',
        '-i', 'pipe:0',
        # RGB → BT.709 matrix (HD) before upload, and tag it.
        '-vf', 'scale=out_color_matrix=bt709:out_range=tv,format=nv12,hwupload',
        '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709',
        # AMD VCN HEVC is markedly less efficient than libx265; qp18 claws back quality for archival output.
        '-c:v', 'hevc_vaapi', '-qp', '18', '-g', '48',
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
    parser.add_argument('--resume-from', type=int, default=0,
                        help='Chunks already finished in --segments-dir (skipped; the '
                             'first processed chunk cold-starts temporal state)')
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

    # --duration is truncated to whole seconds; probe the true float duration so
    # the final chunk's fps uses the real tail length (see chunk loop below).
    duration_f = probe_duration(args.input) or float(args.duration)

    telecined = detect_telecine(args.input, duration_f)
    ts('Telecine: 3:2 pulldown detected — IVTC (fieldmatch+decimate) enabled'
       if telecined else
       'Telecine: none — IVTC disabled, no frame decimation (progressive source)')

    hr_prev = None
    lr_prev = None
    cold_start = True

    segments_txt = open(segment_list_path, 'a')
    try:
        for chunk_idx in range(total_chunks):
            start = chunk_idx * args.chunk_sec
            end = min(start + args.chunk_sec, args.duration)
            seg_name = f'segment_{chunk_idx + 1:04d}'
            segment_path = os.path.join(args.segments_dir, seg_name + '.mkv')
            pts_path = os.path.join(args.segments_dir, seg_name + '.pts')
            if chunk_idx < args.resume_from:
                continue
            # Final chunk runs uncapped to EOF (--duration is truncated to whole seconds).
            limit = args.chunk_sec if chunk_idx < total_chunks - 1 else args.chunk_sec + 86400

            chunk_wall_start = time.time()
            ts(f'[Chunk {chunk_idx + 1}/{total_chunks}] {start}s → {end}s')

            with tempfile.TemporaryDirectory() as frames_dir:
                try:
                    frame_count = extract_frames(
                        args.input, start, limit,
                        args.in_width, args.in_height, frames_dir, pts_path,
                        denoise=args.denoise, telecined=telecined,
                    )
                except subprocess.CalledProcessError as e:
                    raise RuntimeError(f'Frame extraction failed: {e}')

                if frame_count == 0:
                    ts('  No frames extracted, skipping.')
                    continue

                print(f'  Frames: {frame_count}', file=sys.stderr, flush=True)

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
                    frames_dir,
                    args.out_width, args.out_height,
                    segment_path, model, hr_prev, lr_prev,
                    scene_warmup=args.scene_warmup,
                    cold_start=cold_start,
                )
                cold_start = False

            segments_txt.write(f'{seg_name} {start}\n')
            segments_txt.flush()

            elapsed = int(time.time() - chunk_wall_start)
            notes = []
            if scene_changes:
                notes.append(f'scene cuts: {scene_changes}')
            ts(f'  Chunk {chunk_idx + 1} done in {elapsed}s'
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
