# Known limitations

- The friendly MAC-derived Soft-AP (for example `InputPilot-Dupe9`) is **open** unless you set
  `WIFI_AP_PASS`. Multiple boards on the same LAN get distinct SSIDs and mDNS
  names (`inputpilot-xxxx.local`). The network grants no control access:
  sensitive operations still require Secure Protocol v2.
- USB VID/PID (`0xCAFE` / `0x4001`) are hobbyist IDs, not USB-IF assigned.
- Flashing requires manual **BOOT+RESET**, then a **power-cycle** for HID
  enumeration (OTG auto-reset is unreliable).
- On-device pytest E2E (HID cursor / keystroke proof) is **macOS-only**.
- WiFi and BLE share the ESP32-S3's 2.4 GHz radio and can run concurrently in
  `wifi+ble` mode; throughput and latency still depend on local radio conditions.
- BLE teardown deliberately avoids `NimBLEDevice::deinit()` (upstream crash on
  Arduino-ESP32 3.2.x / IDF 5.4).
- BLE security is owned by the USB-trusted Secure Protocol session; the app
  deliberately does not create a separate iOS/NimBLE bond.
