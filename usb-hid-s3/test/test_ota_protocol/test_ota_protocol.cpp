#include <unity.h>
#include "OTAProtocol.h"

void setUp() {}
void tearDown() {}

void test_start_metadata_parses() {
  OTAStartRequest request; std::string error;
  TEST_ASSERT_TRUE(OTAProtocol::parseStart(
      "START protocol=2 version=0.8.11 size=1271270 sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      request, error));
  TEST_ASSERT_EQUAL_UINT32(2, request.protocol);
  TEST_ASSERT_EQUAL_UINT32(1271270, request.size);
  TEST_ASSERT_EQUAL_STRING("0.8.11", request.version.c_str());
}

void test_invalid_start_is_rejected() {
  OTAStartRequest request; std::string error;
  TEST_ASSERT_FALSE(OTAProtocol::parseStart("START protocol=2 size=0", request, error));
  TEST_ASSERT_NOT_EQUAL(0, error.size());
}

void test_offsets_must_be_exact_and_bounded() {
  TEST_ASSERT_TRUE(OTAProtocol::acceptsOffset(100, 100, 50, 200));
  TEST_ASSERT_FALSE(OTAProtocol::acceptsOffset(100, 99, 50, 200));
  TEST_ASSERT_FALSE(OTAProtocol::acceptsOffset(190, 190, 11, 200));
  TEST_ASSERT_FALSE(OTAProtocol::acceptsOffset(100, 100, 0, 200));
}

void test_state_names_are_stable() {
  TEST_ASSERT_EQUAL_STRING("idle", OTAProtocol::stateName(OTAState::Idle));
  TEST_ASSERT_EQUAL_STRING("receiving", OTAProtocol::stateName(OTAState::Receiving));
  TEST_ASSERT_EQUAL_STRING("failed", OTAProtocol::stateName(OTAState::Failed));
  TEST_ASSERT_EQUAL_STRING("cancelled", OTAProtocol::stateName(OTAState::Cancelled));
}

int main(int, char **) {
  UNITY_BEGIN();
  RUN_TEST(test_start_metadata_parses);
  RUN_TEST(test_invalid_start_is_rejected);
  RUN_TEST(test_offsets_must_be_exact_and_bounded);
  RUN_TEST(test_state_names_are_stable);
  return UNITY_END();
}
