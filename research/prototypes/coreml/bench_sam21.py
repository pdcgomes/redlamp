"""Time Apple's SAM 2.1 Core ML packages (apple/coreml-sam2.1-*) per compute unit.

Runs the image encoder once per photo and the prompt encoder + mask decoder per
hover point, which is the interaction pattern for "hover to select any object".
Models are compiled to a stable .mlmodelc path, so running the script twice
shows whether the OS caches the Neural Engine compilation between processes.

Usage:
  build/research-venv/bin/python research/prototypes/coreml/bench_sam21.py [--variant tiny]
"""

import argparse
import pathlib
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from common import DATA, OUT, compile_once, load_timed, median_ms, placement, write_json  # noqa: E402

UNITS = ["cpuAndGPU", "cpuAndNeuralEngine", "all"]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--variant", default="tiny")
    parser.add_argument("--runs", type=int, default=10)
    args = parser.parse_args()
    root = DATA / f"sam2.1-{args.variant}"
    stem = f"SAM2_1{args.variant.capitalize()}"
    parts = {name: compile_once(root / f"{stem}{name}FLOAT16.mlpackage")
             for name in ("ImageEncoder", "PromptEncoder", "MaskDecoder")}

    frame = Image.open(DATA / "stacks" / "pcb_000.JPG").convert("RGB")
    image = frame.resize((1024, 1024), Image.BICUBIC)
    points = np.array([[[512.0, 512.0]]], dtype=np.float32)
    labels = np.array([[1]], dtype=np.int32)

    report = {"variant": args.variant, "machine": "Apple M1 Ultra", "units": {}, "placement": {}}
    for name, compiled in parts.items():
        report["placement"][name] = {u: placement(compiled, u) for u in ("cpuAndNeuralEngine", "all")}

    mask = None
    for units in UNITS:
        encoder, enc_load = load_timed(parts["ImageEncoder"], units)
        prompt, prompt_load = load_timed(parts["PromptEncoder"], units)
        decoder, dec_load = load_timed(parts["MaskDecoder"], units)
        feats = encoder.predict({"image": image})
        enc_ms, enc_p90 = median_ms(lambda: encoder.predict({"image": image}), runs=args.runs)

        rng = np.random.default_rng(7)

        def hover():
            p = (points + rng.uniform(-200, 200, points.shape)).astype(np.float32)
            emb = prompt.predict({"points": p, "labels": labels})
            return decoder.predict({
                "image_embedding": feats["image_embedding"],
                "sparse_embedding": emb["sparse_embeddings"],
                "dense_embedding": emb["dense_embeddings"],
                "feats_s0": feats["feats_s0"],
                "feats_s1": feats["feats_s1"],
            })

        hover_ms, hover_p90 = median_ms(hover, runs=args.runs * 2)
        out = hover()
        if mask is None:
            mask = out["low_res_masks"][0, int(np.argmax(out["scores"][0]))]
        report["units"][units] = {
            "loadSeconds": {"encoder": round(enc_load, 2), "prompt": round(prompt_load, 2), "decoder": round(dec_load, 2)},
            "encoderMedianMs": round(enc_ms, 1), "encoderP90Ms": round(enc_p90, 1),
            "hoverMedianMs": round(hover_ms, 1), "hoverP90Ms": round(hover_p90, 1),
        }
        print(f"{units}: load enc {enc_load:.2f}s / prompt {prompt_load:.2f}s / dec {dec_load:.2f}s; "
              f"encoder {enc_ms:.1f} ms; hover {hover_ms:.1f} ms", flush=True)

    embedding_bytes = sum(np.asarray(feats[k]).astype(np.float16).nbytes for k in ("image_embedding", "feats_s0", "feats_s1"))
    report["embeddingCacheMiB"] = round(embedding_bytes / 2**20, 2)
    OUT.mkdir(parents=True, exist_ok=True)
    overlay = np.asarray(image, dtype=np.float32) / 255.0
    selected = np.asarray(Image.fromarray((mask > 0).astype(np.uint8) * 255).resize((1024, 1024))) > 0
    overlay[selected] = overlay[selected] * 0.45 + np.array([0.9, 0.1, 0.1]) * 0.55
    Image.fromarray((overlay * 255).astype(np.uint8)).save(OUT / f"sam2.1-{args.variant}-mask.png")
    print(f"wrote {write_json(f'sam2.1-{args.variant}-bench.json', report)}")


if __name__ == "__main__":
    main()
