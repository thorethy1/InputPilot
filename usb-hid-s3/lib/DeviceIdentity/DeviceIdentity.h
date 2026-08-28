#ifndef DEVICE_IDENTITY_H
#define DEVICE_IDENTITY_H

#include <stddef.h>
#include <stdint.h>

/**
 * Per-device identity derived from the WiFi/eFuse MAC.
 * Enables unique Soft-AP SSIDs and mDNS hostnames on a shared LAN.
 *
 * device_id: 12 lowercase hex chars (no separators), e.g. "aabbccddeeff"
 * suffix:    last 4 hex of device_id, e.g. "eeff"
 * Soft-AP:   InputPilot-<SUFFIX_UPPER>
 * mDNS:      inputpilot-<suffix_lower>
 */

// Pure helpers (unit-testable on host).
bool deviceIdFromMacBytes(const uint8_t mac[6], char outId[13], char outSuffix[5]);
void formatSoftApSsid(const char *suffix4, char out[24]);
void formatMdnsHostname(const char *suffix4, char out[24]);

#ifndef UNIT_TEST
class DeviceIdentity {
public:
  /** Cache MAC-derived strings once (safe to call multiple times). */
  static void begin();

  static const char *deviceId();      // 12-hex
  static const char *suffix();        // 4-hex lowercase
  static const char *softApSsid();    // InputPilot-XXXX
  static const char *mdnsHostname();  // inputpilot-xxxx
  static const char *mdnsFqdn();      // inputpilot-xxxx.local
};
#endif

#endif  // DEVICE_IDENTITY_H
