"""Reference outputs for generative fill's MLX port (RM-10, step 2).

Runs diffusers' Flux2KleinInpaintPipeline (FLUX.2 [klein] 4B, Apache-2.0) in float32 on crops of
CC0 photos, with prompt embeddings made by reference_text_encoder.py, and keeps what the Swift
port is checked against: the initial noise, the VAE's latents, the transformer's first input and
output, the latents after each step and the decoded fill.

    python reference_inpaint.py <model folder> <text reference folder> <out folder> <photo> [<photo>]

The text encoder isn't loaded: the prompts' embeddings come from the text reference folder.
"""

import json
import sys
from pathlib import Path

import numpy as np
import torch
from diffusers import Flux2KleinInpaintPipeline
from PIL import Image, ImageDraw
from safetensors.torch import load_file, save_file

STEPS = 4

# (photo index, crop box left, top, width, height, mask kind, prompt index, seed)
CASES = [
    (0, 200, 120, 512, 512, "ellipse", 0, 7),
    (1, 80, 40, 512, 384, "rectangle", 2, 11),
]


def mask_image(kind, width, height):
    mask = Image.new("L", (width, height), 0)
    draw = ImageDraw.Draw(mask)
    if kind == "ellipse":
        draw.ellipse((width * 0.3, height * 0.25, width * 0.7, height * 0.75), fill=255)
    else:
        draw.rectangle((width * 0.2, height * 0.35, width * 0.55, height * 0.8), fill=255)
    return mask


def main():
    model, text_reference, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    photos = [Path(p) for p in sys.argv[4:]]
    out.mkdir(parents=True, exist_ok=True)
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    pipe = Flux2KleinInpaintPipeline.from_pretrained(
        model, text_encoder=None, tokenizer=None, torch_dtype=torch.float32
    ).to(device)
    prompts = json.loads((text_reference / "index.json").read_text())
    index = []
    for number, (photo, left, top, width, height, kind, prompt, seed) in enumerate(CASES):
        image = Image.open(photos[photo]).convert("RGB").crop((left, top, left + width, top + height))
        mask = mask_image(kind, width, height)
        embeddings = load_file(text_reference / prompts[prompt]["file"])["embeddings"].to(device)[None]

        noise = torch.randn(
            (1, 128, height // 16, width // 16), generator=torch.Generator().manual_seed(seed), dtype=torch.float32
        )
        captured = {}

        def pre_hook(_module, _args, kwargs):
            if "input" not in captured:
                captured["input"] = kwargs["hidden_states"][0].detach().cpu()
                captured["timestep"] = float(kwargs["timestep"][0])
                captured["img_ids"] = kwargs["img_ids"][0].detach().cpu()
                captured["txt_ids"] = kwargs["txt_ids"][0].detach().cpu()

        def post_hook(_module, _args, _kwargs, output):
            if "output" not in captured:
                captured["output"] = output[0][0].detach().cpu()

        steps = []

        def on_step(_pipe, _step, _timestep, kwargs):
            steps.append(kwargs["latents"][0].detach().cpu())
            return {}

        handles = [
            pipe.transformer.register_forward_pre_hook(pre_hook, with_kwargs=True),
            pipe.transformer.register_forward_hook(post_hook, with_kwargs=True),
        ]
        with torch.no_grad():
            result = pipe(
                image=image,
                mask_image=mask,
                prompt_embeds=embeddings,
                latents=noise.to(device),
                height=height,
                width=width,
                strength=1.0,
                num_inference_steps=STEPS,
                output_type="pt",
                callback_on_step_end=on_step,
            ).images[0]
            preprocessed = pipe.image_processor.preprocess(image, height, width).to(device)
            latents = pipe._encode_vae_image(preprocessed, generator=None)
            mask_tensor = pipe.mask_processor.preprocess(mask, height=height, width=width)
        for handle in handles:
            handle.remove()

        tensors = {
            "image": preprocessed[0].permute(1, 2, 0).cpu().contiguous(),
            "mask": mask_tensor[0, 0].contiguous(),
            "embeddings": embeddings[0].cpu().contiguous(),
            "noise": noise[0].permute(1, 2, 0).reshape(-1, 128).contiguous(),
            "image_latents": latents[0].permute(1, 2, 0).reshape(-1, 128).cpu().contiguous(),
            "first_input": captured["input"].contiguous(),
            "first_output": captured["output"].contiguous(),
            "img_ids": captured["img_ids"].to(torch.float32).contiguous(),
            "txt_ids": captured["txt_ids"].to(torch.float32).contiguous(),
            "result": result.permute(1, 2, 0).cpu().contiguous(),
        }
        for step, step_latents in enumerate(steps):
            tensors[f"step_{step}"] = step_latents.contiguous()
        file = f"case-{number}.safetensors"
        save_file(tensors, out / file)
        Image.fromarray((result.permute(1, 2, 0).cpu().numpy() * 255).round().astype(np.uint8)).save(
            out / f"case-{number}.png"
        )
        sigmas = pipe.scheduler.sigmas.cpu().tolist()
        index.append(
            {
                "file": file,
                "photo": photos[photo].name,
                "crop": [left, top, width, height],
                "mask": kind,
                "prompt": prompts[prompt]["prompt"],
                "seed": seed,
                "steps": STEPS,
                "first_timestep": captured["timestep"],
                "sigmas": sigmas,
            }
        )
        print(f"case {number}: {photos[photo].name} {width}x{height}, sigmas {[round(s, 4) for s in sigmas]}", flush=True)
    (out / "index.json").write_text(json.dumps(index, indent=2))


if __name__ == "__main__":
    main()
