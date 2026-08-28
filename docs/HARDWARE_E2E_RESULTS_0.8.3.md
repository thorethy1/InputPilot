# InputPilot 0.8.3 hardware E2E results

Hardware status: **NOT RUN**

Automated tests cannot establish physical USB HID delivery, CoreBluetooth state
transitions, or OTA restart behavior. Record real observations here before the
0.8.3 hardware gate is considered complete.

| Test | Result | Evidence |
|---|---|---|
| Bluetooth off shows Bluetooth off; saved device is not ready | NOT RUN | |
| Saved device absent from Bluetooth and Wi-Fi becomes Offline | NOT RUN | |
| Discovered device is not shown as ready before connection/authentication | NOT RUN | |
| Connected/authenticated BLE device becomes Ready via Bluetooth | NOT RUN | |
| Active Wi-Fi prevents a parallel BLE reconnect from replacing the usable state | NOT RUN | |
| Disconnect clears ready/active BLE state and reconnect restores it | NOT RUN | |
| Keep Awake is disabled offline and works over live Wi-Fi | NOT RUN | |
| Firmware 0.8.3 reports installed/latest/update state correctly | NOT RUN | |
| Wi-Fi OTA from 0.8.2 to 0.8.3 completes and verifies after restart | NOT RUN | |
| BLE OTA from 0.8.2 to 0.8.3 completes and verifies after restart | NOT RUN | |
| Incompatible image is rejected before transfer | NOT RUN | |
| App-update-required manifest blocks download/install | NOT RUN | |
| REST, TCP, and BLE mouse/keyboard controls remain functional | NOT RUN | |
| Diagnostics remain live over BLE and Wi-Fi fallback | NOT RUN | |
| No stuck mouse button after transport loss | NOT RUN | |

For each run record board revision/device ID, firmware and app commits, PC/OS,
phone/OS, connection mode, selected transport, reset reason, BLE disconnect
reason, and HID counters before/after.
