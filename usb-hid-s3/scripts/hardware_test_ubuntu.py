#!/usr/bin/env python3
"""Prove REST/TCP -> ESP32 -> USB HID using Linux evdev on headless Ubuntu."""

from __future__ import annotations

import argparse
import json
import os
import select
import socket
import struct
import sys
import time
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Callable, Iterable

EV_KEY, EV_REL = 0x01, 0x02
REL_X, REL_Y, REL_WHEEL = 0x00, 0x01, 0x08
BTN_LEFT, BTN_RIGHT, BTN_MIDDLE = 0x110, 0x111, 0x112
KEY_LEFTSHIFT, KEY_A, KEY_B, KEY_C = 42, 30, 48, 46
KEY_E, KEY_ENTER, KEY_P, KEY_R, KEY_S, KEY_T, KEY_TAB = 18, 28, 25, 19, 31, 20, 15
EVENT_STRUCT = struct.Struct("@llHHi")
EVENT_NAMES = {
    (EV_REL, REL_X): "REL_X", (EV_REL, REL_Y): "REL_Y", (EV_REL, REL_WHEEL): "REL_WHEEL",
    (EV_KEY, BTN_LEFT): "BTN_LEFT", (EV_KEY, BTN_RIGHT): "BTN_RIGHT", (EV_KEY, BTN_MIDDLE): "BTN_MIDDLE",
    (EV_KEY, KEY_LEFTSHIFT): "KEY_LEFTSHIFT", (EV_KEY, KEY_A): "KEY_A", (EV_KEY, KEY_B): "KEY_B",
    (EV_KEY, KEY_C): "KEY_C", (EV_KEY, KEY_E): "KEY_E", (EV_KEY, KEY_ENTER): "KEY_ENTER",
    (EV_KEY, KEY_P): "KEY_P", (EV_KEY, KEY_R): "KEY_R", (EV_KEY, KEY_S): "KEY_S",
    (EV_KEY, KEY_T): "KEY_T", (EV_KEY, KEY_TAB): "KEY_TAB",
}


class HardwareTestError(RuntimeError):
    pass


@dataclass(frozen=True)
class InputEvent:
    event_type: int
    code: int
    value: int
    device: str

    def evidence(self) -> str:
        name = EVENT_NAMES.get((self.event_type, self.code), f"type={self.event_type}/code={self.code}")
        return f"{self.device}:{name}={self.value}"


@dataclass
class TestResult:
    transport: str
    test: str
    passed: bool
    duration_ms: int
    evidence: list[str]
    error: str = ""


def _read_hex(path: Path) -> int | None:
    try:
        return int(path.read_text(encoding="ascii").strip(), 16)
    except (OSError, ValueError):
        return None


def discover_input_events(vid: int, pid: int) -> list[Path]:
    matches: list[Path] = []
    for event_class in sorted(Path("/sys/class/input").glob("event*")):
        cursor = (event_class / "device").resolve()
        for parent in (cursor, *cursor.parents):
            direct = _read_hex(parent / "idVendor") == vid and _read_hex(parent / "idProduct") == pid
            input_id = _read_hex(parent / "id" / "vendor") == vid and _read_hex(parent / "id" / "product") == pid
            if direct or input_id:
                node = Path("/dev/input") / event_class.name
                if node.exists():
                    matches.append(node)
                break
    return matches


class LinuxInputMonitor:
    def __init__(self, paths: Iterable[Path]):
        self.fds: dict[int, str] = {}
        self.buffers: dict[int, bytes] = {}
        for path in paths:
            try:
                fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
            except PermissionError as exc:
                raise HardwareTestError(
                    f"Keine Leseberechtigung für {path}; als root ausführen oder die Gruppe 'input' verwenden."
                ) from exc
            self.fds[fd] = str(path)
            self.buffers[fd] = b""

    def close(self) -> None:
        for fd in self.fds:
            os.close(fd)
        self.fds.clear()

    def read(self, timeout: float) -> list[InputEvent]:
        ready, _, _ = select.select(list(self.fds), [], [], timeout)
        events: list[InputEvent] = []
        for fd in ready:
            while True:
                try:
                    chunk = os.read(fd, EVENT_STRUCT.size * 64)
                except BlockingIOError:
                    break
                if not chunk:
                    break
                data, offset = self.buffers[fd] + chunk, 0
                while len(data) - offset >= EVENT_STRUCT.size:
                    _, _, event_type, code, value = EVENT_STRUCT.unpack_from(data, offset)
                    offset += EVENT_STRUCT.size
                    if event_type in (EV_KEY, EV_REL):
                        events.append(InputEvent(event_type, code, value, self.fds[fd]))
                self.buffers[fd] = data[offset:]
        return events

    def drain(self) -> None:
        while self.read(0):
            pass

    def observe(self, action: Callable[[], None], predicate: Callable[[list[InputEvent]], bool], timeout: float) -> list[InputEvent]:
        self.drain()
        action()
        deadline, events = time.monotonic() + timeout, []
        while time.monotonic() < deadline:
            events.extend(self.read(min(0.1, deadline - time.monotonic())))
            if predicate(events):
                events.extend(self.read(0.05))
                return events
        return events


