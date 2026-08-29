#ifndef RADIO_MANAGER_H
#define RADIO_MANAGER_H

// Concurrent WiFi and BLE control transports that feed
// command lines into the same handler as the serial interface.
//
// WiFi path:
//   - STA credentials in NVS (WifiCredentials). If none → Soft-AP setup portal
//     (DeviceIdentity::softApSsid) + read-only discovery on :80. STA mode
//     advertises mDNS via DeviceIdentity::mdnsFqdn.
//   - If credentials exist → STA + TCP line control on WIFI_CONTROL_PORT.
//
// WiFi and BLE may operate concurrently in WifiBle mode. USB HID is a separate
// peripheral and is unaffected.

#include <Arduino.h>

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

  // Push a line back to the connected control client (BLE notify / TCP write).
  void sendToControl(const char *line);

  // Apply newly saved STA credentials from an authenticated secure session.
  // If currently in Wifi mode, restarts WiFi to Soft-AP or STA as appropriate.
  void applyWifiCredentials();

  // Invalidate authenticated sessions immediately after BOOT rotates pairing.
  void pairingCredentialRotated();

  // True while Soft-AP setup portal is up.
  bool isSoftAp() const { return softAp_; }

private:
  void startWifi();
  void stopWifi();
  void startBle();
  void stopBle();
  void startSoftAp();
  void startSta(const String &ssid, const String &pass);

  RadioMode mode_ = RadioMode::None;
  bool softAp_ = false;
  char status_[64] = "none";
};

extern RadioManager g_radio;

// Shared BLE session gate used by OTA and diagnostics. All BLE features belong
// to the one control connection and its one authenticated secure session.
bool deviceBleAuthenticated();
bool decryptBleSecureRecord(const uint8_t *record, size_t recordLength,
                            uint8_t *plaintext, size_t plaintextCapacity,
                            size_t &plaintextLength);

#endif // RADIO_MANAGER_H
