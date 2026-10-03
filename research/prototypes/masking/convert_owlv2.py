#!/usr/bin/env python3
"""OWLv2 (B/16, ensemble) to Core ML, for finding things named in words (RM-08): the detector's image
side, and the text features of a list of things computed here (so no text encoder ships).

    research/prototypes/masking/.venv-sam3-coreml/bin/python research/prototypes/masking/convert_owlv2.py [queries|image|check|all]

Writes to build/models/:
  * Owlv2Detector.mlpackage: `image` (RGB, 960 × 960: the photo padded to a square with grey at its
    bottom and right, as OWLv2's own notebook does, then resized) → for each patch of a 60 × 60
    grid, row by row: `classEmbeddings` (3600 × 512, unit length), `logitShift` and `logitScale`
    (3600), `boxes` (3600 × 4: centre x and y, width and height, 0...1 of the square) and
    `objectness` (3600, logits). It computes in float32: in float16 a few dozen patches of each
    photo drift (logit scales off by up to 5, boxes by 0.17 of the square) through the vision
    transformer's massive activations, and float32 costs the GPU about a tenth more. Its weights
    stay in float32 too (365 MB): 8-bit weights move some boxes by over half the square, and
    float16 weights widened as the model loads (constexpr_cast) keep the scores but leave the
    GPU, taking 720 ms a photo rather than 150.
  * Owlv2Queries.bin + Owlv2Queries.json: each prompt's text features (512 float16, unit length)
    and the thing it finds.

A prompt's logit at a patch is (classEmbedding · features + logitShift) × logitScale, and a thing's
score the sigmoid of its prompts' best. The wrapper is checked against Transformers' own pipeline
before conversion, and the Core ML model against PyTorch after, on the landscape bake-off's renders.
"""

import json
import pathlib
import sys
import time

import coremltools as ct
import numpy as np
import torch
from PIL import Image
from transformers import Owlv2ForObjectDetection, Owlv2Processor

ROOT = pathlib.Path(__file__).resolve().parents[3]
MODELS = ROOT / "build/models"
SAMPLES = sorted(
    p for p in (ROOT / "build/landscape-bakeoff").glob("*.png")
    if not any(tag in p.stem for tag in ("-coreml", "-reference", "-sam3"))
)
NAME = "google/owlv2-base-patch16-ensemble"
SIZE = 960
MEAN = (0.48145466, 0.4578275, 0.40821073)
STD = (0.26862954, 0.26130258, 0.27577711)
OUTPUTS = ("classEmbeddings", "logitShift", "logitScale", "boxes", "objectness")
# The first things to find (RM-08), and the words each is asked for by: plain words, as OWLv2's
# notebook asks.
THINGS = {
    "trash": ["trash", "garbage", "rubbish"],
    "litter": ["litter"],
    "plastic bag": ["plastic bag"],
    "bottle": ["bottle"],
    "can": ["can", "drink can"],
    "cigarette butt": ["cigarette butt"],
    "power line": ["power line", "overhead wire"],
    "cable": ["cable", "wire"],
    "sign": ["sign", "signpost"],
    "traffic cone": ["traffic cone"],
    "car": ["car"],
    "person": ["person"],
    "bird": ["bird"],
}
PROMPTS = [(thing, prompt) for thing, prompts in THINGS.items() for prompt in prompts]


