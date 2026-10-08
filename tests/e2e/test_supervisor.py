"""The regression suite's supervisor (scripts/e2e.py): python3 -m unittest discover -s tests/e2e"""

import importlib.util
import json
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

_spec = importlib.util.spec_from_file_location("e2e", Path(__file__).resolve().parents[2] / "scripts/e2e.py")
e2e = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(e2e)

MAIN = ["smoke.photos-open", "smoke.panel-sliders", "smoke.export", "smoke.leave-an-edit"]
RELAUNCH = ["smoke.relaunch-restores"]
INDEX = "Library/Application Support/Redlamp/Library/Index.sqlite"


class LaterLaunches(unittest.TestCase):
    def test_the_relaunch_follows_the_main_group_when_nothing_failed(self):
        self.assertEqual(e2e.later_launches(MAIN, RELAUNCH, []), [("relaunch", RELAUNCH, False)])

    def test_the_relaunch_comes_before_a_retry_that_would_change_what_it_finds(self):
        retry = ["smoke.panel-sliders"]
        self.assertEqual(e2e.later_launches(MAIN, RELAUNCH, retry),
                         [("relaunch", RELAUNCH, False), ("main", retry, True)])

    def test_the_relaunch_waits_for_the_retry_of_the_scenario_that_leaves_what_it_reads(self):
        retry = ["smoke.panel-sliders", "smoke.leave-an-edit"]
        self.assertEqual(e2e.later_launches(MAIN, RELAUNCH, retry),
                         [("main", retry, True), ("relaunch", RELAUNCH, False)])

    def test_either_group_runs_alone(self):
        self.assertEqual(e2e.later_launches([], RELAUNCH, []), [("relaunch", RELAUNCH, False)])
        self.assertEqual(e2e.later_launches(MAIN, [], ["smoke.leave-an-edit"]),
                         [("main", ["smoke.leave-an-edit"], True)])
        self.assertEqual(e2e.later_launches(MAIN, [], []), [])

    def test_only_the_retry_starts_afresh_and_the_relaunch_reads_what_the_launch_before_it_left(self):
        for failed in range(1 << len(MAIN)):
            retry = [scenario for bit, scenario in enumerate(MAIN) if failed & (1 << bit)]
            launches = e2e.later_launches(MAIN, RELAUNCH, retry)
            self.assertEqual([afresh for group, _, afresh in launches], [group == "main" for group, _, _ in launches])
            # A launch starts afresh before the relaunch only to run smoke.leave-an-edit again, which the
            # relaunch reads.
            before = launches[:[group for group, _, _ in launches].index("relaunch")]
            self.assertEqual(any(afresh for _, _, afresh in before), "smoke.leave-an-edit" in retry, retry)


