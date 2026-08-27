# InputPilot 0.8.2 hardware E2E results

Hardware status: **NOT RUN**

Host builds and unit tests cannot establish physical USB HID delivery or BLE
radio stability. Release publication does not change these results; record real
observations here before considering the hardware gate complete.

| Test | Result | Evidence |
|---|---|---|
| Serial `hidtest mouse` → visible PC movement | NOT RUN | |
| Serial `hidtest keyboard` → exactly one `a` | NOT RUN | |
| REST mouse → visible PC movement | NOT RUN | |
| REST keyboard → host receives key | NOT RUN | |
| TCP mouse → visible PC movement | NOT RUN | |
| TCP keyboard → host receives key | NOT RUN | |
| BLE single mouse move → visible PC movement | NOT RUN | |
| BLE single keyboard report → host receives key | NOT RUN | |
| BLE mouse movement for 30 seconds | NOT RUN | |
| BLE keyboard input for 30 seconds | NOT RUN | |
| BLE remains connected under HID load | NOT RUN | |
| No ESP32 PANIC/reboot under HID load | NOT RUN | |
| Left/right/middle click | NOT RUN | |
| Mouse down/up and drag leave no stuck button | NOT RUN | |
| Modifiers, combinations and key-up | NOT RUN | |
| Text input | NOT RUN | |
| `releaseAll` clears every state | NOT RUN | |
| Wi-Fi and BLE enabled concurrently | NOT RUN | |
| `/api/diagnostics` counters match physical result | NOT RUN | |
| Panic breadcrumb survives a forced/reproduced crash | NOT RUN | |
| Core dump can be read and decoded | NOT RUN | |
| Wi-Fi OTA from 0.8.1 to 0.8.2 | NOT RUN | |
| BLE OTA remains compatible | NOT RUN | |

For each run record board revision/device ID, firmware and app commits, PC/OS,
iPhone/iOS, connection mode, transport selected by the event log, reset reason,
BLE disconnect reason, and HID counters before/after.
