"""Opt-in hardware regression: losing BLE must not reset the USB peripheral.

The board must already have BLE enabled and no phone connected. Set RUN_BLE=1
and INPUTPILOT_BLE_ADDRESS to its BLE address (CoreBluetooth UUID on macOS).
No pairing secret is needed: both authenticated and unauthenticated owners
use the same firmware disconnect callback.
"""

import asyncio
import os

import pytest

pytestmark = pytest.mark.ble


def test_repeated_ble_disconnect_preserves_usb_and_uptime(serial_harness):
    if os.environ.get("RUN_BLE") != "1":
        pytest.skip("BLE hardware tests are opt-in; set RUN_BLE=1")
    address = os.environ.get("INPUTPILOT_BLE_ADDRESS")
    if not address:
        pytest.skip("set INPUTPILOT_BLE_ADDRESS for the board on ESP_PORT")
    bleak = pytest.importorskip("bleak")

    def uptime_ms():
        match = serial_harness.send_and_wait(
            "status", r"^\[(\d+)\]\[INFO\]\[APP\] status .*usb=ready", timeout=5
        )
        return int(match.groups[0])

    async def exercise():
        previous = uptime_ms()
        for _ in range(5):
            # Scanning again also verifies advertising recovered after teardown.
            device = await bleak.BleakScanner.find_device_by_address(address, timeout=10)
            assert device is not None, "board did not resume BLE advertising"
            serial_harness.clear_buffer()
            async with bleak.BleakClient(device) as client:
                assert client.is_connected
                serial_harness.wait_for_pattern(r"central connected handle=", timeout=5)
                await asyncio.sleep(1)
            serial_harness.wait_for_pattern(
                r"central disconnected .*cleanup in loop", timeout=5
            )
            # Keep the original CDC handle open: USB re-enumeration must fail
            # this exchange instead of being hidden by opening a fresh port.
            current = uptime_ms()
            assert current > previous, "ESP uptime reset after BLE disconnect"
            previous = current

    asyncio.run(exercise())
