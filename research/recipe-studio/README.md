# Recipe studio

Agents that develop recipes from style references, with humans approving the briefs they work towards and picking what ships. The design is in [docs/recipes/agent-studio.md](../../docs/recipes/agent-studio.md).

Nothing here ships in Redlamp. It's standard-library Python 3.11+ and talks to Redlamp only through `redlamp mcp`.

## Setup

```bash
mise run build          # builds the redlamp CLI (the studio finds it in build/DerivedData)
mise run lookdev        # the CC0 look-development raw set, into build/look-dev
```

Set `REDLAMP_CLI` if the CLI lives elsewhere. Model keys: `ANTHROPIC_API_KEY` or `OPENAI_API_KEY`. Smithsonian, Rijksmuseum and Flickr Commons need `SI_API_KEY`, `RIJKS_API_KEY` and `FLICKR_API_KEY`.

## Use

```bash
cd research/recipe-studio

# 1. References: public-domain and CC0 only, from an allowlist of sources.
python3 -m studio references fetch                       # all styles in studio/reference_queries.json
python3 -m studio references add-own ~/Shoots/pastel --style soft-pastel-daylight --license CC0-1.0 --author "Me"
python3 -m studio references list

# 2. Briefs, then approve or reject them in the harness: Recipe Lab → Runs.
python3 -m studio curate --run spring --model anthropic:<model>

# 3. The loop, on approved briefs. Until critics pass evals, it works on one brief.
python3 -m studio run --run spring --model anthropic:<model> --iterations 4 --calls 400

# 4. In the Recipe Lab → Runs: pairwise picks, final picks, "Add to My Recipes".

# 5. Critic evals against held-out human verdicts (re-run whenever rubrics or the model change).
python3 -m studio eval --model anthropic:<model>
python3 -m studio gate --model anthropic:<model>
```

`--model offline` (the default) is a deterministic stand-in that answers from measurements, for dry runs and tests. `--auto-approve` skips the human brief approval and is for dry runs only; it's recorded in the run as `rater: auto`.

## Layout

| File | What it does |
| --- | --- |
| `studio/references.py` | Allowlisted fetchers (Library of Congress, The Met, Art Institute of Chicago, NASA, Wikimedia Commons, Smithsonian, Rijksmuseum, Flickr Commons) and the manifest in `build/references/manifest.jsonl` |
| `studio/mcp.py` | The `redlamp mcp` client |
| `studio/models.py` | Vision-model clients, the offline stand-in, call budgets and transcripts |
| `studio/roles.py` | Curator, Colorist, Photographer critics and Selector |
| `studio/rating.py` | Bradley-Terry ratings, the diversity penalty and plateau detection |
| `studio/loop.py` | One run end to end |
| `studio/evals.py` | Critic agreement, order consistency, bias probes and the trust gate |
| `studio/rubrics/v1/` | Every prompt; their hash is the rubric version evals are keyed by |

## Tests

```bash
python3 -m unittest discover tests
```

They use a fake MCP server, so they need neither Redlamp nor a network.
