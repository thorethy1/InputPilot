#include <unity.h>
#include <string.h>

#define UNIT_TEST
#include "DeviceIdentity.h"

void test_device_id_from_mac() {
  const uint8_t mac[6] = {0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff};
  char id[13];
  char suffix[5];
  TEST_ASSERT_TRUE(deviceIdFromMacBytes(mac, id, suffix));
  TEST_ASSERT_EQUAL_STRING("aabbccddeeff", id);
  TEST_ASSERT_EQUAL_STRING("eeff", suffix);
}

void test_soft_ap_ssid_uses_friendly_mac_name() {
  char ssid[24];
  formatSoftApSsid("de94", ssid);
  TEST_ASSERT_EQUAL_STRING("InputPilot-Dupe9", ssid);
}

void test_mdns_hostname_lower_suffix() {
  char host[24];
  formatMdnsHostname("EEFF", host);
  TEST_ASSERT_EQUAL_STRING("inputpilot-eeff", host);
}

void test_device_name_matches_soft_ap_name() {
  char name[24];
  formatDeviceName("DE94", name);
  TEST_ASSERT_EQUAL_STRING("InputPilot-Dupe9", name);
}

void test_friendly_name_has_deterministic_fallbacks() {
  char digitsOnly[24];
  char lettersOnly[24];
  formatDeviceName("1234", digitsOnly);
  formatDeviceName("beef", lettersOnly);
  TEST_ASSERT_EQUAL_STRING("InputPilot-Bolt1", digitsOnly);
  TEST_ASSERT_EQUAL_STRING("InputPilot-Bolt1", lettersOnly);
}

void test_null_mac_rejected() {
  char id[13];
  char suffix[5];
  TEST_ASSERT_FALSE(deviceIdFromMacBytes(nullptr, id, suffix));
}

void setUp() {}
void tearDown() {}

int main() {
  UNITY_BEGIN();
  RUN_TEST(test_device_id_from_mac);
  RUN_TEST(test_soft_ap_ssid_uses_friendly_mac_name);
  RUN_TEST(test_mdns_hostname_lower_suffix);
  RUN_TEST(test_device_name_matches_soft_ap_name);
  RUN_TEST(test_friendly_name_has_deterministic_fallbacks);
  RUN_TEST(test_null_mac_rejected);
  return UNITY_END();
}
