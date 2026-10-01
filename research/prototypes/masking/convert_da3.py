#!/usr/bin/env python3
"""Depth Anything 3 Mono-L to Core ML (MSK-17 follow-up): depth and sky for one image.

There is no official Core ML conversion. This wraps the network (DINOv2 ViT-L backbone and DPT
head with its sky branch) so it takes an RGB image at a fixed 504×336 (3:2; the reference
pipeline resizes the long side to 504, both sides multiples of the 14 px patch), freezes the
position embedding for that size (the converter has no bicubic resampling), and checks the
wrapper against the package's own pipeline before converting.

    KMP_DUPLICATE_LIB_OK=TRUE research/prototypes/masking/.venv/bin/python \
        research/prototypes/masking/convert_da3.py build/models/DepthAnything3MonoLarge.mlpackage

Outputs: `depth` (relative, larger is farther) and `sky` (≥ 0.5 is sky), both 336×504.
"""

import pathlib
import sys
import time

import coremltools as ct
import numpy as np
import torch
from depth_anything_3.api import DepthAnything3
from PIL import Image

HEIGHT, WIDTH = 336, 504
ROOT = pathlib.Path(__file__).resolve().parents[3]


class Wrapper(torch.nn.Module):
    def __init__(self, net):
        super().__init__()
        self.backbone = net.backbone
        self.head = net.head
        self.register_buffer("mean", torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1))

    def forward(self, image):
        x = ((image - self.mean) / self.std).unsqueeze(1)
        feats, _ = self.backbone(x, cam_token=None, export_feat_layers=[], ref_view_strategy="first")
        out = self.head(feats, HEIGHT, WIDTH, patch_start_idx=0)
        return out["depth"].reshape(1, 1, HEIGHT, WIDTH), out["sky"].reshape(1, 1, HEIGHT, WIDTH)


def main():
    destination = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / "build/models/DepthAnything3MonoLarge.mlpackage")
    api = DepthAnything3.from_pretrained("depth-anything/DA3MONO-LARGE").eval()
    preprocess = api.input_processor
    api.input_processor = lambda *a, **k: preprocess(*a, **{**k, "sequential": True, "num_workers": 1})
    net = api.model.float().eval()

    # Freeze DINOv2's position embedding for this size.
    vit = net.backbone.pretrained
    tokens = torch.zeros(1, 1 + (HEIGHT // 14) * (WIDTH // 14), vit.embed_dim)
    fixed = vit.interpolate_pos_encoding(tokens, HEIGHT, WIDTH).detach()
    vit.interpolate_pos_encoding = lambda x, w, h: fixed

    wrapper = Wrapper(net).eval()
    sample = ROOT / "build/masking-bakeoff/Sony_ILCE-6700.png"
    image = Image.open(sample).convert("RGB").resize((WIDTH, HEIGHT), Image.BICUBIC)
    tensor = torch.from_numpy(np.asarray(image, dtype=np.float32) / 255).permute(2, 0, 1)[None].contiguous()
    with torch.no_grad():
        depth, sky = wrapper(tensor)
    reference = api.inference([np.asarray(image)], process_res=504)
    agreement = ((sky[0, 0].numpy() >= 0.5) == reference.sky[0]).mean()
    print(f"wrapper vs package: sky agreement {agreement:.4f}, sky fraction {(sky >= 0.5).float().mean():.3f}")
    if agreement < 0.99:
        sys.exit("the wrapper doesn't match the package's pipeline")

    started = time.perf_counter()
    # torch.export records the (fixed) shapes as constants; tracing turns einops' shape
    # arithmetic into tensor ops the converter can't fold. It can't follow addict's Dict, which
    # the head returns, so a plain dict stands in.
    import depth_anything_3.model.dpt as dpt

    dpt.Dict = dict
    exported = torch.export.export(wrapper, (tensor,)).run_decompositions({})
    model = ct.convert(
        exported,
        inputs=[ct.ImageType(name="image", shape=(1, 3, HEIGHT, WIDTH), scale=1 / 255, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="depth"), ct.TensorType(name="sky")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS15,
    )
    model.short_description = "Depth Anything 3 Mono-L: relative depth and sky, 504×336"
    model.license = "Apache-2.0 (weights); training data unaudited, see docs/research/notes/MSK-17-sky-bakeoff.md"
    destination.parent.mkdir(parents=True, exist_ok=True)
    model.save(str(destination))
    print(f"converted in {time.perf_counter() - started:.0f} s: {destination}")

    # The Core ML model against PyTorch on the same image.
    prediction = model.predict({"image": image})
    agreement = ((prediction["sky"][0, 0] >= 0.5) == (sky[0, 0].numpy() >= 0.5)).mean()
    correlation = np.corrcoef(prediction["depth"].ravel(), depth.numpy().ravel())[0, 1]
    print(f"Core ML vs PyTorch: sky agreement {agreement:.4f}, depth correlation {correlation:.4f}")


if __name__ == "__main__":
    main()
