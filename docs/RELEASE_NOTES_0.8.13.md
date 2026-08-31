# InputPilot 0.8.13

This release makes device identity visible, accelerates firmware updates over
Wi-Fi, and adds an AltStore update source for the iOS companion.

- Device details now read and display the USB serial number actually configured
  in firmware. The USB identity editor is populated over authenticated Wi-Fi or
  Bluetooth instead of starting with an empty serial number.
- New app and firmware pairs negotiate a windowed Wi-Fi OTA transfer with
  cumulative 4 KiB acknowledgements. Older app/firmware combinations continue
  to use the compatible per-chunk acknowledgement flow.
- Bluetooth OTA retains its existing flow-controlled 500-byte transfer path;
  hardware throughput remains part of the release-candidate checklist.
- `firmware.bin` remains the stable app-only OTA asset. `InitialFirmware.bin`
  and `InputPilot-Firmware-v0.8.13.zip` remain the USB installation/recovery
  choices.
- Tagged releases now include `altstore-source.json`, pointing to the validated
  public unsigned IPA for installation and automatic updates through AltStore
  Classic.
- Device rows now distinguish online/offline state and show whether the live
  connection is Wi-Fi plus Bluetooth, Wi-Fi only, or Bluetooth only. The
  unhelpful generic “Bluetooth is on” row is no longer shown.

Secure Protocol v2 and OTA schema 1 remain unchanged.
