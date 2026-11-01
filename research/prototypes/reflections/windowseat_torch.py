#!/usr/bin/env python3
"""WindowSeat through diffusers on PyTorch's Metal backend in bfloat16: the reference the MLX port
(windowseat_mlx.py) is checked against, for quality only (RM-22).

    windowseat_torch.py --size 768 --out-dir build/rm22/out/variants/torch-bf16 a.png b.jpg

It follows the authors' windowseat_inference.py (Apache-2.0) with two changes: the transformer stays
in bfloat16, since bitsandbytes' 4-bit layers need CUDA, and the photo's latent is the VAE's mean
rather than a sample from it, so that runs repeat exactly. Each photo is scaled to one square tile.
"""

import argparse
import inspect
import json
import os
import pathlib
import time

import numpy as np
import safetensors.torch
import diffusers.models.modeling_utils
import torch
from diffusers import AutoencoderKLQwenImage, QwenImageEditPipeline, QwenImageTransformer2DModel
from peft import LoraConfig

import glassio

ROOT = pathlib.Path(__file__).resolve().parents[3]

# diffusers empties the device's cache after loading the shards onto the GPU; on this Mac that call to
# torch.mps.empty_cache() never returned (1 November 2026), so loading skips it.
diffusers.models.modeling_utils.empty_device_cache = lambda *args, **kwargs: None


def load(base, lora_dir, device):
    transformer = QwenImageTransformer2DModel.from_pretrained(base, subfolder="transformer", torch_dtype=torch.bfloat16, device_map=str(device))
    transformer.add_adapter(LoraConfig.from_pretrained(str(lora_dir)))
    state = safetensors.torch.load_file(str(lora_dir / "pytorch_lora_weights.safetensors"), device=str(device))
    _, unexpected = transformer.load_state_dict(state, strict=False)
    if unexpected:
        raise ValueError(f"unexpected LoRA keys: {unexpected[:4]}")
    vae = AutoencoderKLQwenImage.from_pretrained(base, subfolder="vae", torch_dtype=torch.bfloat16).to(device)
    embeds = safetensors.torch.load_file(str(lora_dir.parent / "text_embeddings" / "state_dict.safetensors"), device=str(device))
    return transformer.eval(), vae.eval(), embeds


@torch.no_grad()
def remove_square(transformer, vae, embeds, rgb01, device):
    x = torch.from_numpy(rgb01.transpose(2, 0, 1)[None] * 2 - 1).to(device, torch.bfloat16)
    mean = torch.tensor(vae.config.latents_mean, device=device, dtype=torch.bfloat16).view(1, -1, 1, 1, 1)
    std = torch.tensor(vae.config.latents_std, device=device, dtype=torch.bfloat16).view(1, -1, 1, 1, 1)
    z = (vae.encode(x.unsqueeze(2)).latent_dist.mode() - mean) / std
    _, c, _, h, w = z.shape
    tokens = QwenImageEditPipeline._pack_latents(z[:, :, 0], batch_size=1, num_channels_latents=c, height=h, width=w)
    mask = embeds["prompt_mask"] > 0
    kwargs = {"txt_seq_lens": mask.sum(dim=1).tolist()} if "txt_seq_lens" in inspect.signature(transformer.forward).parameters else {}
    velocity = transformer(
        hidden_states=tokens.to(torch.bfloat16),
        timestep=torch.full((1,), 499.0, device=device, dtype=torch.bfloat16) / 1000.0,
        encoder_hidden_states=embeds["prompt_embeds"].to(torch.bfloat16),
        encoder_hidden_states_mask=mask,
        img_shapes=[[(1, h // 2, w // 2)]],
        guidance=None,
        return_dict=False,
        **kwargs,
    )[0]
    velocity = QwenImageEditPipeline._unpack_latents(velocity, height=h * 8, width=w * 8, vae_scale_factor=8)
    out = z - velocity.to(z.dtype)
    image = vae.decode(out * std + mean).sample[:, :, 0]
    return ((image.float()[0] + 1) / 2).clamp(0, 1).cpu().numpy().transpose(1, 2, 0)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base", default=str(ROOT / "build/rm22/models/qwen-image-edit-2509"))
    parser.add_argument("--lora", type=pathlib.Path, default=ROOT / "build/rm22/models/windowseat/transformer_lora")
    parser.add_argument("--size", type=int, default=768)
    parser.add_argument("--out-dir", type=pathlib.Path, required=True)
    parser.add_argument("inputs", type=pathlib.Path, nargs="+")
    args = parser.parse_args()
    device = torch.device("mps")
    start = time.time()
    transformer, vae, embeds = load(args.base, args.lora, device)
    print(json.dumps({"load_seconds": round(time.time() - start, 1)}), flush=True)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    for path in args.inputs:
        square = glassio.resize(glassio.read(path), args.size, args.size)
        torch.mps.reset_peak_memory_stats() if hasattr(torch.mps, "reset_peak_memory_stats") else None
        start = time.time()
        out = remove_square(transformer, vae, embeds, square, device)
        torch.mps.synchronize()
        glassio.write_tiff16(args.out_dir / f"{path.stem}.tif", out)
        print(json.dumps({"input": path.name, "seconds": round(time.time() - start, 1), "driver_gb": round(torch.mps.driver_allocated_memory() / 1e9, 1), "loadavg": round(os.getloadavg()[0], 1)}), flush=True)


if __name__ == "__main__":
    main()
