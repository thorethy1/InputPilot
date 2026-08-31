# InputPilot 0.8.18

## Transport reliability

- BLE authentication timing now belongs to the Secure Protocol lifecycle. The
  bounded deadline starts when `secure begin` is processed, not while GATT
  discovery is still competing with an unavailable Wi-Fi network.
- Queued BLE handshake frames are drained before deadline expiry, and a secure
  session is valid only for the BLE connection generation that established it.
- Wi-Fi station retries, TCP session resets, and SoftAP fallback no longer
  change BLE authentication state. SoftAP periodically retries saved networks,
  allowing router recovery without rebooting the device.

## Unified protocol and provisioning

- BLE and Wi-Fi advertise one shared capability contract and feed authenticated
  requests into the same command router.
- Wi-Fi add/remove/clear operations return encrypted structured acknowledgements.
  `WIFI STATUS` reports provisioning failure separately from authentication,
  including `network_unreachable` for a failed station join.
- iOS serializes BLE secure request/reply operations, waits for the firmware
  acknowledgement instead of an arbitrary delay, reconnects after transient
  handshake transport timeouts, and reserves terminal authentication failure
  for rejected cryptographic proof.

## Validation

- All 86 native firmware tests pass.
- ESP32-S3 release firmware builds successfully and passes the OTA slot-size
  check with 414,624 bytes free.
- The physical Wi-Fi/BLE recovery matrix is documented in `HARDWARE_E2E.md` and
  remains a release gate on an ESP32-S3 and iPhone.
