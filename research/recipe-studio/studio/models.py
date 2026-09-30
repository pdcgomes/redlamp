"""Pluggable vision-model clients.

Every role talks to a `VisionModel`: a system prompt plus messages of text and image
paths in, text out. `anthropic:<model>` and `openai:<model>` call those APIs over HTTP
(keys from ANTHROPIC_API_KEY / OPENAI_API_KEY); `offline` is a deterministic stand-in
that reads the structured context the roles attach, for dry runs and tests. Every call is
written to the run's transcripts/ folder.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import random
import time
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class Part:
    text: str | None = None
    image: Path | None = None


@dataclass
class Message:
    role: str
    parts: list[Part] = field(default_factory=list)


class BudgetExceeded(Exception):
    pass


class VisionModel:
    name = "model"

    def complete(self, system: str, messages: list[Message], context: dict | None = None) -> str:
        raise NotImplementedError


def _image_payload(path: Path) -> tuple[str, str]:
    data = path.read_bytes()
    media = "image/png" if data[:4] == b"\x89PNG" else "image/jpeg"
    return media, base64.b64encode(data).decode()


class AnthropicModel(VisionModel):
    def __init__(self, model: str):
        self.name = f"anthropic:{model}"
        self.model = model
        self.key = os.environ["ANTHROPIC_API_KEY"]

    def complete(self, system: str, messages: list[Message], context: dict | None = None) -> str:
        body = {"model": self.model, "max_tokens": 4096, "system": system, "messages": []}
        for message in messages:
            content = []
            for part in message.parts:
                if part.image:
                    media, data = _image_payload(part.image)
                    content.append({"type": "image", "source": {"type": "base64", "media_type": media, "data": data}})
                if part.text:
                    content.append({"type": "text", "text": part.text})
            body["messages"].append({"role": message.role, "content": content})
        request = urllib.request.Request(
            "https://api.anthropic.com/v1/messages", data=json.dumps(body).encode(),
            headers={"x-api-key": self.key, "anthropic-version": "2023-06-01", "content-type": "application/json"},
        )
        with urllib.request.urlopen(request, timeout=300) as response:
            payload = json.loads(response.read())
        return "".join(block.get("text", "") for block in payload.get("content", []))


class OpenAIModel(VisionModel):
    def __init__(self, model: str):
        self.name = f"openai:{model}"
        self.model = model
        self.key = os.environ["OPENAI_API_KEY"]

    def complete(self, system: str, messages: list[Message], context: dict | None = None) -> str:
        body = {"model": self.model, "messages": [{"role": "system", "content": system}]}
        for message in messages:
            content = []
            for part in message.parts:
                if part.image:
                    media, data = _image_payload(part.image)
                    content.append({"type": "image_url", "image_url": {"url": f"data:{media};base64,{data}"}})
                if part.text:
                    content.append({"type": "text", "text": part.text})
            body["messages"].append({"role": message.role, "content": content})
        request = urllib.request.Request(
            "https://api.openai.com/v1/chat/completions", data=json.dumps(body).encode(),
            headers={"authorization": f"Bearer {self.key}", "content-type": "application/json"},
        )
        with urllib.request.urlopen(request, timeout=300) as response:
            payload = json.loads(response.read())
        return payload["choices"][0]["message"]["content"]


class OfflineModel(VisionModel):
    """A deterministic stand-in: answers from the `context` the roles pass alongside the
    prompt (fingerprint distances, lint, the recipe), never from the images. It lets the
    whole loop run without an API, and gives evals a baseline to beat. `bias` makes it
    prefer more saturated candidates, for testing the bias probes."""

    def __init__(self, seed: int = 1, bias: str | None = None):
        self.name = "offline" + (f"-{bias}" if bias else "")
        self.random = random.Random(seed)
        self.bias = bias

    def complete(self, system: str, messages: list[Message], context: dict | None = None) -> str:
        context = context or {}
        task = context.get("task")
        if task == "brief":
            stats = context.get("stats", {})
            tone = "low-key" if stats.get("median", 0.5) < 0.42 else ("high-key" if stats.get("median", 0.5) > 0.62 else "mid-tone")
            color = "monochrome" if stats.get("chroma", 1) < 0.01 else ("muted" if stats.get("chroma", 1) < 0.05 else "colorful")
            warmth = "warm" if stats.get("warmth", 0) > 0.004 else ("cool" if stats.get("warmth", 0) < -0.004 else "neutral")
            return json.dumps({
                "title": f"{warmth.title()} {color} {tone} look",
                "description": f"A {warmth}, {color}, {tone} rendering drawn from {context.get('count', 0)} references.",
                "requirements": ["skin stays natural", "skies keep detail", "foliage doesn't turn neon"],
            })
        if task == "propose":
            variants = []
            for index in range(context.get("count", 3)):
                delta = {key: round(self.random.uniform(-12, 12)) for key in ("basic.contrast", "basic.saturation", "basic.highlights")}
                variants.append({"name": f"Variant {index + 1}", "changes": delta, "rationale": "offline exploration"})
            return json.dumps({"variants": variants})
        if task == "revise":
            changes = {key: round(self.random.uniform(-8, 8)) for key in ("basic.contrast", "basic.shadows", "basic.vibrance")}
            return json.dumps({"changes": changes, "rationale": "offline revision"})
        if task == "critique":
            distance = context.get("distance", 1.0)
            lint_penalty = {"pass": 0, "warn": 0.5, "fail": 2}.get(context.get("lint", "pass"), 0)
            score = max(1.0, min(10.0, 9.5 - 3 * distance - lint_penalty))
            return json.dumps({
                "scores": {"brief": round(score, 1), "skin": round(score - lint_penalty, 1), "overall": round(score, 1)},
                "notes": f"Fingerprint distance {distance:.2f}.",
                "changeRequests": ["reduce the difference from the references"] if distance > 0.6 else [],
            })
        if task == "compare":
            a, b = context["a"], context["b"]
            if self.bias == "saturation":
                return json.dumps({"winner": "A" if a.get("saturation", 0) >= b.get("saturation", 0) else "B"})
            if self.bias == "first":
                return json.dumps({"winner": "A"})
            return json.dumps({"winner": "A" if a.get("distance", 1) <= b.get("distance", 1) else "B"})
        return "{}"


def load_model(spec: str, seed: int = 1) -> VisionModel:
    if spec.startswith("anthropic:"):
        return AnthropicModel(spec.split(":", 1)[1])
    if spec.startswith("openai:"):
        return OpenAIModel(spec.split(":", 1)[1])
    if spec.startswith("offline"):
        bias = spec.split(":", 1)[1] if ":" in spec else None
        return OfflineModel(seed=seed, bias=bias)
    raise ValueError(f"unknown model {spec} (anthropic:<model>, openai:<model>, offline)")


class Recorder:
    """Counts calls against a budget and writes each one to transcripts/."""

    def __init__(self, model: VisionModel, folder: Path, budget: int):
        self.model = model
        self.folder = folder
        self.budget = budget
        self.calls = 0
        folder.mkdir(parents=True, exist_ok=True)

    def complete(self, role: str, system: str, messages: list[Message], context: dict | None = None) -> str:
        if self.calls >= self.budget:
            raise BudgetExceeded(f"model call budget of {self.budget} reached")
        self.calls += 1
        started = time.time()
        reply = self.model.complete(system, messages, context)
        record = {
            "n": self.calls, "role": role, "model": self.model.name, "seconds": round(time.time() - started, 2),
            "system": system,
            "messages": [{"role": m.role, "parts": [{"text": p.text, "image": str(p.image) if p.image else None} for p in m.parts]} for m in messages],
            "context": context, "reply": reply,
        }
        (self.folder / f"{self.calls:05d}-{role}.json").write_text(json.dumps(record, indent=1, default=str))
        return reply


def parse_json(reply: str) -> dict:
    """The first JSON object in a model reply (models sometimes wrap it in prose)."""
    start = reply.find("{")
    depth = 0
    for index in range(start, len(reply)):
        if reply[index] == "{":
            depth += 1
        elif reply[index] == "}":
            depth -= 1
            if depth == 0:
                return json.loads(reply[start:index + 1])
    raise ValueError(f"no JSON in reply: {reply[:200]}")


def prompt_version(*texts: str) -> str:
    return hashlib.sha256("\n\0".join(texts).encode()).hexdigest()[:12]
