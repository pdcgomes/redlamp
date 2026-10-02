#!/usr/bin/env python3
"""SAM 3 to Core ML for Landscape masks and people parts: an image encoder, a text-prompted decoder, and the
prompts' text features computed here (so no text encoder ships).

    research/prototypes/masking/.venv-sam3-coreml/bin/python research/prototypes/masking/convert_sam3.py [encoder|decoder|text|all]

Writes to build/models/:
  * Sam3ImageEncoder.mlpackage: `image` (RGB, 1008 × 1008, squashed) → `fpn0` (256 × 288²),
    `fpn1` (256 × 144²), `fpn2` (256 × 72²): the feature levels the decoder reads.
  * Sam3TextDecoder.mlpackage: those, a prompt's `text` (32 × 256) and `textMask` (32) →
    `instances` (288², every instance scoring over 0.4 merged, soft) and `semantic` (288², the
    dense map times the presence score). The position encodings are constant for a fixed size, so
    they are baked in.
  * Sam3Prompts.bin + Sam3Prompts.json: each prompt's text features and mask (float16), and
    its class (a Landscape class or a people part).

Each wrapper is checked against Transformers' own pipeline before conversion, and the Core ML
model against PyTorch after.
"""

import json
import pathlib
import sys
import time

import coremltools as ct
import numpy as np
import torch
from PIL import Image
from transformers import Sam3Model, Sam3Processor
from transformers.models.sam3.modeling_sam3 import Sam3VisionEncoderOutput

from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.frontend.torch.ops import _get_inputs
from coremltools.converters.mil.frontend.torch.torch_op_registry import register_torch_op


# Ops the export leaves that coremltools has no converter for.
@register_torch_op
def alias(context, node):
    context.add(mb.identity(x=_get_inputs(context, node)[0], name=node.name))


# The mask decoder forms instance masks with an einsum that converts to 5-D transposes the GPU
# backend can't compile (an MPS permute of the wrong rank); a matrix multiply is the same product.
_einsum = torch.einsum


def einsum(equation, *operands):
    if equation == "bqc,bchw->bqhw":
        queries, pixels = operands
        b, c, h, w = pixels.shape
        return torch.matmul(queries, pixels.reshape(b, c, h * w)).reshape(b, queries.shape[1], h, w)
    return _einsum(equation, *operands)


torch.einsum = einsum

ROOT = pathlib.Path(__file__).resolve().parents[3]
MODELS = ROOT / "build/models"
SAMPLE = ROOT / "build/landscape-bakeoff/Canon_EOS-R6-Mark-II.png"
SIZE = 1008
PROMPTS = {
    "water": ["water", "sea", "lake", "river"],
    "vegetation": ["tree", "grass", "lawn", "meadow", "bush", "plant"],
    "mountains": ["mountain", "hill"],
    "architecture": ["building"],
    "natural-ground": ["ground", "sand", "rock", "dirt"],
    "artificial-ground": ["road", "pavement", "floor"],
    # People parts Vision can't give on a camera photo (sam3_people_parts.py). "face" only takes
    # the face out of body skin.
    "hair": ["hair"],
    "facial-hair": ["beard", "mustache", "facial hair"],
    "body-skin": ["skin", "arm", "hand", "neck", "leg"],
    "clothes": ["clothing", "shirt", "jacket", "dress", "trousers"],
    "face": ["face"],
}


class TextFeatures:
    """What the model reads of precomputed text features."""

    def __init__(self, pooler_output):
        self.pooler_output = pooler_output


