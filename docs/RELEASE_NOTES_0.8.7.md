# InputPilot 0.8.7

InputPilot 0.8.7 activates secure pairing after the successful physical iPhone
USB-input test. Holding BOOT for two seconds now generates a fresh 128-bit
credential, saves it in device NVS, and types a checksum-protected pairing frame.
The iOS pairing screen validates that frame and stores the credential in the
this-device-only Keychain rather than in the app database.

BLE and Wi-Fi/TCP control sessions use a mutually authenticated HMAC-SHA-256
handshake. HKDF-SHA-256 derives a fresh session key from independent client and
device nonces. Every control record is protected with AES-256-GCM and a strictly
increasing counter; invalid tags and replayed records are rejected. BLE control
characteristics additionally require an encrypted LE Secure Connections link.

Once a device is paired, plaintext REST endpoints no longer accept control,
configuration, Wi-Fi credentials, diagnostics, or OTA traffic. Minimal status
metadata remains readable for local discovery. BLE OTA continues over the
authenticated and link-encrypted BLE session. The older compile-time API token
remains available only for upgrading unpaired installations.

The public release workflow no longer expects Android artifacts. Android stays
archived while development focuses on iOS. Public releases contain firmware,
the initial-flash package, and the unsigned iOS archive; the signed IPA remains
in the private draft release.

Hardware validation is still required for the complete secure handshake on a
physical ESP32-S3 and iPhone before removing all legacy upgrade paths.
