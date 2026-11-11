# InputPilot 1.0.0

The first stable InputPilot release brings the iOS companion and ESP32-S3 firmware to version **1.0.0**.

## Highlights

- Guided first-run setup: hardware preparation, USB-trusted pairing, optional Wi-Fi, authenticated connection checks, and mouse/keyboard tests.
- Native iOS interface with Lara-inspired glass surfaces, light/dark appearance, device switching, gesture trackpad, and keyboard controls.
- Autonomous device-side presets, editable macros, Keychain-backed Secrets, and Apple Shortcuts/Siri integration.
- Authenticated Bluetooth and Wi-Fi control with fallback recovery, improved latency, persistent diagnostics, and checksummed firmware updates with downgrade protection.
- ESP32-side WireGuard configuration with optional Wi-Fi SSID restrictions.

## Downloads and installation

- **InputPilot-v1.0.0-ios-unsigned.ipa**: iOS companion for sideloading with your own signing identity; requires iOS 17 or newer.
- **InitialFirmware.bin**: complete initial USB-flash image, also available through the [Web Flasher](https://thorethy1.github.io/InputPilot/).
- **firmware.bin**: application image for authenticated OTA updates from compatible Secure Protocol v2 firmware.
- **InputPilot-Firmware-v1.0.0.zip**: firmware images, manifests, and flashing support files.
- **firmware-manifest.json** and **altstore-source.json**: version, compatibility, size, and SHA-256 metadata for firmware updates and AltStore.

The Stable and Beta AltStore sources both offer this same 1.0.0 stable app build:

- Stable: https://github.com/thorethy1/InputPilot/raw/main/app-repo.json
- Beta: https://github.com/thorethy1/InputPilot/raw/main/app-repo-beta.json

## Compatibility and limitations

The firmware retains the `esp32-s3-zero-4mb` target and 4 MB partition layout for existing ESP32-S3-Zero/Mini hardware. The N8R8 purchase recommendation does not introduce a separate 8 MB firmware layout. Use the board's native USB port and verify its pin compatibility before flashing.

Captive portal script management remains disabled in the iOS app while those workflows are unreliable. Use Bluetooth or Wi-Fi without a browser login. Older protocol-v1 firmware requires a USB reflash before normal Secure Protocol v2 operation.

Automated builds and tests do not replace an on-device check of USB HID, Bluetooth/Wi-Fi, WireGuard, or firmware recovery on your particular board.
