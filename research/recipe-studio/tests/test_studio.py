"""Unit tests for the studio, with a fake MCP server so they run without Redlamp.

    cd research/recipe-studio && python3 -m unittest discover tests
"""

from __future__ import annotations

import json
import random
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from studio import evals, loop, references, store
from studio.models import BudgetExceeded, Message, OfflineModel, Part, Recorder, parse_json
from studio.rating import bradley_terry, diversity_penalty, plateaued
from studio.roles import fingerprint_vector, kmeans

FINGERPRINT = {
    "lightness": [0.05, 0.1, 0.3, 0.5, 0.7, 0.9, 0.95], "localContrast": 0.05, "clippedHighlights": 0.01,
    "shadowTint": [0, 0], "midtoneTint": [0.002, 0.004], "highlightTint": [0, 0.01], "meanChroma": 0.05,
    "bandChroma": [0.05] * 8, "bandHueOffset": [0] * 8, "bandShare": [0.125] * 8, "grain": 0.002, "vignette": 0.05,
}


class RatingTests(unittest.TestCase):
    def test_bradley_terry_orders_by_wins(self):
        comparisons = [("a", "b", "a")] * 6 + [("b", "c", "b")] * 6 + [("a", "c", "a")] * 6
        ratings = bradley_terry(["a", "b", "c"], comparisons)
        self.assertGreater(ratings["a"], ratings["b"])
        self.assertGreater(ratings["b"], ratings["c"])
        self.assertAlmostEqual(sum(ratings.values()), 0, places=6)

    def test_ties_and_unbeaten_stay_finite(self):
        ratings = bradley_terry(["a", "b"], [("a", "b", "a")] * 10)
        self.assertTrue(all(abs(v) < 10 for v in ratings.values()))
        tied = bradley_terry(["a", "b"], [("a", "b", None)] * 4)
        self.assertAlmostEqual(tied["a"], tied["b"], places=6)

    def test_diversity_and_plateau(self):
        self.assertEqual(diversity_penalty(1.0), 0)
        self.assertGreater(diversity_penalty(0.05), diversity_penalty(0.3))
        self.assertFalse(plateaued([0.1, 0.5]))
        self.assertTrue(plateaued([0.1, 0.9, 0.91, 0.9]))
        self.assertFalse(plateaued([0.1, 0.5, 0.8, 1.2]))


class CuratorTests(unittest.TestCase):
    def test_kmeans_is_seeded_and_separates_clusters(self):
        generator = random.Random(3)
        vectors = [[generator.gauss(0, 0.1), generator.gauss(0, 0.1)] for _ in range(10)]
        vectors += [[generator.gauss(5, 0.1), generator.gauss(5, 0.1)] for _ in range(10)]
        labels = kmeans(vectors, 2, seed=7)
        self.assertEqual(labels, kmeans(vectors, 2, seed=7))
        self.assertEqual(len(set(labels[:10])), 1)
        self.assertEqual(len(set(labels[10:])), 1)
        self.assertNotEqual(labels[0], labels[10])

    def test_fingerprint_vector_has_the_swift_length(self):
        self.assertEqual(len(fingerprint_vector(FINGERPRINT)), 7 + 2 + 6 + 1 + 8 + 2)


class ReferenceTests(unittest.TestCase):
    def test_only_allowlisted_hosts(self):
        with self.assertRaises(references.Refused):
            references._check("https://example.com/look.cube")
        references._check("https://images.metmuseum.org/x.jpg")

    def test_wikimedia_keeps_only_public_domain_and_cc0(self):
        pages = {"query": {"pages": {
            "1": {"pageid": 1, "title": "File:A.jpg", "imageinfo": [{"url": "u", "thumburl": "https://upload.wikimedia.org/a.jpg",
                                                                  "extmetadata": {"LicenseShortName": {"value": "CC0"}}}]},
            "2": {"pageid": 2, "title": "File:B.jpg", "imageinfo": [{"url": "u", "extmetadata": {"LicenseShortName": {"value": "CC BY-SA 4.0"}}}]},
            "3": {"pageid": 3, "title": "File:C.jpg", "imageinfo": [{"url": "https://upload.wikimedia.org/c.jpg",
                                                                  "extmetadata": {"LicenseShortName": {"value": "Public domain"}}}]},
        }}}
        with mock.patch.object(references, "_json", return_value=pages):
            found = references.search_wikimedia("anything", 10)
        self.assertEqual([r.source_id for r in found], ["1", "3"])
        self.assertEqual([r.license for r in found], [references.CC0, references.PUBLIC_DOMAIN])

    def test_met_keeps_only_public_domain(self):
        responses = [{"objectIDs": [1, 2]},
                     {"isPublicDomain": False, "primaryImage": "https://images.metmuseum.org/1.jpg"},
                     {"isPublicDomain": True, "primaryImage": "https://images.metmuseum.org/2.jpg", "title": "T"}]
        with mock.patch.object(references, "_json", side_effect=responses), mock.patch.object(references.time, "sleep"):
            found = references.search_met("x", 5)
        self.assertEqual([r.source_id for r in found], ["2"])


