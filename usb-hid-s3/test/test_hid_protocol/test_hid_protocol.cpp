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

void test_layout_resolved_modifier_reports() {
  HIDMessage m; std::string error;
  const uint8_t uppercase[] = {1, 0x13, 0x02, 0x34};  // Shift + German Ä key
  TEST_ASSERT_TRUE(HIDProtocol::decode(uppercase, sizeof(uppercase), m, error));
  TEST_ASSERT_EQUAL_STRING("report 2 52", HIDProtocol::command(m).c_str());
  const uint8_t altGr[] = {1, 0x13, 0x40, 0x14};      // AltGr + Q = @ on DE
  TEST_ASSERT_TRUE(HIDProtocol::decode(altGr, sizeof(altGr), m, error));
  TEST_ASSERT_EQUAL_STRING("report 64 20", HIDProtocol::command(m).c_str());
  const uint8_t combo[] = {1, 0x13, 0x43, 0x08};      // Ctrl + Shift + AltGr
  TEST_ASSERT_TRUE(HIDProtocol::decode(combo, sizeof(combo), m, error));
  TEST_ASSERT_EQUAL_HEX8(0x43, m.modifier);
}

void test_rejects_invalid_binary_payloads() {
  HIDMessage m; std::string error;
  const uint8_t shortMove[] = {1, 1, 0, 0};
  TEST_ASSERT_FALSE(HIDProtocol::decode(shortMove, sizeof(shortMove), m, error));
  const uint8_t unknownType[] = {1, 0x66};
  TEST_ASSERT_FALSE(HIDProtocol::decode(unknownType, sizeof(unknownType), m, error));
  const uint8_t oversizedReport[] = {1, 0x13, 0, 4, 0};
  TEST_ASSERT_FALSE(HIDProtocol::decode(oversizedReport, sizeof(oversizedReport), m, error));
}

int main(int, char **) {
  UNITY_BEGIN();
  RUN_TEST(test_move_frame);
  RUN_TEST(test_button_and_release_frames);
  RUN_TEST(test_rejects_bad_frames);
  RUN_TEST(test_keyboard_report_frame);
  RUN_TEST(test_layout_resolved_modifier_reports);
  RUN_TEST(test_rejects_invalid_binary_payloads);
  return UNITY_END();
}
