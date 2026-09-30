"""Keeping the critics honest.

- Agreement: a critic configuration (model + rubrics) is trusted only after it matches
  held-out human pairwise verdicts at least 70% of the time, over at least 30 of them
  (collect about 200 before trusting critics on a larger batch).
- Order: every comparison is asked in both orders; a critic that flips with the order
  isn't judging the images.
- Bias probes: fixed pairs of a neutral edit against itself with +30 saturation or +30
  contrast, the "more" side alternating; a critic that picks "more" most of the time, or
  the left image most of the time, is flagged.
- Versions: rubrics, prompts and the model name hash to a version; a report is stored per
  version, so any change is re-scored against the same verdicts.
"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from pathlib import Path

from . import RUNS
from .mcp import RedlampMCP
from .models import Message, Part, Recorder, load_model, parse_json
from .roles import rubric, rubric_version, stable_fraction
from .store import all_runs

EVALS = RUNS / "_evals"
HELD_OUT = 0.3
MIN_VERDICTS = 30
MIN_AGREEMENT = 0.70
MIN_ORDER_CONSISTENCY = 0.8
MAX_BIAS = 0.75


@dataclass
class Report:
    version: str
    model: str
    rubric: str
    verdicts: int
    agreement: float | None
    order_consistency: float | None
    position_bias: float | None
    saturation_preference: float | None
    contrast_preference: float | None
    trusted: bool
    reason: str


def version(model_name: str) -> str:
    return f"{model_name}|{rubric_version()}"


def report_path(model_name: str) -> Path:
    safe = version(model_name).replace(":", "_").replace("|", "__").replace("/", "_")
    return EVALS / f"{safe}.json"


def human_pairs(held_out: bool = True) -> list[dict]:
    """Human pairwise verdicts with a winner, across every run. The held-out split is
    fixed by hashing the pair, so the same verdicts are always held out."""
    pairs = []
    for run in all_runs():
        for verdict in run.verdicts():
            if verdict.get("type") != "pairwise" or verdict.get("rater") in (None, "agent", "auto"):
                continue
            if not verdict.get("winner"):
                continue
            key = "|".join(sorted([verdict["a"], verdict["b"]]))
            if held_out and stable_fraction(key) >= HELD_OUT:
                continue
            pairs.append({**verdict, "run": run.id})
    return pairs


def _judge(recorder: Recorder, mcp: RedlampMCP, a, b, brief: str, image: str, context: dict, run: str = "_evals") -> str:
    """One critic judgment of A (left) against B (right); `a`/`b` are recipe paths or objects."""
    result = mcp.call("compare", a=a, b=b, image=image, run=run)
    parts = [Part(image=Path(result["path"]))] if result.get("path") else []
    parts.append(Part(text=f"Brief: {brief}\nLeft is A, right is B."))
    reply = parse_json(recorder.complete("eval", rubric("pairwise"), [Message("user", parts)], {"task": "compare", **context}))
    return str(reply.get("winner", "tie")).upper()


def evaluate(model_spec: str, images: list[str] | None = None, log=print, seed: int = 1) -> Report:
    model = load_model(model_spec, seed)
    EVALS.mkdir(parents=True, exist_ok=True)
    recorder = Recorder(model, EVALS / "transcripts", budget=10_000)
    agree = decided = consistent = asked = first = 0
    saturation_more = contrast_more = probes = 0
    with RedlampMCP() as mcp:
        if images is None:
            from .loop import lookdev_images
            images = lookdev_images(mcp, 3)
        pairs = human_pairs()
        for pair in pairs:
            from .store import Run
            run = Run(pair["run"])
            brief = next((b for b in run.briefs() if b["id"] == pair.get("brief")), {"title": "", "description": ""})
            text = f"{brief['title']}\n{brief['description']}"
            a, b = str(run.recipe_path(pair["a"])), str(run.recipe_path(pair["b"]))
            context = {"a": _features(run, pair["a"]), "b": _features(run, pair["b"])}
            forward = _judge(recorder, mcp, a, b, text, images[0], context)
            backward = _judge(recorder, mcp, b, a, text, images[0], {"a": context["b"], "b": context["a"]})
            asked += 2
            first += (forward == "A") + (backward == "A")
            forward_pick = pair["a"] if forward == "A" else (pair["b"] if forward == "B" else None)
            backward_pick = pair["b"] if backward == "A" else (pair["a"] if backward == "B" else None)
            if forward_pick == backward_pick:
                consistent += 1
                if forward_pick is not None:
                    decided += 1
                    agree += forward_pick == pair["winner"]
        # Bias probes: the same neutral edit against itself with +30 saturation, then +30
        # contrast, on several photos, with the "more" side alternating between A and B.
        for index, image in enumerate((images * 4)[:8]):
            parameter, counter = (("basic.saturation", "saturation"), ("basic.contrast", "contrast"))[index % 2]
            more = {"name": "Probe", "includes": ["presence", "tone"], "settings": {"values": {parameter: 30}}}
            neutral = {"name": "Probe", "includes": ["presence", "tone"], "settings": {"values": {}}}
            more_first = (index // 2) % 2 == 0
            first_recipe, second_recipe = (more, neutral) if more_first else (neutral, more)
            boost = 30 if counter == "saturation" else 0
            features = ({"distance": 0.5, "saturation": boost}, {"distance": 0.5, "saturation": 0})
            context = {"a": features[0], "b": features[1]} if more_first else {"a": features[1], "b": features[0]}
            pick = _judge(recorder, mcp, first_recipe, second_recipe, "A natural, balanced everyday look.", image, context)
            probes += 1
            asked += 1
            first += pick == "A"
            chose_more = (pick == "A") == more_first and pick in ("A", "B")
            if chose_more:
                if counter == "saturation":
                    saturation_more += 1
                else:
                    contrast_more += 1
    per_kind = max(probes / 2, 1)
    report = Report(
        version=version(model.name), model=model.name, rubric=rubric_version(), verdicts=len(pairs),
        agreement=agree / decided if decided else None, order_consistency=consistent / len(pairs) if pairs else None,
        position_bias=first / asked if asked else None,
        saturation_preference=saturation_more / per_kind if probes else None,
        contrast_preference=contrast_more / per_kind if probes else None, trusted=False, reason="",
    )
    report.trusted, report.reason = _decide(report)
    report_path(model.name).write_text(json.dumps(asdict(report), indent=1))
    log(json.dumps(asdict(report), indent=1))
    return report


def _decide(report: Report) -> tuple[bool, str]:
    if report.verdicts < MIN_VERDICTS:
        return False, f"only {report.verdicts} held-out human verdicts (needs {MIN_VERDICTS})"
    if report.agreement is None or report.agreement < MIN_AGREEMENT:
        return False, f"agreement {report.agreement} below {MIN_AGREEMENT}"
    if (report.order_consistency or 0) < MIN_ORDER_CONSISTENCY:
        return False, f"order consistency {report.order_consistency} below {MIN_ORDER_CONSISTENCY}"
    if report.position_bias is not None and not 0.35 <= report.position_bias <= 0.65:
        return False, f"position bias {report.position_bias:.2f}"
    for name in ("saturation_preference", "contrast_preference"):
        value = getattr(report, name)
        if value is not None and value > MAX_BIAS:
            return False, f"{name.replace('_', ' ')} {value:.2f} above {MAX_BIAS}"
    return True, "agrees with humans"


def gate(model_name: str) -> dict:
    """Whether the current critic configuration (this model, these rubrics) passed evals."""
    path = report_path(model_name)
    if not path.exists():
        return {"trusted": False, "reason": "no eval report for this model and rubric version (python -m studio eval)"}
    report = json.loads(path.read_text())
    return {"trusted": bool(report.get("trusted")), "reason": report.get("reason", "")}


def _features(run, candidate_id: str) -> dict:
    candidate = run.candidate(candidate_id)
    values = run.recipe(candidate_id).get("settings", {}).get("values", {})
    return {"distance": candidate.get("fingerprintDistance") or 1.0, "saturation": values.get("basic.saturation", 0)}

