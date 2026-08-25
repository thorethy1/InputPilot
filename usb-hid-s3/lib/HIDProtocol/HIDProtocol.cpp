#include "HIDProtocol.h"

namespace {
int16_t le16(const uint8_t *p) {
  return static_cast<int16_t>(static_cast<uint16_t>(p[0]) |
                              (static_cast<uint16_t>(p[1]) << 8));
}
const char *buttonName(uint8_t button) {
  switch (button) { case 1: return "right"; case 2: return "middle"; default: return "left"; }
}
}

bool HIDProtocol::decode(const uint8_t *data, size_t length, HIDMessage &out,
                         std::string &error) {
  if (!data || length < 2) { error = "frame too short"; return false; }
  if (data[0] != Version) { error = "unsupported protocol version"; return false; }
  out = HIDMessage{};
  out.type = static_cast<HIDMessageType>(data[1]);
  switch (out.type) {
    case HIDMessageType::MouseMove:
      if (length != 6) { error = "mouse move length"; return false; }
      out.x = le16(data + 2); out.y = le16(data + 4); break;
    case HIDMessageType::MouseScroll:
      if (length != 4) { error = "scroll length"; return false; }
      out.wheel = le16(data + 2); break;
    case HIDMessageType::MouseButtonDown:
    case HIDMessageType::MouseButtonUp:
    case HIDMessageType::MouseClick:
      if (length != 3 || data[2] > 2) { error = "button payload"; return false; }
      out.button = data[2]; break;
    case HIDMessageType::KeyboardText:
    case HIDMessageType::KeyboardKey:
    case HIDMessageType::KeyboardCombo:
      if (length < 3 || length > 242) { error = "keyboard payload"; return false; }
      out.text.assign(reinterpret_cast<const char *>(data + 2), length - 2); break;
    case HIDMessageType::ReleaseAll:
    case HIDMessageType::Ping:
      if (length != 2) { error = "control payload"; return false; }
      break;
    default: error = "unknown message type"; return false;
  }
  error.clear();
  return true;
}

std::string HIDProtocol::command(const HIDMessage &m) {
  switch (m.type) {
    case HIDMessageType::MouseMove: return "move " + std::to_string(m.x) + " " + std::to_string(m.y);
    case HIDMessageType::MouseScroll: return "move 0 0 " + std::to_string(m.wheel);
    case HIDMessageType::MouseButtonDown: return std::string("button ") + buttonName(m.button) + " down";
    case HIDMessageType::MouseButtonUp: return std::string("button ") + buttonName(m.button) + " up";
    case HIDMessageType::MouseClick: return std::string("click ") + buttonName(m.button);
    case HIDMessageType::KeyboardText: return "type " + m.text;
    case HIDMessageType::KeyboardKey:
    case HIDMessageType::KeyboardCombo: return "key " + m.text;
    case HIDMessageType::ReleaseAll: return "release all";
    case HIDMessageType::Ping: return "";
  }
  return "";
}
