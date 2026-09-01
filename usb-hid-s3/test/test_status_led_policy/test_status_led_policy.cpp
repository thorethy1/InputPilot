#include <unity.h>

#include "StatusLedPolicy.h"

using StatusLedPolicy::Inputs;
using StatusLedPolicy::State;

void test_ble_only_ready_is_not_reported_as_wifi_error() {
  Inputs inputs;
  inputs.controlRadioReady = true;
  TEST_ASSERT_EQUAL_INT(static_cast<int>(State::Ready),
                        static_cast<int>(StatusLedPolicy::resolve(inputs)));
}

void test_fallback_ap_and_keep_awake_have_stable_priorities() {
  Inputs inputs;
  inputs.controlRadioReady = true;
  inputs.keepAwakeActive = true;
  TEST_ASSERT_EQUAL_INT(static_cast<int>(State::KeepAwake),
                        static_cast<int>(StatusLedPolicy::resolve(inputs)));
  inputs.fallbackApActive = true;
  TEST_ASSERT_EQUAL_INT(static_cast<int>(State::FallbackAp),
                        static_cast<int>(StatusLedPolicy::resolve(inputs)));
}

void test_ota_has_highest_priority() {
  Inputs inputs;
  inputs.otaActive = true;
  inputs.fallbackApActive = true;
  inputs.keepAwakeActive = true;
  inputs.controllerConnected = true;
  inputs.controlRadioReady = true;
  TEST_ASSERT_EQUAL_INT(static_cast<int>(State::Ota),
                        static_cast<int>(StatusLedPolicy::resolve(inputs)));
}

int main(int, char **) {
  UNITY_BEGIN();
  RUN_TEST(test_ble_only_ready_is_not_reported_as_wifi_error);
  RUN_TEST(test_fallback_ap_and_keep_awake_have_stable_priorities);
  RUN_TEST(test_ota_has_highest_priority);
  return UNITY_END();
}
