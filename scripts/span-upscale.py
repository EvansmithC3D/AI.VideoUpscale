#!/usr/bin/env python3
"""SPAN 2x upscaler for extracted PNG frames (PyTorch/ROCm via spandrel).

Drop-in replacement for realesrgan-ncnn-vulkan's directory contract: upscales
every PNG in --input and writes a same-named PNG to --output. The live 1080p
shell scripts call this for the GPU stage; extraction/encode stay in the shell.

Model: 2xNomosUni_span_multijpg (Phhofm) — SPAN architecture, trained on the
Nomos universal dataset (real film/photography) with JPEG degradations, which
maps well onto MPEG-2 DVD block/mosquito noise. ~2.2M params; single-image
(no temporal state), so the shell's atadenoise postfilter still applies.

Runs inside the dedicated venv (spandrel is not installed system-wide):
    HSA_OVERRIDE_GFX_VERSION=10.3.0 /home/evanna/.venvs/span-upscale/bin/python3 \
        scripts/span-upscale.py --input /tmp/frames --output /tmp/upscaled
"""
import argparse
import glob
import os
import queue
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor

import cv2
import torch

DEFAULT_MODEL = '/usr/local/share/span-models/2xNomosUni_span_multijpg.safetensors'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--input', required=True, help='Directory of source PNG frames')
    parser.add_argument('--output', required=True, help='Directory for upscaled PNG frames')
    parser.add_argument('--model', default=DEFAULT_MODEL)
    parser.add_argument('--fp16', action='store_true',
                        help='Half-precision inference (2x rate on RDNA2; validate quality first)')
    args = parser.parse_args()

    from spandrel import ModelLoader
    desc = ModelLoader().load_from_file(args.model)
    model = desc.model.cuda().eval()
    if args.fp16:
        model = model.half()
    scale = desc.scale

    frames = sorted(glob.glob(os.path.join(args.input, '*.png')))
    total = len(frames)
    if total == 0:
        print('ERROR: no PNG frames in input directory', file=sys.stderr, flush=True)
        sys.exit(1)

    os.makedirs(args.output, exist_ok=True)
    print(f'  SPAN {scale}x ({os.path.basename(args.model)}, '
          f'{"fp16" if args.fp16 else "fp32"}): {total} frames',
          file=sys.stderr, flush=True)

    # PNG decode/encode dominates over the ~2.2M-param model, so overlap them:
    # a reader thread prefetches decodes and a small writer pool handles encodes
    # (cv2 releases the GIL in imread/imwrite) while the main thread runs the GPU.
    read_q = queue.Queue(maxsize=4)

    def reader():
        for f in frames:
            read_q.put((f, cv2.imread(f)))
        read_q.put(None)

    write_errors = []

    def write_frame(path, arr):
        if not cv2.imwrite(path, arr, [cv2.IMWRITE_PNG_COMPRESSION, 1]):
            write_errors.append(path)

    threading.Thread(target=reader, daemon=True).start()

    t0 = time.time()
    i = 0
    with torch.inference_mode(), ThreadPoolExecutor(max_workers=2) as writers:
        pending = []
        while True:
            item = read_q.get()
            if item is None:
                break
            f, img = item
            if img is None:
                print(f'ERROR: unreadable frame {f}', file=sys.stderr, flush=True)
                sys.exit(1)
            t = torch.from_numpy(img[..., ::-1].copy()).cuda()
            t = t.permute(2, 0, 1).unsqueeze(0)
            t = (t.half() if args.fp16 else t.float()) / 255.0
            out = model(t)
            out = (out.clamp(0, 1) * 255.0).round().byte()
            out = out.squeeze(0).permute(1, 2, 0).cpu().numpy()[..., ::-1]
            pending.append(writers.submit(
                write_frame, os.path.join(args.output, os.path.basename(f)), out))
            if len(pending) > 8:
                pending = [p for p in pending if not p.done()]
            i += 1
            if i % 500 == 0 or i == total:
                fps = i / (time.time() - t0)
                print(f'  Frame {i}/{total}  ({fps:.2f} fps)', file=sys.stderr, flush=True)

    if write_errors:
        print(f'ERROR: failed writing {len(write_errors)} frames '
              f'(first: {write_errors[0]})', file=sys.stderr, flush=True)
        sys.exit(1)
    written = len(glob.glob(os.path.join(args.output, '*.png')))
    if written != total:
        print(f'ERROR: wrote {written}/{total} frames', file=sys.stderr, flush=True)
        sys.exit(1)

    elapsed = time.time() - t0
    print(f'  Done: {total} frames in {elapsed:.1f}s ({total / elapsed:.2f} fps)',
          file=sys.stderr, flush=True)


if __name__ == '__main__':
    main()
