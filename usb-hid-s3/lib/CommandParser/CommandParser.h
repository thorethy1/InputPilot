#ifndef COMMAND_PARSER_H
#define COMMAND_PARSER_H

// Pure, Arduino-free parsing of the serial command line.
// Unit-tested under env:native (see test/test_command_parser).

#include <string>

enum class CmdType {
  None,          // empty line
  Unknown,       // unrecognized / invalid
  Move,          // move dx dy [wheel]
  Click,         // click [left|right|middle]
  ButtonDown,    // button <left|right|middle> down
  ButtonUp,      // button <left|right|middle> up
  ReleaseAll,    // release all mouse buttons and keyboard keys
  Type,          // type <text>
  Key,           // key <name[+name...]>
  KeyboardReport,// report <modifier-byte> <usage-byte>
  JiggleOn,      // jiggle on
  JiggleOff,     // jiggle off
  JiggleStatus,  // jiggle | jiggle status
  JiggleInterval,// jiggle interval <milliseconds>
  AutoClickOn,   // autoclick on
  AutoClickOff,  // autoclick off
  AutoClickStatus,
  AutoClickInterval,
  PairingTest,    // pairtest: emit a non-enforcing USB HID pairing frame
  Radio,         // radio wifi|ble|none
  WifiStatus,    // wifi | wifi status
  WifiSet,       // wifi set <ssid> <pass...>
  WifiClear,     // wifi clear
  Status,        // status
  Version,       // version
  Help,          // help
};

enum class MouseBtn { Left, Right, Middle };
enum class RadioSel { None, Wifi, Ble, WifiBle };

struct ParsedCommand {
  CmdType type = CmdType::None;

  // Move
  int dx = 0;
  int dy = 0;
  int wheel = 0;
  int modifier = 0;
  int keycode = 0;
  int intervalMs = 0;

  // Click
  MouseBtn button = MouseBtn::Left;

  // Type (verbatim, case + spaces preserved) / Key (name, lowercased)
  // WifiSet: text = ssid, text2 = password (may contain spaces)
  std::string text;
  std::string text2;

  // Radio
  RadioSel radio = RadioSel::None;

  // Populated when type == Unknown
  std::string error;
};

class CommandParser {
public:
  // Parse a single command line (no trailing newline required).
  static ParsedCommand parse(const std::string &line);
};

#endif // COMMAND_PARSER_H
