# InputPilot Secure Protocol v2

InputPilot has one device identity, one USB-established trust secret and one
application protocol. BLE and Wi-Fi are transports for that protocol; neither
transport grants access merely because a link or socket is connected.

## Lifecycle

1. Public BLE manufacturer data and mDNS/HTTP discovery expose only product,
   firmware/protocol versions, the 12-hex device ID and secure TCP port.
2. Holding BOOT while connected over USB HID rotates a random 128-bit secret
   and types an `IPPAIR1` frame. Firmware invalidates every active session.
3. A transport starts `secure begin`; the device returns an authenticated
   nonce challenge; the client proves the USB secret and device ID.
4. HKDF-SHA-256 derives separate client-to-device and device-to-client
   AES-256-GCM keys. Every record has a strictly increasing 64-bit counter.
5. Setup, HID control, settings, diagnostics, management and OTA are accepted
   only while that concrete transport session is established.

There is no token authentication, plaintext control, open provisioning write,
or compatibility negotiation. Protocol versions other than 2 require a manual
firmware reflash.

## Handshake and records

The handshake is line framed on TCP and UTF-8 framed on the BLE Control
characteristic:

- client: `secure begin`
- device: `secure challenge 1 <device-id> <server-nonce-hex>`
- client: `secure hello <client-nonce-hex> <client-proof-hex>`
- device: `secure ready <server-proof-hex>`

Proofs are HMAC-SHA-256 over the direction label (`IPSEC1-C` or `IPSEC1-S`),
device ID and both nonces. The version-1 handshake spelling is retained only as
the trust bootstrap grammar; it does not indicate protocol compatibility.

HKDF salt is `server_nonce || client_nonce`. Info is
`InputPilot secure protocol v2 client` for client-to-device and
`InputPilot secure protocol v2 server` for device-to-client.

Binary records are `0xA1 || counter_be64 || ciphertext || tag_128`. TCP renders
the same fields as `secure data <counter> <ciphertext> <tag>`. Client nonces are
`IPC || 0x02 || counter`; server nonces are `IPS || 0x02 || counter`. The
lowercase device ID is AES-GCM additional authenticated data. Replay, invalid
tag, wrong identity and out-of-order records are rejected.

## BLE mapping

The Secure Protocol service is `7d9f0001-4f4d-4f56-4552-484944000001`:

| Characteristic | Suffix | Purpose |
|---|---:|---|
| Control | `0002` | handshake and encrypted protocol records |
| Status | `0005` | handshake replies and encrypted protocol responses |

The GATT layer intentionally does not create a second iOS/NimBLE bond database.
Confidentiality, integrity, peer authentication and replay protection come from
the USB-trusted Secure Protocol session. Separate OTA data/status
characteristics remain for BLE flow control, but every OTA control/data write
is an encrypted record from that same session. Diagnostics are encrypted
commands and responses on Control/Status rather than separate characteristics.

## Wi-Fi mapping

TCP port 3333 carries the handshake and encrypted records on both SoftAP and
station networks. HTTP port 80 is read-only discovery. The app recognizes a
device after provisioning by device ID, then must successfully authenticate on
TCP before saving setup.

Wi-Fi OTA uses encrypted commands `START`, `DATA`, `FINISH`, and `ABORT`.
Firmware bytes therefore never pass through an HTTP upload endpoint. BLE uses
the same OTA engine, metadata validation, SHA-256 verification and exclusive
transport ownership.

Starting with 0.8.13, `START ... flow=windowed` negotiates cumulative ACK flow
control. A supporting device replies `ota ready 0 window=4096 chunk=128`; the
sender may then keep at most `window` unacknowledged bytes in flight. The
legacy `ota ready 0` reply selects one acknowledgement per `DATA` command, so
new and old app/firmware combinations remain interoperable.

Authenticated management supports `USB GET`, which returns `product_name`,
numeric `vid`, numeric `pid`, and `serial_number` as JSON. `USB SET` and
`USB RESET` retain their existing restart behavior.

## Session ownership and recovery

- One BLE manager owns the CoreBluetooth connection per device ID.
- Metadata, controls, diagnostics and OTA lease that shared connection.
- Disconnect, credential rotation or authentication failure clears keys,
  counters, queued writes and held HID state.
- USB trust rotation disconnects active transports and invalidates every
  application session immediately.
- A feature is ready only after application authentication, not GATT discovery,
  BLE connection or TCP connection.
- Automatic transport selection considers only authenticated ready sessions.
  It never introduces a less secure transport.

## Wi-Fi provisioning

Wi-Fi is optional. A trusted device can be added and controlled entirely over
BLE without ever provisioning a network. Firmware keeps BLE advertising while
configured Wi-Fi networks are unavailable, so the app can establish the same
Secure Protocol v2 session as its automatic fallback.

Firmware stores up to five networks. Saving a network through the encrypted BLE
management frame adds or updates it and moves it to the front of the connection
order. On startup (or after a credentials change), station mode tries each saved
network before exposing the setup Soft-AP. Passwords are never returned to the
app.

Authenticated text command `WIFI LIST` returns `{"count":2}`. The app then
requests each bounded entry with `WIFI GET 0`, `WIFI GET 1`, and so on; the
response is `{"ssid":"network name"}`. This keeps encrypted responses within a
small BLE ATT payload even when every stored SSID has the maximum length.
Encrypted binary management types under the existing `0xFE` prefix are:

- `0x01 <ssid-length> <password-length> <ssid> <password>`: add/update
- `0x04 <ssid-length> <ssid>`: remove one network
- `0x05`: remove every network
