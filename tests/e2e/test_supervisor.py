"""The regression suite's supervisor (scripts/e2e.py): python3 -m unittest discover -s tests/e2e"""

import importlib.util
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


if __name__ == "__main__":
    unittest.main()
