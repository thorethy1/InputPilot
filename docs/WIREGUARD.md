# ESP32 WireGuard client

InputPilot 0.9.3 can establish a WireGuard tunnel directly from the ESP32-S3.
The iOS app does not create a VPN and does not need a Network Extension. It is
only the authenticated setup and control client.

## Setup

1. Add a client peer for the InputPilot on your WireGuard server.
2. Give that peer a stable IPv4 address and export its `wg-quick` `.conf`.
3. In the iOS app, open the device, choose **WireGuard**, import the `.conf`,
   optionally select the Wi-Fi SSIDs on which the tunnel may run, and install it.
4. Permit the iPhone's WireGuard peer or routed VPN network to reach the
   InputPilot address on TCP port 3333. The existing Secure Protocol v2
   authentication is still mandatory inside the tunnel.

The ESP first connects to a saved Wi-Fi network and obtains valid wall-clock
time using NTP. It then resolves the peer endpoint, performs the WireGuard
handshake, and exposes the existing HTTP discovery service on port 80 and the
authenticated control service on port 3333 through the tunnel interface.

## Supported `.conf` subset

The constrained ESP32 implementation accepts:

- one `[Interface]` with one IPv4 `Address` and `PrivateKey`;
- optional `ListenPort`, `DNS`, and `MTU` (576–1420; `DNS` is accepted but the
  ESP continues to use the DNS server supplied by Wi-Fi);
- one `[Peer]` with `PublicKey`, `Endpoint`, and one IPv4 `AllowedIPs` range;
- optional `PresharedKey` and `PersistentKeepalive`.

`AllowedIPs` must contain the interface address. This lets lwIP route precisely
that range without replacing the physical Wi-Fi default route. A full tunnel
such as `0.0.0.0/0` is supported. IPv6, multiple addresses, peers or AllowedIPs
ranges, and executable `PreUp`, `PostUp`, `PreDown`, or `PostDown` settings are
rejected before storage.

Example:

```ini
[Interface]
PrivateKey = <inputpilot-private-key>
Address = 10.7.0.23/32
MTU = 1280

[Peer]
PublicKey = <server-public-key>
PresharedKey = <optional-preshared-key>
Endpoint = vpn.example.net:51820
AllowedIPs = 10.7.0.0/24
PersistentKeepalive = 25
```

## Wi-Fi restriction and recovery

The allow-list contains up to five exact SSID names. When enabled, the ESP
starts WireGuard only on a selected SSID and reports `ssid_blocked` elsewhere.
Changing Wi-Fi, the allow-list, the profile, or the enabled switch tears down
and reevaluates the tunnel without rebooting. BLE remains available as the
recovery and configuration path if a profile or route is wrong.

## Security and storage

The app validates the file and uploads it in checksummed chunks only after
Secure Protocol v2 authentication over BLE or TCP. Installation is committed
only after size, checksum, and a second device-side parse all succeed. To avoid
a policy race, a new profile is stored disabled, the SSID rule is committed,
and only then is the requested enabled state applied.

The ESP stores the profile in its NVS partition. Private and preshared keys are
never included in public discovery, authenticated status, or diagnostics. The
app retains only the non-secret tunnel address as a future endpoint and drops
the imported profile after a successful transfer. Protect physical access to
devices that are not provisioned with ESP32 flash/NVS encryption.
