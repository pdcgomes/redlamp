"""The regression suite's supervisor (scripts/e2e.py): python3 -m unittest discover -s tests/e2e"""

import importlib.util
import unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location("e2e", Path(__file__).resolve().parents[2] / "scripts/e2e.py")
e2e = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(e2e)

MAIN = ["smoke.photos-open", "smoke.panel-sliders", "smoke.export", "smoke.leave-an-edit"]
RELAUNCH = ["smoke.relaunch-restores"]


class LaterLaunches(unittest.TestCase):
    def test_the_relaunch_follows_the_main_group_when_nothing_failed(self):
        self.assertEqual(e2e.later_launches(MAIN, RELAUNCH, []), [("relaunch", RELAUNCH)])

    def test_the_relaunch_comes_before_a_retry_that_would_change_what_it_finds(self):
        retry = ["smoke.panel-sliders"]
        self.assertEqual(e2e.later_launches(MAIN, RELAUNCH, retry), [("relaunch", RELAUNCH), ("main", retry)])

    def test_the_relaunch_waits_for_the_retry_of_the_scenario_that_leaves_what_it_reads(self):
        retry = ["smoke.panel-sliders", "smoke.leave-an-edit"]
        self.assertEqual(e2e.later_launches(MAIN, RELAUNCH, retry), [("main", retry), ("relaunch", RELAUNCH)])

    def test_either_group_runs_alone(self):
        self.assertEqual(e2e.later_launches([], RELAUNCH, []), [("relaunch", RELAUNCH)])
        self.assertEqual(e2e.later_launches(MAIN, [], ["smoke.leave-an-edit"]), [("main", ["smoke.leave-an-edit"])])
        self.assertEqual(e2e.later_launches(MAIN, [], []), [])


if __name__ == "__main__":
    unittest.main()
