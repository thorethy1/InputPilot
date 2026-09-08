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
4. Complete BLE connection, GATT discovery and the Secure Protocol handshake.
   Confirm iOS creates no system bond and the UI remains “Authenticating” until
   the server proof verifies.
5. Send home SSID/password over the encrypted BLE management record. Confirm
   neither value appears in app, serial or firmware logs. Confirm BLE remains
   authenticated and responsive throughout the non-blocking STA join.
6. Wait for mDNS rediscovery on the home LAN. Verify exact device-ID match and a
   fresh Secure Protocol handshake over TCP before setup completes. Repeat with
   mDNS blocked and verify the secure BLE-to-STA-address handoff still succeeds.
7. Exercise mouse/trackpad, keyboard/layout input, presets/macros, Keep Awake,
   diagnostics, device settings, USB identity and reboot over BLE and Wi-Fi
   wherever the UI offers both. Set a non-default USB serial number, reopen
   device details, and verify the value is read back over each transport.
8. Install a valid image by encrypted BLE OTA; verify inactive-slot selection,
   SHA-256/metadata validation, reboot, reconnect and installed version.
9. Repeat by encrypted Wi-Fi OTA and verify no HTTP OTA request is emitted.
   Record image size, negotiated window/chunk, total transfer time, and average
   bytes per second. Confirm 0.8.13 negotiates the windowed path and compare it
   with the legacy one-ACK-per-128-byte baseline.
10. In the device list, verify live states for Wi-Fi plus Bluetooth, Wi-Fi only,
    Bluetooth only, and offline. Turning off iOS Bluetooth must remove the BLE
    path without hiding a still-working Wi-Fi path.

## Recovery matrix

- Cancel USB capture, malformed frame and pairing-secret storage failure.
- Rotate the credential while BLE/TCP is connected; old sessions and old phone
  credentials must fail immediately, with no plaintext retry.
- Deny Bluetooth permission, toggle Bluetooth, reconnect after backgrounding
  and power-cycle during discovery. No iOS pairing prompt may appear.
- Upgrade a phone that still has a bond from an older build; forgetting that
  obsolete system bond must be a one-time transition only. A stale application
  secret must show actionable USB re-pair guidance.
- Delay GATT discovery for longer than 15 seconds while Wi-Fi scans. The BLE
  link must remain connected because no authentication attempt has started.
  Then send `secure begin` without a valid `secure hello`; the ESP32 must
  disconnect that central after the bounded protocol-authentication window,
  remain responsive and advertise again.
- While one phone has an authenticated BLE session, connect a second central.
  The first session and an active BLE OTA must continue unchanged; the second
  central must be disconnected and its writes ignored.
- Supply wrong Wi-Fi password, unavailable SSID, captive portal, DHCP failure,
  mDNS failure and changed IP. The authenticated BLE session must remain usable,
  `WIFI STATUS` must report a provisioning-specific failure, and recovery must
  never offer manual or unauthenticated device addition.
- Boot in Wi-Fi+BLE mode with every saved network unavailable. Establish and
  use the full Secure Protocol over BLE before, during, and after SoftAP
  fallback; there must be no repeating authentication-deadline disconnect.
  Restore the router and verify the periodic station retry reconnects Wi-Fi
  without rebooting or resetting the established BLE session.
- Add a valid and an invalid network over BLE. In both cases verify the
  encrypted management acknowledgement arrives before radio transition. The
  valid network must connect; the invalid network must return
  `network_unreachable`, while subsequent BLE commands continue to work.
- Drop Wi-Fi during an authenticated dual-transport session, exercise BLE HID
  and management throughout reconnect attempts, then restore Wi-Fi and verify
  a fresh TCP handshake without BLE renegotiation.
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
- Open device details and reload USB identity plus the configured Wi-Fi list 50
  times over BLE-only mode. The USB serial must populate every time, the ESP32
  must not reset, and diagnostics must show neither queue overflow nor secure
  response timeout.
