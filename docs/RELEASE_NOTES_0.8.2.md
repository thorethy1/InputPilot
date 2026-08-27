# InputPilot 0.8.2

0.8.2 unifies actual USB reports on one checked Arduino-ESP32 HID handle, adds
real USB result counters and RTC crash breadcrumbs, moves BLE decode work out
of the NimBLE callback, and implements CoreBluetooth ATT flow control with a
50 Hz coalesced movement fast path. BLE diagnostics share the control session.

OTA protocol/schema remain `1`; a normal 0.8.1 → 0.8.2 `firmware.bin` update is
compatible. Physical checks remain **NOT RUN** until recorded in
`HARDWARE_E2E_RESULTS_0.8.2.md`.
