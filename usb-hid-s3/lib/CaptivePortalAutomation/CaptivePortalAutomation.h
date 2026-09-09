#ifndef INPUTPILOT_CAPTIVE_PORTAL_AUTOMATION_H
#define INPUTPILOT_CAPTIVE_PORTAL_AUTOMATION_H

#include <Arduino.h>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>
#include <atomic>

#include "Config.h"

// Persistent, SSID-bound HTTP workflows. The firmware deliberately does not
// embed or execute a POSIX shell: iOS and the ESP32 have no supported shell
// runtime. Instead, the app uploads this bounded HTTP DSL over the authenticated
// InputPilot protocol and the ESP32 runs it after its station connection settles.
class CaptivePortalAutomation {
 public:
  static constexpr size_t MaxScripts = CAPTIVE_PORTAL_MAX_SCRIPTS;
  static constexpr size_t MaxScriptBytes = CAPTIVE_PORTAL_MAX_SCRIPT_BYTES;
  static constexpr uint32_t MinDelayMs = 0;
  static constexpr uint32_t MaxDelayMs = 60000;

  void begin();
  void loop();

  // Handles CAPTIVE protocol commands and returns true when the command belongs
  // to this feature. Callers are still responsible for secure reply framing.
  bool handleCommand(const std::string &command, std::string &reply);
  void beginUpload(uint64_t token, const String &ssid, uint32_t delayMs,
                   size_t size, uint32_t checksum, bool enabled,
                   std::string &reply);
  void writeUpload(uint64_t token, uint32_t offset, const uint8_t *data,
                   size_t length, std::string &reply);

  std::string statusJson();
  bool active() const { return running_.load(); }

 private:
  enum class State { Idle, Waiting, Running, Success, AlreadyConnected, Failed };

  struct ScriptRecord {
    String ssid;
    String script;
    uint32_t delayMs = 4000;
    bool enabled = true;
  };

  struct Upload {
    bool active = false;
    uint64_t token = 0;
    String ssid;
    uint32_t delayMs = 4000;
    bool enabled = true;
    size_t expectedSize = 0;
    uint32_t expectedChecksum = 0;
    std::vector<uint8_t> bytes;
  };

  static void taskEntry(void *context);
  void runTask();
  void run(const ScriptRecord &record);
  bool load(size_t index, ScriptRecord &record) const;
  int find(const String &ssid) const;
  bool save(const ScriptRecord &record);
  bool remove(const String &ssid);
  size_t count() const;
  bool startForSSID(const String &ssid, bool manual);
  void setStatus(State state, const String &ssid, const String &message,
                 const String &error = String());
  static uint32_t checksum(const uint8_t *data, size_t length);

  Upload upload_;
  String observedSSID_;
  String pendingSSID_;
  uint32_t pendingSinceMs_ = 0;
  bool ranForCurrentConnection_ = false;
  std::atomic<bool> running_{false};
  SemaphoreHandle_t mutex_ = nullptr;
  State state_ = State::Idle;
  String statusSSID_;
  String statusMessage_;
  String statusError_;
  uint32_t lastRunMs_ = 0;
};

extern CaptivePortalAutomation g_captivePortalAutomation;

#endif  // INPUTPILOT_CAPTIVE_PORTAL_AUTOMATION_H
