#ifndef BLE_ADVERTISING_RECOVERY_H
#define BLE_ADVERTISING_RECOVERY_H

namespace BLEAdvertisingRecovery {

// Pure policy used by the firmware watchdog and host-side regression tests.
inline bool shouldAttempt(bool transportEnabled, bool stackReady,
                          bool connected, bool advertising) {
  return transportEnabled && stackReady && !connected && !advertising;
}

}  // namespace BLEAdvertisingRecovery

#endif  // BLE_ADVERTISING_RECOVERY_H