class Detector(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model
        self.register_buffer("mean", torch.tensor(MEAN).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor(STD).view(1, 3, 1, 1))

    def forward(self, image):
        # Owlv2ForObjectDetection's image path with its vision transformer inlined: the export
        # can't follow the decorators around the transformer's forward.
        m = self.model
        vision = m.owlv2.vision_model
        hidden = vision.pre_layernorm(vision.embeddings((image - self.mean) / self.std))
        for layer in vision.encoder.layers:
            hidden = layer(hidden, None)
        hidden = vision.post_layernorm(hidden)
        # Each patch's embedding times the class token's, as image_embedder merges them.
        patches = m.layer_norm(hidden[:, 1:, :] * hidden[:, :1, :])
        head = m.class_head
        embeds = head.dense0(patches)
        embeds = embeds / (torch.sqrt((embeds * embeds).sum(-1, keepdim=True)) + 1e-6)
        shift = head.logit_shift(patches)[..., 0]
        scale = head.elu(head.logit_scale(patches))[..., 0] + 1
        boxes = torch.sigmoid(m.box_head(patches) + m.box_bias)
        objectness = m.objectness_head(patches)[..., 0]
        return embeds[0], shift[0], scale[0], boxes[0], objectness[0]


def load():
    model = Owlv2ForObjectDetection.from_pretrained(NAME, attn_implementation="eager").eval()
    return model, Owlv2Processor.from_pretrained(NAME)


def square(image):
    """The photo as the model reads it: padded to a square with grey at its bottom and right, then
    resized (PIL's bilinear filter widens as it shrinks, so it anti-aliases)."""
    side = max(image.size)
    padded = Image.new("RGB", (side, side), (128, 128, 128))
    padded.paste(image, (0, 0))
    return padded.resize((SIZE, SIZE), Image.BILINEAR)


def tensor(image):
    return torch.from_numpy(np.asarray(image, np.float32) / 255).permute(2, 0, 1)[None].contiguous()


def text_features(model, processor, prompts):
    tokens = processor(text=prompts, return_tensors="pt")
    with torch.no_grad():
        features = model.owlv2.get_text_features(
            input_ids=tokens["input_ids"], attention_mask=tokens["attention_mask"], return_dict=True,
        ).pooler_output
    return features / features.norm(dim=-1, keepdim=True)


def logits(embeds, shift, scale, features):
    return (embeds @ features.T + shift[:, None]) * scale[:, None]


def queries(model, processor):
    MODELS.mkdir(parents=True, exist_ok=True)
    features = text_features(model, processor, [prompt for _, prompt in PROMPTS])
    index = {}
    blobs = []
    offset = 0
    for (thing, prompt), row in zip(PROMPTS, features):
        blob = row.numpy().astype(np.float16)
        index[prompt] = {"thing": thing, "offset": offset, "features": [int(blob.size)]}
        offset += blob.nbytes
        blobs.append(blob.tobytes())
    (MODELS / "Owlv2Queries.bin").write_bytes(b"".join(blobs))
    (MODELS / "Owlv2Queries.json").write_text(json.dumps(index, indent=2) + "\n")
    print(f"{len(index)} prompts for {len(THINGS)} things, {offset} bytes")


def check_wrapper(model, processor, wrapper):
    image = Image.open(SAMPLES[0]).convert("RGB")
    prompts = [prompt for _, prompt in PROMPTS]
    inputs = processor(text=[prompts], images=image, return_tensors="pt")
    mean, std = torch.tensor(MEAN).view(1, 3, 1, 1), torch.tensor(STD).view(1, 3, 1, 1)
    with torch.no_grad():
        reference = model(**inputs)
        embeds, shift, scale, boxes, objectness = wrapper(inputs["pixel_values"] * std + mean)
    mine = logits(embeds, shift, scale, text_features(model, processor, prompts))
    print(
        f"wrapper vs pipeline on {SAMPLES[0].name}: logits max diff "
        f"{(mine - reference.logits[0]).abs().max().item():.5f}, boxes "
        f"{(boxes - reference.pred_boxes[0]).abs().max().item():.6f}, objectness "
        f"{(objectness - reference.objectness_logits[0]).abs().max().item():.5f}",
    )


def convert(wrapper):
    started = time.perf_counter()
    example = tensor(square(Image.open(SAMPLES[0]).convert("RGB")))
    program = torch.export.export(wrapper, (example,))
    model = ct.convert(
        program.run_decompositions({}),
        inputs=[ct.ImageType(name="image", shape=(1, 3, SIZE, SIZE), scale=1 / 255, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name=name) for name in OUTPUTS],
        convert_to="mlprogram", compute_precision=ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.macOS15,
    )
    model.short_description = (
        "OWLv2 B/16: a 960 x 960 RGB photo (padded square with grey) to class embeddings, logit shift "
        "and scale, boxes and objectness for each of 60 x 60 patches"
    )
    model.license = "Apache-2.0 (google/owlv2-base-patch16-ensemble)"
    MODELS.mkdir(parents=True, exist_ok=True)
    model.save(str(MODELS / "Owlv2Detector.mlpackage"))
    print(f"Owlv2Detector: converted in {time.perf_counter() - started:.0f} s", flush=True)
    size = sum(f.stat().st_size for f in (MODELS / "Owlv2Detector.mlpackage").rglob("*") if f.is_file())
    print(f"Owlv2Detector: {size / 1e6:.0f} MB")


def check_coreml(model, processor, wrapper, name, count=40):
    """Checked as the app runs it, on the GPU (the Neural Engine computes in float16)."""
    features = text_features(model, processor, [prompt for _, prompt in PROMPTS])
    things = list(THINGS)
    columns = [things.index(thing) for thing, _ in PROMPTS]
    coreml = ct.models.MLModel(str(MODELS / f"{name}.mlpackage"), compute_units=ct.ComputeUnit.CPU_AND_GPU)
    image = square(Image.open(SAMPLES[0]).convert("RGB"))
    coreml.predict({"image": image})
    started = time.perf_counter()
    for _ in range(3):
        coreml.predict({"image": image})
    print(f"{name}: {(time.perf_counter() - started) / 3 * 1000:.0f} ms a photo on the GPU")
    worst_logit, worst_box, worst_score, agreements, quiet = 0.0, 0.0, 0.0, [], True
    for path in SAMPLES[:count]:
        image = square(Image.open(path).convert("RGB"))
        out = coreml.predict({"image": image})
        with torch.no_grad():
            embeds, shift, scale, boxes, _ = wrapper(tensor(image))
        theirs = logits(*(torch.from_numpy(np.asarray(out[n], np.float32)) for n in OUTPUTS[:3]), features)
        mine = logits(embeds, shift, scale, features)
        worst_logit = max(worst_logit, (theirs - mine).abs().max().item())
        worst_score = max(worst_score, (torch.sigmoid(theirs) - torch.sigmoid(mine)).abs().max().item())
        worst_box = max(worst_box, np.abs(out["boxes"] - boxes.numpy()).max())

        def found(values):
            scores = torch.zeros(values.shape[0], len(things))
            for column, thing in enumerate(columns):
                scores[:, thing] = torch.maximum(scores[:, thing], torch.sigmoid(values[:, column]))
            return {(int(p), int(t)) for p, t in zip(*torch.nonzero(scores > 0.2, as_tuple=True))}

        a, b = found(theirs), found(mine)
        agreements.append(len(a & b) / len(a | b) if a | b else 1.0)
        if quiet:
            continue
        names = sorted({things[t] for _, t in b})
        print(f"  {path.stem}: {len(b)} patches over 0.2 ({', '.join(names) or 'nothing'})")
    print(
        f"{name} vs PyTorch on {min(count, len(SAMPLES))} renders: logits max diff {worst_logit:.4f}, scores "
        f"{worst_score:.4f}, boxes {worst_box:.5f}, patches over 0.2 agree {min(agreements):.3f} at worst "
        f"({np.mean(agreements):.3f} on average)",
    )


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    model, processor = load()
    wrapper = Detector(model).eval()
    if what in ("queries", "all"):
        queries(model, processor)
    if what in ("image", "all"):
        check_wrapper(model, processor, wrapper)
        convert(wrapper)
    if what in ("image", "check", "all"):
        check_coreml(model, processor, wrapper, "Owlv2Detector")