class RestClient:
    def __init__(self, base_url: str, token: str, timeout: float):
        self.base_url, self.token, self.timeout = base_url.rstrip("/"), token, timeout

    def request(self, method: str, path: str, body: dict | None = None) -> dict:
        data = json.dumps(body).encode() if body is not None else None
        headers = {"Accept": "application/json"}
        if data is not None:
            headers["Content-Type"] = "application/json"
        if self.token:
            headers["X-API-Token"] = self.token
        request = urllib.request.Request(self.base_url + path, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                raw = response.read().decode()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode(errors="replace")
            raise HardwareTestError(f"REST {path}: HTTP {exc.code}: {detail}") from exc
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            raise HardwareTestError(f"REST {path} fehlgeschlagen: {exc}") from exc

    def post(self, path: str, body: dict | None = None) -> None:
        payload = self.request("POST", path, {} if body is None else body)
        if payload.get("ok") is not True:
            raise HardwareTestError(f"REST {path} meldet keinen Erfolg: {payload}")


class TcpClient:
    def __init__(self, host: str, port: int, token: str, auth_required: bool, timeout: float):
        self.socket = socket.create_connection((host, port), timeout=timeout)
        self.socket.settimeout(timeout)
        if auth_required:
            if not token:
                self.close()
                raise HardwareTestError("Das Gerät verlangt Authentifizierung; --token fehlt.")
            self.send(f"auth {token}")
            if self._readline() != "auth ok":
                self.close()
                raise HardwareTestError("TCP-Authentifizierung fehlgeschlagen.")

    def _readline(self) -> str:
        data = bytearray()
        while len(data) < 512:
            byte = self.socket.recv(1)
            if not byte or byte == b"\n":
                break
            if byte != b"\r":
                data.extend(byte)
        return data.decode(errors="replace")

    def send(self, command: str) -> None:
        self.socket.sendall((command + "\n").encode())

    def close(self) -> None:
        try:
            self.socket.close()
        except OSError:
            pass


def key_cycle(code: int) -> Callable[[list[InputEvent]], bool]:
    def matches(events: list[InputEvent]) -> bool:
        values = [e.value for e in events if e.event_type == EV_KEY and e.code == code]
        return 1 in values and 0 in values and values.index(1) < values.index(0)
    return matches


def key_sequence(codes: list[int]) -> Callable[[list[InputEvent]], bool]:
    def matches(events: list[InputEvent]) -> bool:
        downs = [e.code for e in events if e.event_type == EV_KEY and e.value == 1 and e.code < BTN_LEFT]
        cursor = 0
        for code in downs:
            if cursor < len(codes) and code == codes[cursor]:
                cursor += 1
        return cursor == len(codes) and all(
            any(e.event_type == EV_KEY and e.code == code and e.value == 0 for e in events) for code in codes
        )
    return matches


def key_set_cycle(codes: set[int]) -> Callable[[list[InputEvent]], bool]:
    return lambda events: all(
        any(e.event_type == EV_KEY and e.code == code and e.value == 1 for e in events)
        and any(e.event_type == EV_KEY and e.code == code and e.value == 0 for e in events)
        for code in codes
    )


def relative_motion(dx: int = 0, dy: int = 0, wheel: int = 0) -> Callable[[list[InputEvent]], bool]:
    expected = {code: value for code, value in ((REL_X, dx), (REL_Y, dy), (REL_WHEEL, wheel)) if value}
    return lambda events: all(
        sum(e.value for e in events if e.event_type == EV_REL and e.code == code) == value
        for code, value in expected.items()
    )


class HardwareRunner:
    def __init__(self, monitor: LinuxInputMonitor, timeout: float):
        self.monitor, self.timeout, self.results = monitor, timeout, []

    def verify(self, transport: str, name: str, action: Callable[[], None], predicate: Callable[[list[InputEvent]], bool]) -> None:
        started = time.monotonic()
        try:
            events = self.monitor.observe(action, predicate, self.timeout)
            passed = predicate(events)
            evidence = [e.evidence() for e in events if (e.event_type, e.code) in EVENT_NAMES]
            error = "" if passed else "Erwartetes Linux-Input-Event nicht empfangen"
        except Exception as exc:
            passed, evidence, error = False, [], str(exc)
        self.results.append(TestResult(transport, name, passed, int((time.monotonic() - started) * 1000), evidence, error))
        print(f"[{'PASS' if passed else 'FAIL'}] {transport:4s} | {name}")
        if error:
            print(f"       {error}")

    def run_suite(self, name: str, send: Callable[[str, tuple[str, dict | None]], None]) -> None:
        action = lambda text, path, body=None: lambda: send(text, (path, body))
        self.verify(name, "Maus X/Y bewegen", action("move 37 -11", "/api/move", {"dx": 37, "dy": -11}), relative_motion(37, -11))
        self.verify(name, "Scrollen", action("move 0 0 2", "/api/move", {"dx": 0, "dy": 0, "wheel": 2}), relative_motion(wheel=2))
        for button_name, button_code in (("left", BTN_LEFT), ("right", BTN_RIGHT), ("middle", BTN_MIDDLE)):
            self.verify(name, f"{button_name} click", action(f"click {button_name}", "/api/click", {"button": button_name}), key_cycle(button_code))
        self.verify(name, "Mouse Down", action("button left down", "/api/button", {"button": "left", "state": "down"}), lambda ev: any(e.code == BTN_LEFT and e.value == 1 for e in ev))
        self.verify(name, "Dragging-Bewegung", action("move 13 7", "/api/move", {"dx": 13, "dy": 7}), relative_motion(13, 7))
        self.verify(name, "Mouse Up", action("button left up", "/api/button", {"button": "left", "state": "up"}), lambda ev: any(e.code == BTN_LEFT and e.value == 0 for e in ev))
        key_name, key_code = ("enter", KEY_ENTER) if name == "REST" else ("tab", KEY_TAB)
        self.verify(name, "Einzelner Tastendruck", action(f"key {key_name}", "/api/key", {"key": key_name}), key_cycle(key_code))
        text, codes = ("rest", [KEY_R, KEY_E, KEY_S, KEY_T]) if name == "REST" else ("tcp", [KEY_T, KEY_C, KEY_P])
        self.verify(name, "Text-Eingabe", action(f"type {text}", "/api/type", {"text": text}), key_sequence(codes))
        usage, letter = (4, KEY_A) if name == "REST" else (5, KEY_B)
        self.verify(name, "Modifier + HID-Report", action(f"report 2 {usage}", "/api/report", {"modifiers": 2, "usage": usage}), key_set_cycle({KEY_LEFTSHIFT, letter}))
        self.verify(name, "ReleaseAll Vorbereitung", action("button right down", "/api/button", {"button": "right", "state": "down"}), lambda ev: any(e.code == BTN_RIGHT and e.value == 1 for e in ev))
        self.verify(name, "releaseAll", action("release all", "/api/release-all"), lambda ev: any(e.code == BTN_RIGHT and e.value == 0 for e in ev))


def diagnostics_delta(before: dict, after: dict, field: str) -> int:
    return int(after.get("hid", {}).get(field, 0)) - int(before.get("hid", {}).get(field, 0))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="InputPilot REST/TCP -> echtes USB-HID auf Headless Ubuntu testen")
    parser.add_argument("--host", required=True, help="IP/Hostname des ESP32")
    parser.add_argument("--token", default=os.environ.get("INPUTPILOT_TOKEN", ""), help="Control-Token oder INPUTPILOT_TOKEN")
    parser.add_argument("--transport", choices=("all", "rest", "tcp"), default="all")
    parser.add_argument("--tcp-port", type=int, default=3333)
    parser.add_argument("--vid", type=lambda x: int(x, 0), default=0xCAFE)
    parser.add_argument("--pid", type=lambda x: int(x, 0), default=0x4001)
    parser.add_argument("--input-event", action="append", default=[])
    parser.add_argument("--timeout", type=float, default=3.0)
    parser.add_argument("--json-output", type=Path)
    return parser.parse_args()


