"""Redlamp's agent recipe studio: agents that develop recipes from style references.

The agents only ever reach Redlamp through `redlamp mcp`; everything they produce goes
into a run directory (build/recipe-runs/<run>/) that the Recipe Lab shows and where
humans record their verdicts. See docs/recipes/agent-studio.md.
"""

import os
from pathlib import Path

ROOT = Path(os.environ.get("REDLAMP_ROOT", Path(__file__).resolve().parents[3]))
RUNS = ROOT / "build" / "recipe-runs"
REFERENCES = ROOT / "build" / "references"
STUDIO = Path(__file__).resolve().parent
