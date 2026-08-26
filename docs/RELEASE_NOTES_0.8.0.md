# InputPilot 0.8.0

InputPilot 0.8.0 adds authenticated BLE firmware updates, a native four-tab iOS interface, first-class Bluetooth and BLE-only status, and a centralized red iOS accent color. The firmware now uses dual OTA slots on the supported 4 MB Waveshare ESP32-S3-Zero and validates image size, order, and SHA-256 before activation.

For first installation or migration, use the release's merged initial-flash image or initial-flash package over USB. Later updates use the Firmware tab, which downloads and transfers `firmware.bin` from GitHub Releases. Interrupted or rejected updates keep the previously installed firmware bootable.

Hardware BLE OTA, interruption recovery, post-reboot USB HID, and signed-device UI checks remain release-candidate checks that require a physical ESP32-S3-Zero and iPhone; see `docs/HARDWARE_E2E.md`.

**Hardware validation is required before publishing the final v0.8.0 release.** Record results in `docs/HARDWARE_E2E_RESULTS_0.8.0.md`.
