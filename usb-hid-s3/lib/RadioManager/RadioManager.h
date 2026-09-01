#ifndef RADIO_MANAGER_H
#define RADIO_MANAGER_H

// Concurrent WiFi and BLE control transports that feed
// command lines into the same handler as the serial interface.
//
// WiFi path:
//   - Ordered STA credentials in NVS (WifiCredentials). If none → Soft-AP setup portal
//     (DeviceIdentity::softApSsid) + read-only discovery on :80. STA mode
//     advertises mDNS via DeviceIdentity::mdnsFqdn.
//   - If credentials exist → STA + TCP line control on WIFI_CONTROL_PORT.
//
// WiFi and BLE may operate concurrently in WifiBle mode. USB HID is a separate
// peripheral and is unaffected.

#include <Arduino.h>
#include <string>

#include "RadioMode.h"

class RadioManager {
public:
  void begin(RadioMode initial);

  // Switch the active radio. Tears down the current stack first.
  bool setMode(RadioMode m);

  RadioMode mode() const { return mode_; }
  bool wifiEnabled() const { return mode_ == RadioMode::Wifi || mode_ == RadioMode::WifiBle; }
  bool bleEnabled() const { return mode_ == RadioMode::Ble || mode_ == RadioMode::WifiBle; }

  // Must be called from loop() (TCP client + Soft-AP HTTP + reconnect).
  void loop();

  // Short human-readable status, e.g. "none", "ble:adv", "wifi:1.2.3.4", "wifi:ap".
  const char *statusStr();

  // Called by the NimBLE disconnect callback after re-advertising is checked.
  void setBleAdvertisingStatus(bool active);

  // Live BLE state for diagnostics. Advertising is queried from NimBLE and is
  // never inferred from the absence of a connection.
  bool isBleAdvertising() const;
  bool isBleConnected() const;
  bool isControlSessionConnected() const;
  uint32_t bleAdvertisingRecoveryCount() const { return bleAdvertisingRecoveryCount_; }
  uint32_t bleAdvertisingRecoveryFailureCount() const { return bleAdvertisingRecoveryFailureCount_; }

  // Apply newly saved STA credentials from an authenticated secure session.
  // If currently in Wifi mode, restarts WiFi to Soft-AP or STA as appropriate.
  void applyWifiCredentials(const String &provisionedSsid = String());

  // Authenticated, transport-independent Wi-Fi status payload used by both
  // BLE and TCP Secure Protocol sessions.
  std::string wifiStatusJson() const;

  // Invalidate authenticated sessions immediately after BOOT rotates pairing.
  void pairingCredentialRotated();

  // True while Soft-AP setup portal is up.
  bool isSoftAp() const { return softAp_; }

private:
  void startWifi();
  void stopWifi();
  void startBle();
  void stopBle();
  void serviceBleAdvertising();
  void startSoftAp();
  void startSta(const String &ssid, const String &pass, size_t credentialIndex,
                bool preserveSoftAp = false);
  void finishStaConnection();
  void serviceStaConnection();
  void stopWifiServices();

  RadioMode mode_ = RadioMode::None;
  bool softAp_ = false;
  bool staConnecting_ = false;
  uint32_t staConnectStartedMs_ = 0;
  size_t staCredentialIndex_ = 0;
  size_t staAttempts_ = 0;
  uint32_t staDisconnectedSinceMs_ = 0;
  uint32_t softApStartedMs_ = 0;
  bool staRetryPreservesSoftAp_ = false;
  String provisioningSsid_;
  String provisioningState_ = "idle";
  String provisioningError_;
  char status_[64] = "none";
  uint32_t lastBleAdvertisingCheckMs_ = 0;
  uint32_t bleAdvertisingRecoveryCount_ = 0;
  uint32_t bleAdvertisingRecoveryFailureCount_ = 0;
};

extern RadioManager g_radio;

// BLE transport-session gate used by OTA. Protocol features are dispatched by
// the common command core after this concrete transport session authenticates.
bool deviceBleAuthenticated();
bool deviceBleConnectionOwnsSession(uint16_t connectionHandle);
uint16_t deviceBleSessionHandle();
bool decryptBleSecureRecord(const uint8_t *record, size_t recordLength,
                            uint8_t *plaintext, size_t plaintextCapacity,
                            size_t &plaintextLength);

#endif // RADIO_MANAGER_H
