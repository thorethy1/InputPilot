# InputPilot 0.8.4

InputPilot 0.8.4 removes Bonjour as a connection requirement. Bonjour remains
available for nearby-device discovery, but saved direct addresses are preferred
for status, control, diagnostics, and firmware updates.

When a device is added by IP address or a VPN-resolvable hostname, the app now
keeps the address that actually answered the probe. It no longer replaces that
route with the LAN address reported by the device, which may be unreachable from
the other side of the VPN. iOS Wi-Fi OTA preflights the direct endpoint before
starting and verifies the restarted device using the same ordered candidates.

The wire protocol and OTA schema remain at version 1. Bonjour discovery and
`.local` fallback continue to work on a local network.
