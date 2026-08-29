"""mDNS discovery test for per-device inputpilot-xxxx.local.

Resolves the hostname derived from the public device identity and reads public
discovery metadata at /api/status.
Gated behind RUN_WIFI=1.

Run:
  RUN_WIFI=1 ESP_PORT=... python3 -m pytest tests/e2e/test_mdns.py -m wifi -v
"""

from __future__ import annotations

import json
import os
import re
import socket
import time
import urllib.request

import pytest

MDNS_PATTERN = re.compile(r"^inputpilot-[0-9a-f]{4}\.local$")

pytestmark = pytest.mark.wifi


def _require():
    if os.environ.get("RUN_WIFI") != "1":
        pytest.skip("mDNS tests are opt-in; set RUN_WIFI=1")


def _resolve(host: str, timeout: float = 20.0) -> str:
    deadline = time.time() + timeout
    last_err = None
    while time.time() < deadline:
        try:
            infos = socket.getaddrinfo(host, 80, socket.AF_INET, socket.SOCK_STREAM)
            if infos:
                return infos[0][4][0]
        except socket.gaierror as e:
            last_err = e
            time.sleep(1.0)
    raise TimeoutError(f"could not resolve {host}: {last_err}")


def _fetch_status_via_ip(ip: str) -> dict:
    url = f"http://{ip}/api/status"
    with urllib.request.urlopen(url, timeout=5) as r:
        return json.loads(r.read().decode())


def _identity_from_http(harness) -> str | None:
    st = harness.send_and_wait("status", r"radio=wifi:", timeout=8.0)
    if "wifi:ap" in st.line or "radio=none" in st.line:
        return None
    m = re.search(r"(?:connected ip=|radio=wifi:)([\d.]+)", st.line)
    if not m:
        return None
    body = _fetch_status_via_ip(m.group(1))
    device_id = body.get("device_id", "")
    if isinstance(device_id, str) and re.fullmatch(r"[0-9a-f]{12}", device_id):
        return device_id
    return None


@pytest.fixture(scope="module")
def mdns_ready(serial_harness):
    _require()
    # Ensure STA + mDNS are up (boot default is wifi).
    serial_harness.send_command("radio wifi")
    try:
        serial_harness.wait_for_pattern(
            r"mDNS started as inputpilot-[0-9a-f]{4}\.local|connected ip=",
            timeout=25.0,
        )
    except TimeoutError:
        # Already connected from boot — status is enough.
        st = serial_harness.send_and_wait("status", r"radio=wifi:", timeout=8.0)
        if "wifi:ap" in st.line or "radio=none" in st.line:
            pytest.skip("device not on STA WiFi")
    time.sleep(1.0)  # let mDNS announce settle
    yield serial_harness


@pytest.fixture(scope="module")
def mdns_hostname(mdns_ready):
    device_id = _identity_from_http(mdns_ready)
    if not device_id:
        pytest.skip("could not determine the public device identity")
    host = f"inputpilot-{device_id[-4:]}.local"
    assert MDNS_PATTERN.match(host)
    return host


def test_mdns_resolves_inputpilot(mdns_ready, mdns_hostname):
    ip = _resolve(mdns_hostname, timeout=25.0)
    assert ip.count(".") == 3
    # Cross-check with serial status IP when possible.
    st = mdns_ready.send_and_wait("status", r"radio=wifi:", timeout=5.0)
    if "wifi:ap" not in st.line:
        assert ip in st.line or "radio=wifi:" in st.line


def test_mdns_http_status(mdns_ready, mdns_hostname):
    # Prefer hostname URL so we exercise mDNS end-to-end for the app path.
    url = f"http://{mdns_hostname}/api/status"
    deadline = time.time() + 20.0
    last_err = None
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=5) as r:
                body = json.loads(r.read().decode())
            assert body.get("product") == "InputPilot"
            assert body.get("name", "").startswith("InputPilot-")
            assert body.get("protocol_version") == 2
            assert "secure_protocol_v2" in body.get("capabilities", [])
            device_id = body.get("device_id", "")
            assert isinstance(device_id, str) and len(device_id) == 12
            assert all(c in "0123456789abcdef" for c in device_id)
            return
        except Exception as e:
            last_err = e
            time.sleep(1.0)
    pytest.fail(f"HTTP via {url} failed: {last_err}")
