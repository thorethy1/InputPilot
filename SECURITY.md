# InputPilot security model

InputPilot 0.8.11 uses one device identity, one USB-established trust secret and
one authenticated Secure Protocol v2 across Bluetooth and Wi-Fi/TCP.

## Trust and sessions

- Initial trust is created only through the physical USB HID pairing exchange.
- The pairing secret is stored in firmware NVS and the iOS Keychain.
- BLE and Wi-Fi/TCP perform a mutual challenge/response handshake before any
  sensitive command is accepted.
- Direction-specific AES-256-GCM keys and monotonic counters protect every
  application record. Replayed, modified or unauthenticated records are rejected.
- A failed handshake never selects another protocol or an unencrypted endpoint.

HTTP and Bonjour expose only the minimum metadata required to discover and
identify a device. They cannot provision Wi-Fi, control HID, change settings,
read diagnostics, manage the device or install firmware.

## OTA

BLE and Wi-Fi OTA use the established Secure Protocol session. The firmware
also validates product, board, protocol/schema, declared size, contiguous
offsets and SHA-256 before selecting the new boot partition. Abort, timeout,
disconnect or validation failure leaves the running image selected.

SHA-256 detects transfer corruption; the current release format does not yet
provide publisher signatures. Only install firmware obtained from the official
InputPilot release channel.

## Recovery

Clearing trust, changing hardware or using pre-v2 firmware requires USB pairing
or a full USB reflash. There is intentionally no compatibility or insecure mode.

Report vulnerabilities privately to the maintainers and do not include pairing
secrets, Wi-Fi credentials, typed content or diagnostic exports in public issues.
