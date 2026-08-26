#ifndef HID_PROTOCOL_H
#define HID_PROTOCOL_H

#include <cstddef>
#include <cstdint>
#include <string>

// Compact transport-neutral frame: version, type, payload. Integers are LE.
enum class HIDMessageType : uint8_t {
  MouseMove = 0x01, MouseScroll = 0x02, MouseButtonDown = 0x03,
  MouseButtonUp = 0x04, MouseClick = 0x05, KeyboardText = 0x10,
  KeyboardKey = 0x11, KeyboardCombo = 0x12, KeyboardReport = 0x13,
  ReleaseAll = 0x20,
  Ping = 0x7f
};

struct HIDMessage {
  HIDMessageType type = HIDMessageType::Ping;
  int16_t x = 0;
  int16_t y = 0;
  int16_t wheel = 0;
  uint8_t button = 0;
  uint8_t modifier = 0;
  uint8_t keycode = 0;
  std::string text;
};

class HIDProtocol {
public:
  static constexpr uint8_t Version = 1;
  static bool decode(const uint8_t *data, size_t length, HIDMessage &out,
                     std::string &error);
  static std::string command(const HIDMessage &message);
};

#endif
