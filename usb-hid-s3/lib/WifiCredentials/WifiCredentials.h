#ifndef WIFI_CREDENTIALS_H
#define WIFI_CREDENTIALS_H

#include <Arduino.h>

/**
 * NVS-backed ordered WiFi STA credentials (up to MaxNetworks).
 *
 * Persistence model (Preferences namespace "wifi"):
 *   - `provisioned` (bool): once true, NVS is authoritative (even if ssid empty).
 *   - `count` (byte), `ssid0..4` / `pass0..4`: connection candidates.
 *
 * First boot (`provisioned` false): seed from compile-time WIFI_SSID/WIFI_PASS
 * if WIFI_SSID is non-empty, then mark provisioned. That preserves the old
 * wifi_secrets.h workflow.
 *
 * Legacy `ssid` / `pass` values are migrated to slot zero. `clear()` empties
 * every slot and keeps provisioned=true so compile-time secrets stay ignored.
 */

struct WifiCreds {
  String ssid;
  String pass;
};

class WifiCredentials {
public:
  static constexpr size_t MaxNetworks = 5;

  // Load from NVS (seeding from compile-time defaults on first boot).
  static void begin();

  static bool hasSsid();
  static WifiCreds get();
  static WifiCreds get(size_t index);
  static size_t count();

  // Add or update a network and make it the first connection candidate.
  // Empty pass is allowed (open network).
  static bool save(const String &ssid, const String &pass);

  // Forget one network. Returns false when it was not present.
  static bool remove(const String &ssid);

  // Forget STA creds (forces Soft-AP on next radio wifi).
  static bool clear();

  static bool isProvisioned();
};

#endif  // WIFI_CREDENTIALS_H
