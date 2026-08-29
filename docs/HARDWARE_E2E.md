# Secure Protocol v2 hardware validation

Record firmware/app commits, board ID, iPhone model/iOS version, access-point
model/security mode and pass/fail evidence. Compilation and simulators do not
replace this gate.

## Golden path

1. Erase flash and NVS, then install the v0.8.11 initial-flash image over USB.
2. Confirm public BLE and Soft-AP discovery report the same device ID and
   protocol 2 without exposing settings, logs or credentials.
3. Connect USB HID, hold BOOT for two seconds, capture `IPPAIR1`, and verify the
   Keychain identity equals discovery identity.
4. Complete BLE connection, GATT discovery, iOS BLE encryption/bonding and the
   Secure Protocol handshake. The UI must remain “Authenticating” until the
   server proof verifies.
5. Send home SSID/password over the encrypted BLE management record. Confirm
   neither value appears in app, serial or firmware logs.
6. Wait for mDNS rediscovery on the home LAN. Verify exact device-ID match and a
   fresh Secure Protocol handshake over TCP before setup completes.
7. Exercise mouse/trackpad, keyboard/layout input, presets/macros, Keep Awake,
   diagnostics, device settings, USB identity and reboot over BLE and Wi-Fi
   wherever the UI offers both.
8. Install a valid image by encrypted BLE OTA; verify inactive-slot selection,
   SHA-256/metadata validation, reboot, reconnect and installed version.
9. Repeat by encrypted Wi-Fi OTA and verify no HTTP OTA request is emitted.

## Recovery matrix

- Cancel USB capture, malformed frame and pairing-secret storage failure.
- Rotate the credential while BLE/TCP is connected; old sessions and old phone
  credentials must fail immediately, with no plaintext retry.
- Cancel iOS pairing, deny Bluetooth permission, toggle Bluetooth, remove the
  system bond, reconnect after backgrounding and power-cycle during discovery.
- Attempt connection with a stale iOS bond but current app secret. The app must
  consume `peerRemovedPairingInformation`, reconnect once and let iOS create a
  new bond without repeating USB trust. With a stale app secret, show
  actionable USB re-pair guidance instead.
- Supply wrong Wi-Fi password, unavailable SSID, captive portal, DHCP failure,
  mDNS failure and changed IP. Recovery must return to secure BLE provisioning
  and must never offer manual or unauthenticated device addition.
- Disconnect each transport during drag/macro; confirm release-all and no replay
  of stateful input on the other transport.
- Interrupt BLE and Wi-Fi OTA at start, 25%, 99%, verification and reboot.
  Previous firmware must remain bootable unless the verified boot partition was
  selected.
- Reject wrong SHA, size, version, product, board, protocol, OTA schema,
  out-of-order chunk, replayed secure record and concurrent second OTA owner.
- Attempt every removed endpoint and authentication form. HTTP provisioning,
  HTTP control/management/OTA, plaintext TCP commands and Nordic UART writes
  must be absent or rejected.
- Present protocol 0/1 metadata. The app must say that a manual USB firmware
  reflash is required and must not offer migration or compatibility setup.

## Long-run checks

- Alternate authenticated BLE/Wi-Fi input for 30 minutes while monitoring heap,
  queue depth, disconnect reasons and HID execution counters.
- Perform 50 BLE reconnects and 20 credential rotations; verify one shared
  CoreBluetooth session and no duplicate notification subscriptions.
- Run BLE and Wi-Fi OTA five times each, alternating slots.
- Verify credentials, secure plaintext, session keys and typed content never
  appear in diagnostics exports or logs.
