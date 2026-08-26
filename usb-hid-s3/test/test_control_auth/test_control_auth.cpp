#include <unity.h>

// Exercise ControlAuth with a non-empty token (default Config has "").
#define CONTROL_API_TOKEN "test-token"
#include "ControlAuth.h"

void test_auth_required_when_token_set() {
  TEST_ASSERT_TRUE(controlAuthRequired());
}

void test_token_match() {
  TEST_ASSERT_TRUE(controlTokenMatches("test-token"));
  TEST_ASSERT_FALSE(controlTokenMatches("wrong"));
  TEST_ASSERT_FALSE(controlTokenMatches(""));
  TEST_ASSERT_FALSE(controlTokenMatches(nullptr));
}

void test_gate_rejects_until_auth() {
  bool authed = false;
  TEST_ASSERT_EQUAL(ControlLineGate::Reject, controlGateLine("move 1 0", &authed));
  TEST_ASSERT_FALSE(authed);
  TEST_ASSERT_EQUAL(ControlLineGate::Consumed, controlGateLine("auth wrong", &authed));
  TEST_ASSERT_FALSE(authed);
  TEST_ASSERT_EQUAL(ControlLineGate::Consumed, controlGateLine("auth test-token", &authed));
  TEST_ASSERT_TRUE(authed);
  TEST_ASSERT_EQUAL(ControlLineGate::Accept, controlGateLine("move 1 0", &authed));
}

void test_auth_replies_are_fixed_and_do_not_reflect_secret() {
  TEST_ASSERT_NULL(controlAuthReply(ControlLineGate::Accept, true));
  TEST_ASSERT_EQUAL_STRING("auth ok", controlAuthReply(ControlLineGate::Consumed, true));
  TEST_ASSERT_EQUAL_STRING("auth failed", controlAuthReply(ControlLineGate::Consumed, false));
  TEST_ASSERT_NULL(strstr(controlAuthReply(ControlLineGate::Consumed, true), "test-token"));
  TEST_ASSERT_NULL(strstr(controlAuthReply(ControlLineGate::Consumed, false), "test-token"));
}

void test_auth_failure_resets_a_previously_authenticated_session() {
  bool authed = true;
  TEST_ASSERT_EQUAL(ControlLineGate::Consumed, controlGateLine("auth wrong", &authed));
  TEST_ASSERT_FALSE(authed);
  TEST_ASSERT_EQUAL(ControlLineGate::Reject, controlGateLine("release all", &authed));
}

void setUp() {}
void tearDown() {}

int main() {
  UNITY_BEGIN();
  RUN_TEST(test_auth_required_when_token_set);
  RUN_TEST(test_token_match);
  RUN_TEST(test_gate_rejects_until_auth);
  RUN_TEST(test_auth_replies_are_fixed_and_do_not_reflect_secret);
  RUN_TEST(test_auth_failure_resets_a_previously_authenticated_session);
  return UNITY_END();
}
