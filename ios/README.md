# InputPilot iOS companion

The iOS app supports Secure Protocol v2 devices only.

## Setup lifecycle

On a fresh install, the app guides the user through hardware preparation before
requesting Bluetooth access. The complete flow is:

1. Choose whether InputPilot is ready, the board needs firmware, or hardware
   still needs to be acquired. Review the supported board, USB data cable,
   iPhone USB adapter, and computer checklist. Unprepared boards get a separate
   installation guide with troubleshooting and the official
   [InputPilot Web Flasher](https://thorethy1.github.io/InputPilot/en/) for use
   with Chrome or Edge on a desktop computer. The link can be shared with the
   computer; installation must be explicitly confirmed before continuing.
2. Review Bluetooth and optional Local Network permissions, then establish
   trust through USB HID pairing.
3. Discover the same device identity over BLE and authenticate Secure Protocol v2.
4. Optionally send Wi-Fi credentials through that authenticated BLE session.
5. If Wi-Fi was selected, rediscover and authenticate the same identity over TCP.
6. Verify an authenticated control connection, pointer movement, and keyboard
   output. Choose the computer's keyboard layout before sending test text.

An eight-stage progress indicator follows the whole flow. **Later** opens the
app without marking setup complete; **Guided Setup** on the empty device screen
and **Settings → Setup & Connection Check** provide a way back. With saved
devices, the Settings entry checks the selected device. Exploring without a
device does not start Bluetooth discovery or Bonjour browsing.

Bluetooth-only setup is a complete supported path. Bluetooth is initialized only
when its setup step becomes visible; Local Network access is explained immediately
before optional Wi-Fi discovery. If the app exits after the device is saved but
before the physical HID checks finish, first-run setup resumes at the connection
test. Existing installations with a saved device skip the first-run experience.

Public HTTP is used only for discovery metadata. HID control, keyboard input,
presets, keep-awake settings, Wi-Fi configuration, USB identity, diagnostics,
management and OTA use authenticated BLE or Wi-Fi/TCP sessions.

Older firmware cannot be added. Reflash it over USB with the current merged
image, then run secure setup.

## Appearance and portal scripts

Lara's animated radial color washes are available throughout the app, including
setup and presented editors. **Settings → Appearance** controls dynamic
backgrounds and the Accent Color, Sand, Sage, Rose, Ocean, Lavender, and Graphite
palettes. A shared clock pauses outside the active scene; hidden backgrounds
stop requesting animation frames. Reduce Motion shows a static composition;
Reduce Transparency and Increased Contrast use a plain semantic background.

Wi-Fi portal script management is temporarily disabled because the workflows
are unreliable. Device Details shows this status instead of opening an editor.
The former script destination is inert: it creates no transport session and
does not poll, upload, edit, or run scripts. This app change does not modify
scripts already stored in firmware. Bluetooth and regular Wi-Fi setup remain
available.

## Build and test

Open `InputPilot.xcodeproj` in Xcode, select the InputPilot scheme and run the
app or its unit tests. Bluetooth, USB pairing and the complete setup/OTA flow
must be validated on an iPhone and physical ESP32-S3; see
`../docs/HARDWARE_E2E.md`.


## Apple Shortcuts and cold starts

Save and USB-pair the device in the app once, and grant Bluetooth/local-network
access there. After that, Shortcuts can connect without opening the app UI.
They wait up to 25 seconds for an authenticated transport permitted by the
connection-mode setting. Automatic/preferred modes can use either BLE or Wi-Fi;
Bluetooth-only and Wi-Fi-only modes require that specific transport.
Run Preset returns after the complete program is acknowledged and verified;
delays and key reports then continue autonomously on the ESP32.

BLE first retrieves the saved CoreBluetooth peripheral identifier. Background
scan fallback uses the control service UUID. This requires the updated firmware
advertisement (service UUID plus compact `IP` + six-byte identity in the primary
31-byte payload), as required by [Apple's background scanning rules](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html).
Update the app before updating the firmware: older apps cannot decode compact
identities. The updated app still discovers older firmware in the foreground
and can reconnect to its cached peripheral in the background.

Wi-Fi tries the saved IP and then the saved mDNS hostname. Each socket connection
attempt is bounded to four seconds, followed by a two-second retry delay;
secure authentication has its own timeout. HID commands are sent only after
secure authentication, and an interrupted command sequence is not replayed.
Shortcut connection/execution failures stop the shortcut with an error.

Physical cold-start validation is tracked in `../docs/HARDWARE_E2E.md`; simulator
unit tests alone do not establish background BLE/Wi-Fi reliability.
