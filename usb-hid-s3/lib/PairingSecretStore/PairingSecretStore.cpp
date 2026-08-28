#include "PairingSecretStore.h"

#include <atomic>
#include <Preferences.h>

namespace {
constexpr const char *Namespace = "ip-secure";
constexpr const char *SecretKey = "pair-key";
std::atomic<int> s_cachedPresence{-1};
}

bool PairingSecretStore::hasSecret() {
  const int cached = s_cachedPresence.load();
  if (cached >= 0) return cached == 1;
  Preferences prefs;
  if (!prefs.begin(Namespace, true)) return false;
  const bool present = prefs.getBytesLength(SecretKey) == SecretSize;
  prefs.end();
  s_cachedPresence = present ? 1 : 0;
  return present;
}

bool PairingSecretStore::load(uint8_t output[SecretSize]) {
  if (!output) return false;
  Preferences prefs;
  if (!prefs.begin(Namespace, true)) return false;
  const bool ok = prefs.getBytesLength(SecretKey) == SecretSize &&
                  prefs.getBytes(SecretKey, output, SecretSize) == SecretSize;
  prefs.end();
  return ok;
}

bool PairingSecretStore::replace(const uint8_t secret[SecretSize]) {
  if (!secret) return false;
  Preferences prefs;
  if (!prefs.begin(Namespace, false)) return false;
  const bool ok = prefs.putBytes(SecretKey, secret, SecretSize) == SecretSize;
  prefs.end();
  if (ok) s_cachedPresence = 1;
  return ok;
}

bool PairingSecretStore::clear() {
  Preferences prefs;
  if (!prefs.begin(Namespace, false)) return false;
  const bool ok = !prefs.isKey(SecretKey) || prefs.remove(SecretKey);
  prefs.end();
  if (ok) s_cachedPresence = 0;
  return ok;
}
