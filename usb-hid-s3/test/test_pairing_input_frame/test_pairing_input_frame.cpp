#include <unity.h>
#include <cstring>

#include "PairingInputFrame.h"

void setUp() {}
void tearDown() {}

void test_formats_fixed_length_uppercase_frame_without_secret_logging() {
  const uint8_t secret[16] = {0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                              0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff};
  char output[PairingInputFrame::EncodedLength + 1]{};
  TEST_ASSERT_TRUE(PairingInputFrame::format("aabbccddeeff", secret, output, sizeof(output)));
  TEST_ASSERT_EQUAL(PairingInputFrame::EncodedLength, strlen(output));
  TEST_ASSERT_TRUE(strncmp(output, "IPPAIR1aabbccddeeff00112233445566778899AABBCCDDEEFF", 51) == 0);
  TEST_ASSERT_EQUAL('\n', output[PairingInputFrame::EncodedLength - 1]);
}

void test_rejects_wrong_device_id_or_small_output() {
  const uint8_t secret[16]{};
  char output[PairingInputFrame::EncodedLength + 1]{};
  TEST_ASSERT_FALSE(PairingInputFrame::format("short", secret, output, sizeof(output)));
  TEST_ASSERT_FALSE(PairingInputFrame::format("aabbccddeeff", secret, output, PairingInputFrame::EncodedLength));
}

int main(int, char **) {
  UNITY_BEGIN();
  RUN_TEST(test_formats_fixed_length_uppercase_frame_without_secret_logging);
  RUN_TEST(test_rejects_wrong_device_id_or_small_output);
  return UNITY_END();
}
