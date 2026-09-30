"""The agents: Curator, Colorist, Photographer critics and the Selector.

Each role owns one kind of decision and talks to Redlamp only through `RedlampMCP`.
Technical QA is not a role: lint and fingerprint distance are deterministic tools, and a
candidate that fails lint is dropped before any critic sees it.
"""

from __future__ import annotations

import copy
import hashlib
import json
import math
import random
from dataclasses import dataclass
from pathlib import Path

from . import ROOT, STUDIO
from .mcp import RedlampMCP
from .models import Message, Part, Recorder, parse_json, prompt_version
from .rating import bradley_terry, diversity_penalty
from .references import Corpus, Reference
from .store import Run, now

RUBRICS = STUDIO / "rubrics" / "v1"


def rubric(name: str) -> str:
    return (RUBRICS / f"{name}.md").read_text()


def rubric_version() -> str:
    return "v1-" + prompt_version(*(path.read_text() for path in sorted(RUBRICS.glob("*.md"))))


# MARK: - Curator


def fingerprint_vector(f: dict) -> list[float]:
    """The same flat vector as `StyleFingerprint.vector` in Swift, for clustering."""
    return ([v / 0.05 for v in f["lightness"]] + [f["localContrast"] / 0.01, f["clippedHighlights"] / 0.05]
            + [v / 0.008 for v in f["shadowTint"] + f["midtoneTint"] + f["highlightTint"]] + [f["meanChroma"] / 0.015]
            + [c * min(s * 8, 1) / 0.02 for c, s in zip(f["bandChroma"], f["bandShare"])]
            + [f["grain"] / 0.004, f["vignette"] / 0.04])


def kmeans(vectors: list[list[float]], k: int, seed: int, iterations: int = 30) -> list[int]:
    """Seeded k-means with k-means++ initialisation; returns a cluster per vector."""
    generator = random.Random(seed)
    if k >= len(vectors):
        return list(range(len(vectors)))

    def distance(a, b):
        return sum((x - y) ** 2 for x, y in zip(a, b))

    centres = [vectors[generator.randrange(len(vectors))]]
    while len(centres) < k:
        weights = [min(distance(v, c) for c in centres) for v in vectors]
        total = sum(weights) or 1
        pick, running = generator.random() * total, 0.0
        for vector, weight in zip(vectors, weights):
            running += weight
            if running >= pick:
                centres.append(vector)
                break
    labels = [0] * len(vectors)
    for _ in range(iterations):
        labels = [min(range(k), key=lambda c: distance(v, centres[c])) for v in vectors]
        for c in range(k):
            members = [v for v, label in zip(vectors, labels) if label == c]
            if members:
                centres[c] = [sum(values) / len(members) for values in zip(*members)]
    return labels


