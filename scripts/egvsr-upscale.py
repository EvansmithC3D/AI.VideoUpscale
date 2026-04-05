#!/usr/bin/env python3
"""Upscale PNG frames from a directory using EGVSR 4x, writing raw BGR24
frames to stdout for direct piping into ffmpeg — no intermediate PNG writes.

Usage:
    HSA_OVERRIDE_GFX_VERSION=10.3.0 python3 egvsr-upscale.py \
        --input /tmp/frames | \
    ffmpeg -f rawvideo -pixel_format bgr24 -video_size 3840x2160 \
           -framerate 29.97 -i pipe:0 -c:v libx265 -crf 18 output.mkv
"""
import argparse
import glob
import os
import sys

import cv2
import numpy as np
import torch

EGVSR_ROOT = '/usr/local/share/egvsr'
WEIGHTS = os.path.join(EGVSR_ROOT, 'EGVSR_iter420000.pth')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--input', required=True)
    args = parser.parse_args()

    sys.path.insert(0, os.path.join(EGVSR_ROOT, 'codes'))
    from models.networks.egvsr_nets import FRNet

    model = FRNet(in_nc=3, out_nc=3, nf=64, nb=10, degradation='BI', scale=4)
    ckpt = torch.load(WEIGHTS, map_location='cpu', weights_only=False)
    ckpt = {k: v for k, v in ckpt.items() if 'upsample_func.kernels' not in k}
    model.load_state_dict(ckpt, strict=False)
    model = model.cuda().eval()

    frames = sorted(glob.glob(os.path.join(args.input, '*.png')))
    total = len(frames)
    if total == 0:
        print('  ERROR: No PNG frames found in input directory', file=sys.stderr, flush=True)
        sys.exit(1)

    img0 = cv2.imread(frames[0])
    h, w = img0.shape[:2]
    hr_prev = torch.zeros(1, 3, h * 4, w * 4, dtype=torch.float32).cuda()

    print(f'  Processing {total} frames with EGVSR (4x → {w*4}x{h*4})...', file=sys.stderr, flush=True)

    out_stream = sys.stdout.buffer

    for i, f in enumerate(frames):
        img = cv2.imread(f)
        lr = torch.from_numpy(
            cv2.cvtColor(img, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0
        ).permute(2, 0, 1).unsqueeze(0).cuda()

        with torch.no_grad():
            hr = model(lr, lr, hr_prev)
        hr_prev = hr.detach()

        out = hr.squeeze(0).cpu().numpy().transpose(1, 2, 0)
        out = np.clip(out, 0, 1)
        out_bgr = cv2.cvtColor((out * 255).astype(np.uint8), cv2.COLOR_RGB2BGR)
        out_stream.write(out_bgr.tobytes())
        out_stream.flush()

        if (i + 1) % 100 == 0 or i == total - 1:
            print(f'  Frame {i+1}/{total}', file=sys.stderr, flush=True)


if __name__ == '__main__':
    main()
