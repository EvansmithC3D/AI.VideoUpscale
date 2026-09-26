#!/usr/bin/env python3
"""Estimate the A/V drift an old upscale has from per-chunk even-spread timing.

Before Sept 2026 every upscale script dropped frame timestamps and re-timed each
chunk at (frame count / chunk seconds) fps. On sources mixing 23.976 film with
29.97 video-rate sections this drifts the picture off the audio mid-chunk (and
stutters). This replays that re-timing against the source's real packet
timestamps and reports the worst drift — no decode, no GPU.

Usage: scan-timing-drift.py [--chunk SECONDS] file.mkv [file.mkv ...]
Output (TSV, one line per file): max_drift_ms  seconds_over_45ms  frames  file
"""
import argparse
import subprocess
import sys


def packet_pts(path):
    out = subprocess.run(
        ['ffprobe', '-v', 'error', '-select_streams', 'v:0',
         '-show_entries', 'packet=pts_time', '-of', 'csv=p=0', path],
        capture_output=True, text=True, check=True).stdout
    return sorted(float(x) for x in out.split() if x not in ('', 'N/A'))


def drift(pts, chunk):
    t0 = pts[0]
    rel = [p - t0 for p in pts]
    end = rel[-1]
    worst, over, i = 0.0, 0.0, 0
    start = 0.0
    while start <= end:
        stop = start + chunk
        j = i
        while j < len(rel) and rel[j] < stop:
            j += 1
        n = j - i
        if n:
            span = min(chunk, end - start + (rel[j - 1] - rel[j - 2] if n > 1 else 0))
            step = span / n
            prev_bad = None
            for k in range(n):
                d = abs(start + k * step - rel[i + k])
                worst = max(worst, d)
                if d > 0.045:
                    if prev_bad is not None:
                        over += rel[i + k] - prev_bad
                    prev_bad = rel[i + k]
                else:
                    prev_bad = None
        i = j
        start = stop
    return worst, over


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--chunk', type=float, default=300)
    ap.add_argument('files', nargs='+')
    args = ap.parse_args()
    for f in args.files:
        try:
            pts = packet_pts(f)
            worst, over = drift(pts, args.chunk)
            print(f'{worst * 1000:.0f}\t{over:.0f}\t{len(pts)}\t{f}', flush=True)
        except Exception as e:  # keep scanning the rest of the library
            print(f'ERR\t-\t-\t{f}\t{e}', flush=True)


if __name__ == '__main__':
    sys.exit(main())
