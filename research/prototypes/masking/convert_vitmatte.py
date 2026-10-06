#!/usr/bin/env python3
"""ViTMatte-base (hustvl, trained on Composition-1k) to Core ML for 1024 px tiles (MSK-32).

The network takes a tile's RGB in [0, 1] and its trimap (0 background, 0.5 unsure, 1 subject),
both 1024 × 1024, and returns the alpha matte at that size. The converter resamples neither
bicubically nor linearly in one dimension, so the backbone's absolute position embeddings and the
relative ones of its global-attention blocks are computed once for that size and traced as
constants. The wrapper is checked against the transformers pipeline on a tile of a real portrait
before converting, and the Core ML model against the wrapper after.

    KMP_DUPLICATE_LIB_OK=TRUE research/prototypes/masking/.venv-coreml/bin/python \
        research/prototypes/masking/convert_vitmatte.py

Writes build/models/ViTMatteBase-1024.mlpackage: inputs `image` (1×3×1024×1024) and `trimap`
(1×1×1024×1024), output `alpha` (1×1×1024×1024).
"""

import pathlib
import sys
import time

import coremltools as ct
import numpy as np
import torch
from PIL import Image
from transformers import VitMatteForImageMatting, VitMatteImageProcessor
from transformers.models.vitdet import modeling_vitdet

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from portrait_bench import trimap  # noqa: E402

TILE = 1024
NAME = "hustvl/vitmatte-base-composition-1k"
ROOT = pathlib.Path(__file__).resolve().parents[3]


class Wrapper(torch.nn.Module):
    """RGB and trimap in, as the pipeline's processor prepares them: the image scaled to [-1, 1]
    and the trimap as a fourth channel."""

    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, image, tri):
        return self.model(pixel_values=torch.cat([(image - 0.5) / 0.5, tri], dim=1)).alphas


def freeze(model, sample):
    """Traces the position embeddings at the tile's size as constants."""
    embeddings = model.backbone.embeddings
    tokens = TILE // model.config.backbone_config.patch_size
    with torch.no_grad():
        positions = embeddings.get_absolute_positions(embeddings.position_embeddings, True, tokens, tokens)
    embeddings.get_absolute_positions = lambda *args, **kwargs: positions
    original = modeling_vitdet.get_rel_pos
    table = {}

    def frozen(q_size, k_size, rel_pos):
        key = (id(rel_pos), int(q_size), int(k_size))
        if key not in table:
            table[key] = original(int(q_size), int(k_size), rel_pos).detach()
        return table[key]

    modeling_vitdet.get_rel_pos = frozen
    with torch.no_grad():
        model(pixel_values=sample)
    return len(table)


def portrait_tile():
    """A tile across the hair of DSC02005 at the size Redlamp stores masks at, with its trimap
    from Vision's mask (5% of the long side outside it)."""
    work = ROOT / "build/edge-cases"
    photo = Image.open(work / "DSC02005.jpg").convert("RGB")
    scale = 4096 / max(photo.size)
    photo = photo.resize((round(photo.width * scale), round(photo.height * scale)), Image.LANCZOS)
    coarse = np.asarray(Image.open(work / "DSC02005-vision.png").convert("L").resize(photo.size, Image.BILINEAR),
                        np.float32) / 255
    tri = trimap(coarse, inner=0.01, outer=0.05)
    rows = np.nonzero((coarse > 0.5).any(axis=1))[0]
    columns = np.nonzero(coarse[rows[0] + 40] > 0.5)[0]
    y = int(np.clip(rows[0] - 300, 0, photo.height - TILE))
    x = int(np.clip(columns.mean() - TILE // 2, 0, photo.width - TILE))
    image = np.asarray(photo)[y:y + TILE, x:x + TILE]
    return image, tri[y:y + TILE, x:x + TILE]


def main():
    destination = ROOT / "build/models/ViTMatteBase-1024.mlpackage"
    destination.parent.mkdir(parents=True, exist_ok=True)
    model = VitMatteForImageMatting.from_pretrained(NAME).eval()
    image, tri = portrait_tile()
    unsure = tri == 0.5
    print(f"tile: {unsure.mean():.0%} unsure")

    processor = VitMatteImageProcessor.from_pretrained(NAME)
    inputs = processor(images=Image.fromarray(image), trimaps=Image.fromarray((tri * 255).astype(np.uint8)),
                       return_tensors="pt")
    with torch.no_grad():
        reference = model(**inputs).alphas[0, 0, :TILE, :TILE].numpy()

    image_tensor = torch.from_numpy(image.astype(np.float32) / 255).permute(2, 0, 1)[None]
    tri_tensor = torch.from_numpy(tri.astype(np.float32))[None, None]
    tables = freeze(model, torch.cat([(image_tensor - 0.5) / 0.5, tri_tensor], dim=1))
    wrapper = Wrapper(model).eval()
    with torch.no_grad():
        wrapped = wrapper(image_tensor, tri_tensor)[0, 0].numpy()
    print(f"wrapper against the pipeline: worst {np.abs(wrapped - reference).max():.2e} "
          f"({tables} relative position tables frozen)")

    started = time.perf_counter()
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, (image_tensor, tri_tensor))
    converted = ct.convert(
        traced,
        inputs=[ct.TensorType(name="image", shape=image_tensor.shape),
                ct.TensorType(name="trimap", shape=tri_tensor.shape)],
        outputs=[ct.TensorType(name="alpha")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS15,
    )
    converted.author = "hustvl (ViTMatte, Apache-2.0 weights); converted for Redlamp"
    converted.short_description = "ViTMatte-base alpha matting for a 1024 px tile and its trimap"
    converted.save(str(destination))
    print(f"converted in {time.perf_counter() - started:.0f} s: {destination}")

    loaded = ct.models.MLModel(str(destination), compute_units=ct.ComputeUnit.ALL)
    feed = {"image": image_tensor.numpy(), "trimap": tri_tensor.numpy()}
    loaded.predict(feed)
    started = time.perf_counter()
    alpha = loaded.predict(feed)["alpha"][0, 0]
    elapsed = time.perf_counter() - started
    difference = np.abs(alpha - wrapped)[unsure]
    print(f"Core ML against the wrapper over the unsure pixels: mean {difference.mean():.4f}, "
          f"worst {difference.max():.3f}; {elapsed * 1000:.0f} ms a tile")


if __name__ == "__main__":
    main()
