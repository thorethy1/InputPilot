# InputPilot 0.8.16

This release rebuilds the OTA hot path and improves recovery when Bluetooth and
Wi-Fi are active at the same time.

## Highlights

- Wi-Fi OTA now uses authenticated binary frames with 2 KiB firmware chunks
  and a 32 KiB cumulative acknowledgement window. Older counterparts remain
  compatible through the existing text transfer modes.
- BLE OTA no longer performs AES-GCM work inside NimBLE callbacks. Incoming
  records enter bounded queues and are decrypted and written from the firmware
  loop, preventing host-task starvation and resets during sustained transfers.
- BLE negotiates a large ATT MTU, requests stable low-latency connection
  parameters, and reconnects a previously discovered peripheral without first
  waiting for another scan cycle.
- Secure management requests are serialized. USB identity and configured Wi-Fi
  network reads also fall back to the authenticated Wi-Fi connection if BLE is
  temporarily unavailable.
- Interrupted Wi-Fi OTA sessions release the shared update engine immediately,
  allowing a clean retry.

Both the firmware and iOS app must be updated to use binary Wi-Fi OTA. The first
update from an older firmware remains compatible and uses its supported mode.
