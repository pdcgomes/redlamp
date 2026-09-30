"""python -m studio <command>: the agent recipe studio.

  references fetch [--styles a,b] [--per-query 4]   fill build/references from allowlisted sources
  references add-own <folder> --style S --license L --author A
  references list
  curate --run R [--model M]                         draft style briefs (humans approve them in the Lab)
  run --run R [--model M] [options]                  develop recipes for approved briefs
  eval [--model M]                                   score critics against held-out human verdicts
  gate [--model M]                                   is this critic configuration trusted?

Models: offline (default, deterministic), anthropic:<model>, openai:<model>.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

from . import evals, loop, references
from .mcp import RedlampMCP
from .models import Recorder, load_model
from .roles import Curator
from .store import Run


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m studio", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)

    refs = commands.add_parser("references")
    refs_commands = refs.add_subparsers(dest="action", required=True)
    fetch = refs_commands.add_parser("fetch")
    fetch.add_argument("--styles")
    fetch.add_argument("--per-query", type=int, default=4)
    own = refs_commands.add_parser("add-own")
    own.add_argument("folder", type=Path)
    own.add_argument("--style", required=True)
    own.add_argument("--license", required=True)
    own.add_argument("--author", required=True)
    refs_commands.add_parser("list")

    curate = commands.add_parser("curate")
    curate.add_argument("--run", required=True)
    curate.add_argument("--model", default="offline")
    curate.add_argument("--seed", type=int, default=1)
    curate.add_argument("--styles")

    run = commands.add_parser("run")
    run.add_argument("--run", default=time.strftime("run-%Y%m%d-%H%M"))
    run.add_argument("--model", default="offline")
    run.add_argument("--seed", type=int, default=1)
    run.add_argument("--iterations", type=int, default=4)
    run.add_argument("--variants", type=int, default=3)
    run.add_argument("--calls", type=int, default=400, help="model call budget")
    run.add_argument("--renders", type=int, default=3000, help="MCP render budget")
    run.add_argument("--fit-evaluations", type=int, default=80)
    run.add_argument("--images", nargs="*")
    run.add_argument("--styles")
    run.add_argument("--max-briefs", type=int)
    run.add_argument("--auto-approve", action="store_true", help="approve briefs without a human (dry runs only)")

    evaluate = commands.add_parser("eval")
    evaluate.add_argument("--model", default="offline")
    gate = commands.add_parser("gate")
    gate.add_argument("--model", default="offline")

    args = parser.parse_args(argv)
    if args.command == "references":
        if args.action == "fetch":
            added = references.fetch(per_query=args.per_query, only=set(args.styles.split(",")) if args.styles else None)
            print(f"{len(added)} new references in build/references")
        elif args.action == "add-own":
            added = references.add_own(args.folder, args.style, args.license, args.author)
            print(f"{len(added)} photos added")
        else:
            for style, entries in references.Corpus().by_style().items():
                print(f"{style}: {len(entries)}")
                for entry in entries:
                    print(f"  {entry.id}  {entry.license}  {entry.title[:70]}")
        return 0
    if args.command == "curate":
        store = Run(args.run)
        model = load_model(args.model, args.seed)
        with RedlampMCP() as mcp:
            briefs = Curator(mcp, Recorder(model, store.dir / "transcripts", 200), store, args.seed).curate(
                references.Corpus(), styles=set(args.styles.split(",")) if args.styles else None)
        store.update_info(id=args.run, model=model.name, status="awaiting-brief-approval")
        print(f"{len(briefs)} briefs in {store.dir}; approve them in the Recipe Lab (Runs tab)")
        return 0
    if args.command == "run":
        summary = loop.run(loop.Config(
            run=args.run, model=args.model, seed=args.seed, model_calls=args.calls, renders=args.renders,
            iterations=args.iterations, variants=args.variants, images=args.images or [],
            fit_evaluations=args.fit_evaluations, auto_approve=args.auto_approve, max_briefs=args.max_briefs,
            styles=set(args.styles.split(",")) if args.styles else None,
        ))
        print(json.dumps(summary))
        return 0
    if args.command == "eval":
        report = evals.evaluate(args.model)
        return 0 if report.trusted else 2
    if args.command == "gate":
        verdict = evals.gate(load_model(args.model).name)
        print(json.dumps(verdict))
        return 0 if verdict["trusted"] else 2
    return 1


if __name__ == "__main__":
    sys.exit(main())
