# M1 Device and Connection Checklist

Use this checklist on a physical iPhone and at least two saved InputPilot devices.
Record the date, iOS version, app build, firmware versions and failures when the
M1 milestone reaches its hardware gate.

## Active device

- [ ] The first saved device becomes active when no previous selection exists.
- [ ] The active badge and VoiceOver value identify the same device.
- [ ] Leading swipe and context-menu actions change the active device.
- [ ] Control, Firmware, Settings and Diagnostics immediately follow the selection.
- [ ] Deleting the active device selects the next saved device without a blank screen.

## Connection states and recovery

- [ ] Wi-Fi plus Bluetooth displays Connected and names both transports.
- [ ] Wi-Fi-only fallback remains Connected while Bluetooth reconnects or is off.
- [ ] Bluetooth-only operation remains Connected while Wi-Fi is unavailable.
- [ ] A total outage displays Offline and Try Again starts only one recovery attempt.
- [ ] Denied Bluetooth access offers the InputPilot system-settings action when no fallback works.
- [ ] Invalid USB trust displays Attention Required and links to the recovery guide.
- [ ] Normal screens do not expose protocol versions, endpoints or transport error codes.
- [ ] Diagnostics retains device ID, firmware, protocol, OTA schema, logs and export.

## Safety and accessibility

- [ ] An unexpected disconnect releases held mouse buttons and keyboard modifiers.
- [ ] Status meaning remains understandable without color.
- [ ] Status, active-device controls and recovery actions have useful VoiceOver output.
- [ ] Controls remain usable at accessibility Dynamic Type sizes.
- [ ] Light Mode, Dark Mode and Reduce Motion behavior are acceptable.
