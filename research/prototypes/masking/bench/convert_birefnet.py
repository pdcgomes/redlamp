"""Can BiRefNet (and RMBG-2.0, which shares its architecture) run in Redlamp? Its decoder's
deformable convolutions (torchvision's deform_conv2d) have no Core ML operation, so here they are
written as bilinear samples (grid_sample) and a matrix product, checked against torchvision; then
the model is traced, converted to a Core ML program in float16, and its mask on a photo compared
with PyTorch's (MSK-39).

    ../.venv/bin/python convert_birefnet.py [--repo ZhengPeng7/BiRefNet_lite] [--size 1024] [--photo pets-01]
                                            [--out /Volumes/SSD/redlamp-tmp/mask-bench/birefnet.mlpackage]

Prints the deformable convolution's largest difference from torchvision's, the conversion's time,
the package's size, and the Core ML mask's IoU and mean difference against PyTorch's.
"""

import argparse
import pathlib
import sys
import time

import numpy as np
import torch
import torch.nn.functional as F
from PIL import Image

import candidates
import common as c


def deform_conv2d(input, offset, weight, bias=None, stride=(1, 1), padding=(0, 0), dilation=(1, 1), mask=None):
    """torchvision.ops.deform_conv2d for one group, from operations Core ML has."""
    n, channels, height, width = input.shape
    out_channels, _, kernel_h, kernel_w = weight.shape
    stride_h, stride_w = (stride, stride) if isinstance(stride, int) else stride
    pad_h, pad_w = (padding, padding) if isinstance(padding, int) else padding
    dil_h, dil_w = (dilation, dilation) if isinstance(dilation, int) else dilation
    out_h, out_w = offset.shape[2], offset.shape[3]
    ys = (torch.arange(out_h, dtype=input.dtype) * stride_h - pad_h).view(1, out_h, 1)
    xs = (torch.arange(out_w, dtype=input.dtype) * stride_w - pad_w).view(1, 1, out_w)
    samples = []
    for a in range(kernel_h):
        for b in range(kernel_w):
            k = a * kernel_w + b
            y = ys + a * dil_h + offset[:, 2 * k]
            x = xs + b * dil_w + offset[:, 2 * k + 1]
            grid = torch.stack((2 * x / max(width - 1, 1) - 1, 2 * y / max(height - 1, 1) - 1), dim=-1)
            sample = F.grid_sample(input, grid, mode="bilinear", padding_mode="zeros", align_corners=True)
            samples.append(sample * mask[:, k:k + 1] if mask is not None else sample)
    stacked = torch.stack(samples, dim=2).reshape(n, channels * kernel_h * kernel_w, out_h * out_w)
    out = torch.matmul(weight.reshape(out_channels, -1), stacked).reshape(n, out_channels, out_h, out_w)
    return out + bias.view(1, -1, 1, 1) if bias is not None else out


def check_equivalence():
    from torchvision.ops import deform_conv2d as reference

    torch.manual_seed(0)
    worst = 0.0
    for kernel, padding in ((3, 1), (7, 3), (1, 0)):
        x = torch.randn(1, 8, 20, 24)
        weight = torch.randn(6, 8, kernel, kernel)
        bias = torch.randn(6)
        offset = torch.randn(1, 2 * kernel * kernel, 20, 24) * 3
        mask = torch.rand(1, kernel * kernel, 20, 24) * 2
        ours = deform_conv2d(x, offset, weight, bias, padding=(padding, padding), mask=mask)
        theirs = reference(x, offset, weight, bias, padding=(padding, padding), mask=mask)
        worst = max(worst, float((ours - theirs).abs().max() / theirs.abs().max()))
    return worst


class Final(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, x):
        return self.model(x)[-1].sigmoid()


def allow_one_element_casts():
    """Swin's window code takes int() of a shape computed in floats, which the trace keeps as a
    one-element array; coremltools' cast wants a scalar."""
    from coremltools.converters.mil import Builder as mb
    from coremltools.converters.mil.frontend.torch import ops

    original = ops._cast

    def cast(context, node, dtype, dtype_name):
        x = ops._get_inputs(context, node, expected=1)[0]
        if x.val is not None and np.size(x.val) == 1 and np.ndim(x.val) > 0:
            context.add(mb.const(val=dtype(np.asarray(x.val).reshape(()).item()), name=node.name))
            return
        original(context, node, dtype, dtype_name)

    ops._cast = cast


def main():
    import coremltools as ct

    allow_one_element_casts()
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default="ZhengPeng7/BiRefNet_lite")
    parser.add_argument("--size", type=int, default=1024)
    parser.add_argument("--photo", default="pets-01")
    parser.add_argument("--out", default="/Volumes/SSD/redlamp-tmp/mask-bench/birefnet.mlpackage")
    args = parser.parse_args()

    print(f"==> deform_conv2d from grid_sample: largest difference {check_equivalence():.2e} of torchvision's range")
    from transformers import AutoModelForImageSegmentation

    model = AutoModelForImageSegmentation.from_pretrained(args.repo, trust_remote_code=True).eval().float()
    sys.modules[type(model).__module__].deform_conv2d = deform_conv2d
    wrapped = Final(model).eval()
    entry = c.photo(args.photo)
    image = Image.open(c.bench_jpeg(entry)).convert("RGB")
    square = np.asarray(image.resize((args.size, args.size), Image.BILINEAR), np.float32) / 255
    tensor = torch.from_numpy((square - candidates.MEAN) / candidates.STD).permute(2, 0, 1)[None]
    with torch.no_grad():
        expected = wrapped(tensor)[0, 0].numpy()
        started = time.time()
        traced = torch.jit.trace(wrapped, tensor, check_trace=False)
    print(f"==> traced in {time.time() - started:.0f} s")
    started = time.time()
    converted = ct.convert(
        traced, inputs=[ct.TensorType(name="image", shape=tensor.shape)], outputs=[ct.TensorType(name="mask")],
        convert_to="mlprogram", compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS15,
    )
    converted.save(args.out)
    size = sum(p.stat().st_size for p in pathlib.Path(args.out).rglob("*") if p.is_file()) / 1e6
    print(f"==> converted in {time.time() - started:.0f} s: {args.out} ({size:.0f} MB)")
    started = time.time()
    got = converted.predict({"image": tensor.numpy()})["mask"][0, 0]
    seconds = time.time() - started
    a, b = got >= 0.5, expected >= 0.5
    iou = (a & b).sum() / max((a | b).sum(), 1)
    print(f"==> Core ML on {args.photo}: IoU {iou:.4f} against PyTorch, mean difference {np.abs(got - expected).mean():.4f}, "
          f"{seconds:.2f} s for the first prediction")


if __name__ == "__main__":
    main()
