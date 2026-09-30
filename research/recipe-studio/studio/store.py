"""The run directory, in the same format the Swift `RunStore` reads (see RecipeRun.swift)."""

from __future__ import annotations

import json
import time
from pathlib import Path

from . import RUNS


def now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


class Run:
    def __init__(self, run_id: str, root: Path = RUNS):
        self.id = run_id
        self.dir = root / run_id
        for folder in ("briefs", "candidates", "renders", "transcripts"):
            (self.dir / folder).mkdir(parents=True, exist_ok=True)

    # run.json
    def info(self) -> dict:
        path = self.dir / "run.json"
        return json.loads(path.read_text()) if path.exists() else {"id": self.id}

    def update_info(self, **fields) -> None:
        info = self.info()
        info.update({key: value for key, value in fields.items() if value is not None})
        info.setdefault("created", now())
        (self.dir / "run.json").write_text(json.dumps(info, indent=1, sort_keys=True))

    # Briefs
    def briefs(self) -> list[dict]:
        return [json.loads(path.read_text()) for path in sorted((self.dir / "briefs").glob("*.json"))]

    def save_brief(self, brief: dict) -> None:
        (self.dir / "briefs" / f"{brief['id']}.json").write_text(json.dumps(brief, indent=1, sort_keys=True))

    def brief_status(self, brief: dict) -> str:
        decisions = [v for v in self.verdicts() if v.get("type") == "brief" and v.get("brief") == brief["id"]]
        if decisions:
            return "approved" if decisions[-1].get("approved") else "rejected"
        return brief.get("status", "proposed")

    # Candidates (the MCP server writes them; the studio updates ratings)
    def candidates(self, brief: str | None = None) -> list[dict]:
        items = [json.loads(path.read_text()) for path in sorted((self.dir / "candidates").glob("*.json"))]
        return [item for item in items if brief is None or item.get("brief") == brief]

    def candidate(self, candidate_id: str) -> dict:
        return json.loads((self.dir / "candidates" / f"{candidate_id}.json").read_text())

    def update_candidate(self, candidate: dict) -> None:
        (self.dir / "candidates" / f"{candidate['id']}.json").write_text(json.dumps(candidate, indent=1, sort_keys=True))

    def recipe(self, candidate_id: str) -> dict:
        return json.loads((self.dir / "candidates" / f"{candidate_id}.redrecipe").read_text())

    def recipe_path(self, candidate_id: str) -> Path:
        return self.dir / "candidates" / f"{candidate_id}.redrecipe"

    def render_path(self, candidate: dict) -> Path | None:
        return self.dir / candidate["render"] if candidate.get("render") else None

    # Append-only logs
    def append(self, name: str, record: dict) -> None:
        with (self.dir / name).open("a") as handle:
            handle.write(json.dumps(record, sort_keys=True) + "\n")

    def lines(self, name: str) -> list[dict]:
        path = self.dir / name
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]

    def verdicts(self) -> list[dict]:
        return self.lines("verdicts.jsonl")

    def comparisons(self) -> list[dict]:
        return self.lines("comparisons.jsonl")

    def critiques(self) -> list[dict]:
        return self.lines("critiques.jsonl")

    def save_shortlist(self, shortlist: list[dict]) -> None:
        (self.dir / "shortlist.json").write_text(json.dumps(shortlist, indent=1, sort_keys=True))

    def shortlist(self) -> list[dict]:
        path = self.dir / "shortlist.json"
        return json.loads(path.read_text()) if path.exists() else []


def all_runs(root: Path = RUNS) -> list[Run]:
    if not root.exists():
        return []
    return [Run(path.name, root) for path in sorted(root.iterdir()) if path.is_dir() and not path.name.startswith("_")]