class Curator:
    def __init__(self, mcp: RedlampMCP, model: Recorder, run: Run, seed: int):
        self.mcp, self.model, self.run, self.seed = mcp, model, run, seed

    def curate(self, corpus: Corpus, per_brief: int = 8, styles: set[str] | None = None, log=print) -> list[dict]:
        """One or more briefs per style bucket, splitting large buckets by fingerprint."""
        briefs = []
        for style, references in sorted(corpus.by_style().items()):
            if styles and style not in styles:
                continue
            paths, vectors = [], []
            for reference in references:
                path = corpus.path(reference)
                try:
                    measured = self.mcp.call("fingerprint", images=[str(path)])
                except Exception as error:
                    log(f"  skip {reference.id}: {error}")
                    continue
                paths.append((reference, path))
                vectors.append(measured.get("vector") or fingerprint_vector(measured["fingerprint"]))
            if len(paths) < 2:
                continue
            k = max(1, math.ceil(len(paths) / per_brief))
            labels = kmeans(vectors, k, self.seed)
            for cluster in range(k):
                members = [pair for pair, label in zip(paths, labels) if label == cluster]
                if len(members) >= 2:
                    briefs.append(self.brief(style, cluster, members))
                    log(f"  brief {briefs[-1]['id']}: {briefs[-1]['title']}")
        return briefs

    def brief(self, style: str, cluster: int, members: list[tuple[Reference, Path]]) -> dict:
        images = [str(path) for _, path in members]
        measured = self.mcp.call("fingerprint", images=images)
        fingerprint = measured["fingerprint"]
        tint = fingerprint["midtoneTint"]
        stats = {
            "median": fingerprint["lightness"][3], "chroma": fingerprint["meanChroma"],
            "warmth": tint[1], "contrast": fingerprint["localContrast"], "grain": fingerprint["grain"],
        }
        parts = [Part(image=path) for _, path in members[:4]]
        parts.append(Part(text=f"Style bucket: {style}\nMeasured: {measured['summary']}\nReferences: " + "; ".join(
            f"{ref.title[:60]} ({ref.date})" for ref, _ in members)))
        reply = self.model.complete("curator", rubric("curator"), [Message("user", parts)],
                                    {"task": "brief", "stats": stats, "count": len(members)})
        drafted = parse_json(reply)
        brief = {
            "id": f"{style}-{cluster + 1}", "title": drafted.get("title", style), "description": drafted.get("description", ""),
            "requirements": drafted.get("requirements", []),
            "references": [str(path.relative_to(ROOT)) if path.is_relative_to(ROOT) else str(path) for _, path in members],
            "targetFingerprint": fingerprint, "status": "proposed", "createdBy": f"curator ({self.model.model.name})",
        }
        self.run.save_brief(brief)
        return brief


# MARK: - Colorist


class Colorist:
    def __init__(self, mcp: RedlampMCP, model: Recorder, run: Run, images: list[str], schema: dict, fit_evaluations: int):
        self.mcp, self.model, self.run, self.images = mcp, model, run, images
        self.groups = {p["key"]: p["group"] for p in schema["parameters"]}
        self.ranges = {p["key"]: (p["min"], p["max"]) for p in schema["parameters"]}
        self.base_looks = {look["id"]: look["reference"] for look in schema["baseLooks"]}
        self.schema_text = json.dumps({
            "parameters": [p for p in schema["parameters"] if p["renders"] and p["group"] != "not-in-recipes"],
            "baseLooks": [{"id": look["id"], "name": look["name"], "summary": look["summary"]} for look in schema["baseLooks"]],
        })
        self.fit_evaluations = fit_evaluations
        self.counter = len(run.candidates())

    def next_id(self) -> str:
        self.counter += 1
        return f"c{self.counter:03d}"

    def save(self, recipe: dict, brief: dict, parent: str | None, iteration: int, origin: str, notes: str) -> dict:
        candidate_id = self.next_id()
        recipe = {**recipe, "id": f"local/{self.run.id}/{candidate_id}", "version": 1}
        recipe.pop("embeddedBaseLooks", None) if not recipe.get("embeddedBaseLooks") else None
        result = self.mcp.call(
            "save_candidate", run=self.run.id, recipe=recipe, id=candidate_id, brief=brief["id"], parent=parent,
            iteration=iteration, origin=origin, notes=notes, images=self.images,
        )
        return self.run.candidate(result["candidate"])

    def apply(self, recipe: dict, changes: dict, base_look: str | None) -> dict:
        updated = copy.deepcopy(recipe)
        values = updated.setdefault("settings", {}).setdefault("values", {})
        includes = set(updated.get("includes", []))
        for key, value in changes.items():
            if key not in self.groups or self.groups[key] == "not-in-recipes":
                continue
            low, high = self.ranges[key]
            values[key] = max(low, min(high, float(value)))
            includes.add(self.groups[key])
        if base_look and base_look in self.base_looks:
            updated["baseLook"] = self.base_looks[base_look]
            includes.add("baseLook")
        updated["includes"] = sorted(includes)
        return updated

    def propose(self, brief: dict, variants: int, log=print) -> list[dict]:
        fitted = self.mcp.call(
            "fit_to_fingerprint", target=brief["targetFingerprint"], images=self.images, name=brief["title"],
            evaluations=self.fit_evaluations, run=self.run.id, brief=brief["id"], seed=1, id=self.next_id(),
        )
        start = self.run.candidate(fitted["candidate"])
        log(f"  fit {start['id']}: distance {fitted['startDistance']:.2f} → {fitted['distance']:.2f}")
        recipe = self.run.recipe(start["id"])
        sheet = self.run.render_path(start)
        parts = ([Part(image=sheet)] if sheet else []) + [Part(text=(
            f"Brief: {brief['title']}\n{brief['description']}\nRequirements: {'; '.join(brief.get('requirements', []))}\n"
            f"Starting recipe (fitted):\n{json.dumps(recipe.get('settings', {}))}\nSchema:\n{self.schema_text}\n"
            f"Propose {variants} variants."))]
        reply = self.model.complete("colorist", rubric("colorist"), [Message("user", parts)],
                                    {"task": "propose", "count": variants})
        created = [start]
        for index, variant in enumerate(parse_json(reply).get("variants", [])[:variants]):
            candidate = self.apply(recipe, variant.get("changes", {}), variant.get("baseLook"))
            candidate["name"] = variant.get("name") or f"{brief['title']} {index + 1}"
            created.append(self.save(candidate, brief, start["id"], 1, "colorist", variant.get("rationale", "")))
        return created

    def revise(self, brief: dict, parent: dict, requests: list[str], iteration: int) -> dict:
        recipe = self.run.recipe(parent["id"])
        sheet = self.run.render_path(parent)
        parts = ([Part(image=sheet)] if sheet else []) + [Part(text=(
            f"Brief: {brief['title']}\n{brief['description']}\nCurrent recipe:\n{json.dumps(recipe.get('settings', {}))}\n"
            f"Critics ask:\n- " + "\n- ".join(requests or ["refine towards the brief"]) + f"\nSchema:\n{self.schema_text}"))]
        reply = parse_json(self.model.complete("colorist", rubric("colorist"), [Message("user", parts)], {"task": "revise"}))
        revised = self.apply(recipe, reply.get("changes", {}), reply.get("baseLook"))
        revised["name"] = recipe.get("name", brief["title"])
        return self.save(revised, brief, parent["id"], iteration, "mutation", reply.get("rationale", ""))


