"""Python candidates for the mask bench (MSK-39, MSK-40): each loads its model once and predicts
regions on a photo's bench JPEG; `maskbench run` then gives each region Redlamp's own edges.

Weights are downloaded into HF_HUB_CACHE, by default /Volumes/SSD/redlamp-tmp/mask-bench/hf-hub, so
the evaluation models stay off the internal disk; delete that folder when the comparisons end. The
models run with PyTorch on the GPU (MPS), with the CPU for the few operations MPS lacks.

* `dichotomous`: BiRefNet and the models built on it (RMBG-2.0): the salient foreground, predicted
  at a square input of `input` pixels; Background is its inverse.
* `oneformer`: OneFormer's ADE20K semantic segmentation, its sky class as a probability per pixel.
"""

import os

os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
os.environ.setdefault("HF_HUB_CACHE", "/Volumes/SSD/redlamp-tmp/mask-bench/hf-hub")

import cv2  # noqa: E402
import numpy as np  # noqa: E402
import torch  # noqa: E402
import torch.nn.functional as F  # noqa: E402
from PIL import Image  # noqa: E402

MEAN = np.array([0.485, 0.456, 0.406], np.float32)
STD = np.array([0.229, 0.224, 0.225], np.float32)


def device():
    return torch.device("mps" if torch.backends.mps.is_available() else "cpu")


class Dichotomous:
    def __init__(self, repo, size):
        from transformers import AutoModelForImageSegmentation

        torch.set_float32_matmul_precision("high")
        self.model = AutoModelForImageSegmentation.from_pretrained(repo, trust_remote_code=True).to(device()).eval()
        self.size = size

    def predict(self, path, kinds):
        image = Image.open(path).convert("RGB")
        square = np.asarray(image.resize((self.size, self.size), Image.BILINEAR), np.float32) / 255
        tensor = torch.from_numpy((square - MEAN) / STD).permute(2, 0, 1)[None].to(device())
        with torch.no_grad():
            prediction = self.model(tensor)[-1].sigmoid()[0, 0].float().cpu().numpy()
        subject = cv2.resize(prediction, image.size, interpolation=cv2.INTER_LINEAR)
        maps = {"subject": subject, "background": 1 - subject}
        return {kind: maps[kind] for kind in kinds if kind in maps}


class BEN2:
    """BEN2 (PramaLLC): its own code from its repository, its weights from model.safetensors; it
    resizes the photo itself and returns the foreground with the mask as its alpha."""

    def __init__(self, repo):
        import importlib.util

        from huggingface_hub import hf_hub_download
        from safetensors.torch import load_file

        spec = importlib.util.spec_from_file_location("BEN2", hf_hub_download(repo, "BEN2.py"))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.model = module.BEN_Base().to(device()).eval()
        self.model.load_state_dict(load_file(hf_hub_download(repo, "model.safetensors")))

    def predict(self, path, kinds):
        image = Image.open(path).convert("RGB")
        with torch.no_grad():
            foreground = self.model.inference(image)
        alpha = np.asarray(foreground.split()[-1], np.float32) / 255
        subject = cv2.resize(alpha, image.size, interpolation=cv2.INTER_LINEAR)
        maps = {"subject": subject, "background": 1 - subject}
        return {kind: maps[kind] for kind in kinds if kind in maps}


class OneFormerSky:
    def __init__(self, repo):
        from transformers import OneFormerForUniversalSegmentation, OneFormerProcessor

        self.processor = OneFormerProcessor.from_pretrained(repo)
        self.model = OneFormerForUniversalSegmentation.from_pretrained(repo).to(device()).eval()
        self.sky = next(int(i) for i, name in self.model.config.id2label.items() if name == "sky")

    def predict(self, path, kinds):
        if "sky" not in kinds:
            return {}
        image = Image.open(path).convert("RGB")
        inputs = self.processor(images=image, task_inputs=["semantic"], return_tensors="pt")
        inputs = {k: v.to(device()) if hasattr(v, "to") else v for k, v in inputs.items()}
        with torch.no_grad():
            outputs = self.model(**inputs)
        classes = outputs.class_queries_logits.softmax(-1)[..., :-1]
        masks = outputs.masks_queries_logits.sigmoid()
        scores = torch.einsum("bqc,bqhw->bchw", classes, masks)[0]
        scores = F.interpolate(scores[None], size=image.size[::-1], mode="bilinear", align_corners=False)[0]
        sky = (scores[self.sky] / scores.sum(0).clamp(min=1e-6)).float().cpu().numpy()
        return {"sky": sky}


def load(spec):
    if spec["model"] == "dichotomous":
        return Dichotomous(spec["repo"], spec.get("input", 1024))
    if spec["model"] == "oneformer":
        return OneFormerSky(spec["repo"])
    if spec["model"] == "ben2":
        return BEN2(spec["repo"])
    raise SystemExit(f"no Python model {spec['model']} (candidates.py)")
