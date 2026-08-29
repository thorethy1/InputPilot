# InputPilot 0.8.11

This release introduces Secure Protocol v2 and intentionally breaks
compatibility with older firmware.

- USB HID pairing is the only way to establish initial trust.
- Bluetooth and Wi-Fi/TCP carry directionally keyed AES-256-GCM sessions for
  control, configuration, management, diagnostics and OTA.
- Wi-Fi credentials are sent only through an authenticated Bluetooth session;
  setup saves the device only after authenticating the same identity on the
  home network.
- Token authentication, writable HTTP APIs, manual address setup, NUS control
  and compatibility fallbacks have been removed.
- OTA uses the active secure session on both Bluetooth and Wi-Fi and retains
  board, protocol, size, offset and SHA-256 validation.
- A stale iOS BLE bond after a fresh flash or USB trust rotation is recovered
  once through CoreBluetooth before secure authentication continues.

Devices running older firmware must be reflashed over USB before they can be
added to this app.
