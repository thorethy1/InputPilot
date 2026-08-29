"""Authenticated Secure Protocol v2 tests over Wi-Fi/TCP.

Requires RUN_WIFI=1 and INPUTPILOT_PAIRING_SECRET_HEX containing the 16-byte
secret captured during the USB HID pairing step. The value is never printed.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import re
import socket
import time
import urllib.request

import pytest
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

CONTROL_PORT = 3333
IP_RE = re.compile(r"connected ip=([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)")
pytestmark = pytest.mark.wifi


def _require_wifi() -> bytes:
    if os.environ.get("RUN_WIFI") != "1":
        pytest.skip("Wi-Fi tests are opt-in; set RUN_WIFI=1")
    value = os.environ.get("INPUTPILOT_PAIRING_SECRET_HEX", "")
    try:
        secret = bytes.fromhex(value)
    except ValueError:
        secret = b""
    if len(secret) != 16:
        pytest.skip("set INPUTPILOT_PAIRING_SECRET_HEX from the USB pairing step")
    return secret


@pytest.fixture(scope="module")
def wifi_device(serial_harness):
    secret = _require_wifi()
    serial_harness.send_command("radio none")
    time.sleep(0.8)
    serial_harness.clear_buffer()
    try:
        match = serial_harness.send_and_wait("radio wifi", IP_RE, timeout=25.0)
    except TimeoutError:
        pytest.skip("Wi-Fi did not connect")
    ip = match.groups[0]
    with urllib.request.urlopen(f"http://{ip}/api/status", timeout=5) as response:
        discovery = json.loads(response.read().decode())
    device_id = discovery.get("device_id", "")
    assert re.fullmatch(r"[0-9a-f]{12}", device_id)
    assert discovery.get("protocol_version") == 2
    yield ip, device_id, secret


def _readline(stream) -> str:
    line = stream.readline()
    assert line, "secure transport closed during handshake"
    return line.decode().strip()


def _secure_connection(ip: str, device_id: str, secret: bytes):
    connection = socket.create_connection((ip, CONTROL_PORT), timeout=6)
    stream = connection.makefile("rwb", buffering=0)
    stream.write(b"secure begin\n")
    fields = _readline(stream).split()
    assert fields[:3] == ["secure", "challenge", "1"]
    assert fields[3].lower() == device_id
    server_nonce = bytes.fromhex(fields[4])
    client_nonce = os.urandom(16)
    client_proof = hmac.new(
        secret, b"IPSEC1-C" + device_id.encode() + server_nonce + client_nonce,
        hashlib.sha256,
    ).digest()
    stream.write(f"secure hello {client_nonce.hex()} {client_proof.hex()}\n".encode())
    ready = _readline(stream).split()
    assert ready[:2] == ["secure", "ready"]
    expected = hmac.new(
        secret, b"IPSEC1-S" + device_id.encode() + server_nonce + client_nonce,
        hashlib.sha256,
    ).hexdigest()
    assert hmac.compare_digest(ready[2].lower(), expected)
    key = HKDF(
        algorithm=hashes.SHA256(), length=32,
        salt=server_nonce + client_nonce,
        info=b"InputPilot secure protocol v2 client",
    ).derive(secret)
    return connection, stream, AESGCM(key)


def _send_secure(stream, cipher: AESGCM, device_id: str, counter: int, command: str):
    counter_bytes = counter.to_bytes(8, "big")
    sealed = cipher.encrypt(b"IPC\x02" + counter_bytes, command.encode(), device_id.encode())
    stream.write(
        f"secure data {counter_bytes.hex()} {sealed[:-16].hex()} {sealed[-16:].hex()}\n".encode()
    )


def test_plaintext_control_is_rejected(wifi_device, serial_harness):
    ip, _, _ = wifi_device
    serial_harness.clear_buffer()
    with socket.create_connection((ip, CONTROL_PORT), timeout=6) as connection:
        connection.sendall(b"move 42 0\n")
        time.sleep(0.5)
    with pytest.raises(TimeoutError):
        serial_harness.wait_for_pattern(r"move dx=42 dy=0", timeout=1.0)


def test_authenticated_wifi_control_reaches_hid(wifi_device, serial_harness):
    ip, device_id, secret = wifi_device
    connection, stream, cipher = _secure_connection(ip, device_id, secret)
    try:
        serial_harness.clear_buffer()
        _send_secure(stream, cipher, device_id, 1, "move 41 0")
        serial_harness.wait_for_pattern(r"move dx=41 dy=0", timeout=5.0)
    finally:
        stream.close()
        connection.close()
