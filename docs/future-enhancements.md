# Future enhancements — re-review backlog

This is the running backlog for periodic tech re-reviews ("re-review the repo for
new models / efficiency enhancements for ROCm hardware"). A re-review should **start
here**: for each item, check the revisit trigger, research what's changed since the
last look, and update this file — move items that are now actionable, add dated notes
on what you found, and adjust triggers if they've shifted. See
`docs/flashvsr-feasibility.md` for the tone/depth expected of a fully-evaluated item.

**Last reviewed: 2026-09-26**

---

## a. Temporal (multi-frame) VSR to replace SPAN + atadenoise

SPAN (`2xNomosUni_span_multijpg`) is a single-image model, so the live 1080p pipeline
leans on an `atadenoise=s=5` postfilter to suppress per-frame flicker, at the cost of
slight smoothing. BasicVSR is already in the repo as a manual, experimental path
(`scripts/upscale-live-*-basicvsr.sh`, bidirectional temporal SR, ~3.3 fps at 270p
input) — a true temporal model would remove the need for the postfilter entirely.

**Why interesting:** flicker suppression via denoise is a hack; a model with real
temporal awareness would look better and could be faster than BasicVSR's bidirectional
approach if it's designed for streaming/causal inference.

**Why deferred today:** research candidates found in Sept 2026 don't yet have
production-ready weights suited to DVD/MPEG-2 degradation:
- LIF-VSR (lightweight, near real-time) — https://www.ncbi.nlm.nih.gov/pmc/articles/PMC12846234/
- Compressed-Domain-Aware Online VSR — https://arxiv.org/pdf/2603.07694
- AdcVSR (diffusion-distilled, ICLR 2026) — https://mlanthology.org/iclr/2026/chen2026iclr-improved/

**Revisit trigger:** open weights for a lightweight temporal model trained on
compressed/real-world degradations, loadable in PyTorch without CUDA-only kernels.

---

## b. A/B test Phhofm `2xPublic_realplksr_dysample_layernorm`

A RealPLKSR 2x model (June 2025) that handles blur, noise, JPEG artifacts, and
sharpening in one pass. Spandrel already loads it, so it's a drop-in swap for
`scripts/span-upscale.py --model` — no pipeline changes needed.

**Why interesting:** it's heavier than SPAN, so quality might be meaningfully better;
cheap to find out.

**Why deferred today:** hasn't been benchmarked against SPAN on this library's actual
DVD sources yet.

**Links:** https://github.com/Phhofm/models/releases and https://openmodeldb.info/
(also scan for new Phhofm and OpenModelDB 2x releases generally each review).

**Revisit trigger:** none needed — it's cheap to test on a 90 s clip any review.

---

## c. AV1 encoding via SVT-AV1 in place of x265 medium CRF 18

SVT-AV1 presets 6–8 roughly match or beat x265 medium/slow on quality-per-bit and
encode faster, which matters because the live pipeline's final mux/encode stage is
CPU-bound (Ryzen 7 3700X) rather than GPU-bound.

**Why interesting:** faster encode = shorter end-to-end job time, potentially better
quality at the same bitrate.

**Why deferred today:** Jellyfin client AV1 direct-play support is uneven across
devices; switching now would force server-side transcodes on older clients, trading
one bottleneck for another.

**Links:** https://jellyfin.org/docs/general/clients/codec-support/ and
https://www.forasoft.com/learn/video-quality/articles-vqm/encoder-comparison-x264-x265-svt-av1

**Revisit trigger:** all of the owner's Jellyfin client devices can direct-play AV1.

---

## d. TheRock native gfx103X PyTorch wheels

AMD's TheRock nightly `gfx103X-dgpu` wheels support gfx1031 natively, which would let
us drop `HSA_OVERRIDE_GFX_VERSION=10.3.0` entirely.

**Why interesting:** removes a compatibility hack; native kernel support could also be
faster than the gfx1030-kernel override path.

**Why deferred today:** the GPU isn't the pipeline bottleneck (the live 1080p path is
CPU/encode-bound; see item c), so there's little to gain right now. Also, **caution**:
a ROCm 6.4.3+ regression causes SIGSEGV on gfx1031/gfx1032 when
`HSA_OVERRIDE_GFX_VERSION=10.3.0` is set, and it's still unfixed as of 7.2.x
(https://github.com/ollama/ollama/issues/12111). The pinned `torch 2.5.1+rocm6.2` venv
bundles its own ROCm 6.2 libs and avoids this regression entirely — **never upgrade the
torch in the `span-upscale` venv in place**; any test of TheRock wheels must happen in
a separate, throwaway venv.

**Links:** https://github.com/ROCm/TheRock/blob/main/RELEASES.md

**Revisit trigger:** the GPU becomes the pipeline bottleneck again, or official RDNA2
support lands / the SIGSEGV regression is fixed.

---

## e. Hardware / source upgrades

Two independent upgrade paths that would beat any amount of model tuning on this box:

- **GPU:** an RDNA3/RDNA4 or NVIDIA card would unlock FlashVSR-class diffusion VSR —
  see `docs/flashvsr-feasibility.md` for the full writeup; the blocker there is that
  FlashVSR's efficient path is CUDA-only Block-Sparse-Attention with no HIP/ROCm port.
- **Source quality:** every title in this library is a 720x480 SD DVD rip (see memory
  note `library-all-sd-dvd.md`). Blu-ray (HD) sources would raise the quality ceiling
  more than any upscaling model change — the DVD is the actual bottleneck on output
  quality, not the model.

**Why deferred today:** no budget/hardware decision has been made; nothing to act on
until then.

**Revisit trigger:** a hardware purchase, or HD sources becoming available for
re-ripping.

---

## f. MIGraphX / vs-mlrt inference backend

An alternative ROCm inference path via VapourSynth + MIGraphX, as an alternative to
the current spandrel/PyTorch stack.

**Why interesting:** could be faster than PyTorch/ROCm for inference, and MIGraphX is
AMD's own optimized graph runtime.

**Why deferred today:** low value while the pipeline is CPU-bound at the encode stage
rather than GPU-bound (same underlying reason as item d).

**Links:** https://github.com/AmusementClub/vs-mlrt/releases/ and
https://pypi.org/project/vapoursynth-mlrt-migx/17.0/

**Revisit trigger:** same as item d — the GPU becomes the bottleneck again.

---

## g. Shows library

`/mnt/jellyfin-shows` is wired up client-side (fstab entry with `nofail`, queue
daemon already scans it recursively), but as of 2026-07-19 the NFS server
(192.168.40.200) does not export `/mnt/media/jellyfin/shows`. See memory note
`jellyfin-shows-mapping.md`.

**Why deferred today:** purely blocked on a server-side export; nothing to fix here.

**Revisit trigger:** the export is added server-side — then run
`sudo mount /mnt/jellyfin-shows`; the daemon picks up episodes automatically on its
next scan.

---

## i. Proper IVTC for mixed-cadence DVDs

**What:** Recover clean 23.976 progressive frames from hard-telecined sections
of discs that also contain soft-pulldown film, while keeping real per-frame
timestamps (e.g. VapourSynth VIVTC/TIVTC with timecode output, or a
field-matching step that doesn't re-time the stream).

**Why interesting:** Such sections currently just get `yadif`, so they play at
29.97 with every 5th frame a deinterlaced near-duplicate: slight judder but in
sync. True IVTC would make them smooth film.

**Why deferred:** ffmpeg's `decimate` assumes a uniform 29.97 input and
invents evenly spaced 23.976 timestamps. On mixed discs it drops real frames
and compresses the timeline (a 75 s Casino clip came out as 63.9 s). `pullup`
keeps real time but halved the film sections in testing (Sept 2026). The
scripts therefore skip IVTC whenever soft pulldown is present
(`vfr_has_soft_pulldown` in `scripts/lib/vfr-timing.sh`). No title in the
library has needed IVTC so far.

**Revisit trigger:** A title whose hard-telecined sections judder noticeably,
or a VFR-aware IVTC becomes available in the toolchain (e.g. VapourSynth is
installed for another reason).

---

## h. Standing checks every review

Regardless of the above items, every re-review should also spot-check:

- ROCm release notes for RDNA2 (gfx1031/gfx1032) status changes.
- Spandrel releases — https://github.com/chaiNNer-org/spandrel/releases (new
  supported architectures may open up new candidate models for item b).
- FlashVSR's revisit conditions in `docs/flashvsr-feasibility.md` (a ROCm/HIP
  Block-Sparse-Attention port, a non-block-sparse official build, or a GPU upgrade).
