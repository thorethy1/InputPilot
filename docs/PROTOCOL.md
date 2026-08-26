# InputPilot Control Protocol v1

This protocol carries semantic HID events from a trusted phone to the ESP32-S3. The firmware turns them into USB HID reports; it never captures input from the attached computer. BLE, persistent TCP, and REST share the same command sink.

## Security and discovery

Control is local-only. Set `CONTROL_API_TOKEN` at firmware build time. REST uses `X-API-Token` or `Authorization: Bearer`; TCP and the legacy BLE control characteristic authenticate once with `auth <token>`. Binary BLE events are rejected until that session is authenticated. Use BLE pairing/bonding and an API token on deployed devices.

The firmware advertises `_http._tcp` over mDNS and the BLE services below. `GET /api/status` reports `protocol_version` and `capabilities`, allowing clients to fall back for firmware before 0.5.0.

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

TCP listens on port 3333 and is persistent. Commands are UTF-8 lines ending in LF. A disconnect releases all held keys, modifiers, and mouse buttons.

`report` is the v0.6 layout boundary. The client maps each Unicode character for the selected host layout to a USB HID usage and modifier byte (including right Alt/AltGr bit `0x40`), then sends one report. The firmware presses and releases that report; it does not interpret UTF-8 as HID key codes. Legacy `type` and `key` remain supported. Multiline and long input is emitted as ordered per-character reports (newline becomes Enter), so neither TCP line framing nor BLE MTU splits UTF-8.

## BLE GATT

The primary service UUID is `7d9f0001-4f4d-4f56-4552-484944000001`.

| Characteristic | UUID suffix | Properties | Use |
|---|---:|---|---|
| Control | `0002` | Write / Write Without Response | release-all, ping |
| Mouse | `0003` | Write / Write Without Response | move, scroll, buttons |
| Keyboard | `0004` | Write / Write Without Response | text, keys, combos |
| Status | `0005` | Read / Notify | protocol status |

The Nordic UART Service remains available for 0.4.x-compatible text commands and authentication. Integer fields are little-endian. Every binary frame begins with protocol version `0x01`, followed by type and payload:

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

The manufacturer-data payload is UTF-8 `IP<device_id>`. Clients compare the complete normalized ID and must not connect to the first device merely sharing the service UUID. Older firmware without this identity is still usable over TCP/REST, but cannot be selected safely by BLE when multiple devices are present.

## Capabilities

Protocol v1 firmware reports only implemented features: `mouse_move`, `mouse_click`, `mouse_button_state`, `mouse_scroll`, `keyboard_type`, `keyboard_key`, `keyboard_layout`, `release_all`, `ble_control`, `tcp_control`, `rest_control`, and `protocol_v1`. Clients treat an absent/empty list as legacy capability information; when a non-empty list is present they disable unsupported controls rather than sending them blindly.

## Transport selection

Automatic mode prefers BLE for latency-sensitive events and TCP for long text or macro streams; REST is the management/fallback path. `Prefer Bluetooth`, `Prefer Wi-Fi`, `Bluetooth Only`, and `Wi-Fi Only` constrain this order. Presets, recording, playback, and live controls all emit the same semantic events.
