#include <unity.h>

#include "BLEAdvertisingRecovery.h"

void test_recovers_enabled_idle_non_advertising_stack() {
  TEST_ASSERT_TRUE(BLEAdvertisingRecovery::shouldAttempt(true, true, false, false));
}

void test_does_not_restart_while_connected_or_already_advertising() {
  TEST_ASSERT_FALSE(BLEAdvertisingRecovery::shouldAttempt(true, true, true, false));
  TEST_ASSERT_FALSE(BLEAdvertisingRecovery::shouldAttempt(true, true, false, true));
}

void test_does_not_restart_disabled_or_unready_stack() {
  TEST_ASSERT_FALSE(BLEAdvertisingRecovery::shouldAttempt(false, true, false, false));
  TEST_ASSERT_FALSE(BLEAdvertisingRecovery::shouldAttempt(true, false, false, false));
}

void setUp() {}
void tearDown() {}

int main() {
  UNITY_BEGIN();
  RUN_TEST(test_recovers_enabled_idle_non_advertising_stack);
  RUN_TEST(test_does_not_restart_while_connected_or_already_advertising);
  RUN_TEST(test_does_not_restart_disabled_or_unready_stack);
  return UNITY_END();
}
