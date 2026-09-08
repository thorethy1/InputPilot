#include <unity.h>

#include "BLEDiscoveryMetadata.h"
#include "ProtocolCapabilities.h"

void test_metadata_is_complete_and_below_gatt_limit() {
  const std::string json = BLEDiscoveryMetadata::build(
      "aabbccddeeff", "InputPilot-Dupe9");
  TEST_ASSERT_FALSE(json.empty());
  TEST_ASSERT_LESS_THAN(BLEDiscoveryMetadata::MaxGattValueBytes, json.size());
  TEST_ASSERT_NOT_EQUAL(std::string::npos,
                        json.find("\"deviceId\":\"aabbccddeeff\""));
  TEST_ASSERT_NOT_EQUAL(std::string::npos,
                        json.find("\"secure_protocol_v2\""));
  TEST_ASSERT_NOT_EQUAL(std::string::npos,
                        json.find("\"protocol_core\""));
  TEST_ASSERT_NOT_EQUAL(std::string::npos,
                        json.find("\"secure_wifi_setup\""));
  TEST_ASSERT_NOT_EQUAL(std::string::npos,
                        json.find("\"multiple_wifi\""));
  TEST_ASSERT_NOT_EQUAL(std::string::npos,
                        json.find("\"usb_manufacturer\""));
  TEST_ASSERT_EQUAL_CHAR('}', json.back());
}

void test_oversized_name_is_rejected_instead_of_truncated() {
  const std::string name(400, 'x');
  TEST_ASSERT_TRUE(BLEDiscoveryMetadata::build("aabbccddeeff", name.c_str()).empty());
}

void test_radio_mode_is_distinct_from_supported_capabilities() {
  TEST_ASSERT_EQUAL_STRING("\"none\"",
                           ProtocolCapabilities::radioModeJson(false, false));
  TEST_ASSERT_EQUAL_STRING("\"ble\"",
                           ProtocolCapabilities::radioModeJson(true, false));
  TEST_ASSERT_EQUAL_STRING("\"wifi\"",
                           ProtocolCapabilities::radioModeJson(false, true));
  TEST_ASSERT_EQUAL_STRING("\"wifi+ble\"",
                           ProtocolCapabilities::radioModeJson(true, true));
}

int main(int, char **) {
  UNITY_BEGIN();
  RUN_TEST(test_metadata_is_complete_and_below_gatt_limit);
  RUN_TEST(test_oversized_name_is_rejected_instead_of_truncated);
  RUN_TEST(test_radio_mode_is_distinct_from_supported_capabilities);
  return UNITY_END();
}
