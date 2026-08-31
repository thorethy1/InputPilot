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
- BLE deliberately creates no separate iOS/NimBLE bond. Secure Protocol v2
  provides authenticated encryption directly, so flashing and USB trust
  rotation cannot leave conflicting link-layer pairing databases behind.
- A BLE connection has 15 seconds to authenticate. The first connection owns
  the session exclusively; another central cannot reset it, submit control or
  OTA writes, or receive session notifications.
- Wi-Fi provisioning now changes from Soft-AP to STA asynchronously while BLE
  remains responsive. The authenticated BLE session reports the assigned STA
  address, allowing the app to verify Secure Protocol over TCP even when a
  router delays or filters mDNS.
- Public BLE metadata discovery now completes its CoreBluetooth disconnect
  before handing the device to the secure connection manager, preventing two
  app-owned centrals from racing for the firmware's single session owner.
- Public BLE discovery metadata is bounded below the 512-byte GATT value limit.

Devices running older firmware must be reflashed over USB before they can be
added to this app.