# MARK: - Critics


@dataclass
class Critic:
    persona: str
    mcp: RedlampMCP
    model: Recorder
    run: Run

    @property
    def name(self) -> str:
        return f"critic-{self.persona}"

    def distance(self, candidate: dict, brief: dict, images: list[str]) -> float:
        if candidate.get("fingerprintDistance") is not None:
            return float(candidate["fingerprintDistance"])
        measured = self.mcp.call("fingerprint", images=images, recipe=str(self.run.recipe_path(candidate["id"])),
                                 target=brief["targetFingerprint"])
        candidate["fingerprintDistance"] = measured["distance"]
        self.run.update_candidate(candidate)
        return measured["distance"]

    def critique(self, candidate: dict, brief: dict, images: list[str]) -> dict:
        sheet = self.run.render_path(candidate)
        parts = ([Part(image=sheet)] if sheet else []) + [Part(text=(
            f"Brief: {brief['title']}\n{brief['description']}\nRequirements: {'; '.join(brief.get('requirements', []))}"))]
        context = {"task": "critique", "distance": self.distance(candidate, brief, images), "lint": candidate.get("lint")}
        verdict = parse_json(self.model.complete(self.name, rubric(f"critic-{self.persona}"), [Message("user", parts)], context))
        record = {"candidate": candidate["id"], "critic": self.name, "rubricVersion": rubric_version(),
                  "scores": verdict.get("scores", {}), "notes": verdict.get("notes"),
                  "changeRequests": verdict.get("changeRequests", [])}
        self.run.append("critiques.jsonl", record)
        return record

    def compare(self, a: dict, b: dict, brief: dict, image: str, generator: random.Random, images: list[str]) -> str | None:
        """Pairwise, with the presentation order randomised and names hidden."""
        swapped = generator.random() < 0.5
        first, second = (b, a) if swapped else (a, b)
        result = self.mcp.call("compare", a=str(self.run.recipe_path(first["id"])), b=str(self.run.recipe_path(second["id"])),
                               image=image, run=self.run.id)
        parts = [Part(image=Path(result["path"]))] if result.get("path") else []
        parts.append(Part(text=f"Brief: {brief['title']}\n{brief['description']}\nLeft is A, right is B."))

        def features(candidate):
            values = self.run.recipe(candidate["id"]).get("settings", {}).get("values", {})
            return {"distance": self.distance(candidate, brief, images), "saturation": values.get("basic.saturation", 0)}

        reply = parse_json(self.model.complete(self.name, rubric("pairwise"), [Message("user", parts)],
                                               {"task": "compare", "a": features(first), "b": features(second)}))
        pick = str(reply.get("winner", "tie")).upper()
        winner = first["id"] if pick == "A" else (second["id"] if pick == "B" else None)
        self.run.append("comparisons.jsonl", {"a": a["id"], "b": b["id"], "winner": winner, "critic": self.name,
                                              "swapped": swapped, "brief": brief["id"]})
        return winner


