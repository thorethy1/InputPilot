# InputPilot 0.8.14

This release makes the complete USB identity configurable from the iOS app and
removes the remaining legacy MKF Labs branding.

## Highlights

- Read and edit the USB manufacturer alongside product name, VID, PID, and
  serial number over authenticated Wi-Fi or Bluetooth.
- Persist the manufacturer in firmware and apply it to the USB descriptor after
  the controlled restart.
- Keep old app/firmware combinations compatible through the existing USB
  identity format while advertising the new `usb_manufacturer` capability.
- Use `thorethy` as the default USB manufacturer and AltStore developer name.
- Clean up the remaining internal iOS identifiers that referenced MKF Labs.

The default VID/PID remain `CAFE:4001`. A VID is a 16-bit hexadecimal number;
changing it in the app does not assign ownership or permission to use it.
