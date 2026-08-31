# InputPilot 0.8.15

This patch release fixes a BLE regression in 0.8.14 that could disconnect or
destabilize the ESP32 when the app opened device details or sent commands.

## Highlights

- Prevent oversized encrypted BLE notifications from reaching the NimBLE
  stack.
- Send large management responses as compact encrypted binary records while
  retaining the existing text format for short responses.
- Restore the legacy `USB GET` response for older apps and use `USB GET2` for
  the complete manufacturer-aware identity.
- Let the iOS app decrypt both secure response formats transparently.
- Add regression coverage for the negotiated iOS ATT payload size.

Updating both the firmware and iOS app is recommended so the extended USB
identity and all larger management responses use the corrected protocol path.