class StartAfresh(unittest.TestCase):
    """A retry finds what the first attempt found, whatever the first attempt left."""

    def setUp(self):
        self.run = Path(tempfile.mkdtemp(prefix="e2e-supervisor-"))
        self.addCleanup(shutil.rmtree, self.run, ignore_errors=True)
        originals = self.run / "originals"
        (originals / "Bracket").mkdir(parents=True)
        (originals / "_DSC0009.ARW").write_bytes(b"raw")
        (originals / "Bitmap.jpg").write_bytes(b"jpeg")
        (originals / "Bracket/Bracket-1.jpg").write_bytes(b"one")
        e2e.copy_photos(originals, self.run / "photos")
        # What the first attempt left: an export beside a photo, a sidecar, the library's index and what
        # smoke.leave-an-edit leaves for the relaunch.
        (self.run / "photos/_DSC0009-redlamp.jpg").write_bytes(b"export")
        (self.run / "photos/_DSC0009.ARW.redlamp").mkdir()
        (self.run / "photos/_DSC0009.ARW.redlamp/edit.json").write_text("{}")
        (self.run / "home" / INDEX).parent.mkdir(parents=True)
        (self.run / "home" / INDEX).write_bytes(b"index")
        (self.run / "left.json").write_text('{"photo": "_DSC0009.ARW", "exposure": 0.77}')
        self.calls = []
        self.staging = None
        replacements = {
            "defaults": lambda *arguments: self.calls.append(("defaults", *arguments)),
            "read_default": lambda key: self.staging if key == "export.staging" else None,
            "seed_models": lambda home: self.calls.append(("seed_models", home, sorted(home.iterdir()))),
            "keep_compiled_models": lambda home: self.calls.append(("keep_compiled_models", (home / INDEX).exists())),
        }
        for name, replacement in replacements.items():
            patcher = mock.patch.object(e2e, name, replacement)
            patcher.start()
            self.addCleanup(patcher.stop)

    def files(self, folder: Path) -> dict[str, bytes]:
        return {str(p.relative_to(folder)): p.read_bytes() for p in sorted(folder.rglob("*")) if p.is_file()}

    def test_the_photos_are_cloned_again_from_the_originals(self):
        e2e.start_afresh(self.run, relay=4321, attempt=2)
        self.assertEqual(self.files(self.run / "photos"), self.files(self.run / "originals"))

    def test_the_home_holds_only_the_models_again(self):
        e2e.start_afresh(self.run, relay=4321, attempt=2)
        self.assertFalse((self.run / "home" / INDEX).exists())
        self.assertIn(("seed_models", self.run / "home", []), self.calls)
        # The compiles the first attempt made are kept for the next run before its home goes.
        self.assertIn(("keep_compiled_models", True), self.calls)

    def test_the_defaults_are_seeded_again(self):
        e2e.start_afresh(self.run, relay=4321, attempt=2)
        defaults = [call[1:] for call in self.calls if call[0] == "defaults"]
        self.assertEqual(defaults[0], ("delete", e2e.BUNDLE_ID))
        self.assertIn(("write", e2e.BUNDLE_ID, "FeedbackEndpoint", "http://127.0.0.1:4321/api/feedback"), defaults)
        self.assertIn(("write", e2e.BUNDLE_ID, "welcome.shown", "-int", "99"), defaults)

    def test_what_the_first_attempt_left_is_kept_in_its_own_folder(self):
        e2e.start_afresh(self.run, relay=4321, attempt=2)
        kept = self.run / "attempt-1"
        self.assertEqual((kept / "photos/_DSC0009-redlamp.jpg").read_bytes(), b"export")
        self.assertTrue((kept / "photos/_DSC0009.ARW.redlamp/edit.json").exists())
        self.assertEqual((kept / "home" / INDEX).read_bytes(), b"index")
        self.assertTrue((kept / "left.json").exists())
        self.assertFalse((self.run / "left.json").exists())

    def test_what_the_first_attempt_should_not_have_left_goes_to_the_storage_check(self):
        thumbnails = self.run / "home/Library/Caches/app.redlamp/Thumbnails"
        thumbnails.mkdir(parents=True)
        (thumbnails / ".pack.rltp.part").write_bytes(b"")
        self.staging = '{\n    "_DSC0009-redlamp.jpg" = 1;\n}\n'
        problems = e2e.start_afresh(self.run, relay=4321, attempt=2)
        self.assertEqual(problems, [
            "attempt 1: staging left in Library/Caches/app.redlamp/Thumbnails: .pack.rltp.part",
            'attempt 1: an export\'s staging is still listed: { "_DSC0009-redlamp.jpg" = 1; }',
        ])
        self.staging = None
        report = e2e.storage_check(self.run / "home", e2e.temporary_compiles(), 0, problems)
        self.assertEqual(report["problems"], problems)


def scenario(name: str, status: str = "passed", stall: float | None = None, message: str | None = None) -> list[dict]:
    """A scenario's events as the driver writes them, with a stall in it when `stall` is its length."""
    events = [{"event": "scenario-start", "scenario": name}]
    if stall:
        events.append({"event": "hang", "scenario": name, "seconds": stall, "stack": [f"{name} frame"]})
    end = {"event": "scenario-end", "scenario": name, "status": status}
    if message:
        end["message"] = message
    return events + [end]


def stall(seconds: float, scenario_name: str | None = None) -> dict:
    hang = {"event": "hang", "seconds": seconds, "stack": ["between scenarios"]}
    if scenario_name:
        hang["scenario"] = scenario_name
    return hang


