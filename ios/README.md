# InputPilot iOS companion

The iOS app supports Secure Protocol v2 devices only.

## Setup lifecycle

1. Discover the InputPilot over BLE.
2. Establish trust through USB HID pairing.
3. Authenticate the BLE Secure Protocol session.
4. Send Wi-Fi credentials through that encrypted session.
5. Rediscover the same device identity on the home network.
6. Authenticate its Wi-Fi/TCP Secure Protocol session and save the device.

Public HTTP is used only for discovery metadata. HID control, keyboard input,
presets, keep-awake settings, Wi-Fi configuration, USB identity, diagnostics,
management and OTA use authenticated BLE or Wi-Fi/TCP sessions.

Older firmware cannot be added. Reflash it over USB with the current merged
image, then run secure setup.

## Build and test

Open `InputPilot.xcodeproj` in Xcode, select the InputPilot scheme and run the
app or its unit tests. Bluetooth, USB pairing and the complete setup/OTA flow
must be validated on an iPhone and physical ESP32-S3; see
`../docs/HARDWARE_E2E.md`.
