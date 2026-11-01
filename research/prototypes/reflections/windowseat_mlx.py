#!/usr/bin/env python3
"""WindowSeat reflection removal on Apple silicon through MLX (RM-22).

WindowSeat (huawei-bayerlab/windowseat-reflection-removal-v1-0, Apache-2.0) is a rank-128 LoRA on
Qwen/Qwen-Image-Edit-2509 (Apache-2.0). It removes reflections in one pass of the transformer: the
photo's VAE latent is the only image stream, the prompt is a fixed embedding shipped beside the LoRA
(text_embeddings/state_dict.safetensors), the timestep is 0.499, and the latent less the predicted
velocity is decoded. Neither the text encoder nor the vision-language encoder runs. The authors'
windowseat_inference.py (Apache-2.0) is the reference this follows; mflux's MLX ports of the
Qwen-Image transformer and VAE (MIT) do the arithmetic.

    windowseat_mlx.py convert --bits 4 --out build/rm22/windowseat-q4
    windowseat_mlx.py run --model build/rm22/windowseat-q4 --size 768 in.png out.png
    windowseat_mlx.py bench --model build/rm22/windowseat-q4 --sizes 512,768,1024 in.png

`convert` reads the base model's transformer and VAE from --base (a Hugging Face snapshot holding only
transformer/ and vae/), adds the LoRA's B·A to each weight it targets in float32, quantises every
linear layer of the transformer but img_in, txt_in, norm_out.linear and proj_out to --bits (the
modulation layers stay at 8 bits under a 4-bit model, as mflux does), and saves the transformer, the
VAE and the prompt embedding: the files a Redlamp model manifest would list. `--bits 16` keeps
bfloat16. `run` removes reflections from a photo at the model's resolution: the photo is scaled so
its short side is --size and cut into square tiles of that side, as WindowSeat does by default.
"""

import argparse
import json
import os
import pathlib
import resource
import time
from types import SimpleNamespace

import mlx.core as mx
import mlx.nn as nn
import numpy as np
from mlx.utils import tree_flatten, tree_unflatten

from mflux.models.common.weights.loading.weight_definition import ComponentDefinition
from mflux.models.common.weights.loading.weight_loader import WeightLoader
from mflux.models.qwen.model.qwen_transformer.qwen_transformer import QwenTransformer
from mflux.models.qwen.model.qwen_vae.qwen_vae import QwenVAE
from mflux.models.qwen.weights.qwen_weight_mapping import QwenWeightMapping

import glassio

ROOT = pathlib.Path(__file__).resolve().parents[3]
TIMESTEP = 0.499
DENSE = {"img_in", "txt_in", "proj_out", "norm_out.linear"}

# The LoRA is saved with diffusers' module names; mflux names a few modules differently.
RENAMES = [
    (".attn.to_out.0", ".attn.attn_to_out.0"),
    (".img_mlp.net.0.proj", ".img_ff.mlp_in"),
    (".img_mlp.net.2", ".img_ff.mlp_out"),
    (".txt_mlp.net.0.proj", ".txt_ff.mlp_in"),
    (".txt_mlp.net.2", ".txt_ff.mlp_out"),
]


_apply_block = QwenTransformer._apply_transformer_block


def _apply_block_evaluated(*args, **kwargs):
    # Evaluating block by block keeps each Metal command buffer short. As one graph, a 60-block pass
    # ran long enough on a shared GPU for macOS to cancel it ("Impacting Interactivity"), and a
    # cancelled buffer once left a tile of NaN.
    out = _apply_block(*args, **kwargs)
    mx.eval(out)
    return out


if os.environ.get("WINDOWSEAT_EVAL_PER_BLOCK", "1") != "0":
    QwenTransformer._apply_transformer_block = staticmethod(_apply_block_evaluated)


class BaseDefinition:
    """The base model's transformer and VAE only: WindowSeat needs no text encoder."""

    @staticmethod
    def get_components():
        return [
            ComponentDefinition(name="vae", hf_subdir="vae", loading_mode="single", mapping_getter=QwenWeightMapping.get_vae_mapping),
            ComponentDefinition(
                name="transformer", hf_subdir="transformer", loading_mode="multi_glob", mapping_getter=QwenWeightMapping.get_transformer_mapping
            ),
        ]

    @staticmethod
    def get_download_patterns():
        return ["vae/*", "transformer/*"]


