# InputPilot v0.8.0 hardware E2E results

> Release gate template. Do not mark a test PASS without performing it on the recorded hardware.

## Test environment

| Field | Value |
| --- | --- |
| Board revision | NOT RECORDED |
| Flash size | NOT RECORDED |
| Commit SHA | NOT RECORDED |
| Source firmware | NOT RECORDED |
| Target firmware | NOT RECORDED |
| iPhone model | NOT RECORDED |
| iOS version | NOT RECORDED |
| App build | NOT RECORDED |
| CONTROL_API_TOKEN | enabled / disabled (select one) |

## Test matrix

Use `PASS`, `FAIL`, or `NOT RUN`, and attach concise evidence or observations.

| Test | Result | Evidence / notes |
| --- | --- | --- |
| USB migration | NOT RUN | |
| Merged initial-flash.bin after erase-flash | NOT RUN | |
| Individual initial-flash files after erase-flash | NOT RUN | |
| boot_app0.bin present | NOT RUN | |
| Partition table / two OTA slots correct | NOT RUN | |
| First boot after erased flash | NOT RUN | |
| USB enumeration as InputPilot S3 | NOT RUN | |
| BLE metadata and OTA schema 1 after clean install | NOT RUN | |
| First OTA after clean install uses inactive slot | NOT RUN | |
| BLE discovery | NOT RUN | |
| BLE advertising visible (wifi+ble) | NOT RUN | |
| BLE advertising visible (BLE-only) | NOT RUN | |
| Manufacturer data is exact `IP` + device ID | NOT RUN | |
| Device name present in scan response | NOT RUN | |
| NUS, HID, and OTA services connectable | NOT RUN | |
| Scan Nearby onboarding finds device | NOT RUN | |
| Onboarding metadata read / save | NOT RUN | |
| Stored-device BLE reconnect | NOT RUN | |
| Re-advertising after disconnect | NOT RUN | |
| BLE control while Wi-Fi enabled | NOT RUN | |
| BLE OTA metadata/status while Wi-Fi enabled | NOT RUN | |
| BLE-only onboarding | NOT RUN | |
| BLE auth success | NOT RUN | |
| BLE auth failure | NOT RUN | |
| Normal OTA | NOT RUN | |
| SHA mismatch | NOT RUN | |
| Invalid / foreign firmware | NOT RUN | |
| Oversized firmware | NOT RUN | |
| Manual cancel | NOT RUN | |
| BLE disconnect at ~50% | NOT RUN | |
| Power cycle after failed OTA | NOT RUN | |
| Successful retry | NOT RUN | |
| Reboot | NOT RUN | |
| Automatic reconnect | NOT RUN | |
| Firmware version verification | NOT RUN | |
| Mouse after OTA | NOT RUN | |
| Keyboard after OTA | NOT RUN | |
| releaseAll after OTA | NOT RUN | |
| BLE-only control | NOT RUN | |
| Wi-Fi-only control | NOT RUN | |
| Automatic mode | NOT RUN | |
| Light Mode | NOT RUN | |
| Dark Mode | NOT RUN | |
| Dynamic Type | NOT RUN | |
| VoiceOver | NOT RUN | |

## Release-gate decision

- Decision: NOT EVALUATED
- Tester:
- Date:
- Blocking issues:
