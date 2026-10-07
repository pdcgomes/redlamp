"""Port of Gharbi et al. 2016's noise-aware Bayer model (Caffe, MIT) to PyTorch.

Reads pretrained_models/bayer_noise/weights.caffemodel from mgharbi/demosaicnet_caffe
with a minimal protobuf wire decoder (no Caffe needed), builds the network described by
its deploy.prototxt, saves a state_dict, and checks it on demosaicnet's test image.

Usage:
  build/rawdn-venv/bin/python research/prototypes/raw_denoise/models/demosaicnet_noise.py
"""

import os
import struct
import sys

import numpy as np
import torch as th
import torch.nn as nn
import torch.nn.functional as F

MODELS = "build/proto-data/raw-denoise/models/demosaicnet"
CAFFEMODEL = os.path.join(MODELS, "caffe-bayer_noise/weights.caffemodel")
PTH = os.path.join(MODELS, "bayer_noise_from_caffe.pth")
NOISE_RANGE = (0.0, 0.0784)  # sigma on a [0, 1] scale, from bin/demosaick


def _varint(buf, i):
    shift = result = 0
    while True:
        b = buf[i]
        i += 1
        result |= (b & 0x7F) << shift
        if not b & 0x80:
            return result, i
        shift += 7


def _fields(buf):
    i, out = 0, []
    while i < len(buf):
        key, i = _varint(buf, i)
        num, wt = key >> 3, key & 7
        if wt == 0:
            val, i = _varint(buf, i)
        elif wt == 1:
            val, i = buf[i : i + 8], i + 8
        elif wt == 2:
            n, i = _varint(buf, i)
            val, i = buf[i : i + n], i + n
        elif wt == 5:
            val, i = buf[i : i + 4], i + 4
        else:
            raise ValueError(f"wire type {wt}")
        out.append((num, wt, val))
    return out


def _blob(buf):
    shape, data, legacy = None, [], {}
    for num, wt, val in _fields(buf):
        if num == 7:  # BlobShape
            dims = []
            for n2, w2, v2 in _fields(val):
                if n2 == 1 and w2 == 2:
                    j = 0
                    while j < len(v2):
                        d, j = _varint(v2, j)
                        dims.append(d)
                elif n2 == 1:
                    dims.append(v2)
            shape = dims
        elif num == 5 and wt == 2:  # packed float data
            data.append(np.frombuffer(val, dtype="<f4"))
        elif num == 5 and wt == 5:
            data.append(np.frombuffer(val, dtype="<f4"))
        elif num in (1, 2, 3, 4) and wt == 0:
            legacy[num] = val
    arr = np.concatenate(data) if data else np.zeros(0, np.float32)
    if shape is None:
        shape = [legacy.get(k, 1) for k in (1, 2, 3, 4)]
    return arr.reshape(shape)


def load_caffemodel(path):
    net = {}
    for num, wt, val in _fields(open(path, "rb").read()):
        if num == 100 and wt == 2:  # LayerParameter (V2)
            name, blobs = None, []
            for n2, w2, v2 in _fields(val):
                if n2 == 1:
                    name = v2.decode()
                elif n2 == 7:
                    blobs.append(_blob(v2))
            if blobs:
                net[name] = blobs
    return net


class BayerNoiseDemosaick(nn.Module):
    """deploy.prototxt of pretrained_models/bayer_noise, unpadded ("valid") convolutions.

    Input mosaick: [N, 3, H, W], the image times a GRBG mask (zeros elsewhere), white-balanced
    and sRGB gamma-encoded in [0, 1]. noise: [N] Gaussian sigma on the same scale.
    Output: [N, 3, H - 2c, W - 2c] RGB, c = 31 for this depth.
    """

    def __init__(self):
        super().__init__()
        self.pack_mosaick = nn.Conv2d(3, 4, 2, stride=2)
        self.preconv1 = nn.Conv2d(5, 128, 3)
        self.convs = nn.ModuleList([nn.Conv2d(64, 64, 3) for _ in range(13)])  # conv2..conv14
        self.conv15 = nn.Conv2d(64, 128, 3)
        self.residual = nn.Conv2d(64, 12, 1)
        self.unpack_mosaick = nn.ConvTranspose2d(12, 3, 2, stride=2, groups=3)
        self.post_conv1 = nn.Conv2d(6, 64, 3)
        self.output = nn.Conv2d(64, 3, 1)

    def forward(self, mosaick, noise):
        packed = self.pack_mosaick(mosaick)
        level = noise.view(-1, 1, 1, 1).expand(-1, 1, packed.shape[2], packed.shape[3])
        x = F.relu(self.preconv1(th.cat([packed, level], 1)))
        x = x[:, :64] * x[:, 64:]
        for conv in self.convs:
            x = F.relu(conv(x))
        x = F.relu(self.conv15(x))
        x = x[:, :64] * x[:, 64:]
        up = self.unpack_mosaick(self.residual(x))
        oy = (mosaick.shape[2] - up.shape[2]) // 2
        ox = (mosaick.shape[3] - up.shape[3]) // 2
        cropped = mosaick[:, :, oy : oy + up.shape[2], ox : ox + up.shape[3]]
        x = F.relu(self.post_conv1(th.cat([cropped, up], 1)))
        return self.output(x)


def convert():
    blobs = load_caffemodel(CAFFEMODEL)
    net = BayerNoiseDemosaick()
    names = {"pack_mosaick": net.pack_mosaick, "preconv1": net.preconv1, "conv15": net.conv15,
             "residual": net.residual, "unpack_mosaick": net.unpack_mosaick,
             "post_conv1": net.post_conv1, "output": net.output}
    names.update({f"conv{i + 2}": c for i, c in enumerate(net.convs)})
    for name, mod in names.items():
        b = blobs[name]
        assert tuple(b[0].shape) == tuple(mod.weight.shape), (name, b[0].shape, mod.weight.shape)
        mod.weight.data = th.from_numpy(b[0].copy())
        if len(b) > 1:
            mod.bias.data = th.from_numpy(b[1].reshape(-1).copy())
        else:
            mod.bias.data.zero_()
    unused = sorted(set(blobs) - set(names))
    print("converted", len(names), "layers; unused caffe blobs:", unused)
    th.save(net.state_dict(), PTH)
    return net


def grbg(im):
    m = np.zeros_like(im)
    m[1, 0::2, 0::2] = 1
    m[0, 0::2, 1::2] = 1
    m[2, 1::2, 0::2] = 1
    m[1, 1::2, 1::2] = 1
    return im * m


def main():
    import imageio
    import demosaicnet

    net = convert().eval()
    src = os.path.join(os.path.dirname(demosaicnet.__file__), "data", "test_input.png")
    gt = np.transpose(imageio.imread(src).astype(np.float32) / 255.0, [2, 0, 1])
    gt = gt[:, : 2 * (gt.shape[1] // 2), : 2 * (gt.shape[2] // 2)]
    rng = np.random.default_rng(0)
    psnr = lambda a, b: 10 * np.log10(1 / np.mean((a - b) ** 2))
    ref = demosaicnet.BayerDemosaick().eval()
    for dev in ["cpu", "mps"] if th.backends.mps.is_available() else ["cpu"]:
        net.to(dev)
        ref.to(dev)
        for sigma in [0.0, 0.02, 0.05]:
            noisy = (gt + rng.normal(0, sigma, gt.shape)).astype(np.float32)
            x = th.from_numpy(grbg(noisy))[None].to(dev)
            with th.no_grad():
                y = net(x, th.tensor([sigma], dtype=th.float32, device=dev))[0].cpu().numpy()
                y0 = ref(x)[0].cpu().numpy()
            c = (gt.shape[1] - y.shape[1]) // 2
            g = gt[:, c : c + y.shape[1], c : c + y.shape[2]]
            n = noisy[:, c : c + y.shape[1], c : c + y.shape[2]]
            print(f"{dev} sigma={sigma:.2f}: in {tuple(x.shape)} out {y.shape}  noisy {psnr(n, g):5.2f} dB"
                  f" -> bayer_noise {psnr(np.clip(y, 0, 1), g):5.2f} dB"
                  f" (noise-free BayerDemosaick {psnr(np.clip(y0, 0, 1), g):5.2f} dB)")


if __name__ == "__main__":
    sys.exit(main())
