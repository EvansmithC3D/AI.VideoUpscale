# FlashVSR feasibility on this server — evaluated 2026-06-13

**Decision: HOLD OFF / SKIP** for now. FlashVSR cannot run in its optimized form on
this hardware, and the only viable path is a slow, unoptimized fallback of uncertain
quality. Revisit only if the conditions in "When to revisit" below change.

## Why FlashVSR was considered

FlashVSR (late-2025, OpenImagingLab) is a one-step **diffusion-based streaming** video
super-resolution model. Community forks advertise it running on "12 GB VRAM + 32 GB RAM"
(via DiT tiling + the "tiny" conditional decoder), which matches this box exactly
(RX 6700 XT 12 GB, 32 GB RAM). Its draw over our current stack is strong temporal
consistency — it would, in principle, replace the EGVSR / BasicVSR + `atadenoise`
flicker-mitigation approach.

## The blocker — the optimized path is CUDA-only

FlashVSR's efficiency comes from **Block-Sparse-Attention (mit-han-lab)**, a custom
attention kernel:

- Compiled with `nvcc` / `ninja` (CUDA C++ / CUTLASS). There is **no HIP/ROCm port**.
- Tested on NVIDIA **A100 / A800 / H200** only. Even H200 gets "limited acceleration."
- Our GPU is **gfx1031 (RDNA2)** with no `nvcc` and no matrix/WMMA hardware these
  kernels assume. It cannot build or run them.

So the headline "real-time streaming" performance is impossible here.

## The fallback — SDPA, and why it's marginal

- The [ComfyUI-FlashVSR_Stable](https://github.com/naxci1/ComfyUI-FlashVSR_Stable) node
  exposes an `sdpa` attention mode (PyTorch `scaled_dot_product_attention`), which runs
  on ROCm. The official team is also reportedly working on a non-block-sparse build.
- Trade-offs: dense/SDPA attention is **much slower** than the sparse kernel (FlashVSR is
  already far heavier per frame than EGVSR — diffusion vs. a single CNN pass), and it can
  **lose quality at higher resolutions**. SDPA throughput on gfx1031 specifically is
  unproven.
- **Unverifiable without the GPU:** the only way to confirm it actually produces frames
  is to run inference, which contends for the single GPU currently committed to the
  multi-week re-upscale campaign. We can install/import/load on CPU, but cannot validate
  a real run without pausing the campaign.

## Cost if we had proceeded

- Weights (`JunhaoZhuang/FlashVSR-v1.1`): **~7 GB** total —
  `diffusion_pytorch_model_streaming_dmd.safetensors` 5.68 GB (the DiT, shared by tiny
  and full), `Wan2.1_VAE.pth` 508 MB, `LQ_proj_in.ckpt` 576 MB, `TCDecoder.ckpt` 189 MB.
  ("tiny" vs "full" only swaps the decoder; the 5.68 GB DiT is common.)
- Plus a ROCm torch wheel (~2.5 GB) + diffusers/deps in an isolated venv → ~10 GB total.
- Disk is not the constraint (150 GB free on `/`); the constraint is bandwidth + GPU time
  for an unverifiable, likely-slow result.

## Two setup paths (for if/when we revisit)

1. **ComfyUI + FlashVSR_Stable node, `attention_mode=sdpa`** — most likely to actually
   run (pre-built/tested SDPA path); heaviest install; needs a headless API driver for
   batch use.
2. **Standalone CLI + SDPA patch** — clone `OpenImagingLab/FlashVSR`, patch its
   locality-constrained sparse attention to `scaled_dot_product_attention`, write a
   headless CLI benchmark. Fits our CLI/headless workflow better; the patch is bespoke and
   unverified until a GPU run.

Either way: isolate in a fresh venv (do **not** disturb the system `torch 2.5.1+rocm6.2`
the live-action campaign depends on), target the **tiny** decoder + DiT tiling for 12 GB,
and benchmark on a short clip (~10-20 s) against the existing EGVSR `[upscaled]` output
for the same timecode — not a full film.

## When to revisit

- OpenImagingLab ships an official **non-Block-Sparse** FlashVSR build, **or**
- A ROCm/HIP port of Block-Sparse-Attention appears (watch the ROCm 7.x RDNA2 efforts), **or**
- The server gains an NVIDIA GPU or an RDNA3+/AI-capable AMD card with mature ROCm support.

Until then, EGVSR (4K) / RealESRGAN-x2plus (1080p) / BasicVSR (experimental) remain the
right tools for this GPU.

## Sources

- FlashVSR (official): https://github.com/OpenImagingLab/FlashVSR
- Weights v1.1: https://huggingface.co/JunhaoZhuang/FlashVSR-v1.1
- Block-Sparse-Attention: https://github.com/mit-han-lab/Block-Sparse-Attention
- ComfyUI SDPA fallback fork: https://github.com/naxci1/ComfyUI-FlashVSR_Stable
- ROCm 7.x RDNA2 support effort: https://github.com/ROCm/TheRock/discussions/3194
