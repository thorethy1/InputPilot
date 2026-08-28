# Known limitations

- **No auth by default** on Soft-AP, HTTP, TCP, or BLE control (open Soft-AP,
  unauthenticated REST/TCP). See root `SECURITY.md` when present.
- Soft-AP `InputPilot-XXXX` (per-device suffix) is **open** unless you set
  `WIFI_AP_PASS`. Multiple boards on the same LAN get distinct SSIDs and mDNS
  names (`inputpilot-xxxx.local`); use `device_id` from `/api/status` or
  `/api/wifi` to tell them apart.
- USB VID/PID (`0xCAFE` / `0x4001`) are hobbyist IDs, not USB-IF assigned.
- Flashing requires manual **BOOT+RESET**, then a **power-cycle** for HID
  enumeration (OTG auto-reset is unreliable).
- On-device pytest E2E (HID cursor / keystroke proof) is **macOS-only**.
- WiFi and BLE share the ESP32-S3's 2.4 GHz radio and can run concurrently in
  `wifi+ble` mode; throughput and latency still depend on local radio conditions.
- BLE teardown deliberately avoids `NimBLEDevice::deinit()` (upstream crash on
  Arduino-ESP32 3.2.x / IDF 5.4).
- BLE control uses application-token confirmation but does not implement BLE
  cryptographic pairing or bonding.