def quantisation_predicate(bits):
    def predicate(path, module):
        if not hasattr(module, "to_quantized") or path in DENSE:
            return False
        if bits == 4 and path.endswith("img_mod_linear"):
            return {"bits": 8, "group_size": 64}
        return True

    return predicate


def node(tree, path):
    for part in path.split("."):
        tree = tree[int(part)] if isinstance(tree, list) else tree[part]
    return tree


def fuse_lora(transformer_tree, lora_dir):
    """Adds scale·B·A to each weight the LoRA targets, in float32, keeping the weight's dtype."""
    config = json.loads((lora_dir / "adapter_config.json").read_text())
    scale = config["lora_alpha"] / config["r"]
    lora = mx.load(str(lora_dir / "pytorch_lora_weights.safetensors"))
    fused = 0
    for key in sorted(k for k in lora if ".lora_A." in k):
        module = key.split(".lora_A.")[0]
        b = lora[key.replace(".lora_A.", ".lora_B.")]
        path = module
        for old, new in RENAMES:
            path = path.replace(old, new)
        holder = node(transformer_tree, path)
        weight = holder["weight"]
        delta = (b.astype(mx.float32) @ lora[key].astype(mx.float32)) * scale
        holder["weight"] = (weight.astype(mx.float32) + delta).astype(weight.dtype)
        mx.eval(holder["weight"])
        fused += 1
    return fused


def build_from_base(base_dir, lora_dir, bits):
    weights = WeightLoader.load(weight_definition=BaseDefinition, model_path=str(base_dir))
    fused = fuse_lora(weights.components["transformer"], lora_dir)
    transformer, vae = QwenTransformer(), QwenVAE()
    transformer.update(weights.components["transformer"], strict=False)
    vae.update(weights.components["vae"], strict=False)
    if bits < 16:
        nn.quantize(transformer, group_size=64, bits=bits, class_predicate=quantisation_predicate(bits))
    mx.eval(transformer.parameters(), vae.parameters())
    return transformer, vae, fused


def save(out_dir, transformer, vae, lora_dir, bits, fused):
    out_dir.mkdir(parents=True, exist_ok=True)
    mx.save_safetensors(str(out_dir / "transformer.safetensors"), dict(tree_flatten(transformer.parameters())))
    mx.save_safetensors(str(out_dir / "vae.safetensors"), dict(tree_flatten(vae.parameters())))
    embeds = mx.load(str(lora_dir.parent / "text_embeddings" / "state_dict.safetensors"))
    mx.save_safetensors(str(out_dir / "prompt.safetensors"), {"prompt_embeds": embeds["prompt_embeds"], "prompt_mask": embeds["prompt_mask"].astype(mx.int32)})
    files = {p.name: p.stat().st_size for p in sorted(out_dir.glob("*.safetensors"))}
    (out_dir / "model.json").write_text(json.dumps({"bits": bits, "group_size": 64, "lora_modules_fused": fused, "timestep": TIMESTEP, "files": files}, indent=2) + "\n")
    return files


def load(model_dir, vae_dtype=mx.bfloat16):
    info = json.loads((model_dir / "model.json").read_text())
    transformer, vae = QwenTransformer(), QwenVAE()
    if info["bits"] < 16:
        nn.quantize(transformer, group_size=64, bits=info["bits"], class_predicate=quantisation_predicate(info["bits"]))
    # mflux keeps some VAE norms as 1-D weights its modules reshape when they run, so update() rather than
    # load_weights(), whose shape check refuses them, as mflux itself loads them.
    transformer.update(tree_unflatten(list(mx.load(str(model_dir / "transformer.safetensors")).items())), strict=False)
    vae.update(tree_unflatten(list(mx.load(str(model_dir / "vae.safetensors")).items())), strict=False)
    if vae_dtype != mx.bfloat16:
        vae.set_dtype(vae_dtype)
    prompt = mx.load(str(model_dir / "prompt.safetensors"))
    mx.eval(transformer.parameters(), vae.parameters(), prompt)
    return SimpleNamespace(transformer=transformer, vae=vae, embeds=prompt["prompt_embeds"].astype(mx.bfloat16), mask=prompt["prompt_mask"], info=info)


