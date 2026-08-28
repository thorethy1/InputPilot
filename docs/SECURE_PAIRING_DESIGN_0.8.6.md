# InputPilot v0.8.6 secure pairing design

## Status

This document is the implementation design for secure onboarding. v0.8.6 starts
with a hardware input proof and capability-gated protocol work. Authentication
and encryption must not become mandatory until the physical iPhone tests in
this document pass. The existing `CONTROL_API_TOKEN` behavior remains in place
during this development stage and must not be described as encryption.

## First trust

InputPilot generates a fresh 128-bit, single-use secret with the ESP32 hardware
random-number generator. It is represented as 32 uppercase hexadecimal
characters. A pairing frame contains:

1. the fixed `IPPAIR1` marker;
2. the 12-character device ID;
3. the 32-character one-time secret;
4. an 8-character corruption checksum; and
5. Enter.

The secret is emitted only after the BOOT button is held for two seconds after
normal USB startup. It is never advertised, returned by BLE or Wi-Fi, or written
to firmware/app logs. The development-only `pairtest` serial command emits the
same kind of HID frame for repeatable testing.

Two retrieval paths are required:

- Connect InputPilot to a computer, focus a text editor, hold BOOT, then copy or
  manually transfer the typed value to the iPhone.
- Connect InputPilot directly to an iPhone, open Settings → USB Pairing Input
  Test, and hold BOOT. UIKit receives InputPilot as a physical USB keyboard and
  validates the frame without retaining the secret.

The v0.8.6 input-test screen validates transport and framing only. It does not
save trust or enable mandatory authentication.

## Target cryptographic exchange

After the USB input proof passes, the iPhone and firmware will exchange
ephemeral P-256 public keys over BLE. The one-time USB secret authenticates the
complete transcript with HMAC-SHA-256. HKDF-SHA-256 derives directional session
keys. A successful exchange pins the device identity key in iOS Keychain and
stores the phone public key on the device. The temporary secret is erased after
success, timeout, reboot, or too many failed attempts.

A short numeric PIN is intentionally not used: without a reviewed PAKE it would
permit offline guessing if an attacker captured the transcript. The 128-bit
typed value has enough entropy to authenticate the exchange directly.

## Target transports

- BLE: LE Secure Connections and bonding plus application-level authenticated
  encryption, unique nonces, monotonically increasing counters, and replay
  rejection. Advertising and minimal discovery identity remain public.
- Wi-Fi REST: HTTPS with a per-device certificate/key created on the device.
  The iOS app pins the device identity learned during USB-authenticated pairing.
- Wi-Fi stream control: TLS or an authenticated-encryption record layer before
  plaintext TCP control is disabled.
- Secrets: iOS Keychain and protected device storage. No compile-time API key.

No input, OTA data, credentials, diagnostics, or management settings may use an
unauthenticated plaintext channel after secure mode becomes mandatory.

## Rollout gates

1. Validate USB HID capture on physical USB-C iPhones and documented adapters.
2. Validate the computer text-editor path and the BOOT-button timing.
3. Add key exchange behind a new advertised capability; keep legacy access
   available for recovery during development.
4. Add encrypted BLE records and pinned TLS; test replay and wrong-device cases.
5. Test upgrade, lost-phone, trust reset, and interrupted-pairing recovery.
6. Only then remove the optional unauthenticated default and compile-time token.

## Hardware test record

| Test | Result | Notes |
|---|---|---|
| USB-C iPhone powers and enumerates InputPilot | NOT RUN | Required before enforcement |
| Pairing screen receives one complete frame | NOT RUN | Secret must not enter logs |
| Computer text editor receives one complete frame | NOT RUN | Test common host layouts |
| Two-second BOOT hold emits once per press | NOT RUN | Holding BOOT during plug-in enters bootloader; press after startup |
| Invalid/truncated frame is rejected | NOT RUN | No credential retained |