# MARK: - Selector


class Selector:
    """Ratings from pairwise comparisons (Bradley-Terry), with human verdicts counted three
    times, a penalty for candidates too close to recipes the library already has, and the
    shortlist."""

    HUMAN_WEIGHT = 3

    def __init__(self, run: Run, library_prints: dict[str, dict], mcp: RedlampMCP, images: list[str]):
        self.run, self.library_prints, self.mcp, self.images = run, library_prints, mcp, images
        self.distance_cache: dict[str, float] = {}

    def library_distance(self, candidate: dict) -> float:
        if candidate["id"] in self.distance_cache:
            return self.distance_cache[candidate["id"]]
        best = math.inf
        for recipe_id, fingerprint in self.library_prints.items():
            measured = self.mcp.call("fingerprint", images=self.images, recipe=str(self.run.recipe_path(candidate["id"])),
                                     target=fingerprint)
            best = min(best, measured["distance"])
        self.distance_cache[candidate["id"]] = best
        return best

    def ratings(self, brief: dict, candidates: list[dict]) -> dict[str, float]:
        ids = [c["id"] for c in candidates]
        pairs = [(c["a"], c["b"], c.get("winner")) for c in self.run.comparisons() if c.get("brief") == brief["id"]]
        for verdict in self.run.verdicts():
            if verdict.get("type") == "pairwise" and verdict.get("brief") == brief["id"]:
                pairs += [(verdict["a"], verdict["b"], verdict.get("winner"))] * self.HUMAN_WEIGHT
        strengths = bradley_terry(ids, pairs)
        return {c["id"]: strengths[c["id"]] - diversity_penalty(self.library_distance(c)) for c in candidates}

    def shortlist(self, brief: dict, ratings: dict[str, float], size: int = 3) -> list[str]:
        return [cid for cid, _ in sorted(ratings.items(), key=lambda item: -item[1])[:size]]


def library_fingerprints(mcp: RedlampMCP, run: Run, images: list[str], limit: int = 40) -> dict[str, dict]:
    """Fingerprints of the bundled recipes on the run's images, cached in the run."""
    cache = run.dir / "library-fingerprints.json"
    if cache.exists():
        return json.loads(cache.read_text())
    prints = {}
    for recipe in mcp.call("list_recipes")[:limit]:
        prints[recipe["id"]] = mcp.call("fingerprint", images=images, recipe=recipe["id"])["fingerprint"]
    cache.write_text(json.dumps(prints))
    return prints


def stable_fraction(key: str) -> float:
    return int(hashlib.sha256(key.encode()).hexdigest()[:8], 16) / 0xFFFFFFFF
