#include <unity.h>
#include <initializer_list>

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

void test_ap_pulse_preserves_normal_status_between_flashes() {
  Inputs inputs;
  inputs.fallbackApActive = true;
  inputs.controllerConnected = true;
  for (uint32_t now : {0U, 179U, 4000U, 4179U}) {
    TEST_ASSERT_EQUAL_INT(static_cast<int>(State::FallbackAp),
                          static_cast<int>(StatusLedPolicy::resolve(inputs, now)));
  }
  for (uint32_t now : {180U, 3999U, 4180U, 7999U}) {
    TEST_ASSERT_EQUAL_INT(static_cast<int>(State::ControllerConnected),
                          static_cast<int>(StatusLedPolicy::resolve(inputs, now)));
  }
  inputs.keepAwakeActive = true;
  TEST_ASSERT_EQUAL_INT(static_cast<int>(State::KeepAwake),
                        static_cast<int>(StatusLedPolicy::resolve(inputs, 2000)));
  inputs.otaActive = true;
  TEST_ASSERT_EQUAL_INT(static_cast<int>(State::Ota),
                        static_cast<int>(StatusLedPolicy::resolve(inputs, 4000)));
}

int main(int, char **) {
  UNITY_BEGIN();
  RUN_TEST(test_ble_only_ready_is_not_reported_as_wifi_error);
  RUN_TEST(test_fallback_ap_and_keep_awake_have_stable_priorities);
  RUN_TEST(test_ota_has_highest_priority);
  RUN_TEST(test_ap_pulse_preserves_normal_status_between_flashes);
  return UNITY_END();
}