def pack(latents, h, w):
    c = latents.shape[1]
    x = latents.reshape(1, c, h // 2, 2, w // 2, 2).transpose(0, 2, 4, 1, 3, 5)
    return x.reshape(1, (h // 2) * (w // 2), c * 4)


def unpack(tokens, h, w, c=16):
    x = tokens.reshape(1, h // 2, w // 2, c, 2, 2).transpose(0, 3, 1, 4, 2, 5)
    return x.reshape(1, c, h, w)


def remove_square(model, rgb01, stages=None):
    """One tile: an sRGB image in [0, 1], H×W×3 with sides a multiple of 16, to the model's output.
    With `stages`, each stage's seconds and MLX's peak memory are added to it."""

    def mark(name, *arrays):
        if stages is not None:
            mx.eval(*arrays)
            now = time.time()
            stages[name] = {"seconds": round(now - stages.pop("_t", now), 2), "peak_gb": round(mx.get_peak_memory() / 1e9, 2)}
            stages["_t"] = now
            mx.reset_peak_memory()

    if stages is not None:
        mx.reset_peak_memory()
        stages["_t"] = time.time()
    height, width = rgb01.shape[:2]
    x = mx.array(rgb01.transpose(2, 0, 1)[None] * 2 - 1).astype(model.vae.decoder.conv_in.conv3d.weight.dtype)
    z = model.vae.encode(x)
    z = z[:, :, 0] if z.ndim == 5 else z
    mark("encode", z)
    h, w = z.shape[-2:]
    tokens = pack(z.astype(mx.bfloat16), h, w)
    config = SimpleNamespace(height=height, width=width)
    velocity = model.transformer(t=TIMESTEP, config=config, hidden_states=tokens, encoder_hidden_states=model.embeds, encoder_hidden_states_mask=model.mask)
    out = z.astype(mx.float32) - unpack(velocity, h, w).astype(mx.float32)
    mark("transformer", out)
    image = model.vae.decode(out.astype(x.dtype))
    image = image[:, :, 0] if image.ndim == 5 else image
    image = mx.clip((image.astype(mx.float32)[0] + 1) / 2, 0, 1)
    mark("decode", image)
    if stages is not None:
        stages.pop("_t", None)
    return np.array(image).transpose(1, 2, 0)


def tiles(length, side, overlap=64):
    """Start positions of tiles of `side` covering `length`, the last flush with the end (WindowSeat's rule)."""
    if length <= side:
        return [0]
    starts = list(range(0, length - side + 1, max(1, side - overlap)))
    if starts[-1] != length - side:
        starts.append(length - side)
    return starts


def working_size(width, height, size):
    """The photo scaled so its short side is `size`, each side rounded to a multiple of 16."""
    scale = size / min(width, height)
    return max(16, round(width * scale / 16) * 16), max(16, round(height * scale / 16) * 16)


def remove(model, rgb01, size):
    """Removes reflections from a working-size sRGB image in square tiles of side `size` (the short side
    when the image is that small), blended with WindowSeat's triangular weights."""
    height, width = rgb01.shape[:2]
    side = min(width, height, size)
    acc = np.zeros((height, width, 3), np.float64)
    wsum = np.zeros((height, width, 1), np.float64)
    ramp = lambda n: np.maximum(1 - np.abs(2 * np.arange(n) / max(n - 1, 1) - 1), 1e-3)
    window = (ramp(side)[:, None] * ramp(side)[None, :])[..., None]
    for y0 in tiles(height, side):
        for x0 in tiles(width, side):
            for attempt in range(3):
                try:
                    out = remove_square(model, rgb01[y0 : y0 + side, x0 : x0 + side])
                except RuntimeError as error:
                    print(f"tile at {x0},{y0}: {error}; running it again", flush=True)
                    continue
                if np.isfinite(out).all():
                    break
                print(f"tile at {x0},{y0} came back with NaN; running it again", flush=True)
            else:
                raise RuntimeError(f"tile at {x0},{y0} failed three times")
            acc[y0 : y0 + side, x0 : x0 + side] += out * window
            wsum[y0 : y0 + side, x0 : x0 + side] += window
    return (acc / wsum).astype(np.float32)


def peak_rss_gb():
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e9


def load_variant(args):
    """A saved model (--model), or one built in memory from the base and the LoRA (--from-base BITS)."""
    if args.model:
        return load(args.model, mx.float32 if args.vae_float32 else mx.bfloat16)
    transformer, vae, fused = build_from_base(args.base, args.lora, args.from_base)
    if args.vae_float32:
        vae.set_dtype(mx.float32)
    prompt = mx.load(str(args.lora.parent / "text_embeddings" / "state_dict.safetensors"))
    info = {"bits": args.from_base, "lora_modules_fused": fused}
    return SimpleNamespace(transformer=transformer, vae=vae, embeds=prompt["prompt_embeds"].astype(mx.bfloat16), mask=prompt["prompt_mask"].astype(mx.int32), info=info)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    convert = commands.add_parser("convert")
    convert.add_argument("--bits", type=int, choices=(3, 4, 5, 6, 8, 16), default=4)
    convert.add_argument("--out", type=pathlib.Path, required=True)
    runner = commands.add_parser("run", help="remove reflections from photos at the model's resolution")
    runner.add_argument("--size", type=int, default=768, help="the short side the photo is scaled to, and the tiles' side")
    runner.add_argument("--square", action="store_true", help="scale each photo to one square tile instead")
    runner.add_argument("--out-dir", type=pathlib.Path, required=True)
    runner.add_argument("inputs", type=pathlib.Path, nargs="+")
    bench = commands.add_parser("bench", help="time and peak memory of one square tile at each size")
    bench.add_argument("--sizes", default="512,768,1024")
    bench.add_argument("--repeat", type=int, default=2)
    bench.add_argument("input", type=pathlib.Path)
    for command in (convert, runner, bench):
        command.add_argument("--base", type=pathlib.Path, default=ROOT / "build/rm22/models/qwen-image-edit-2509")
        command.add_argument("--lora", type=pathlib.Path, default=ROOT / "build/rm22/models/windowseat/transformer_lora")
    for command in (runner, bench):
        source = command.add_mutually_exclusive_group(required=True)
        source.add_argument("--model", type=pathlib.Path, help="a directory `convert` wrote")
        source.add_argument("--from-base", type=int, choices=(4, 8, 16), help="build in memory at these bits")
        command.add_argument("--vae-float32", action="store_true")
    args = parser.parse_args()

    if args.command == "convert":
        start = time.time()
        transformer, vae, fused = build_from_base(args.base, args.lora, args.bits)
        files = save(args.out, transformer, vae, args.lora, args.bits, fused)
        print(json.dumps({"fused": fused, "files": files, "seconds": round(time.time() - start, 1), "peak_rss_gb": round(peak_rss_gb(), 1)}))
        return

    start = time.time()
    model = load_variant(args)
    load_seconds = time.time() - start
    print(json.dumps({"load_seconds": round(load_seconds, 1), "bits": model.info["bits"]}), flush=True)
    if args.command == "run":
        args.out_dir.mkdir(parents=True, exist_ok=True)
        for path in args.inputs:
            image = glassio.read(path)
            width, height = (args.size, args.size) if args.square else working_size(image.shape[1], image.shape[0], args.size)
            small = glassio.resize(image, width, height)
            start = time.time()
            out = remove(model, small, args.size) if not args.square else remove_square(model, small)
            glassio.write_tiff16(args.out_dir / f"{path.stem}.tif", out)
            print(json.dumps({"input": path.name, "working": [width, height], "seconds": round(time.time() - start, 1), "loadavg": round(os.getloadavg()[0], 1)}), flush=True)
        return

    image = glassio.read(args.input)
    for size in [int(s) for s in args.sizes.split(",")]:
        square = glassio.resize(image, size, size)
        for attempt in range(args.repeat):
            mx.clear_cache()
            stages = {}
            start = time.time()
            remove_square(model, square, stages)
            seconds = time.time() - start
            print(json.dumps({"size": size, "attempt": attempt, "seconds": round(seconds, 2), "peak_gb": max(v["peak_gb"] for v in stages.values()), "stages": stages, "loadavg": round(os.getloadavg()[0], 1)}), flush=True)


if __name__ == "__main__":
    main()
