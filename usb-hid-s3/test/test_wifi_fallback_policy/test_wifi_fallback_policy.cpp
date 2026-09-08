#include <unity.h>

#include "WifiFallbackPolicy.h"

using WifiFallbackPolicy::RetryDecision;

void test_retry_waits_without_credentials_or_before_interval() {
  TEST_ASSERT_EQUAL_INT(static_cast<int>(RetryDecision::Wait),
                        static_cast<int>(WifiFallbackPolicy::decide(0, true, 0)));
  TEST_ASSERT_EQUAL_INT(static_cast<int>(RetryDecision::Wait),
                        static_cast<int>(WifiFallbackPolicy::decide(1, false, 0)));
}

void test_retry_is_deferred_while_phone_is_on_fallback_ap() {
  TEST_ASSERT_EQUAL_INT(
      static_cast<int>(RetryDecision::DeferForActiveClient),
      static_cast<int>(WifiFallbackPolicy::decide(2, true, 1)));
}

void test_station_retry_is_allowed_without_ap_clients() {
  TEST_ASSERT_EQUAL_INT(
      static_cast<int>(RetryDecision::RetryStation),
      static_cast<int>(WifiFallbackPolicy::decide(2, true, 0)));
}

int main(int, char **) {
  UNITY_BEGIN();
  RUN_TEST(test_retry_waits_without_credentials_or_before_interval);
  RUN_TEST(test_retry_is_deferred_while_phone_is_on_fallback_ap);
  RUN_TEST(test_station_retry_is_allowed_without_ap_clients);
  return UNITY_END();
}
