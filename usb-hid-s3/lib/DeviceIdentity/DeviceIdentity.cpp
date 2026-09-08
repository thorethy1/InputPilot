#include "DeviceIdentity.h"

#include <stdio.h>
#include <string.h>

static char hexNibble(uint8_t v) {
  v &= 0x0f;
  return (char)(v < 10 ? ('0' + v) : ('a' + (v - 10)));
}

bool deviceIdFromMacBytes(const uint8_t mac[6], char outId[13], char outSuffix[5]) {
  if (!mac || !outId || !outSuffix) return false;
  for (int i = 0; i < 6; i++) {
    outId[i * 2] = hexNibble((uint8_t)(mac[i] >> 4));
    outId[i * 2 + 1] = hexNibble(mac[i]);
  }
  outId[12] = '\0';
  outSuffix[0] = outId[8];
  outSuffix[1] = outId[9];
  outSuffix[2] = outId[10];
  outSuffix[3] = outId[11];
  outSuffix[4] = '\0';
  return true;
}

namespace {

uint32_t friendlyHash(const char *deviceId) {
  // FNV-1a over the complete, case-normalized MAC makes the friendly label
  // stable without exposing the MAC itself. All twelve digits contribute.
  uint32_t hash = 2166136261u;
  for (size_t i = 0; deviceId && deviceId[i]; ++i) {
    char c = deviceId[i];
    if (c >= 'A' && c <= 'F') c = (char)(c - 'A' + 'a');
    hash ^= static_cast<uint8_t>(c);
    hash *= 16777619u;
  }
  return hash;
}

char firstMacDigit(const char *deviceId, uint32_t hash) {
  for (size_t i = 0; deviceId && deviceId[i]; ++i) {
    if (deviceId[i] >= '0' && deviceId[i] <= '9') return deviceId[i];
  }
  return (char)('0' + (hash % 10));
}

}  // namespace

void formatSoftApSsid(const char *deviceId, char out[24]) {
  if (!out) return;
  // Two independently selected syllables provide 256 short, pronounceable
  // labels. With the trailing MAC digit this replaces the previous 60-name
  // space with 2,560 combinations while staying well inside BLE limits.
  static const char *const starts[] = {
      "Al", "Be", "Co", "Di", "El", "Fa", "Gi", "Ha",
      "Io", "Ju", "Ka", "Lu", "Mi", "No", "Or", "Pi"};
  static const char *const ends[] = {
      "ba", "co", "do", "fi", "go", "ha", "jo", "ki",
      "lo", "mi", "no", "pa", "ri", "so", "tu", "vo"};
  const uint32_t hash = friendlyHash(deviceId);
  const char digit = firstMacDigit(deviceId, hash);
  snprintf(out, 24, "InputPilot-%s%s%c", starts[hash & 0x0f],
           ends[(hash >> 8) & 0x0f], digit);
}

void formatDeviceName(const char *deviceId, char out[24]) {
  formatSoftApSsid(deviceId, out);
}

void formatMdnsHostname(const char *suffix4, char out[24]) {
  if (!out) return;
  char low[5] = {'0', '0', '0', '0', '\0'};
  if (suffix4) {
    for (int i = 0; i < 4 && suffix4[i]; i++) {
      char c = suffix4[i];
      if (c >= 'A' && c <= 'F') c = (char)(c - 'A' + 'a');
      low[i] = c;
    }
  }
  snprintf(out, 24, "inputpilot-%s", low);
}

#ifndef UNIT_TEST
#include <esp_mac.h>
#include "Logging.h"

namespace {

bool s_ready = false;
char s_deviceId[13];
char s_suffix[5];
char s_softAp[24];
char s_deviceName[24];
char s_mdns[24];
char s_mdnsFqdn[32];

void ensureReady() {
  if (s_ready) return;
  uint8_t mac[6] = {0};
  if (esp_read_mac(mac, ESP_MAC_WIFI_STA) != ESP_OK) {
    // Last resort: zeros → still yields a deterministic (bad) id for logging.
    memset(mac, 0, sizeof(mac));
  }
  deviceIdFromMacBytes(mac, s_deviceId, s_suffix);
  formatSoftApSsid(s_deviceId, s_softAp);
  formatDeviceName(s_deviceId, s_deviceName);
  formatMdnsHostname(s_suffix, s_mdns);
  snprintf(s_mdnsFqdn, sizeof(s_mdnsFqdn), "%s.local", s_mdns);
  s_ready = true;
  LOG_INFO("device_id=%s soft-ap=\"%s\" mdns=%s", s_deviceId, s_softAp, s_mdnsFqdn);
}

}  // namespace

void DeviceIdentity::begin() { ensureReady(); }

const char *DeviceIdentity::deviceId() {
  ensureReady();
  return s_deviceId;
}

const char *DeviceIdentity::suffix() {
  ensureReady();
  return s_suffix;
}

const char *DeviceIdentity::softApSsid() {
  ensureReady();
  return s_softAp;
}

const char *DeviceIdentity::deviceName() {
  ensureReady();
  return s_deviceName;
}

const char *DeviceIdentity::mdnsHostname() {
  ensureReady();
  return s_mdns;
}

const char *DeviceIdentity::mdnsFqdn() {
  ensureReady();
  return s_mdnsFqdn;
}
#endif  // !UNIT_TEST