- Run BLE and Wi-Fi OTA five times each, alternating slots. Record negotiated
  BLE ATT payload, ACK window, queue errors, elapsed time, and throughput for
  every run; do not increase BLE queue/window constants without these results.
- On 0.8.16 peers, confirm Wi-Fi logs `flow=binary`, completes the transfer in
  at most five seconds on a normal local 802.11n network, and reports a final
  cumulative ACK before verification.
- Repeat BLE OTA with both a large (roughly 500-byte) and a smaller (roughly
  150-byte) negotiated firmware payload. Confirm neither queue overflow nor a
  disconnect occurs through at least five complete images.
- Verify credentials, secure plaintext, session keys and typed content never
  appear in diagnostics exports or logs.


## Apple Shortcuts cold-start regression matrix

Use the updated iOS app and firmware. Complete USB pairing and grant Bluetooth
and local-network permissions once. Record iOS/app/firmware versions, elapsed
connection time, transport and the exact shortcut result for each run.

- Run Connect Device → Send Text → Send Keyboard Shortcut and a multi-step
  preset without opening InputPilot first. Repeat with the app suspended,
  terminated, and after an iPhone reboot and first unlock. Check that text and
  key combinations arrive exactly once and in order.
- Repeat in BLE-only mode with Wi-Fi unavailable, Wi-Fi-only mode with Bluetooth
  off, and Automatic with each radio unavailable in turn. A ready excluded
  transport must not count as successful connection.
- BLE: keep the saved device/trust but remove its
  `inputpilot.blePeripheral.<deviceId>` preference in a development build to
  force discovery. Start a shortcut in the background; verify a filtered scan
  finds the compact identity and finishes authentication. Repeat after an
  ESP32 restart and with a stale cached peripheral identifier.
- BLE: start a foreground scan, background the app, then run a shortcut;
  verify scanning switches to the service-filtered background path.
- Wi-Fi: change the ESP32 DHCP address, retaining the old IP in the saved
  device. With BLE off, verify the old socket attempt expires and the saved
  mDNS hostname connects. Also test a direct IP/VPN endpoint without mDNS.
- Make both transports unreachable: the shortcut must fail within its bounded
  connection wait, and later shortcut actions must not run. Restore the device
  and run again. Cancel during the connection wait and while runs are queued;
  cancelled work must not type later.
- Start several shortcuts rapidly: sequences must remain serialized. Drop the
  active transport halfway through a preset; verify failure without replaying
  the sequence on the other transport.
- Upgrade order: updated app + old firmware must still discover in the
  foreground and reconnect through a cached identifier; then update firmware
  and verify background discovery without the cached identifier.


## BLE reconnect after prolonged inactivity and AP status LED

- Leave the ESP32 running with no controller connected for at least 30 minutes,
  including fallback AP mode with the configured router unavailable. Reconnect
  over BLE without rebooting either device. Repeat with the iOS app terminated.
  Verify the connection progresses through authentication to Ready and input
  works, without cycling through reconnect/connect/authenticate indefinitely.
- In a development build, force the BLE notification payload to 20 bytes (ATT
  MTU 23). Both the 64-byte challenge and 77-byte server proof must arrive in
  order and authenticate. Restore normal MTU and repeat. Temporarily reject
  notification sends to verify backpressure retries resume at the same offset.
- Disconnect halfway through a fragmented reply, reconnect, and verify no
  fragment from the previous connection reaches the new handshake. On failure,
  capture serial BLE logs and the app's Bluetooth logs before rebooting.
- With AP enabled, check 180 ms of violet every four seconds, followed by the
  normal state: connected blue, Keep Awake cyan, ready green. An AP available
  for control counts as radio-ready even without a router or BLE. OTA retains
  its uninterrupted amber pattern. Turn off the AP and verify violet stops.

Update the app before firmware when testing handshake fragmentation. Whole
handshake replies at a sufficiently large MTU remain compatible with older apps;
small-MTU fragmented replies require the updated app.
