# InputPilot HID Control Protocol v1

This protocol carries semantic HID events from a trusted phone to the ESP32-S3. The firmware turns them into USB HID reports; it never captures input from the attached computer. BLE and persistent TCP share the encrypted command sink. REST remains available only to unpaired legacy installations and for minimal paired-device discovery.

## Security and discovery

Paired v0.8.7 devices use the secure channel described below and reject legacy plaintext control. `CONTROL_API_TOKEN` remains an upgrade-only option for devices that have not yet been paired. It authenticates but does not encrypt legacy traffic.

The firmware advertises `_http._tcp` over mDNS and the BLE services below. `GET /api/status` and BLE OTA Status both report protocol and capabilities, so BLE-only clients do not depend on REST.

## Semantic events

| Event | Text/TCP command | REST |
|---|---|---|
| Mouse move | `move <dx> <dy>` | `POST /api/move` |
| Scroll | `move 0 0 <delta>` | `POST /api/move` |
| Button down/up | `button <left/right/middle> <down/up>` | `POST /api/button` |
| Click | `click <button>` | `POST /api/click` |
| Text | `type <UTF-8 text>` | `POST /api/type` |
| Key/combo | `key <name[+name...]>` | `POST /api/key` |
| Layout-resolved key | `report <modifiers:u8> <usage:u8>` | `POST /api/report` |
| Release all | `release all` | `POST /api/release-all` |

## Keep Awake v2

Firmware capability `keep_awake_v2` means movement and clicking are independent,
persistent schedules. Both continue without a connected client and restore from
NVS after restart. Valid intervals are 5,000 through 3,600,000 milliseconds.

| Setting | BLE/TCP text command | REST |
|---|---|---|
| Movement enabled | `jiggle on\|off` | `POST /api/keep-awake` |
| Movement interval | `jiggle interval <ms>` | `POST /api/keep-awake` |
| Click enabled | `autoclick on\|off` | `POST /api/keep-awake` |
| Click interval | `autoclick interval <ms>` | `POST /api/keep-awake` |

`GET /api/keep-awake` returns `move_enabled`, `move_interval_ms`,
`click_enabled`, and `click_interval_ms`. `/api/jiggle` remains compatible with
older clients and changes only movement enablement.

## Secure pairing and encrypted control

Capability `secure_channel_v1` indicates v0.8.7-or-newer pairing and encrypted control.
The `IPPAIR1` USB frame carries a 128-bit credential associated with the
12-character device ID. iOS stores it in Keychain; firmware stores it in NVS.

BLE and TCP start with `secure begin`. Firmware returns
`secure challenge 1 <device-id> <server-nonce>`. The app replies with
`secure hello <client-nonce> <hmac>`, and firmware confirms with
`secure ready <hmac>`. HMAC-SHA-256 covers the protocol direction, device ID,
and both nonces. HKDF-SHA-256 with both nonces as salt and
`InputPilot secure channel v1` as info derives the AES-256-GCM key.

Binary BLE records are `0xA1 || counter_be64 || ciphertext || tag_128`. TCP uses
the equivalent hexadecimal `secure data` line. The AES-GCM nonce is
`IPC || 0x01 || counter_be64`, and the lowercase device ID is authenticated
additional data. Counters must increase strictly within a session.
Capability `secure_wifi_setup_v1` adds an authenticated BLE management payload.
Inside an encrypted binary record it is `0xFE || 0x01 || ssid_length:u8 ||
password_length:u8 || ssid_utf8 || password_utf8`. Firmware accepts this marker
only after decrypting a paired session. The compact length-prefixed form fits a
maximum 32-byte SSID and 63-byte password in one common iOS ATT write and
preserves spaces without placing credentials on the legacy text channel.
Capability `secure_usb_identity_v1` adds two more encrypted management records:
`0xFE || 0x02` restores USB defaults, while
`0xFE || 0x03 || vid_le16 || pid_le16 || product_length:u8 ||
serial_length:u8 || product_ascii || serial_ascii` saves a validated USB
identity. Both operations schedule a restart so USB re-enumerates; the default
serial remains the stable 12-character MAC-derived device ID.
After normal USB enumeration, holding BOOT for two seconds types a fixed-length
`IPPAIR1` frame through USB HID. The frame carries device ID, a fresh 128-bit
hexadecimal pairing credential, and a corruption checksum. Firmware omits the
credential from logs. See `docs/SECURE_PAIRING_DESIGN_0.8.6.md` for the staged
enforcement design.

TCP listens on port 3333 and is persistent. Handshake and encrypted records are UTF-8 lines ending in LF. A disconnect clears the session key and releases all held keys, modifiers, and mouse buttons.

