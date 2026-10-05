"""Converts FLUX.2 [klein] 4B (Apache-2.0) into the folder Redlamp downloads for generative fill (RM-10).

    python convert_flux.py <model folder> <out folder>

The transformer's blocks, modulations and prompt projection are quantised to 4 bits in groups of
64 (MLX's affine quantisation, as `Flux2Transformer` does at load), the rest kept in bfloat16, and
written in shards under GitHub's 2 GB a file. The VAE is copied as it is. Generative Remove takes
no words (the owner's choice, 2026-10-05), so no text encoder ships: the prompts it uses are
encoded here, as diffusers' Flux2Klein pipelines encode them, and saved with the model.
"""

import json
import shutil
import sys
from pathlib import Path

import mlx.core as mx
import torch
from diffusers import Flux2KleinInpaintPipeline
from safetensors.torch import save_file

BITS = 4
GROUP_SIZE = 64
SHARD_BYTES = 1_800_000_000
# Kept dense, as Flux2Transformer keeps them: small, and at the model's two ends.
DENSE = ("x_embedder.", "time_guidance_embed.", "norm_out.", "proj_out.")

# The prompts Generative Remove can use; which it does is chosen on the judging set (step 4).
PROMPTS = {
    "empty": "",
    "background": "the background, continued naturally, with nothing in front of it",
    "remove": "Remove the object and fill in the background",
}


def encode_prompts(model: Path):
    pipe = Flux2KleinInpaintPipeline.from_pretrained(model, transformer=None, vae=None, dtype=torch.float32)
    out = {}
    for name, prompt in PROMPTS.items():
        with torch.no_grad():
            embeddings, _ = pipe.encode_prompt(prompt=prompt, device="cpu", num_images_per_prompt=1)
        out[name] = embeddings[0].to(torch.bfloat16).contiguous()
        print(f"prompt {name!r}: {tuple(embeddings.shape)}", flush=True)
    return out


def convert_transformer(source: Path, target: Path):
    target.mkdir(parents=True, exist_ok=True)
    weights = {}
    for shard in sorted(source.glob("*.safetensors")):
        weights.update(mx.load(str(shard)))
    out = {}
    for name, array in sorted(weights.items()):
        quantise = name.endswith(".weight") and array.ndim == 2 and not name.startswith(DENSE)
        if quantise:
            weight, scales, biases = mx.quantize(array.astype(mx.bfloat16), group_size=GROUP_SIZE, bits=BITS)
            stem = name[: -len(".weight")]
            out[stem + ".weight"] = weight
            out[stem + ".scales"] = scales
            out[stem + ".biases"] = biases
        else:
            out[name] = array.astype(mx.bfloat16)
    shards, current, size = [], {}, 0
    for name, array in out.items():
        if current and size + array.nbytes > SHARD_BYTES:
            shards.append(current)
            current, size = {}, 0
        current[name] = array
        size += array.nbytes
    shards.append(current)
    for index, shard in enumerate(shards, 1):
        path = target / f"model-{index:05d}-of-{len(shards):05d}.safetensors"
        mx.save_safetensors(str(path), shard)
        print(f"{path.name}: {sum(a.nbytes for a in shard.values()) / 1e9:.2f} GB", flush=True)
    config = json.loads((source / "config.json").read_text())
    config["quantization"] = {"bits": BITS, "group_size": GROUP_SIZE}
    (target / "config.json").write_text(json.dumps(config, indent=2))


def main():
    model, out = Path(sys.argv[1]), Path(sys.argv[2])
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    convert_transformer(model / "transformer", out / "transformer")
    (out / "vae").mkdir()
    for name in ("config.json", "diffusion_pytorch_model.safetensors"):
        shutil.copy(model / "vae" / name, out / "vae" / name)
    prompts = encode_prompts(model)
    save_file(prompts, out / "prompts.safetensors")
    (out / "prompts.json").write_text(json.dumps(PROMPTS, indent=2))
    shutil.copy(model / "LICENSE.md", out / "LICENSE.txt")


if __name__ == "__main__":
    main()
