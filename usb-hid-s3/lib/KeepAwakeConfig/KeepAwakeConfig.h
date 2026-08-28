#ifndef KEEP_AWAKE_CONFIG_H
#define KEEP_AWAKE_CONFIG_H

#include <cstdint>

struct KeepAwakeSettings {
  bool moveEnabled = false;
  uint32_t moveIntervalMs = 30000;
  bool clickEnabled = false;
  uint32_t clickIntervalMs = 60000;
};

class KeepAwakeConfig {
public:
  static KeepAwakeSettings load();
  static bool save(const KeepAwakeSettings &settings);
  static bool validInterval(uint32_t intervalMs);
};

#endif
