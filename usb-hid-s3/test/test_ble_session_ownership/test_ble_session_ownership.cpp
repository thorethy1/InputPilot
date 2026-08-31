#include <unity.h>

#include "BLESessionOwnership.h"

void setUp() {}
void tearDown() {}

void test_first_connection_claims_session() {
  BLESessionOwnership ownership(15000);
  TEST_ASSERT_EQUAL_INT(
      static_cast<int>(BLESessionOwnership::ClaimResult::Claimed),
      static_cast<int>(ownership.claim(7, 100)));
  TEST_ASSERT_TRUE(ownership.connected());
  TEST_ASSERT_TRUE(ownership.owns(7));
}

void test_second_connection_cannot_displace_owner() {
  BLESessionOwnership ownership(15000);
  ownership.claim(7, 100);
  ownership.authenticated(7);
  TEST_ASSERT_EQUAL_INT(
      static_cast<int>(BLESessionOwnership::ClaimResult::Rejected),
      static_cast<int>(ownership.claim(9, 200)));
  TEST_ASSERT_TRUE(ownership.owns(7));
  TEST_ASSERT_FALSE(ownership.owns(9));
  TEST_ASSERT_FALSE(ownership.release(9));
  TEST_ASSERT_TRUE(ownership.owns(7));
}

void test_unauthenticated_owner_expires_but_authenticated_owner_does_not() {
  BLESessionOwnership ownership(15000);
  ownership.claim(3, 1000);
  TEST_ASSERT_FALSE(ownership.authenticationExpired(15999, false));
  TEST_ASSERT_TRUE(ownership.authenticationExpired(16000, false));
  ownership.authenticated(3);
  TEST_ASSERT_FALSE(ownership.authenticationExpired(50000, true));
}

void test_timeout_handles_millis_wraparound() {
  BLESessionOwnership ownership(32);
  ownership.claim(3, UINT32_MAX - 15);
  TEST_ASSERT_FALSE(ownership.authenticationExpired(15, false));
  TEST_ASSERT_TRUE(ownership.authenticationExpired(16, false));
}

void test_owner_disconnect_releases_session() {
  BLESessionOwnership ownership(15000);
  ownership.claim(4, 0);
  TEST_ASSERT_TRUE(ownership.release(4));
  TEST_ASSERT_FALSE(ownership.connected());
  TEST_ASSERT_EQUAL_UINT16(BLESessionOwnership::NoOwner, ownership.owner());
}

int main(int, char **) {
  UNITY_BEGIN();
  RUN_TEST(test_first_connection_claims_session);
  RUN_TEST(test_second_connection_cannot_displace_owner);
  RUN_TEST(test_unauthenticated_owner_expires_but_authenticated_owner_does_not);
  RUN_TEST(test_timeout_handles_millis_wraparound);
  RUN_TEST(test_owner_disconnect_releases_session);
  return UNITY_END();
}
