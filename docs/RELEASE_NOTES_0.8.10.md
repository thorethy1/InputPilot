# InputPilot 0.8.10

InputPilot 0.8.10 is an OTA reliability hotfix for securely paired devices.
The iOS app no longer attempts plaintext Wi-Fi REST OTA after pairing. Updates
from firmware 0.8.8 and 0.8.9 use smaller, paced Bluetooth packets to avoid
overloading their legacy BLE receivers.

Firmware 0.8.10 moves partition erase, flash writes, verification, completion,
abort, and disconnect cleanup out of NimBLE callbacks. Bluetooth callbacks now
only copy commands and data into bounded queues, while the normal firmware loop
performs the expensive OTA work. A smaller advertised acknowledgement window
keeps the phone's in-flight data within that queue.

The updated iOS app uses the conservative Bluetooth path when upgrading 0.8.8
or 0.8.9. If one of those installed versions resets while handling the initial
OTA command, USB remains the recovery path because an app update cannot replace
code that is already running on the device. Once 0.8.10 is installed, subsequent
Bluetooth updates use the queued receiver. Paired devices intentionally continue
to reject plaintext REST OTA.
