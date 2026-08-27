"""Pure host-side checks for the Ubuntu hardware harness matchers."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "scripts" / "hardware_test_ubuntu.py"
SPEC = importlib.util.spec_from_file_location("hardware_test_ubuntu", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def event(event_type: int, code: int, value: int):
    return MODULE.InputEvent(event_type, code, value, "/dev/input/event-test")


class HardwareMatcherTests(unittest.TestCase):
    def test_key_cycle_requires_down_before_up(self):
        matcher = MODULE.key_cycle(MODULE.KEY_ENTER)
        self.assertTrue(matcher([
            event(MODULE.EV_KEY, MODULE.KEY_ENTER, 1),
            event(MODULE.EV_KEY, MODULE.KEY_ENTER, 0),
        ]))
        self.assertFalse(matcher([event(MODULE.EV_KEY, MODULE.KEY_ENTER, 1)]))
        self.assertFalse(matcher([
            event(MODULE.EV_KEY, MODULE.KEY_ENTER, 0),
            event(MODULE.EV_KEY, MODULE.KEY_ENTER, 1),
        ]))

    def test_text_sequence_ignores_key_up_but_requires_all_releases(self):
        matcher = MODULE.key_sequence([MODULE.KEY_T, MODULE.KEY_C, MODULE.KEY_P])
        events = []
        for code in (MODULE.KEY_T, MODULE.KEY_C, MODULE.KEY_P):
            events += [event(MODULE.EV_KEY, code, 1), event(MODULE.EV_KEY, code, 0)]
        self.assertTrue(matcher(events))
        self.assertFalse(matcher(events[:-1]))

    def test_relative_motion_sums_split_reports(self):
        matcher = MODULE.relative_motion(37, -11, 2)
        self.assertTrue(matcher([
            event(MODULE.EV_REL, MODULE.REL_X, 20),
            event(MODULE.EV_REL, MODULE.REL_X, 17),
            event(MODULE.EV_REL, MODULE.REL_Y, -11),
            event(MODULE.EV_REL, MODULE.REL_WHEEL, 2),
        ]))
        self.assertFalse(matcher([event(MODULE.EV_REL, MODULE.REL_X, 36)]))

    def test_diagnostics_delta(self):
        before = {"hid": {"rxTcp": 4}}
        after = {"hid": {"rxTcp": 17}}
        self.assertEqual(MODULE.diagnostics_delta(before, after, "rxTcp"), 13)


if __name__ == "__main__":
    unittest.main()
