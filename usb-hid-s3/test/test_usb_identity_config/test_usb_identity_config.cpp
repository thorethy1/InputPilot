#include <unity.h>

#define UNIT_TEST
#include "USBIdentityConfig.h"

void test_product_name_validation() {
  TEST_ASSERT_TRUE(usbProductNameValid("InputPilot"));
  TEST_ASSERT_FALSE(usbProductNameValid(""));
  TEST_ASSERT_FALSE(usbProductNameValid("01234567890123456789012345678901"));
  TEST_ASSERT_FALSE(usbProductNameValid("InputPilot\n"));
}

void test_serial_validation() {
  TEST_ASSERT_TRUE(usbSerialNumberValid("aabbccddeeff"));
  TEST_ASSERT_TRUE(usbSerialNumberValid("Desk-InputPilot_1.0"));
  TEST_ASSERT_FALSE(usbSerialNumberValid("serial with spaces"));
  TEST_ASSERT_FALSE(usbSerialNumberValid(""));
}

void test_vid_pid_validation() {
  TEST_ASSERT_TRUE(usbVidPidValid(0xcafe));
  TEST_ASSERT_TRUE(usbVidPidValid(0x4001));
  TEST_ASSERT_FALSE(usbVidPidValid(0));
  TEST_ASSERT_FALSE(usbVidPidValid(0x10000));
}

void setUp() {}
void tearDown() {}

int main() {
  UNITY_BEGIN();
  RUN_TEST(test_product_name_validation);
  RUN_TEST(test_serial_validation);
  RUN_TEST(test_vid_pid_validation);
  return UNITY_END();
}
