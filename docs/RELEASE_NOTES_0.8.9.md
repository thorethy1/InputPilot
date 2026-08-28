# InputPilot 0.8.9

InputPilot 0.8.9 fixes regressions introduced by encrypted onboarding. Paired
devices can restore their USB defaults over the authenticated Bluetooth
management channel, keeping the MAC-derived USB serial number, and BLE firmware
updates now use a bounded, readiness-aware transfer path.

Bluetooth advertisements and the HTTP API identify each unit as
`InputPilot-XXXX`. The iOS control screen now shows one active transport status,
coalesces scrolling to keep encrypted input responsive, and gives Preset Run an
independent button. A long press performs a right click; tap followed by hold
starts a left-button drag.
