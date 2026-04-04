#!/usr/bin/env python3
"""Batch upscale a directory of PNG frames using RealESRGAN (PyTorch/ROCm).

Usage:
    HSA_OVERRIDE_GFX_VERSION=10.3.0 python3 realesrgan-upscale.py \
        --model x2plus --input /tmp/frames --output /tmp/upscaled
"""
import argparse
import glob
import os
import sys

import cv2


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--model', choices=['x2plus', 'x4plus'], required=True)
    parser.add_argument('--input', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()

    from basicsr.archs.rrdbnet_arch import RRDBNet
    from realesrgan import RealESRGANer

    scale = 2 if args.model == 'x2plus' else 4
    model_path = f'/usr/local/share/realesrgan-pth/RealESRGAN_{args.model}.pth'

    model = RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64, num_block=23,
                    num_grow_ch=32, scale=scale)
    upsampler = RealESRGANer(
        scale=scale, model_path=model_path, model=model,
        tile=0, tile_pad=10, pre_pad=0, half=True, device='cuda'
    )

    frames = sorted(glob.glob(os.path.join(args.input, '*.png')))
    total = len(frames)
    if total == 0:
        print('  ERROR: No PNG frames found in input directory', flush=True)
        sys.exit(1)

    print(f'  Processing {total} frames with RealESRGAN-{args.model} (scale={scale}x)...', flush=True)

    for i, f in enumerate(frames):
        img = cv2.imread(f, cv2.IMREAD_UNCHANGED)
        out, _ = upsampler.enhance(img, outscale=scale)
        cv2.imwrite(os.path.join(args.output, os.path.basename(f)), out)
        if (i + 1) % 100 == 0 or i == total - 1:
            print(f'  Frame {i+1}/{total}', flush=True)


if __name__ == '__main__':
    main()
