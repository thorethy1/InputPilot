"""Host-side tests for the passive Ubuntu HID event listener."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "scripts" / "listen_hid_ubuntu.py"
SPEC = importlib.util.spec_from_file_location("listen_hid_ubuntu", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class HidListenerFormattingTests(unittest.TestCase):
    def test_formats_keyboard_key_state_readably(self):
        event = MODULE.InputEvent(MODULE.EV_KEY, MODULE.KEY_A, 1, "/dev/input/event15")
        self.assertEqual(MODULE.format_event(event), "KEYBOARD event15 KEY_A DOWN")

    def test_formats_mouse_button_state_readably(self):
        event = MODULE.InputEvent(MODULE.EV_KEY, MODULE.BTN_LEFT, 0, "/dev/input/event14")
        self.assertEqual(MODULE.format_event(event), "MOUSE event14 BTN_LEFT UP")

    def test_formats_relative_mouse_motion_with_sign(self):
        event = MODULE.InputEvent(MODULE.EV_REL, MODULE.REL_X, -12, "/dev/input/event14")
        self.assertEqual(MODULE.format_event(event), "MOUSE event14 REL_X -12")

    def test_names_common_keyboard_keys(self):
        event = MODULE.InputEvent(MODULE.EV_KEY, 28, 1, "/dev/input/event15")
        self.assertEqual(MODULE.format_event(event), "KEYBOARD event15 KEY_ENTER DOWN")

    def test_keeps_unknown_key_code_visible(self):
        event = MODULE.InputEvent(MODULE.EV_KEY, 255, 1, "/dev/input/event15")
        self.assertEqual(MODULE.format_event(event), "KEYBOARD event15 KEY_255 DOWN")

    def test_cli_defaults_to_inputpilot_usb_identity(self):
        args = MODULE.build_parser().parse_args([])
        self.assertEqual((args.vid, args.pid), (0xCAFE, 0x4001))
        self.assertEqual(args.input_event, [])
        self.assertIsNone(args.duration)


if __name__ == "__main__":
    unittest.main()
