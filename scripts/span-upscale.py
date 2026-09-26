#!/usr/bin/env python3
"""SPAN 2x upscaler as a raw-video pipe stage (PyTorch/ROCm via spandrel).

Reads packed rgb24 frames of --width x --height from stdin and writes the
upscaled rgb24 frames (width*scale x height*scale) to stdout, in order, one
for one. The live 1080p shell scripts sandwich this between an ffmpeg decode
(stdout -> here) and an ffmpeg x265 encode (here -> stdin), so no frame ever
touches disk and the three stages run concurrently.

Model: 2xNomosUni_span_multijpg (Phhofm) — SPAN architecture, trained on the
Nomos universal dataset (real film/photography) with JPEG degradations, which
maps well onto MPEG-2 DVD block/mosquito noise. ~2.2M params; single-image
(no temporal state), so the shell's atadenoise postfilter still applies.

stdout carries frame bytes only: the real stdout fd is duplicated for frames
and fd 1 is pointed at stderr, so any stray print from torch/spandrel lands in
the log instead of corrupting the video stream.

Runs inside the dedicated venv (spandrel is not installed system-wide):
    ffmpeg -i in.mkv -f rawvideo -pix_fmt rgb24 - |
    HSA_OVERRIDE_GFX_VERSION=10.3.0 /home/evanna/.venvs/span-upscale/bin/python3 \
        scripts/span-upscale.py --width 720 --height 480 --fp16 |
    ffmpeg -f rawvideo -pix_fmt rgb24 -s 1440x960 -i - ...
"""
import argparse
import os
import queue
import sys
import threading
import time

import numpy as np
import torch

DEFAULT_MODEL = '/usr/local/share/span-models/2xNomosUni_span_multijpg.safetensors'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--width', type=int, required=True, help='Input frame width')
    parser.add_argument('--height', type=int, required=True, help='Input frame height')
    parser.add_argument('--model', default=DEFAULT_MODEL)
    parser.add_argument('--fp16', action='store_true',
                        help='Half-precision inference (2x rate on RDNA2; validate quality first)')
    parser.add_argument('--count-file',
                        help='Write the number of frames processed here on clean exit')
    args = parser.parse_args()

    frame_out = os.fdopen(os.dup(1), 'wb', buffering=0)
    os.dup2(2, 1)
    frame_in = sys.stdin.buffer

    from spandrel import ModelLoader
    desc = ModelLoader().load_from_file(args.model)
    model = desc.model.cuda().eval()
    if args.fp16:
        model = model.half()
    scale = desc.scale

    w, h = args.width, args.height
    in_size = w * h * 3
    print(f'  SPAN {scale}x ({os.path.basename(args.model)}, '
          f'{"fp16" if args.fp16 else "fp32"}): {w}x{h} -> {w * scale}x{h * scale}',
          file=sys.stderr, flush=True)

    # Pipe reads/writes release the GIL, so a reader and a writer thread keep
    # the GPU fed while the main thread runs the model.
    read_q = queue.Queue(maxsize=8)
    write_q = queue.Queue(maxsize=8)
    errors = []

    def reader():
        try:
            while True:
                buf = bytearray(in_size)
                view = memoryview(buf)
                got = 0
                while got < in_size:
                    n = frame_in.readinto(view[got:])
                    if not n:
                        break
                    got += n
                if got == 0:
                    break
                if got < in_size:
                    errors.append(f'truncated input frame ({got}/{in_size} bytes)')
                    break
                read_q.put(buf)
        finally:
            read_q.put(None)

    def writer():
        try:
            while True:
                arr = write_q.get()
                if arr is None:
                    return
                frame_out.write(memoryview(arr).cast('B'))
        except BrokenPipeError:
            errors.append('downstream encoder closed the pipe')
            while write_q.get() is not None:
                pass

    threading.Thread(target=reader, daemon=True).start()
    wthread = threading.Thread(target=writer)
    wthread.start()

    t0 = time.time()
    i = 0
    with torch.inference_mode():
        while True:
            buf = read_q.get()
            if buf is None or errors:
                break
            t = torch.frombuffer(buf, dtype=torch.uint8).cuda()
            t = t.view(h, w, 3).permute(2, 0, 1).unsqueeze(0)
            t = (t.half() if args.fp16 else t.float()) / 255.0
            out = model(t)
            out = (out.clamp(0, 1) * 255.0).round().byte()
            write_q.put(out.squeeze(0).permute(1, 2, 0).contiguous().cpu().numpy())
            i += 1
            if i % 2000 == 0:
                print(f'  Frame {i}  ({i / (time.time() - t0):.2f} fps)',
                      file=sys.stderr, flush=True)

    write_q.put(None)
    wthread.join()
    frame_out.close()

    if errors:
        print(f'ERROR: {errors[0]} after {i} frames', file=sys.stderr, flush=True)
        sys.exit(1)
    if i == 0:
        print('ERROR: no frames on stdin', file=sys.stderr, flush=True)
        sys.exit(1)

    elapsed = time.time() - t0
    print(f'  Done: {i} frames in {elapsed:.1f}s ({i / elapsed:.2f} fps)',
          file=sys.stderr, flush=True)
    if args.count_file:
        with open(args.count_file, 'w') as f:
            f.write(f'{i}\n')


if __name__ == '__main__':
    main()