class Encoder(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.vision = model.vision_encoder
        self.patch = model.config.vision_config.backbone_config.patch_size

    def forward(self, image):
        # Sam3VisionModel.forward with its ViT backbone inlined: the export can't follow the
        # decorators around either forward.
        backbone = self.vision.backbone
        side = image.shape[-1] // self.patch
        hidden = backbone.embeddings(image * 2 - 1)
        hidden = backbone.layer_norm(hidden.view(1, side, side, hidden.shape[-1]))
        for layer in backbone.layers:
            hidden = layer(hidden)
        levels, _ = self.vision.neck(hidden.permute(0, 3, 1, 2))
        return levels[0], levels[1], levels[2]


class Decoder(torch.nn.Module):
    def __init__(self, model, positions):
        super().__init__()
        self.model = model
        for i, p in enumerate(positions):
            self.register_buffer(f"position{i}", p)

    def forward(self, fpn0, fpn1, fpn2, text, text_mask):
        # Sam3Model.forward's text-only path, its submodules called directly: the export can't
        # follow the decorators around the model's own forward.
        m = self.model
        mask = text_mask.bool()
        encoded = m.detr_encoder(vision_features=[fpn2], text_features=text, vision_pos_embeds=[self.position2],
                                 text_mask=mask)
        decoded = m.detr_decoder(vision_features=encoded.last_hidden_state, text_features=encoded.text_features,
                                 vision_pos_encoding=encoded.pos_embeds_flattened, text_mask=mask,
                                 spatial_shapes=encoded.spatial_shapes)
        logits = m.dot_product_scoring(decoder_hidden_states=decoded.intermediate_hidden_states,
                                       text_features=encoded.text_features, text_mask=mask).squeeze(-1)[-1]
        presence = torch.sigmoid(decoded.presence_logits[-1])  # (1, 1)
        masks = m.mask_decoder(decoder_queries=decoded.intermediate_hidden_states[-1], backbone_features=[fpn0, fpn1, fpn2],
                               encoder_hidden_states=encoded.last_hidden_state, prompt_features=text, prompt_mask=mask)
        keep = (torch.sigmoid(logits) * presence > 0.4).to(masks.pred_masks.dtype)  # (1, 200)
        instances = (torch.sigmoid(masks.pred_masks) * keep[:, :, None, None]).amax(dim=1, keepdim=True)
        semantic = torch.sigmoid(masks.semantic_seg) * presence[:, :, None, None]
        return instances, semantic


def load():
    model = Sam3Model.from_pretrained("facebook/sam3", torch_dtype=torch.float32).eval()
    processor = Sam3Processor.from_pretrained("facebook/sam3")
    return model, processor


def sample(processor):
    image = Image.open(SAMPLE).convert("RGB")
    squashed = image.resize((SIZE, SIZE), Image.BILINEAR)
    tensor = torch.from_numpy(np.asarray(squashed, np.float32) / 255).permute(2, 0, 1)[None].contiguous()
    return image, squashed, tensor


def text_features(model, processor, prompt):
    tokens = processor(text=prompt, return_tensors="pt")
    with torch.no_grad():
        features = model.get_text_features(input_ids=tokens["input_ids"], attention_mask=tokens["attention_mask"],
                                           return_dict=True)
    return features.pooler_output, tokens["attention_mask"]


def convert(module, example, inputs, outputs, name, description, decompose=True):
    """`decompose`: the default decompositions (the decoder needs them for ops coremltools lacks);
    without, linear layers stay linear (with them the encoder's windowed attention bakes each
    projection weight, expanded to every window row, into a 450 MB constant per layer)."""
    started = time.perf_counter()
    program = torch.export.export(module, example)
    exported = program.run_decompositions() if decompose else program.run_decompositions({})
    model = ct.convert(exported, inputs=inputs, outputs=outputs, convert_to="mlprogram",
                       compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.macOS15)
    model.short_description = description
    model.license = "SAM License (Meta); evaluation only, see docs/research/notes/MSK-17-sky-bakeoff.md"
    MODELS.mkdir(parents=True, exist_ok=True)
    model.save(str(MODELS / f"{name}.mlpackage"))
    print(f"{name}: converted in {time.perf_counter() - started:.0f} s", flush=True)
    # Checked as the app runs it: on the GPU.
    return ct.models.MLModel(str(MODELS / f"{name}.mlpackage"), compute_units=ct.ComputeUnit.CPU_AND_GPU)


def encoder(model, processor):
    image, squashed, tensor = sample(processor)
    wrapper = Encoder(model).eval()
    with torch.no_grad():
        pixels = processor(images=image, return_tensors="pt")["pixel_values"]
        reference = model.get_vision_features(pixel_values=pixels)
        check = wrapper((pixels + 1) / 2)
        mine = wrapper(tensor)
    for i in range(3):
        diff = (check[i] - reference.fpn_hidden_states[i]).abs().max().item()
        print(f"encoder wrapper vs pipeline, level {i}: max diff {diff:.5f}")
    coreml = convert(
        wrapper, (tensor,),
        [ct.ImageType(name="image", shape=(1, 3, SIZE, SIZE), scale=1 / 255, color_layout=ct.colorlayout.RGB)],
        [ct.TensorType(name="fpn0"), ct.TensorType(name="fpn1"), ct.TensorType(name="fpn2")],
        "Sam3ImageEncoder", "SAM 3 image encoder: 1008 × 1008 RGB to three feature levels", decompose=False,
    )
    out = coreml.predict({"image": squashed})
    for i in range(3):
        a, b = out[f"fpn{i}"].ravel(), mine[i].numpy().ravel()
        print(f"Core ML vs PyTorch, level {i}: correlation {np.corrcoef(a, b)[0, 1]:.5f}")


def decoder(model, processor):
    image, squashed, tensor = sample(processor)
    with torch.no_grad():
        vision = model.vision_encoder(tensor * 2 - 1)
    positions = [p.detach().contiguous() for p in vision.fpn_position_encoding[:3]]
    wrapper = Decoder(model, positions).eval()
    text, mask = text_features(model, processor, "tree")
    text, mask = text.contiguous(), mask.contiguous()
    levels = [vision.fpn_hidden_states[i].detach().contiguous() for i in range(3)]
    with torch.no_grad():
        instances, semantic = wrapper(*levels, text, mask)
        out = model(vision_embeds=vision, text_embeds=TextFeatures(pooler_output=text), attention_mask=mask)
        reference = torch.sigmoid(out.semantic_seg) * torch.sigmoid(out.presence_logits)[:, :, None, None]
    print(f"decoder wrapper vs pipeline: semantic max diff {(semantic - reference).abs().max().item():.5f}, "
          f"instances cover {(instances > 0.5).float().mean().item():.3f}")
    example = (*levels, text, mask.to(torch.int32).contiguous())
    coreml = convert(
        wrapper, example,
        [ct.TensorType(name="fpn0", shape=levels[0].shape), ct.TensorType(name="fpn1", shape=levels[1].shape),
         ct.TensorType(name="fpn2", shape=levels[2].shape), ct.TensorType(name="text", shape=text.shape),
         ct.TensorType(name="textMask", shape=mask.shape, dtype=np.int32)],
        [ct.TensorType(name="instances"), ct.TensorType(name="semantic")],
        "Sam3TextDecoder", "SAM 3 decoder: feature levels and a prompt's text features to instance and semantic masks",
    )
    feed = {f"fpn{i}": levels[i].numpy() for i in range(3)}
    feed.update({"text": text.numpy(), "textMask": mask.numpy().astype(np.int32)})
    out = coreml.predict(feed)
    for name, mine in (("instances", instances), ("semantic", semantic)):
        a, b = out[name].ravel(), mine.numpy().ravel()
        agree = ((a > 0.5) == (b > 0.5)).mean()
        print(f"Core ML vs PyTorch, {name}: agreement at 0.5 {agree:.4f}, max diff {np.abs(a - b).max():.4f}")


def text(model, processor):
    MODELS.mkdir(parents=True, exist_ok=True)
    index = {}
    blobs = []
    offset = 0
    for cls, prompts in PROMPTS.items():
        for prompt in prompts:
            features, mask = text_features(model, processor, prompt)
            blob = np.concatenate([features.numpy().astype(np.float16).ravel(), mask.numpy().astype(np.float16).ravel()])
            index[prompt] = {"class": cls, "offset": offset, "features": list(features.shape), "mask": list(mask.shape)}
            offset += blob.nbytes
            blobs.append(blob.tobytes())
    (MODELS / "Sam3Prompts.bin").write_bytes(b"".join(blobs))
    (MODELS / "Sam3Prompts.json").write_text(json.dumps(index, indent=2) + "\n")
    print(f"{len(index)} prompts, {offset} bytes")


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    model, processor = load()
    import transformers.models.sam3.modeling_sam3 as m  # noqa: F401
    if what in ("text", "all"):
        text(model, processor)
    if what in ("decoder", "all"):
        decoder(model, processor)
    if what in ("encoder", "all"):
        encoder(model, processor)
