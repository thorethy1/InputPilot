# InputPilot 0.8.12

This release makes Bluetooth a complete offline control path and adds ordered
multi-network Wi-Fi support.

- USB pairing now identifies the matching BLE device automatically. The add
  flow opens USB pairing directly from the plus button.
- Wi-Fi setup is optional. A device can be added and controlled entirely over
  the authenticated BLE transport without a router or Internet connection.
- Firmware stores up to five Wi-Fi networks, tries them in order, and keeps BLE
  available while networks are unavailable.
- Device details can add, update, list, and remove networks through encrypted
  BLE management commands. Passwords are never returned to the app.
- Existing single-network NVS configurations migrate automatically.

Secure Protocol v2 remains the only supported application protocol. The
`IPPAIR1` USB frame marker is the separate pairing bootstrap format version.
