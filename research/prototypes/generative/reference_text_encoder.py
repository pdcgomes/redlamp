"""Reference prompt embeddings from FLUX.2 [klein] 4B's text encoder, as diffusers' Flux2Klein
pipelines make them (`_get_qwen3_prompt_embeds`): the chat template without thinking, padded to
512 tokens, and the outputs of layers 9, 18 and 27 side by side, 7680 values a token.

Writes one safetensors file a prompt (input_ids, attention_mask, embeddings in float32) and a
JSON index with the templated text, for Redlamp's MLX port (`FluxTextEncoderTests`) to be checked
against. Each prompt is also encoded in bfloat16, to show how far that precision alone moves them.

    pip install torch transformers safetensors
    python reference_text_encoder.py --model <FLUX.2-klein-4B diffusers folder> --out <folder>
"""

import argparse
import json
import os
import time

import torch
from safetensors.torch import save_file
from transformers import AutoTokenizer, Qwen3ForCausalLM

parser = argparse.ArgumentParser()
parser.add_argument("--model", required=True, help="the diffusers folder of black-forest-labs/FLUX.2-klein-4B")
parser.add_argument("--out", required=True)
arguments = parser.parse_args()
MODEL = arguments.model
OUT = arguments.out
LAYERS = (9, 18, 27)
LENGTH = 512
PROMPTS = ["", "a calm lake at dusk", "Remove the ducks and keep the water's reflections"]

os.makedirs(OUT, exist_ok=True)
tokenizer = AutoTokenizer.from_pretrained(f"{MODEL}/tokenizer")
index = []
for dtype in (torch.float32, torch.bfloat16):
    started = time.time()
    model = Qwen3ForCausalLM.from_pretrained(f"{MODEL}/text_encoder", dtype=dtype).eval()
    print(f"loaded {dtype} in {time.time() - started:.1f} s", flush=True)
    for number, prompt in enumerate(PROMPTS):
        text = tokenizer.apply_chat_template(
            [{"role": "user", "content": prompt}], tokenize=False, add_generation_prompt=True, enable_thinking=False,
        )
        inputs = tokenizer(text, return_tensors="pt", padding="max_length", truncation=True, max_length=LENGTH)
        started = time.time()
        with torch.no_grad():
            output = model(
                input_ids=inputs["input_ids"], attention_mask=inputs["attention_mask"],
                output_hidden_states=True, use_cache=False,
            )
        stacked = torch.stack([output.hidden_states[k] for k in LAYERS], dim=1)
        batch, channels, length, width = stacked.shape
        embeddings = stacked.permute(0, 2, 1, 3).reshape(batch, length, channels * width)[0].float()
        name = f"prompt-{number}-{'f32' if dtype == torch.float32 else 'bf16'}"
        save_file(
            {
                "input_ids": inputs["input_ids"][0].to(torch.int32),
                "attention_mask": inputs["attention_mask"][0].to(torch.int32),
                "embeddings": embeddings.contiguous(),
            },
            f"{OUT}/{name}.safetensors",
        )
        tokens = int(inputs["attention_mask"].sum())
        print(f"{name}: {tokens} tokens, {time.time() - started:.1f} s, hidden states {len(output.hidden_states)}", flush=True)
        if dtype == torch.float32:
            index.append({"prompt": prompt, "text": text, "tokens": tokens, "file": f"{name}.safetensors"})
    del model

with open(f"{OUT}/index.json", "w") as f:
    json.dump(index, f, indent=2)

# How far bfloat16 alone moves the embeddings, over the real tokens.
from safetensors.torch import load_file

for number in range(len(PROMPTS)):
    a = load_file(f"{OUT}/prompt-{number}-f32.safetensors")
    b = load_file(f"{OUT}/prompt-{number}-bf16.safetensors")
    n = int(a["attention_mask"].sum())
    x, y = a["embeddings"][:n], b["embeddings"][:n]
    cosine = torch.nn.functional.cosine_similarity(x, y, dim=1)
    relative = (x - y).norm(dim=1) / x.norm(dim=1)
    print(f"prompt {number}: bf16 against f32, cosine min {cosine.min():.5f}, relative error max {relative.max():.4f}, median {relative.median():.4f}")
