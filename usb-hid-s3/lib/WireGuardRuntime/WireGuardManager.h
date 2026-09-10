#ifndef INPUTPILOT_WIREGUARD_MANAGER_H
#define INPUTPILOT_WIREGUARD_MANAGER_H

#include <Arduino.h>
#include <cstdint>
#include <string>
#include <vector>

#include "WireGuardConfigParser.h"

extern "C" {
#include "lwip/netif.h"
}

class WireGuardManager {
 public:
  static constexpr size_t MaxSSIDs = 5;
  enum class State { Disabled, NoConfig, WaitingWiFi, SSIDBlocked, WaitingTime,
                     Connecting, Connected, Error };

  void begin();
  void loop();
  void stop();

  bool handleCommand(const std::string &command, std::string &reply);
  void writeUpload(uint64_t token, size_t offset, const uint8_t *data,
                   size_t length, std::string &reply);
  void addPolicySSID(const uint8_t *data, size_t length, std::string &reply);
  std::string statusJson() const;
  bool configured() const { return configured_; }
  bool active() const { return wgNetif_ != nullptr; }
  const char *tunnelIP() const { return configured_ ? config_.address.c_str() : ""; }

 private:
  struct Upload {
    bool active = false;
    uint64_t token = 0;
    size_t expectedSize = 0;
    uint32_t expectedChecksum = 0;
    bool enabled = true;
    std::vector<uint8_t> bytes;
  };

  bool load();
  bool persist(const std::string &text, bool enabled);
  bool persistPolicy();
  bool start();
  bool ssidAllowed(const String &ssid) const;
  void evaluate();
  void resetAssociation();
  void scheduleRuntimeReset();
  void setError(const char *code);
  static uint32_t checksum(const uint8_t *data, size_t length);

  WireGuardConfig config_;
  bool configured_ = false;
  bool enabled_ = false;
  bool restricted_ = false;
  std::vector<String> allowedSSIDs_;
  Upload upload_;
  std::vector<String> pendingSSIDs_;
  bool pendingRestricted_ = false;
  bool policyUploadActive_ = false;
  State state_ = State::NoConfig;
  String lastSSID_;
  bool requestedTimeSync_ = false;
  uint32_t timeSyncStartedMs_ = 0;
  uint32_t retryAtMs_ = 0;
  uint32_t tunnelStartedMs_ = 0;
  uint32_t runtimeResetAtMs_ = 0;
  String error_;

  struct netif wgNetifStorage_ {};
  struct netif *wgNetif_ = nullptr;
  struct netif *physicalNetif_ = nullptr;
  uint8_t peerIndex_ = 0xff;
  uint8_t presharedKey_[32] {};
};

extern WireGuardManager g_wireGuardManager;

#endif  // INPUTPILOT_WIREGUARD_MANAGER_H
