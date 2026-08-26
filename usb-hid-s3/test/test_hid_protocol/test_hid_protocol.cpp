#include <unity.h>
#include "HIDProtocol.h"

void setUp() {}
void tearDown() {}

void test_move_frame() {
  const uint8_t bytes[] = {1, 1, 0x2c, 0x01, 0x9c, 0xff};
  HIDMessage message; std::string error;
  TEST_ASSERT_TRUE(HIDProtocol::decode(bytes, sizeof(bytes), message, error));
  TEST_ASSERT_EQUAL(300, message.x);
  TEST_ASSERT_EQUAL(-100, message.y);
  TEST_ASSERT_EQUAL_STRING("move 300 -100", HIDProtocol::command(message).c_str());
}

void test_button_and_release_frames() {
  const uint8_t down[] = {1, 3, 1};
  HIDMessage message; std::string error;
  TEST_ASSERT_TRUE(HIDProtocol::decode(down, sizeof(down), message, error));
  TEST_ASSERT_EQUAL_STRING("button right down", HIDProtocol::command(message).c_str());
  const uint8_t release[] = {1, 0x20};
  TEST_ASSERT_TRUE(HIDProtocol::decode(release, sizeof(release), message, error));
  TEST_ASSERT_EQUAL_STRING("release all", HIDProtocol::command(message).c_str());
}

void test_rejects_bad_frames() {
  HIDMessage message; std::string error;
  const uint8_t wrongVersion[] = {2, 0x20};
  TEST_ASSERT_FALSE(HIDProtocol::decode(wrongVersion, sizeof(wrongVersion), message, error));
  const uint8_t badButton[] = {1, 3, 9};
  TEST_ASSERT_FALSE(HIDProtocol::decode(badButton, sizeof(badButton), message, error));
}

void test_keyboard_report_frame() {
  const uint8_t bytes[] = {1, 0x13, 0x40, 0x14};
  HIDMessage m; std::string error;
  TEST_ASSERT_TRUE(HIDProtocol::decode(bytes, sizeof(bytes), m, error));
  TEST_ASSERT_EQUAL_HEX8(0x40, m.modifier);
  TEST_ASSERT_EQUAL_HEX8(0x14, m.keycode);
  TEST_ASSERT_EQUAL_STRING("report 64 20", HIDProtocol::command(m).c_str());
}

int main(int, char **) {
  UNITY_BEGIN();
  RUN_TEST(test_move_frame);
  RUN_TEST(test_button_and_release_frames);
  RUN_TEST(test_rejects_bad_frames);
  RUN_TEST(test_keyboard_report_frame);
  return UNITY_END();
}
