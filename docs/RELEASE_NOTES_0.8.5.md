# InputPilot 0.8.5

InputPilot 0.8.5 fixes the failed v0.8.4 iOS CI tests and makes device identity configurable without rebuilding firmware.

The iOS device screen can read, validate, save, and restore the USB product name, vendor ID, product ID, and serial number over the authenticated Wi-Fi API. Settings persist in NVS and take effect after the firmware performs a controlled restart. Defaults are `InputPilot`, `CAFE:4001`, and a stable serial number derived from the chip MAC.

Firmware now reports itself as `InputPilot-Firmware`, uses `inputpilot-xxxx.local` for Bonjour, and broadcasts `InputPilot-XXXX` during Soft-AP setup. Both companion apps continue to recognize legacy `hid-helper` discovery names.

CI preboots a single simulator, avoids parallel test clones, and builds the unsigned device IPA concurrently. Public releases retain the unsigned IPA, Android APK, full initial-flash ZIP, merged `InitialFirmware.bin`, OTA `firmware.bin`, and the permanent `firmware-manifest.json` required for automatic in-app updates. The separate credentialed signing workflow keeps its directly downloadable signed IPA in an unpublished draft release.

OTA protocol and schema remain at version 1, so v0.8.4 devices can install `firmware.bin` normally through the app.