`report` is the v0.6 layout boundary. The client maps each Unicode character for the selected host layout to a USB HID usage and modifier byte (including right Alt/AltGr bit `0x40`), then sends one report. The firmware presses and releases that report; it does not interpret UTF-8 as HID key codes. Legacy `type` and `key` remain supported. Multiline and long input is emitted as ordered per-character reports (newline becomes Enter), so neither TCP line framing nor BLE MTU splits UTF-8.

## BLE GATT

The primary service UUID is `7d9f0001-4f4d-4f56-4552-484944000001`.

| Characteristic | UUID suffix | Properties | Use |
|---|---:|---|---|
| Control | `0002` | Write / Write Without Response | release-all, ping |
| Mouse | `0003` | Write / Write Without Response | move, scroll, buttons |
| Keyboard | `0004` | Write / Write Without Response | text, keys, combos |
| Status | `0005` | Read / Notify | protocol status |

The Nordic UART Service remains available for 0.4.x-compatible text commands and authentication. Authentication is written to NUS RX only after NUS TX notifications are enabled; its confirmation arrives on NUS TX. Integer fields are little-endian. Every binary frame begins with protocol version `0x01`, followed by type and payload:

| Type | Value | Payload |
|---|---:|---|
| MouseMove | `01` | `dx:i16, dy:i16` |
| MouseScroll | `02` | `delta:i16` |
| MouseButtonDown | `03` | `button:u8` |
| MouseButtonUp | `04` | `button:u8` |
| MouseClick | `05` | `button:u8` |
| KeyboardText | `10` | UTF-8 bytes |
| KeyboardKey | `11` | UTF-8 key name |
| KeyboardCombo | `12` | UTF-8 `+`-separated names |
| KeyboardReport | `13` | `modifiers:u8, usage:u8` |
| ReleaseAll | `20` | none |
| Ping | `7f` | none |

Buttons are `0=left`, `1=right`, `2=middle`. Frames exceeding the negotiated BLE MTU must be split at the semantic-event layer; long text and large macro streams should use TCP. Invalid versions, lengths, types, buttons, or unauthenticated binary events are rejected.

The manufacturer-data payload is UTF-8 `IP<device_id>`. Clients compare the complete normalized ID and must not connect to the first device merely sharing the service UUID. Repeated advertisements are deduplicated by device ID. Older firmware without this identity is still usable over TCP/REST, but cannot be selected safely by BLE when multiple devices are present.

## Capabilities

Protocol v1 firmware reports only implemented features: `mouse_move`, `mouse_click`, `mouse_button_state`, `mouse_scroll`, `keyboard_type`, `keyboard_key`, `keyboard_layout`, `release_all`, `ble_control`, `tcp_control`, `rest_control`, and `protocol_v1`. Clients treat an absent/empty list as legacy capability information; when a non-empty list is present they disable unsupported controls rather than sending them blindly.

## Transport selection

Automatic mode prefers BLE for latency-sensitive events and TCP for long text or macro streams; REST is the management/fallback path. `Prefer Bluetooth`, `Prefer Wi-Fi`, `Bluetooth Only`, and `Wi-Fi Only` constrain this order. A drag, keyboard sequence, text send, preset, or macro leases one ready transport for its ordered lifetime. Loss of that transport aborts the sequence and attempts release-all; failover is allowed only for a later independent sequence.
# BLE OTA protocol v1

InputPilot extends its existing NimBLE server with service `7d9f1001-4f4d-4f56-4552-484944000001` and Control (`...1002`, write-with-response), Data (`...1003`, write-without-response), and Status (`...1004`, read/notify) characteristics. Status is readable before authentication for onboarding and contains `product`, `board`, `deviceId`, `deviceName`, `firmware`, `protocol`, `otaSchema`, `capabilities`, and `authRequired`, plus OTA state/progress fields. The existing NUS authentication command must succeed before Control or Data is accepted.

The client writes `START protocol=1 version=<semver> size=<bytes> sha256=<64 lowercase hex>` to Control. The device validates OTA schema, target slot, protocol, size, and authentication, calls `esp_ota_begin`, then notifies `READY` with `maxChunk` and `windowSize`. Each Data value begins with a four-byte little-endian absolute offset followed by image bytes. Offsets must be contiguous; Status emits ACKs containing the durable received offset. End-of-file is determined only by the declared size and explicit `FINISH`, never by a short BLE packet.

On FINISH the device verifies byte count and streaming SHA-256, parses embedded InputPilot firmware metadata, and rejects a wrong product, board, protocol, schema, or target version. It then calls `esp_ota_end`, and only after every validation succeeds calls `esp_ota_set_boot_partition`. Status transitions through `VERIFYING`, `INSTALLING`, `SUCCESS`, and `REBOOTING`. `ABORT`, disconnect, timeout, write error, invalid offset, metadata mismatch, or checksum mismatch calls `esp_ota_abort` and leaves the installed partition active. Partial-transfer resume is not part of protocol v1.

SHA-256 supplies transport/file integrity, not cryptographic signing or publisher authenticity.
