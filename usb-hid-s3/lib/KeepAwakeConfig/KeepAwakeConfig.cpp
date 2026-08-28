#include "KeepAwakeConfig.h"

#include <Preferences.h>

#include "Config.h"

namespace {
constexpr const char *kNamespace = "keepawake";
}

bool KeepAwakeConfig::validInterval(uint32_t intervalMs) {
  return intervalMs >= KEEP_AWAKE_MIN_INTERVAL_MS &&
         intervalMs <= KEEP_AWAKE_MAX_INTERVAL_MS;
}

KeepAwakeSettings KeepAwakeConfig::load() {
  KeepAwakeSettings settings;
  Preferences preferences;
  if (!preferences.begin(kNamespace, true)) return settings;
  settings.moveEnabled = preferences.getBool("move", JIGGLE_ENABLED_DEFAULT != 0);
  settings.moveIntervalMs = preferences.getUInt("move_ms", JIGGLE_INTERVAL_MS);
  settings.clickEnabled = preferences.getBool("click", CLICK_ENABLED_DEFAULT != 0);
  settings.clickIntervalMs = preferences.getUInt("click_ms", CLICK_INTERVAL_MS);
  preferences.end();
  if (!validInterval(settings.moveIntervalMs)) settings.moveIntervalMs = JIGGLE_INTERVAL_MS;
  if (!validInterval(settings.clickIntervalMs)) settings.clickIntervalMs = CLICK_INTERVAL_MS;
  return settings;
}

bool KeepAwakeConfig::save(const KeepAwakeSettings &settings) {
  if (!validInterval(settings.moveIntervalMs) ||
      !validInterval(settings.clickIntervalMs)) return false;
  Preferences preferences;
  if (!preferences.begin(kNamespace, false)) return false;
  const bool ok = preferences.putBool("move", settings.moveEnabled) == 1 &&
                  preferences.putUInt("move_ms", settings.moveIntervalMs) == sizeof(uint32_t) &&
                  preferences.putBool("click", settings.clickEnabled) == 1 &&
                  preferences.putUInt("click_ms", settings.clickIntervalMs) == sizeof(uint32_t);
  preferences.end();
  return ok;
}
