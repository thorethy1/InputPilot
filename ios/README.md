# InputPilot iOS companion

The iOS app supports Secure Protocol v2 devices only.

## Setup lifecycle

1. Discover the InputPilot over BLE.
2. Establish trust through USB HID pairing.
3. Authenticate the BLE Secure Protocol session.
4. Send Wi-Fi credentials through that encrypted session.
5. Rediscover the same device identity on the home network.
6. Authenticate its Wi-Fi/TCP Secure Protocol session and save the device.

Public HTTP is used only for discovery metadata. HID control, keyboard input,
presets, keep-awake settings, Wi-Fi configuration, USB identity, diagnostics,
management and OTA use authenticated BLE or Wi-Fi/TCP sessions.

Older firmware cannot be added. Reflash it over USB with the current merged
image, then run secure setup.

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