class ModelTests(unittest.TestCase):
    def test_parse_json_from_prose(self):
        self.assertEqual(parse_json('Sure! {"winner": "A", "reason": "x {y}"} done'), {"winner": "A", "reason": "x {y}"})

    def test_recorder_enforces_budget_and_writes_transcripts(self):
        folder = Path(tempfile.mkdtemp())
        try:
            recorder = Recorder(OfflineModel(), folder, budget=1)
            recorder.complete("critic", "sys", [Message("user", [Part(text="hi")])], {"task": "critique", "distance": 0.2})
            with self.assertRaises(BudgetExceeded):
                recorder.complete("critic", "sys", [], {"task": "critique"})
            self.assertEqual(len(list(folder.glob("*.json"))), 1)
        finally:
            shutil.rmtree(folder)


class FakeMCP:
    """Stands in for `redlamp mcp`: deterministic fingerprints, lint and candidates."""

    def __init__(self, runs: Path):
        self.runs = runs
        self.calls = 0

    def __enter__(self):
        return self

    def __exit__(self, *_):
        pass

    def call(self, tool: str, **args):
        self.calls += 1
        if tool == "list_images":
            return {"lookDev": [{"path": f"/img/{c}.raf", "categories": [c], "downloaded": True}
                                for c in ("landscape", "street", "foliage")], "available": []}
        if tool == "schema":
            return {"parameters": [
                {"key": "basic.contrast", "group": "tone", "min": -100, "max": 100, "renders": True},
                {"key": "basic.saturation", "group": "presence", "min": -100, "max": 100, "renders": True},
                {"key": "basic.highlights", "group": "tone", "min": -100, "max": 100, "renders": True},
                {"key": "basic.shadows", "group": "tone", "min": -100, "max": 100, "renders": True},
                {"key": "basic.vibrance", "group": "presence", "min": -100, "max": 100, "renders": True},
            ], "baseLooks": []}
        if tool == "list_recipes":
            return [{"id": "redlamp/essentials/punchy", "tags": []}]
        if tool == "fingerprint":
            recipe = args.get("recipe")
            spread = 0.0
            if recipe and Path(str(recipe)).exists():
                values = json.loads(Path(recipe).read_text()).get("settings", {}).get("values", {})
                spread = abs(values.get("basic.contrast", 0) - 20) / 40
            return {"fingerprint": FINGERPRINT, "summary": "fake", "distance": 0.3 + spread}
        if tool in ("fit_to_fingerprint", "save_candidate"):
            run = store.Run(args["run"], self.runs)
            candidate_id = args.get("id") or f"c{len(run.candidates()) + 1:03d}"
            assert not (run.dir / "candidates" / f"{candidate_id}.json").exists(), f"{candidate_id} overwritten"
            recipe = args.get("recipe") or {"id": f"local/{args['run']}/{candidate_id}", "name": "Fit", "includes": ["tone"],
                                             "settings": {"values": {"basic.contrast": 10}}}
            (run.dir / "candidates" / f"{candidate_id}.redrecipe").write_text(json.dumps(recipe))
            lint = "fail" if recipe.get("settings", {}).get("values", {}).get("basic.contrast", 0) > 90 else "pass"
            candidate = {"id": candidate_id, "brief": args.get("brief"), "parent": args.get("parent"),
                         "iteration": args.get("iteration", 0), "origin": args.get("origin", "fit"), "lint": lint,
                         "fingerprintDistance": 0.5 if tool == "fit_to_fingerprint" else None}
            run.update_candidate(candidate)
            if tool == "fit_to_fingerprint":
                return {"candidate": candidate_id, "distance": 0.5, "startDistance": 1.2}
            return {"candidate": candidate_id, "lint": lint}
        if tool == "compare":
            return {"text": "saved", "path": None}
        raise AssertionError(f"unexpected tool {tool}")


class LoopTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.patches = [
            mock.patch.object(store, "RUNS", self.root),
            mock.patch.object(evals, "RUNS", self.root),
            mock.patch.object(evals, "EVALS", self.root / "_evals"),
            mock.patch.object(loop, "RedlampMCP", lambda: FakeMCP(self.root)),
        ]
        for patch in self.patches:
            patch.start()
        # Run() defaults to the patched folder.
        self.original_init = store.Run.__init__.__defaults__
        store.Run.__init__.__defaults__ = (self.root,)
        run = store.Run("dry")
        run.save_brief({"id": "b1", "title": "Warm muted", "description": "d", "requirements": [], "references": [],
                        "targetFingerprint": FINGERPRINT, "status": "proposed"})
        run.save_brief({"id": "b2", "title": "Cool hard", "description": "d", "requirements": [], "references": [],
                        "targetFingerprint": FINGERPRINT, "status": "proposed"})

    def tearDown(self):
        store.Run.__init__.__defaults__ = self.original_init
        for patch in self.patches:
            patch.stop()
        shutil.rmtree(self.root)

    def test_waits_for_brief_approval(self):
        summary = loop.run(loop.Config(run="dry"), log=lambda *_: None)
        self.assertEqual(summary["approved"], 0)
        self.assertEqual(store.Run("dry").info()["status"], "awaiting-brief-approval")

    def test_a_full_offline_run_is_reproducible_and_limited_to_one_brief_until_trusted(self):
        summary = loop.run(loop.Config(run="dry", auto_approve=True, iterations=3), log=lambda *_: None)
        run = store.Run("dry")
        self.assertEqual(summary["briefs"], 1)  # Critics have no eval report yet.
        self.assertEqual({s["brief"] for s in run.shortlist()}, {"b1"})
        self.assertTrue(run.lines("critiques.jsonl"))
        self.assertTrue(run.lines("comparisons.jsonl"))
        self.assertTrue(run.lines("scores.jsonl"))
        self.assertTrue(list((run.dir / "transcripts").glob("*.json")))
        lineage = {c["id"]: c.get("parent") for c in run.candidates()}
        self.assertIsNone(lineage["c001"])
        self.assertTrue(any(parent for parent in lineage.values()))
        first = [c["rating"] for c in run.candidates() if "rating" in c]

        shutil.rmtree(run.dir)
        store.Run("dry").save_brief({"id": "b1", "title": "Warm muted", "description": "d", "requirements": [],
                                     "references": [], "targetFingerprint": FINGERPRINT, "status": "proposed"})
        loop.run(loop.Config(run="dry", auto_approve=True, iterations=3), log=lambda *_: None)
        second = [c["rating"] for c in store.Run("dry").candidates() if "rating" in c]
        self.assertEqual(first, second)

    def test_budget_stops_the_run_gracefully(self):
        summary = loop.run(loop.Config(run="dry", auto_approve=True, model_calls=3), log=lambda *_: None)
        self.assertIn("budget", summary["stopped"])


class EvalGateTests(unittest.TestCase):
    def test_gate_rules(self):
        base = dict(version="v", model="m", rubric="r", verdicts=40, agreement=0.8, order_consistency=0.9,
                    position_bias=0.5, saturation_preference=0.5, contrast_preference=0.5, trusted=False, reason="")
        self.assertTrue(evals._decide(evals.Report(**base))[0])
        self.assertFalse(evals._decide(evals.Report(**{**base, "verdicts": 10}))[0])
        self.assertFalse(evals._decide(evals.Report(**{**base, "agreement": 0.6}))[0])
        self.assertFalse(evals._decide(evals.Report(**{**base, "saturation_preference": 0.9}))[0])
        self.assertFalse(evals._decide(evals.Report(**{**base, "position_bias": 0.8}))[0])
        self.assertFalse(evals._decide(evals.Report(**{**base, "order_consistency": 0.5}))[0])

    def test_offline_bias_models_behave_as_probes_expect(self):
        biased = OfflineModel(bias="saturation")
        reply = parse_json(biased.complete("", [], {"task": "compare", "a": {"saturation": 0}, "b": {"saturation": 30}}))
        self.assertEqual(reply["winner"], "B")
        first = OfflineModel(bias="first")
        self.assertEqual(parse_json(first.complete("", [], {"task": "compare", "a": {}, "b": {}}))["winner"], "A")


if __name__ == "__main__":
    unittest.main()