class Retries(unittest.TestCase):
    """Each launch is judged on its own events: its stalls are counted once, with the attempt they belong to."""

    def setUp(self):
        self.run = Path(tempfile.mkdtemp(prefix="e2e-supervisor-"))
        self.addCleanup(shutil.rmtree, self.run, ignore_errors=True)
        patcher = mock.patch.object(e2e, "log", lambda message: None)
        patcher.start()
        self.addCleanup(patcher.stop)
        # What each launch writes, in order: its events, and how the app exited.
        self.scripted: list[tuple[list[dict], int]] = []
        self.launched: list[tuple[str, list[str]]] = []
        self.launches = e2e.Launches(self.run, self.launch, timeout=300)

    def launch(self, group: str, ids: list[str]) -> dict:
        """Adds a launch's events to its group's file, as the driver does, and reports where they begin."""
        self.launched.append((group, ids))
        events, returncode = self.scripted.pop(0)
        path = self.run / f"events-{group}.jsonl"
        start = path.stat().st_size if path.exists() else 0
        with path.open("a") as handle:
            handle.writelines(json.dumps(event) + "\n" for event in events)
        return {"returncode": returncode, "timedOut": None, "crashes": [], "seconds": 1, "events": start}

    def stalls(self, hangs: list[dict]) -> list[tuple]:
        return [(hang.get("scenario"), hang["seconds"], hang["attempt"]) for hang in hangs]

    def test_a_first_attempts_stall_stays_with_it_after_a_passing_retry_and_doesnt_count(self):
        self.scripted = [
            (scenario("smoke.export", "failed", stall=2.5, message="The main thread stalled for 2.5 s")
             + scenario("smoke.panel-sliders"), 0),
            (scenario("smoke.export"), 0),
        ]
        self.launches.run_group("main", ["smoke.export", "smoke.panel-sliders"])
        self.launches.run_group("main", ["smoke.export"], attempt=2)
        self.assertEqual(self.launches.results["smoke.export"]["status"], "flaky")
        self.assertEqual(self.launches.hangs, [])
        self.assertEqual(self.stalls(self.launches.retried_hangs), [("smoke.export", 2.5, 1)])
        self.assertEqual(self.launches.attempts, {"smoke.export": 2, "smoke.panel-sliders": 1})

    def test_the_stalls_of_scenarios_that_werent_retried_count_once(self):
        self.scripted = [
            ([stall(3.0)] + scenario("smoke.photos-open", "skipped", stall=2.1)
             + scenario("smoke.export", "failed", stall=2.5), 0),
            (scenario("smoke.relaunch-restores", "failed", stall=2.2), 0),
            (scenario("smoke.export"), 0),
        ]
        self.launches.run_group("main", ["smoke.photos-open", "smoke.export"])
        self.launches.run_group("relaunch", ["smoke.relaunch-restores"])
        self.launches.run_group("main", ["smoke.export"], attempt=2)
        self.assertEqual(self.stalls(self.launches.hangs), [
            (None, 3.0, 1), ("smoke.photos-open", 2.1, 1), ("smoke.relaunch-restores", 2.2, 1),
        ])
        self.assertEqual(self.stalls(self.launches.retried_hangs), [("smoke.export", 2.5, 1)])

    def test_a_stall_in_the_retry_counts_as_the_retrys(self):
        self.scripted = [
            (scenario("smoke.export", "failed", stall=2.5), 0),
            (scenario("smoke.export", "failed", stall=4.0), 0),
        ]
        self.launches.run_group("main", ["smoke.export"])
        self.launches.run_group("main", ["smoke.export"], attempt=2)
        self.assertEqual(self.launches.results["smoke.export"]["status"], "failed")
        self.assertEqual(self.stalls(self.launches.hangs), [("smoke.export", 4.0, 2)])
        self.assertEqual(self.stalls(self.launches.retried_hangs), [("smoke.export", 2.5, 1)])

    def test_a_retry_that_stops_before_its_scenario_runs_it_again_rather_than_taking_the_first_attempts_result(self):
        self.scripted = [
            (scenario("smoke.export", "failed", message="first"), 0),
            ([{"event": "ready"}], -11),
            (scenario("smoke.export"), 0),
        ]
        self.launches.run_group("main", ["smoke.export"])
        self.assertTrue(self.launches.run_group("main", ["smoke.export"], attempt=2))
        self.assertEqual(self.launched, [("main", ["smoke.export"])] * 3)
        self.assertEqual(self.launches.results["smoke.export"]["status"], "flaky")
        self.assertEqual(self.launches.results["smoke.export"]["message"], "passed on retry; first: first")

    def test_a_launch_reads_its_own_events_after_one_cut_short_midway_through_a_line(self):
        path = self.run / "events-main.jsonl"
        path.write_text(json.dumps(scenario("smoke.export")[0]) + "\n" + '{"event": "hang", "sec')
        start = path.stat().st_size
        with path.open("a") as handle:
            handle.writelines(json.dumps(event) + "\n" for event in scenario("smoke.panel-sliders"))
        self.assertEqual(e2e.read_events(path, start), scenario("smoke.panel-sliders"))
        results, hangs, unfinished = e2e.outcomes(self.run, "main", start)
        self.assertEqual(list(results), ["smoke.panel-sliders"])
        self.assertEqual((hangs, unfinished), ([], None))

    def test_the_report_lists_a_stall_a_retry_replaced_with_its_attempt(self):
        hang = {"scenario": "smoke.export", "seconds": 2.5, "stack": ["a", "b"], "attempt": 1}
        report = {"tier": "smoke", "commit": "abc1234", "dirty": False, "verdict": "Passed", "summary": "",
                  "started": "", "seconds": 60, "machine": "", "load": {"before": 1.0, "after": 1.0},
                  "scenarios": [], "crashes": [], "hangs": [], "retriedHangs": [hang],
                  "ownerState": {"summary": ""}}
        e2e.write_report(self.run, report)
        text = (self.run / "report.md").read_text()
        self.assertIn("- smoke.export (attempt 1): 2.5 s at a ← b", text)
        self.assertIn("so they don't count against the run", text)


if __name__ == "__main__":
    unittest.main()
