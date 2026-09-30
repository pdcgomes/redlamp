"""One studio run: propose, render, lint gate, critique, pairwise rating, revise, repeat.

Humans sit at both ends. Briefs must be approved in the Recipe Lab (Runs tab) before any
work starts on them, and the shortlist goes back to the Lab for final picks. Until a
critic configuration has passed its evals (see evals.py), a run works on one brief only.
"""

from __future__ import annotations

import json
import random
import time
from dataclasses import dataclass, field

from .evals import gate
from .mcp import RedlampMCP
from .models import BudgetExceeded, Recorder, load_model
from .rating import plateaued
from .references import Corpus
from .roles import Colorist, Critic, Curator, Selector, library_fingerprints, rubric_version
from .store import Run, now

PERSONAS = ("portrait", "landscape", "street")


@dataclass
class Config:
    run: str
    model: str = "offline"
    seed: int = 1
    model_calls: int = 400
    renders: int = 3000
    iterations: int = 4
    variants: int = 3
    pairs_per_candidate: int = 3
    images: list[str] = field(default_factory=list)
    fit_evaluations: int = 80
    auto_approve: bool = False
    max_briefs: int | None = None
    styles: set[str] | None = None


def lookdev_images(mcp: RedlampMCP, count: int = 6) -> list[str]:
    """A spread of scene categories from the look-dev set."""
    listing = mcp.call("list_images")
    available = [entry for entry in listing.get("lookDev", []) if entry.get("downloaded")]
    wanted = ["landscape", "street", "foliage", "still-life", "night", "high-dynamic-range", "animal", "sky"]
    chosen: list[str] = []
    for category in wanted:
        for entry in available:
            if category in entry["categories"] and entry["path"] not in chosen:
                chosen.append(entry["path"])
                break
        if len(chosen) >= count:
            break
    return chosen or listing.get("available", [])[:count]


def run(config: Config, log=print) -> dict:
    store = Run(config.run)
    model = load_model(config.model, config.seed)
    recorder = Recorder(model, store.dir / "transcripts", config.model_calls)
    generator = random.Random(config.seed)
    store.update_info(id=config.run, seed=config.seed, model=model.name, rubricVersion=rubric_version(), status="running",
                      budget={"modelCalls": config.model_calls, "renders": config.renders})
    with RedlampMCP() as mcp:
        images = config.images or lookdev_images(mcp)
        store.update_info(notes=f"images: {', '.join(p.rsplit('/', 1)[-1] for p in images)}")

        briefs = store.briefs()
        if not briefs:
            log("Curating briefs from build/references…")
            briefs = Curator(mcp, recorder, store, config.seed).curate(Corpus(), styles=config.styles, log=log)
            if not briefs:
                store.update_info(status="no-references")
                log("No references. Fetch some first: python -m studio references fetch")
                return {"briefs": 0}
        if config.auto_approve:
            for brief in briefs:
                if store.brief_status(brief) == "proposed":
                    store.append("verdicts.jsonl", {"type": "brief", "brief": brief["id"], "approved": True,
                                                    "rater": "auto", "at": now()})
        approved = [brief for brief in briefs if store.brief_status(brief) == "approved"]
        if not approved:
            store.update_info(status="awaiting-brief-approval")
            log(f"{len(briefs)} briefs await approval in the Recipe Lab (Runs tab, run {config.run}).")
            return {"briefs": len(briefs), "approved": 0}

        trusted = gate(model.name)
        limit = config.max_briefs or (len(approved) if trusted["trusted"] else 1)
        if not trusted["trusted"] and len(approved) > limit:
            log(f"Critics aren't trusted yet ({trusted['reason']}); working on {limit} brief(s).")
        store.update_info(criticsTrusted=trusted["trusted"])

        schema = mcp.call("schema")
        colorist = Colorist(mcp, recorder, store, images, schema, config.fit_evaluations)
        critics = [Critic(persona, mcp, recorder, store) for persona in PERSONAS]
        selector = Selector(store, library_fingerprints(mcp, store, images[:3]), mcp, images[:3])
        shortlist = store.shortlist()
        summary = {"briefs": len(approved[:limit]), "candidates": 0, "stopped": None}
        try:
            for brief in approved[:limit]:
                log(f"Brief {brief['id']}: {brief['title']}")
                candidates = [c for c in colorist.propose(brief, config.variants, log=log)]
                best: list[float] = []
                critiqued: set[str] = set()
                for iteration in range(1, config.iterations + 1):
                    if mcp.calls > config.renders:
                        raise BudgetExceeded(f"render budget of {config.renders} reached")
                    alive = [c for c in store.candidates(brief["id"]) if c.get("lint") != "fail"]
                    dropped = len(store.candidates(brief["id"])) - len(alive)
                    for candidate in alive:
                        if candidate["id"] not in critiqued:
                            for critic in critics:
                                critic.critique(candidate, brief, images)
                            critiqued.add(candidate["id"])
                    # Each candidate meets a few others, by a different critic each time.
                    for candidate in alive:
                        opponents = [c for c in alive if c["id"] != candidate["id"]]
                        generator.shuffle(opponents)
                        for opponent in opponents[: config.pairs_per_candidate]:
                            critic = generator.choice(critics)
                            critic.compare(candidate, opponent, brief, generator.choice(images), generator, images)
                    ratings = selector.ratings(brief, alive)
                    for candidate in alive:
                        candidate["rating"] = round(ratings[candidate["id"]], 4)
                        store.update_candidate(candidate)
                        store.append("scores.jsonl", {"iteration": iteration, "candidate": candidate["id"],
                                                      "rating": candidate["rating"], "brief": brief["id"]})
                    best.append(max(ratings.values()) if ratings else 0)
                    log(f"  iteration {iteration}: {len(alive)} candidates ({dropped} failed lint), best {best[-1]:.2f}")
                    if plateaued(best) or iteration == config.iterations:
                        break
                    top = sorted(alive, key=lambda c: -ratings[c["id"]])[:2]
                    for parent in top:
                        requests = [r for critique in store.critiques() if critique["candidate"] == parent["id"]
                                    for r in critique.get("changeRequests") or []]
                        colorist.revise(brief, parent, requests[:6], iteration + 1)
                picks = selector.shortlist(brief, selector.ratings(brief, [c for c in store.candidates(brief["id"]) if c.get("lint") != "fail"]))
                shortlist = [entry for entry in shortlist if entry["brief"] != brief["id"]] + [{"brief": brief["id"], "candidates": picks}]
                store.save_shortlist(shortlist)
                summary["candidates"] += len(store.candidates(brief["id"]))
                log(f"  shortlist: {', '.join(picks)}")
        except BudgetExceeded as stop:
            summary["stopped"] = str(stop)
            log(f"Stopped: {stop}")
        store.update_info(status="shortlisted" if not summary["stopped"] else "stopped-on-budget",
                          modelCalls=recorder.calls, renders=mcp.calls, finished=now())
        return summary
