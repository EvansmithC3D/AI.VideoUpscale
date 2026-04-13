"""Standalone RealBasicVSRNet — no mmcv/mmedit dependency.

Architecture mirrors mmagic's RealBasicVSRNet exactly so official checkpoint
weights load without structural changes beyond key stripping.

Key remapping applied during load:
  • Strip 'generator.' prefix
  • Use 'generator_ema.' weights if available (EMA weights for inference)

References:
  RealBasicVSR: Investigating Tradeoffs in Real-World Video Super-Resolution
  Chan et al., CVPR 2022  https://arxiv.org/abs/2111.12704
"""

import torch
import torch.nn as nn
import torch.nn.functional as F

from basicsr.archs.arch_util import ResidualBlockNoBN, flow_warp, make_layer


# ---------------------------------------------------------------------------
# SPyNet (matches mmagic SPyNet key structure exactly)
# ---------------------------------------------------------------------------

class _ConvModule(nn.Module):
    """Single conv layer wrapped so its key is .conv.weight — matches mmagic's
    ConvModule.  Activation is applied in forward but has no parameters."""

    def __init__(self, in_ch, out_ch, kernel, act=True):
        super().__init__()
        self.conv = nn.Conv2d(in_ch, out_ch, kernel, 1, (kernel - 1) // 2)
        self.act = act

    def forward(self, x):
        x = self.conv(x)
        if self.act:
            x = F.relu(x, inplace=True)
        return x


class _SPyNetBasicModule(nn.Module):
    """5-layer flow-estimation module.  Key structure:
      basic_module.N.conv.weight / .bias
    """

    def __init__(self):
        super().__init__()
        self.basic_module = nn.ModuleList([
            _ConvModule(8,  32, 7, act=True),
            _ConvModule(32, 64, 7, act=True),
            _ConvModule(64, 32, 7, act=True),
            _ConvModule(32, 16, 7, act=True),
            _ConvModule(16,  2, 7, act=False),
        ])

    def forward(self, x):
        for m in self.basic_module:
            x = m(x)
        return x


class SPyNet(nn.Module):
    """Spatial Pyramid Network for optical flow.

    Key structure mirrors mmagic SPyNet:
      basic_module.L.basic_module.N.conv.{weight,bias}
      mean, std
    """

    def __init__(self):
        super().__init__()
        self.basic_module = nn.ModuleList([_SPyNetBasicModule() for _ in range(6)])
        self.register_buffer('mean', torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1))
        self.register_buffer('std',  torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1))

    def _compute_flow(self, ref, supp):
        n, _, h, w = ref.size()

        # Normalise
        ref_norm  = [(ref  - self.mean) / self.std]
        supp_norm = [(supp - self.mean) / self.std]

        # Build 6-level Gaussian pyramid (coarse→fine)
        for _ in range(5):
            ref_norm.append( F.avg_pool2d(ref_norm[-1],  2, stride=2))
            supp_norm.append(F.avg_pool2d(supp_norm[-1], 2, stride=2))
        ref_norm  = ref_norm[::-1]
        supp_norm = supp_norm[::-1]

        flow = ref.new_zeros(n, 2, h >> 5, w >> 5)
        for level in range(6):
            # At the coarsest level (0) the flow is already the right size;
            # for finer levels interpolate the previous flow up by 2×.
            if level > 0:
                up = F.interpolate(flow, scale_factor=2, mode='bilinear',
                                   align_corners=True) * 2.0
            else:
                up = flow
            warped = flow_warp(supp_norm[level], up.permute(0, 2, 3, 1))
            inp = torch.cat([ref_norm[level], warped, up], dim=1)  # 3+3+2=8ch
            flow = self.basic_module[level](inp) + up

        return flow

    def forward(self, ref, supp):
        h, w = ref.shape[-2:]
        # Pad to multiples of 32
        h32 = h if h % 32 == 0 else 32 * (h // 32 + 1)
        w32 = w if w % 32 == 0 else 32 * (w // 32 + 1)

        ref_p  = F.interpolate(ref,  (h32, w32), mode='bilinear', align_corners=False)
        supp_p = F.interpolate(supp, (h32, w32), mode='bilinear', align_corners=False)

        flow = F.interpolate(self._compute_flow(ref_p, supp_p),
                             (h, w), mode='bilinear', align_corners=False)
        flow[:, 0] *= float(w) / w32
        flow[:, 1] *= float(h) / h32
        return flow


# ---------------------------------------------------------------------------
# Helpers shared by backbone and cleaning module
# ---------------------------------------------------------------------------

class PixelShufflePack(nn.Module):
    """Matches mmagic PixelShufflePack: key is upsample_conv.*"""

    def __init__(self, in_channels, out_channels, scale_factor, upsample_kernel):
        super().__init__()
        self.upsample_conv = nn.Conv2d(
            in_channels,
            out_channels * scale_factor * scale_factor,
            upsample_kernel,
            padding=(upsample_kernel - 1) // 2,
        )
        self.pixel_shuffle = nn.PixelShuffle(scale_factor)

    def forward(self, x):
        return self.pixel_shuffle(self.upsample_conv(x))


class ResidualBlocksWithInputConv(nn.Module):
    """Matches mmagic ResidualBlocksWithInputConv:
      main.0  →  input Conv2d
      main.2  →  ModuleList of ResidualBlockNoBN
    """

    def __init__(self, in_channels, out_channels=64, num_blocks=30):
        super().__init__()
        self.main = nn.Sequential(
            nn.Conv2d(in_channels, out_channels, 3, 1, 1, bias=True),
            nn.LeakyReLU(negative_slope=0.1, inplace=True),
            make_layer(ResidualBlockNoBN, num_blocks, num_feat=out_channels),
        )

    def forward(self, feat):
        return self.main(feat)


# ---------------------------------------------------------------------------
# BasicVSR backbone (matches mmagic BasicVSRNet key structure)
# ---------------------------------------------------------------------------

class BasicVSRNet(nn.Module):
    """Bidirectional propagation + optical-flow warping.  No DCN.

    Weight keys: backward_resblocks.*, forward_resblocks.*, fusion.*,
                 upsample1.*, upsample2.*, conv_hr.*, conv_last.*, spynet.*
    """

    def __init__(self, mid_channels=64, num_blocks=30):
        super().__init__()
        self.mid_channels = mid_channels

        self.spynet = SPyNet()

        self.backward_resblocks = ResidualBlocksWithInputConv(
            mid_channels + 3, mid_channels, num_blocks)
        self.forward_resblocks  = ResidualBlocksWithInputConv(
            mid_channels + 3, mid_channels, num_blocks)

        self.fusion    = nn.Conv2d(mid_channels * 2, mid_channels, 1, 1, 0)
        self.upsample1 = PixelShufflePack(mid_channels, mid_channels, 2, upsample_kernel=3)
        self.upsample2 = PixelShufflePack(mid_channels, 64,          2, upsample_kernel=3)
        self.conv_hr   = nn.Conv2d(64, 64, 3, 1, 1)
        self.conv_last = nn.Conv2d(64,  3, 3, 1, 1)
        self.img_upsample = nn.Upsample(scale_factor=4, mode='bilinear', align_corners=False)
        self.lrelu = nn.LeakyReLU(negative_slope=0.1, inplace=True)

    def compute_flow(self, lrs):
        n, t, c, h, w = lrs.size()
        l1 = lrs[:, :-1].reshape(-1, c, h, w)
        l2 = lrs[:, 1: ].reshape(-1, c, h, w)
        flows_backward = self.spynet(l1, l2).view(n, t - 1, 2, h, w)
        flows_forward  = self.spynet(l2, l1).view(n, t - 1, 2, h, w)
        return flows_forward, flows_backward

    def forward(self, lrs):
        n, t, c, h, w = lrs.size()
        flows_forward, flows_backward = self.compute_flow(lrs)

        # Backward pass
        out_l = []
        feat_prop = lrs.new_zeros(n, self.mid_channels, h, w)
        for i in range(t - 1, -1, -1):
            if i < t - 1:
                feat_prop = flow_warp(feat_prop,
                                      flows_backward[:, i].permute(0, 2, 3, 1))
            feat_prop = self.backward_resblocks(torch.cat([lrs[:, i], feat_prop], 1))
            out_l.insert(0, feat_prop)

        # Forward pass + upsample
        feat_prop = torch.zeros_like(feat_prop)
        for i in range(t):
            if i > 0:
                feat_prop = flow_warp(feat_prop,
                                      flows_forward[:, i - 1].permute(0, 2, 3, 1))
            feat_prop = self.forward_resblocks(torch.cat([lrs[:, i], feat_prop], 1))

            out = self.lrelu(self.fusion(torch.cat([out_l[i], feat_prop], 1)))
            out = self.lrelu(self.upsample1(out))
            out = self.lrelu(self.upsample2(out))
            out = self.lrelu(self.conv_hr(out))
            out = self.conv_last(out) + self.img_upsample(lrs[:, i])
            out_l[i] = out

        return torch.stack(out_l, 1).clamp(0, 1)


# ---------------------------------------------------------------------------
# RealBasicVSRNet — cleaning module + BasicVSR backbone
# ---------------------------------------------------------------------------

class RealBasicVSRNet(nn.Module):
    """Iterative image cleaning followed by BasicVSR.

    Weight keys: image_cleaning.0.*, image_cleaning.1.*, basicvsr.*
    """

    def __init__(self,
                 mid_channels=64,
                 num_propagation_blocks=20,
                 num_cleaning_blocks=20,
                 dynamic_refine_thres=255,
                 is_sequential_cleaning=False):
        super().__init__()
        self.dynamic_refine_thres = dynamic_refine_thres / 255.0
        self.is_sequential_cleaning = is_sequential_cleaning

        self.image_cleaning = nn.Sequential(
            ResidualBlocksWithInputConv(3, mid_channels, num_cleaning_blocks),
            nn.Conv2d(mid_channels, 3, 3, 1, 1, bias=True),
        )

        self.basicvsr = BasicVSRNet(mid_channels, num_propagation_blocks)
        self.basicvsr.spynet.requires_grad_(False)

    def forward(self, lqs):
        n, t, c, h, w = lqs.size()
        lqs = lqs.clone()  # avoid in-place modification of caller's tensor

        for _ in range(3):
            if self.is_sequential_cleaning:
                residues = []
                for i in range(t):
                    r = self.image_cleaning(lqs[:, i])
                    lqs[:, i] += r
                    residues.append(r)
                residues = torch.stack(residues, 1)
            else:
                flat = lqs.view(-1, c, h, w)
                residues = self.image_cleaning(flat)
                lqs = (flat + residues).view(n, t, c, h, w)

            if torch.mean(torch.abs(residues)) < self.dynamic_refine_thres:
                break

        return self.basicvsr(lqs)


# ---------------------------------------------------------------------------
# Weight loading helper
# ---------------------------------------------------------------------------

def load_realbasicvsr(weights_path, device='cuda'):
    """Load RealBasicVSRNet from an official mmedit/mmagic checkpoint.

    Prefers EMA weights (generator_ema.*) over training weights (generator.*)
    as EMA produces better inference results.
    """
    ckpt = torch.load(weights_path, map_location='cpu', weights_only=False)
    sd = ckpt.get('state_dict', ckpt)

    # Prefer EMA generator weights
    prefix = 'generator_ema.' if any(k.startswith('generator_ema.') for k in sd) else 'generator.'

    remapped = {}
    for k, v in sd.items():
        if not k.startswith(prefix):
            continue
        remapped[k[len(prefix):]] = v

    model = RealBasicVSRNet(
        mid_channels=64,
        num_propagation_blocks=20,
        num_cleaning_blocks=20,
        is_sequential_cleaning=True,
    )

    missing, unexpected = model.load_state_dict(remapped, strict=False)
    if missing:
        print(f'  [warn] missing keys ({len(missing)}): {missing[:3]}...')
    if unexpected:
        print(f'  [warn] unexpected keys ({len(unexpected)}): {unexpected[:3]}...')

    return model.to(device).eval()
