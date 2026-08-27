#!/usr/bin/env python3
"""Passively display InputPilot USB keyboard and mouse events on Linux."""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from hardware_test_ubuntu import (
    BTN_LEFT,
    BTN_MIDDLE,
    BTN_RIGHT,
    EV_KEY,
    EV_REL,
    REL_WHEEL,
    REL_X,
    REL_Y,
    InputEvent,
    LinuxInputMonitor,
    discover_input_events,
)

KEY_A = 30
KEY_NAMES = {
    1: "KEY_ESC", 2: "KEY_1", 3: "KEY_2", 4: "KEY_3", 5: "KEY_4",
    6: "KEY_5", 7: "KEY_6", 8: "KEY_7", 9: "KEY_8", 10: "KEY_9", 11: "KEY_0",
    12: "KEY_MINUS", 13: "KEY_EQUAL", 14: "KEY_BACKSPACE", 15: "KEY_TAB",
    16: "KEY_Q", 17: "KEY_W", 18: "KEY_E", 19: "KEY_R", 20: "KEY_T",
    21: "KEY_Y", 22: "KEY_U", 23: "KEY_I", 24: "KEY_O", 25: "KEY_P",
    26: "KEY_LEFTBRACE", 27: "KEY_RIGHTBRACE", 28: "KEY_ENTER", 29: "KEY_LEFTCTRL",
    30: "KEY_A", 31: "KEY_S", 32: "KEY_D", 33: "KEY_F", 34: "KEY_G",
    35: "KEY_H", 36: "KEY_J", 37: "KEY_K", 38: "KEY_L", 39: "KEY_SEMICOLON",
    40: "KEY_APOSTROPHE", 41: "KEY_GRAVE", 42: "KEY_LEFTSHIFT", 43: "KEY_BACKSLASH",
    44: "KEY_Z", 45: "KEY_X", 46: "KEY_C", 47: "KEY_V", 48: "KEY_B",
    49: "KEY_N", 50: "KEY_M", 51: "KEY_COMMA", 52: "KEY_DOT", 53: "KEY_SLASH",
    54: "KEY_RIGHTSHIFT", 55: "KEY_KPASTERISK", 56: "KEY_LEFTALT", 57: "KEY_SPACE",
    58: "KEY_CAPSLOCK", 59: "KEY_F1", 60: "KEY_F2", 61: "KEY_F3", 62: "KEY_F4",
    63: "KEY_F5", 64: "KEY_F6", 65: "KEY_F7", 66: "KEY_F8", 67: "KEY_F9",
    68: "KEY_F10", 69: "KEY_NUMLOCK", 70: "KEY_SCROLLLOCK", 71: "KEY_KP7",
    72: "KEY_KP8", 73: "KEY_KP9", 74: "KEY_KPMINUS", 75: "KEY_KP4",
    76: "KEY_KP5", 77: "KEY_KP6", 78: "KEY_KPPLUS", 79: "KEY_KP1",
    80: "KEY_KP2", 81: "KEY_KP3", 82: "KEY_KP0", 83: "KEY_KPDOT",
    87: "KEY_F11", 88: "KEY_F12", 96: "KEY_KPENTER", 97: "KEY_RIGHTCTRL",
    98: "KEY_KPSLASH", 100: "KEY_RIGHTALT", 102: "KEY_HOME", 103: "KEY_UP",
    104: "KEY_PAGEUP", 105: "KEY_LEFT", 106: "KEY_RIGHT", 107: "KEY_END",
    108: "KEY_DOWN", 109: "KEY_PAGEDOWN", 110: "KEY_INSERT", 111: "KEY_DELETE",
    125: "KEY_LEFTMETA", 126: "KEY_RIGHTMETA", 127: "KEY_COMPOSE",
}
BUTTON_NAMES = {
    BTN_LEFT: "BTN_LEFT",
    BTN_RIGHT: "BTN_RIGHT",
    BTN_MIDDLE: "BTN_MIDDLE",
}
RELATIVE_NAMES = {
    REL_X: "REL_X",
    REL_Y: "REL_Y",
    REL_WHEEL: "REL_WHEEL",
}


def format_event(event: InputEvent) -> str:
    """Return a compact, human-readable representation of an input event."""
    device = Path(event.device).name
    if event.event_type == EV_KEY:
        is_button = event.code in BUTTON_NAMES
        name = BUTTON_NAMES.get(event.code, KEY_NAMES.get(event.code, f"KEY_{event.code}"))
        state = {0: "UP", 1: "DOWN", 2: "REPEAT"}.get(event.value, f"VALUE_{event.value}")
        source = "MOUSE" if is_button else "KEYBOARD"
        return f"{source} {device} {name} {state}"
    if event.event_type == EV_REL:
        name = RELATIVE_NAMES.get(event.code, f"REL_{event.code}")
        return f"MOUSE {device} {name} {event.value:+d}"
    return f"INPUT {device} type={event.event_type} code={event.code} value={event.value}"


def build_parser() -> argparse.ArgumentParser:
    """Build argument parser for the live listener."""
    parser = argparse.ArgumentParser(
        description="Passiv InputPilot USB-Keyboard/Maus-Eventmonitor. "
        "Zeigt live alle HID-Events von Tastatur und Maus an.",
    )
    parser.add_argument("--vid", type=lambda s: int(s, 16), default=0xCAFE,
                        help="USB Vendor-ID (hex, Default: CAFE)")
    parser.add_argument("--pid", type=lambda s: int(s, 16), default=0x4001,
                        help="USB Product-ID (hex, Default: 4001)")
    parser.add_argument("--input-event", action="append", default=[], type=Path,
                        help="/dev/input/event*-Pfad (wiederholbar; ersetzt Auto-Discovery)")
    parser.add_argument("--duration", type=float, default=None,
                        help="Maximale Laufzeit in Sekunden (Default: unbegrenzt)")
    return parser


def main() -> None:
    """Live event monitor entry point."""
    args = build_parser().parse_args()
    paths: list[Path] = args.input_event.copy()
    if not paths:
        discovered = discover_input_events(args.vid, args.pid)
        if not discovered:
            sys.exit("FEHLER: Kein InputPilot mit VID:PID {:04x}:{:04x} gefunden.\n"
                     "       USB-Gerät angeschlossen? --input-event manuell setzen?"
                     .format(args.vid, args.pid))
        paths = discovered
    print(f"InputPilot USB-Listener startet … Eventnodes: {' '.join(str(p) for p in paths)}")
    if args.duration:
        print(f"Begrenzt auf {args.duration:.0f} Sekunden.")
    print("─── Events ────────────────────────────────")
    monitor = LinuxInputMonitor(paths)
    try:
        deadline = time.monotonic() + args.duration if args.duration else None
        while True:
            if deadline and time.monotonic() >= deadline:
                break
            events = monitor.read(1.0)
            for event in events:
                print(format_event(event), flush=True)
    except KeyboardInterrupt:
        pass
    finally:
        monitor.close()
        print("─── Monitor beendet ──────────────────────")


if __name__ == "__main__":
    main()