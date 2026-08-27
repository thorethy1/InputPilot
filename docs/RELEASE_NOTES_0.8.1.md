# InputPilot 0.8.1 release candidate

This hardware-fix candidate moves USB HID report submission into the Arduino main loop, sends explicit mouse button reports, adds acknowledged BLE control writes and instruments every input stage. It also adds bounded iOS app logs, diagnostics export, HID counters, reset/disconnect context, and app/firmware commit identities.

No tag or GitHub Release is created by this change. All physical HID checks remain **NOT RUN** until recorded in `HARDWARE_E2E_RESULTS_0.8.1.md`.