def add_diagnostic_result(results: list[TestResult], name: str, passed: bool, evidence: list[str], error: str) -> None:
    results.append(TestResult("DIAG", name, passed, 0, evidence, "" if passed else error))
    print(f"[{'PASS' if passed else 'FAIL'}] DIAG | {name}: {', '.join(evidence)}")


def main() -> int:
    args = parse_args()
    if sys.platform != "linux":
        print("FEHLER: Dieses Skript benötigt Linux/Ubuntu.", file=sys.stderr)
        return 2
    from urllib.parse import urlparse
    url = args.host if "://" in args.host else f"http://{args.host}"
    parsed = urlparse(url)
    if not parsed.hostname:
        print(f"FEHLER: Ungültiger Host: {args.host}", file=sys.stderr)
        return 2
    host, base_url = parsed.hostname, f"{parsed.scheme}://{parsed.netloc}"
    try:
        paths = [Path(path) for path in args.input_event] or discover_input_events(args.vid, args.pid)
        if not paths:
            raise HardwareTestError(f"Kein InputPilot mit VID:PID {args.vid:04x}:{args.pid:04x} gefunden.")
        print("Input-Geräte: " + ", ".join(map(str, paths)))
        monitor, rest = LinuxInputMonitor(paths), RestClient(base_url, args.token, args.timeout)
        tcp: TcpClient | None = None
        runner = HardwareRunner(monitor, args.timeout)
        try:
            status = rest.request("GET", "/api/status")
            if status.get("usb") != "ready":
                raise HardwareTestError(f"Firmware meldet USB nicht bereit: {status.get('usb')!r}")
            auth_required = bool(status.get("auth_required"))
            if auth_required and not args.token:
                raise HardwareTestError("Das Gerät verlangt Authentifizierung; --token oder INPUTPILOT_TOKEN setzen.")
            rest.post("/api/jiggle", {"enabled": False})
            rest.post("/api/release-all")
            time.sleep(0.15)
            monitor.drain()
            # Establish the counter baseline after setup traffic, so the
            # transport deltas below can only be satisfied by the test suite.
            before = rest.request("GET", "/api/diagnostics")
            if args.transport in ("all", "rest"):
                runner.run_suite("REST", lambda _text, spec: rest.post(spec[0], spec[1]))
            if args.transport in ("all", "tcp"):
                tcp = TcpClient(host, args.tcp_port, args.token, auth_required, args.timeout)
                runner.run_suite("TCP", lambda text, _spec: tcp.send(text))
                tcp.send("release all")
                time.sleep(0.1)
            after = rest.request("GET", "/api/diagnostics")
            for field in (["rxRest"] if args.transport == "rest" else ["rxTcp"] if args.transport == "tcp" else ["rxRest", "rxTcp"]):
                delta = diagnostics_delta(before, after, field)
                add_diagnostic_result(runner.results, f"{field} erhöht", delta > 0, [f"delta={delta}"], "Zähler wurde nicht erhöht")
            succeeded, failed = diagnostics_delta(before, after, "usbReportsSucceeded"), diagnostics_delta(before, after, "usbReportsFailed")
            add_diagnostic_result(runner.results, "USB-Report-Erfolg", succeeded > 0 and failed == 0,
                                  [f"succeeded_delta={succeeded}", f"failed_delta={failed}"], "USB-Reports fehlen oder sind fehlgeschlagen")
            uptime_ok = int(after.get("uptime", 0)) >= int(before.get("uptime", 0))
            add_diagnostic_result(runner.results, "Kein Reboot während Test", uptime_ok,
                                  [f"uptime={before.get('uptime')}->{after.get('uptime')}"], "ESP32 wurde neu gestartet")
            report = {"schema": 1, "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                      "host": host, "firmware": status.get("version"), "deviceId": before.get("deviceId"),
                      "inputDevices": [str(path) for path in paths], "diagnosticsBefore": before,
                      "diagnosticsAfter": after, "results": [asdict(result) for result in runner.results]}
            if args.json_output:
                args.json_output.parent.mkdir(parents=True, exist_ok=True)
                args.json_output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
                print(f"Bericht: {args.json_output}")
            failed_results = [result for result in runner.results if not result.passed]
            print(f"\nErgebnis: {len(runner.results) - len(failed_results)}/{len(runner.results)} PASS")
            return 1 if failed_results else 0
        finally:
            if tcp:
                tcp.close()
            try:
                rest.post("/api/release-all")
            except Exception:
                pass
            monitor.close()
    except (HardwareTestError, OSError) as exc:
        print(f"FEHLER: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
