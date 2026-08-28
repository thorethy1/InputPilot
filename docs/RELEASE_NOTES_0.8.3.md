# InputPilot 0.8.3

0.8.3 completes the 0.8.x reliability foundation by making live device,
connection, and firmware-update state explicit and trustworthy in the iOS app.

Persisted transport capabilities are no longer presented as proof that a saved
device is online. The app now distinguishes Bluetooth radio availability,
discovery, connection, authentication, readiness, live Wi-Fi reachability, and
offline state. A working transport takes precedence over another transport that
is reconnecting.

Firmware management separately presents installed and latest firmware, whether
an update is needed, compatibility and OTA migration blockers, newer-app
requirements, and release-check failures. Existing BLE and Wi-Fi OTA protocols,
schema 1, integrity verification, and post-reboot verification are unchanged.

The iOS and Android device-list jiggle switches were removed. The feature remains
as the clearer “Keep Awake” setting in device details and is enabled only while
its Wi-Fi API is reachable. Android saved devices likewise begin in a checking
state and report live Wi-Fi availability rather than pointer activity.

Automated iOS tests cover the new state resolution and compatibility decisions.
Physical BLE, Wi-Fi, HID, diagnostics, and OTA validation remains part of the
release hardware gate and must be recorded in
`HARDWARE_E2E_RESULTS_0.8.3.md` before publishing hardware results.
