#include <unity.h>

#include "SecureReplySizing.h"

void test_short_replies_keep_legacy_text_format() {
  TEST_ASSERT_EQUAL_UINT32(90, SecureReplySizing::textRecordLength(14));
  TEST_ASSERT_FALSE(SecureReplySizing::requiresBinary(14, 244));
}

void test_usb_identity_uses_compact_binary_record() {
  constexpr size_t identityBytes = 115;
  TEST_ASSERT_EQUAL_UINT32(292, SecureReplySizing::textRecordLength(identityBytes));
  TEST_ASSERT_EQUAL_UINT32(140, SecureReplySizing::binaryRecordLength(identityBytes));
  TEST_ASSERT_TRUE(SecureReplySizing::requiresBinary(identityBytes, 182));
  TEST_ASSERT_TRUE(SecureReplySizing::binaryRecordLength(identityBytes) <= 182);
  TEST_ASSERT_TRUE(SecureReplySizing::requiresBinary(identityBytes, 244));
  TEST_ASSERT_FALSE(SecureReplySizing::requiresBinary(identityBytes, 292));
}

void setUp() {}
void tearDown() {}

int main() {
  UNITY_BEGIN();
  RUN_TEST(test_short_replies_keep_legacy_text_format);
  RUN_TEST(test_usb_identity_uses_compact_binary_record);
  return UNITY_END();
}
