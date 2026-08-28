# InputPilot 0.8.4 hardware E2E results

Hardware status: **NOT RUN**

Automated tests cover endpoint ordering and address persistence. Record physical
network, VPN, control, and OTA observations here before considering the 0.8.4
hardware gate complete.

| Test | Result | Evidence |
|---|---|---|
| Add by direct LAN IP with Bonjour unavailable | NOT RUN | |
| Add by VPN IP/hostname and retain that route after refresh | NOT RUN | |
| REST and TCP control work with Bonjour unavailable | NOT RUN | |
| Wi-Fi diagnostics work with Bonjour unavailable | NOT RUN | |
| Wi-Fi OTA completes and verifies after restart with Bonjour unavailable | NOT RUN | |
| Bonjour discovery and `.local` fallback still work on the LAN | NOT RUN | |
| BLE control and BLE OTA remain functional | NOT RUN | |

For each run record board revision/device ID, source and target firmware, app
commit, phone/OS, VPN technology and route, selected transport, and post-reboot
identity/version verification.
