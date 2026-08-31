#include "WifiCredentials.h"

#include <Preferences.h>

#include "Config.h"
#include "Logging.h"

namespace {

Preferences s_prefs;
bool s_ready = false;

constexpr const char *kNs = "wifi";
constexpr const char *kKeyProv = "provisioned";
constexpr const char *kKeySsid = "ssid";
constexpr const char *kKeyPass = "pass";
constexpr const char *kKeyCount = "count";

String indexedKey(const char *prefix, size_t index) {
  return String(prefix) + String(index);
}

size_t storedCount() {
  return min(static_cast<size_t>(s_prefs.getUChar(kKeyCount, 0)),
             WifiCredentials::MaxNetworks);
}

WifiCreds storedAt(size_t index) {
  WifiCreds value;
  if (index >= storedCount()) return value;
  value.ssid = s_prefs.getString(indexedKey("ssid", index).c_str(), "");
  value.pass = s_prefs.getString(indexedKey("pass", index).c_str(), "");
  return value;
}

bool writeAll(const WifiCreds *values, size_t count) {
  count = min(count, WifiCredentials::MaxNetworks);
  for (size_t i = 0; i < WifiCredentials::MaxNetworks; ++i) {
    const String ssidKey = indexedKey("ssid", i);
    const String passKey = indexedKey("pass", i);
    if (i < count) {
      if (s_prefs.putString(ssidKey.c_str(), values[i].ssid) == 0) return false;
      if (s_prefs.putString(passKey.c_str(), values[i].pass) == 0 &&
          values[i].pass.length() > 0) return false;
    } else {
      s_prefs.remove(ssidKey.c_str());
      s_prefs.remove(passKey.c_str());
    }
  }
  s_prefs.putUChar(kKeyCount, static_cast<uint8_t>(count));
  s_prefs.putBool(kKeyProv, true);
  return true;
}

bool openRw() {
  if (!s_ready) return false;
  return s_prefs.begin(kNs, false);
}

bool openRo() {
  if (!s_ready) return false;
  return s_prefs.begin(kNs, true);
}

}  // namespace

void WifiCredentials::begin() {
  s_ready = true;
  if (!openRw()) {
    LOG_WIFI("nvs open failed");
    s_ready = false;
    return;
  }
  const bool provisioned = s_prefs.getBool(kKeyProv, false);
  if (storedCount() == 0) {
    // Migrate the pre-multi-network keys before considering compile defaults.
    const String legacySsid = s_prefs.getString(kKeySsid, "");
    if (legacySsid.length() > 0) {
      const WifiCreds migrated[] = {{legacySsid, s_prefs.getString(kKeyPass, "")}};
      writeAll(migrated, 1);
      s_prefs.remove(kKeySsid);
      s_prefs.remove(kKeyPass);
      LOG_WIFI("migrated legacy SSID=\"%s\"", legacySsid.c_str());
    }
  }
  if (!provisioned && storedCount() == 0) {
    const String compileSsid = WIFI_SSID;
    if (compileSsid.length() > 0) {
      const WifiCreds seeded[] = {{compileSsid, String(WIFI_PASS)}};
      writeAll(seeded, 1);
      LOG_WIFI("nvs seeded from compile-time SSID=\"%s\"", compileSsid.c_str());
    } else {
      LOG_WIFI("nvs empty (no compile-time SSID); Soft-AP available");
    }
  }
  s_prefs.end();
}

bool WifiCredentials::isProvisioned() {
  if (!openRo()) return false;
  const bool v = s_prefs.getBool(kKeyProv, false);
  s_prefs.end();
  return v;
}

WifiCreds WifiCredentials::get() {
  return get(0);
}

WifiCreds WifiCredentials::get(size_t index) {
  WifiCreds c;
  if (!openRo()) return c;
  c = storedAt(index);
  s_prefs.end();
  return c;
}

size_t WifiCredentials::count() {
  if (!openRo()) return 0;
  const size_t value = storedCount();
  s_prefs.end();
  return value;
}

bool WifiCredentials::hasSsid() {
  return get().ssid.length() > 0;
}

bool WifiCredentials::save(const String &ssid, const String &pass) {
  if (ssid.length() == 0) return false;
  if (ssid.length() > 32) return false;
  if (pass.length() > 63) return false;
  if (!openRw()) return false;
  WifiCreds values[MaxNetworks];
  size_t outputCount = 1;
  values[0] = {ssid, pass};
  const size_t existingCount = storedCount();
  for (size_t i = 0; i < existingCount && outputCount < MaxNetworks; ++i) {
    const WifiCreds value = storedAt(i);
    if (value.ssid.length() > 0 && value.ssid != ssid) values[outputCount++] = value;
  }
  const bool ok = writeAll(values, outputCount);
  s_prefs.end();
  if (!ok) return false;
  LOG_WIFI("nvs saved SSID=\"%s\"", ssid.c_str());
  return true;
}

bool WifiCredentials::remove(const String &ssid) {
  if (ssid.length() == 0 || !openRw()) return false;
  WifiCreds values[MaxNetworks];
  size_t outputCount = 0;
  bool found = false;
  const size_t existingCount = storedCount();
  for (size_t i = 0; i < existingCount; ++i) {
    const WifiCreds value = storedAt(i);
    if (value.ssid == ssid) { found = true; continue; }
    if (value.ssid.length() > 0) values[outputCount++] = value;
  }
  const bool ok = found && writeAll(values, outputCount);
  s_prefs.end();
  if (ok) LOG_WIFI("nvs removed SSID=\"%s\"", ssid.c_str());
  return ok;
}

bool WifiCredentials::clear() {
  if (!openRw()) return false;
  const bool ok = writeAll(nullptr, 0);
  s_prefs.remove(kKeySsid);
  s_prefs.remove(kKeyPass);
  s_prefs.end();
  if (!ok) return false;
  LOG_WIFI("nvs cleared (Soft-AP on next radio wifi)");
  return true;
}
