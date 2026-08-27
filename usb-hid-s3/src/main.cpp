// USB HID Mouse+Keyboard on ESP32-S3 (ESP32 core native USB: USBCDC + USBHID).
//
// Composite device: USB-CDC serial (logging + command interface) plus a HID
// keyboard (report id 1) and mouse (report id 2), driven by the ESP32 core's
// native USB stack. The Adafruit TinyUSB stack was dropped because, combined
// with the core USBCDC, its re-enumeration left the CDC OUT endpoint (serial
// RX) non-functional; the core stack integrates CDC RX+TX and HID cleanly.
//
// Serial commands (move/click/type/key/jiggle/radio/...) plus a FreeRTOS jiggle
// task. The `radio` command activates WiFi, BLE, both, or neither.

#include <Arduino.h>
#include "USB.h"
#include "USBHIDMouse.h"
#include "USBHIDKeyboard.h"

#include "Config.h"
#include "Logging.h"

#include "CommandParser.h"
#include "CommandSink.h"
#include "DeviceIdentity.h"
#include "JiggleEngine.h"
#include "KeyMap.h"
#include "RadioMode.h"
#include "RadioManager.h"
#include "StatusLed.h"
#include "WifiCredentials.h"
#include "BLEOTA.h"
#include "OTAEngine.h"
#include "FirmwareMetadata.h"
#include "HIDEventQueue.h"
#include <esp_system.h>
#include <atomic>

// Kept in the application image so both the device and clients can reject a
// valid ESP32 image built for another product or board before activation.
extern "C" const char inputPilotFirmwareMetadata[] __attribute__((used)) =
    FW_METADATA_PREFIX "product=" FW_PRODUCT ";board=" FW_BOARD ";version=" FW_VERSION
    ";protocol=1;otaSchema=1;commit=" FW_GIT_COMMIT ";";

// ---------------------------------------------------------------------------
// USB devices (core stack). ARDUINO_USB_CDC_ON_BOOT=0, so the core does NOT
// auto-start USB at boot; we register identity + HID + CDC here and call
// USB.begin() exactly once (ESPUSB::begin() only inits TinyUSB on the first
// call, so everything must be registered before it).
//
// UsbSerial is our USB-CDC (replaces the boot `Serial`); Logging.h logs to it.
// ---------------------------------------------------------------------------
USBCDC UsbSerial(0);
static USBHIDMouse Mouse;
static USBHIDKeyboard Keyboard;
static USBHID g_hid;  // standalone handle used only for ready() (global HID state)

// ---------------------------------------------------------------------------
// Shared state
// ---------------------------------------------------------------------------
static JiggleEngine g_jiggle(JIGGLE_MAX_DELTA, JIGGLE_INTERVAL_MS);
static SemaphoreHandle_t g_hidQueueMutex = nullptr;
static HIDEventQueue g_hidQueue;
static std::atomic<uint32_t> g_hidEnqueueSequence{0};
static std::atomic<uint32_t> g_hidProcessedSequence{0};
static uint32_t g_lastMoveQueueLogMs = 0;
static HIDDiagnosticsSnapshot g_hidStats;
static portMUX_TYPE g_hidStatsMux = portMUX_INITIALIZER_UNLOCKED;
static uint8_t g_mouseButtons = 0;
static char g_activeText[256]{};
static size_t g_activeTextOffset = 0;
static HIDEvent g_activeTextEvent;
static bool g_activeTextOK = true;
static std::atomic<bool> g_cancelActiveText{false};
static uint32_t g_hidPauseUntil = 0;

static char g_cmdBuf[SERIAL_CMD_MAXLEN];
static size_t g_cmdLen = 0;
static uint32_t g_lastHeartbeatMs = 0;
static const uint32_t HEARTBEAT_MS = 10000;

// ---------------------------------------------------------------------------
// HID helpers. These functions are called only by processHIDQueue() from the
// Arduino loop. Transport callbacks only decode and enqueue.
// ---------------------------------------------------------------------------
static bool hidReady() {
  return g_hid.ready();
}

static int8_t clamp8(int v) {
  if (v > 127) return 127;
  if (v < -127) return -127;
  return (int8_t)v;
}

// Move the mouse by (dx,dy) pixels and scroll `wheel`, chunked into int8 steps.
static bool hidMouseMove(int dx, int dy, int wheel) {
  if (!hidReady()) {
    LOG_HID("mouse move skipped: not-ready");
    return false;
  }
  int rx = dx, ry = dy, rw = wheel;
  bool ok = true;
  do {
    int8_t sx = clamp8(rx);
    int8_t sy = clamp8(ry);
    int8_t sw = clamp8(rw);
    hid_mouse_report_t report = {.buttons = g_mouseButtons, .x = sx, .y = sy, .wheel = sw, .pan = 0};
    ok = Mouse.sendReport(report) && ok;
    rx -= sx;
    ry -= sy;
    rw -= sw;
  } while (rx || ry || rw);
  return ok;
}

static uint8_t buttonMask(MouseBtn b) {
  switch (b) {
    case MouseBtn::Right: return MOUSE_RIGHT;
    case MouseBtn::Middle: return MOUSE_MIDDLE;
    case MouseBtn::Left:
    default: return MOUSE_LEFT;
  }
}

static bool hidClick(MouseBtn b) {
  if (!hidReady()) {
    LOG_HID("click skipped: not-ready");
    return false;
  }
  const uint8_t mask = buttonMask(b);
  g_mouseButtons |= mask;
  hid_mouse_report_t down = {.buttons = g_mouseButtons, .x = 0, .y = 0, .wheel = 0, .pan = 0};
  const bool downOk = Mouse.sendReport(down);
  g_mouseButtons &= ~mask;
  hid_mouse_report_t up = {.buttons = g_mouseButtons, .x = 0, .y = 0, .wheel = 0, .pan = 0};
  return Mouse.sendReport(up) && downOk;
}

static bool hidMouseButton(MouseBtn b, bool down) {
  if (!hidReady()) return false;
  if (down) g_mouseButtons |= buttonMask(b); else g_mouseButtons &= ~buttonMask(b);
  hid_mouse_report_t report = {.buttons = g_mouseButtons, .x = 0, .y = 0, .wheel = 0, .pan = 0};
  return Mouse.sendReport(report);
}

static bool executeReleaseAll() {
  g_activeText[0] = '\0'; g_activeTextOffset = 0; g_mouseButtons = 0;
  hid_mouse_report_t mouse = {.buttons = 0, .x = 0, .y = 0, .wheel = 0, .pan = 0};
  hid_keyboard_report_t keyboard = {};
  const bool ok = Mouse.sendReport(mouse) && g_hid.SendReport(HID_REPORT_ID_KEYBOARD, &keyboard, sizeof(keyboard));
  LOG_HID("release all");
  return ok;
}

static bool hidTypeCharacter(uint8_t character) {
  if (!hidReady()) {
    LOG_HID("type skipped: not-ready");
    return false;
  }
  return Keyboard.write(character) > 0;
}

static bool hidKey(const KeyCode &kc) {
  if (!hidReady()) {
    LOG_HID("key skipped: not-ready");
    return false;
  }
  hid_keyboard_report_t report = {};
  report.modifier = kc.modifier;
  report.keycode[0] = kc.keycode;
  hid_keyboard_report_t empty = {};
  return g_hid.SendReport(HID_REPORT_ID_KEYBOARD, &report, sizeof(report)) &&
         g_hid.SendReport(HID_REPORT_ID_KEYBOARD, &empty, sizeof(empty));
}

static bool hidReport(uint8_t modifier, uint8_t keycode) {
  KeyCode kc;
  kc.found = true;
  kc.modifier = modifier;
  kc.keycode = keycode;
  return hidKey(kc);
}

static const char *hidEventName(HIDEventType type);

static bool enqueueHIDEventWithSequence(const HIDEvent &input, const char *source,
                                        uint32_t *queuedSequence) {
  if (!g_hidQueueMutex) return false;
  if (g_otaEngine.active() && input.type != HIDEventType::ReleaseAll) {
    LOG_WARN("HID event blocked during OTA type=%u src=%s",
             static_cast<unsigned>(input.type), source ? source : "?");
    return false;
  }
  HIDEvent event = input;
  event.sequence = g_hidEnqueueSequence.fetch_add(1) + 1;
  snprintf(event.source, sizeof(event.source), "%s", source ? source : "unknown");
  if (source && (strncmp(source, "ble", 3) == 0 || strcmp(source, "wifi") == 0 ||
                 strcmp(source, "http") == 0 || strcmp(source, "serial") == 0))
    recordHIDInput(source, static_cast<uint8_t>(event.type), 0);
  if (xSemaphoreTake(g_hidQueueMutex, pdMS_TO_TICKS(20)) != pdTRUE) {
    LOG_WARN("HID queue lock timeout src=%s", source ? source : "?");
    return false;
  }
  const bool accepted = g_hidQueue.push(event);
  const size_t depth = g_hidQueue.size();
  xSemaphoreGive(g_hidQueueMutex);
  if (!accepted) {
    portENTER_CRITICAL(&g_hidStatsMux); ++g_hidStats.queueRejected; portEXIT_CRITICAL(&g_hidStatsMux);
    LOG_WARN("HID %s event queue failure type=%u depth=%u src=%s",
             event.critical() ? "critical" : "queue overflow",
             static_cast<unsigned>(event.type), static_cast<unsigned>(depth),
             source ? source : "?");
    if (event.type == HIDEventType::ButtonUp) requestReleaseAll("button-up-recovery");
    return false;
  }
  portENTER_CRITICAL(&g_hidStatsMux);
  ++g_hidStats.queued;
  g_hidStats.lastSequence = event.sequence;
  snprintf(g_hidStats.lastSource, sizeof(g_hidStats.lastSource), "%s", event.source);
  snprintf(g_hidStats.lastQueuedEvent, sizeof(g_hidStats.lastQueuedEvent), "%s", hidEventName(event.type));
  portEXIT_CRITICAL(&g_hidStatsMux);
  if (queuedSequence) *queuedSequence = event.sequence;
  if (event.type != HIDEventType::MouseMove || millis() - g_lastMoveQueueLogMs >= 1000) {
    if (event.type == HIDEventType::MouseMove) g_lastMoveQueueLogMs = millis();
    LOG_HID_DEBUG("queue enqueue type=%u depth=%u src=%s",
                  static_cast<unsigned>(event.type), static_cast<unsigned>(depth),
                  source ? source : "?");
  }
  return true;
}

bool enqueueHIDEvent(const HIDEvent &input, const char *source) {
  return enqueueHIDEventWithSequence(input, source, nullptr);
}

void requestReleaseAll(const char *source) {
  g_cancelActiveText.store(true);
  if (!enqueueHIDEvent(HIDEvent::releaseAll(), source))
    LOG_ERROR("HID releaseAll queue failure src=%s", source ? source : "?");
}

bool requestReleaseAllAndWait(const char *source, uint32_t timeoutMs) {
  uint32_t sequence = 0;
  if (!enqueueHIDEventWithSequence(HIDEvent::releaseAll(), source, &sequence)) return false;
  const uint32_t start = millis();
  while (g_hidProcessedSequence.load() < sequence && millis() - start < timeoutMs) delay(1);
  if (g_hidProcessedSequence.load() < sequence) {
    LOG_ERROR("HID executor timeout waiting releaseAll src=%s", source ? source : "?");
    return false;
  }
  return true;
}

static bool popHIDEvent(HIDEvent &event) {
  if (xSemaphoreTake(g_hidQueueMutex, pdMS_TO_TICKS(50)) != pdTRUE) return false;
  const bool available = g_hidQueue.pop(event);
  xSemaphoreGive(g_hidQueueMutex);
  return available;
}

static const char *hidEventName(HIDEventType type) {
  switch (type) {
    case HIDEventType::MouseMove: return "mouse_move"; case HIDEventType::Click: return "click";
    case HIDEventType::ButtonDown: return "button_down"; case HIDEventType::ButtonUp: return "button_up";
    case HIDEventType::TypeText: return "keyboard_text"; case HIDEventType::KeyboardReport: return "keyboard_report";
    case HIDEventType::ReleaseAll: return "release_all"; case HIDEventType::Pause: return "pause";
  }
  return "unknown";
}

static void recordExecution(const HIDEvent &event, bool ok) {
  portENTER_CRITICAL(&g_hidStatsMux);
  if (ok) ++g_hidStats.executed; else ++g_hidStats.executeFailed;
  if (event.type == HIDEventType::MouseMove || event.type == HIDEventType::Click ||
      event.type == HIDEventType::ButtonDown || event.type == HIDEventType::ButtonUp) ++g_hidStats.mouseExecuted;
  if (event.type == HIDEventType::TypeText || event.type == HIDEventType::KeyboardReport) ++g_hidStats.keyboardExecuted;
  g_hidStats.lastSequence = event.sequence;
  snprintf(g_hidStats.lastSource, sizeof(g_hidStats.lastSource), "%s", event.source);
  snprintf(g_hidStats.lastType, sizeof(g_hidStats.lastType), "%s", hidEventName(event.type));
  snprintf(g_hidStats.lastExecutedEvent, sizeof(g_hidStats.lastExecutedEvent), "%s", hidEventName(event.type));
  portEXIT_CRITICAL(&g_hidStatsMux);
  if (!ok) LOG_ERROR("HID execute failed sequence=%lu type=%s src=%s usbReady=%s",
                     static_cast<unsigned long>(event.sequence), hidEventName(event.type), event.source,
                     hidReady() ? "true" : "false");
}

static void processHIDQueue(size_t budget = 6) {
  if (g_cancelActiveText.exchange(false)) { g_activeText[0] = '\0'; g_activeTextOffset = 0; }
  if (static_cast<int32_t>(millis() - g_hidPauseUntil) < 0) return;
  if (g_activeText[g_activeTextOffset]) {
    const bool ok = hidTypeCharacter(static_cast<uint8_t>(g_activeText[g_activeTextOffset++]));
    g_activeTextOK = g_activeTextOK && ok;
    if (!g_activeText[g_activeTextOffset]) { recordExecution(g_activeTextEvent, g_activeTextOK); g_activeText[0] = '\0'; g_activeTextOffset = 0; }
    return;
  }
  static uint32_t lastMoveExecutionLogMs = 0;
  for (size_t processed = 0; processed < budget; ++processed) {
    HIDEvent event;
    if (!popHIDEvent(event)) break;
    bool ok = true;
    switch (event.type) {
      case HIDEventType::MouseMove: ok = hidMouseMove(event.dx, event.dy, event.wheel); break;
      case HIDEventType::Click: ok = hidClick(static_cast<MouseBtn>(event.button)); break;
      case HIDEventType::ButtonDown: ok = hidMouseButton(static_cast<MouseBtn>(event.button), true); break;
      case HIDEventType::ButtonUp: ok = hidMouseButton(static_cast<MouseBtn>(event.button), false); break;
      case HIDEventType::TypeText:
        snprintf(g_activeText, sizeof(g_activeText), "%s", event.text); g_activeTextOffset = 0; g_activeTextEvent = event; g_activeTextOK = true;
        if (g_activeText[0]) { g_activeTextOK = hidTypeCharacter(static_cast<uint8_t>(g_activeText[g_activeTextOffset++])); }
        if (!g_activeText[g_activeTextOffset]) { ok = g_activeTextOK; g_activeText[0] = '\0'; g_activeTextOffset = 0; }
        else { g_hidProcessedSequence.store(event.sequence); return; }
        break;
      case HIDEventType::KeyboardReport: ok = hidReport(event.modifier, event.keycode); break;
      case HIDEventType::ReleaseAll: ok = executeReleaseAll(); break;
      case HIDEventType::Pause: g_hidPauseUntil = millis() + event.pauseMs; break;
    }
    recordExecution(event, ok);
    g_hidProcessedSequence.store(event.sequence);
    if (event.type == HIDEventType::MouseMove && millis() - lastMoveExecutionLogMs >= 1000) {
      lastMoveExecutionLogMs = millis(); LOG_HID_DEBUG("executor sequence=%lu move ok=%s", static_cast<unsigned long>(event.sequence), ok ? "true" : "false");
    }
    if (event.type == HIDEventType::Pause || g_activeText[0]) break;
  }
}

// ---------------------------------------------------------------------------
// Serial command dispatch
// ---------------------------------------------------------------------------
static void printHelp() {
  LOG_INFO("commands:");
  LOG_INFO("  move <dx> <dy> [wheel]   move mouse (relative)");
  LOG_INFO("  click [left|right|middle]");
  LOG_INFO("  button <left|right|middle> down|up");
  LOG_INFO("  release all");
  LOG_INFO("  type <text>              type a string");
  LOG_INFO("  key <name[+name...]>     press a key/combo (enter,esc,cmd+space,...)");
  LOG_INFO("  report <modifier> <usage> send a layout-resolved USB HID key report");
  LOG_INFO("  hidtest mouse|keyboard   exercise USB HID without a radio transport");
  LOG_INFO("  jiggle on|off|status");
  LOG_INFO("  radio wifi|ble|both|none enable control radios");
  LOG_INFO("  wifi status|set|clear    NVS WiFi creds (Soft-AP if none)");
  LOG_INFO("  status | version | help");
}

static void printStatus() {
  LOG_INFO("status version=%s uptime=%lus heap=%u usb=%s jiggle=%s interval=%lums radio=%s",
           FW_VERSION, (unsigned long)(millis() / 1000), (unsigned)ESP.getFreeHeap(),
           hidReady() ? "ready" : "not-ready",
           g_jiggle.isEnabled() ? "on" : "off",
           (unsigned long)g_jiggle.intervalMs(),
           g_radio.statusStr());
}

bool deviceJiggleEnabled() { return g_jiggle.isEnabled(); }
uint32_t deviceJiggleIntervalMs() { return g_jiggle.intervalMs(); }
bool deviceHidReady() { return hidReady(); }
bool deviceOtaActive() { return g_otaEngine.active(); }
HIDDiagnosticsSnapshot deviceHidDiagnostics() {
  portENTER_CRITICAL(&g_hidStatsMux); HIDDiagnosticsSnapshot copy = g_hidStats; portEXIT_CRITICAL(&g_hidStatsMux);
  return copy;
}

void recordHIDInput(const char *source, uint8_t type, size_t length) {
  portENTER_CRITICAL(&g_hidStatsMux);
  if (source && strncmp(source, "ble", 3) == 0) { ++g_hidStats.rxBle; g_hidStats.lastBleRxLength = length; g_hidStats.lastBleRxType = type; }
  else if (source && strcmp(source, "wifi") == 0) ++g_hidStats.rxTcp;
  else if (source && strcmp(source, "http") == 0) ++g_hidStats.rxRest;
  else if (source && strcmp(source, "serial") == 0) ++g_hidStats.rxSerial;
  ++g_hidStats.decoded;
  portEXIT_CRITICAL(&g_hidStatsMux);
}

void recordHIDDecodeError(const char *source, size_t length) {
  portENTER_CRITICAL(&g_hidStatsMux); ++g_hidStats.decodeErrors;
  if (source && strncmp(source, "ble", 3) == 0) { ++g_hidStats.rxBle; g_hidStats.lastBleRxLength = length; }
  portEXIT_CRITICAL(&g_hidStatsMux);
}
void recordHIDBleFrame(uint8_t type, size_t length) {
  portENTER_CRITICAL(&g_hidStatsMux); g_hidStats.lastBleRxType = type; g_hidStats.lastBleRxLength = length; portEXIT_CRITICAL(&g_hidStatsMux);
}

void handleCommandLine(const std::string &line, const char *source) {
  if (line == "hidtest mouse") {
    enqueueHIDEvent(HIDEvent::move(20, 0), source); enqueueHIDEvent(HIDEvent::pause(150), source);
    enqueueHIDEvent(HIDEvent::move(-20, 0), source); LOG_HID("hidtest mouse queued"); return;
  }
  if (line == "hidtest keyboard") {
    HIDEvent e; e.type = HIDEventType::KeyboardReport; e.keycode = 0x04;
    enqueueHIDEvent(e, source); LOG_HID("hidtest keyboard queued key=a"); return;
  }
  ParsedCommand c = CommandParser::parse(line);
  if (g_otaEngine.active() && c.type != CmdType::ReleaseAll) {
    LOG_WARN("command blocked during OTA src=%s", source ? source : "?");
    return;
  }
  if (c.type != CmdType::None)
    // Never mirror raw commands into diagnostics: they may contain typed text,
    // Wi-Fi passwords, or authentication tokens.
    LOG_CMD_DEBUG("src=%s type=%u", source ? source : "?",
                  static_cast<unsigned>(c.type));
  switch (c.type) {
    case CmdType::None:
      break;
    case CmdType::Move:
      LOG_CMD("move dx=%d dy=%d wheel=%d", c.dx, c.dy, c.wheel);
      enqueueHIDEvent(HIDEvent::move(c.dx, c.dy, c.wheel), source);
      break;
    case CmdType::Click:
      LOG_CMD("click %d", (int)c.button);
      { HIDEvent e; e.type = HIDEventType::Click; e.button = static_cast<uint8_t>(c.button); enqueueHIDEvent(e, source); }
      break;
    case CmdType::ButtonDown:
    case CmdType::ButtonUp:
      { HIDEvent e; e.type = c.type == CmdType::ButtonDown ? HIDEventType::ButtonDown : HIDEventType::ButtonUp;
        e.button = static_cast<uint8_t>(c.button); enqueueHIDEvent(e, source); }
      break;
    case CmdType::ReleaseAll:
      requestReleaseAll(source);
      break;
    case CmdType::Type:
      LOG_CMD("type len=%u", (unsigned)c.text.size());
      { HIDEvent e; e.type = HIDEventType::TypeText;
        strncpy(e.text, c.text.c_str(), sizeof(e.text) - 1); enqueueHIDEvent(e, source); }
      break;
    case CmdType::Key: {
      KeyCode kc = KeyMap::lookup(c.text);
      if (!kc.found) {
        LOG_WARN("key unknown: %s", c.text.c_str());
        break;
      }
      LOG_CMD("key %s mod=0x%02x kc=0x%02x", c.text.c_str(), kc.modifier, kc.keycode);
      { HIDEvent e; e.type = HIDEventType::KeyboardReport; e.modifier = kc.modifier;
        e.keycode = kc.keycode; enqueueHIDEvent(e, source); }
      break;
    }
    case CmdType::KeyboardReport:
      LOG_CMD("report mod=0x%02x kc=0x%02x", c.modifier, c.keycode);
      { HIDEvent e; e.type = HIDEventType::KeyboardReport; e.modifier = c.modifier;
        e.keycode = c.keycode; enqueueHIDEvent(e, source); }
      break;
    case CmdType::JiggleOn:
      g_jiggle.setEnabled(true);
      LOG_JIG("jiggle=on interval=%lums", (unsigned long)g_jiggle.intervalMs());
      break;
    case CmdType::JiggleOff:
      g_jiggle.setEnabled(false);
      LOG_JIG("jiggle=off");
      break;
    case CmdType::JiggleStatus:
      LOG_JIG("jiggle=%s interval=%lums", g_jiggle.isEnabled() ? "on" : "off",
              (unsigned long)g_jiggle.intervalMs());
      break;
    case CmdType::Radio: {
      RadioMode target = RadioMode::None;
      switch (c.radio) {
        case RadioSel::Wifi: target = RadioMode::Wifi; break;
        case RadioSel::Ble: target = RadioMode::Ble; break;
        case RadioSel::WifiBle: target = RadioMode::WifiBle; break;
        case RadioSel::None: default: target = RadioMode::None; break;
      }
      g_radio.setMode(target);
      LOG_RADIO("radio=%s status=%s", radioModeToString(g_radio.mode()),
                g_radio.statusStr());
      break;
    }
    case CmdType::WifiStatus: {
      WifiCreds wc = WifiCredentials::get();
      LOG_WIFI("wifi configured=%s ssid=\"%s\" soft_ap=%s radio=%s",
               WifiCredentials::hasSsid() ? "yes" : "no",
               wc.ssid.c_str(),
               g_radio.isSoftAp() ? "yes" : "no",
               g_radio.statusStr());
      break;
    }
    case CmdType::WifiSet: {
      if (!WifiCredentials::save(String(c.text.c_str()), String(c.text2.c_str()))) {
        LOG_WARN("wifi set failed");
        break;
      }
      LOG_WIFI("wifi set ok ssid=\"%s\"", c.text.c_str());
      g_radio.applyWifiCredentials();
      break;
    }
    case CmdType::WifiClear: {
      WifiCredentials::clear();
      LOG_WIFI("wifi clear ok");
      g_radio.applyWifiCredentials();
      break;
    }
    case CmdType::Status:
      printStatus();
      break;
    case CmdType::Version:
      LOG_INFO("version=%s name=%s", FW_VERSION, FW_NAME);
      break;
    case CmdType::Help:
      printHelp();
      break;
    case CmdType::Unknown:
    default:
      LOG_WARN("cmd error: %s", c.error.c_str());
      break;
  }
}

static void serviceSerialCommands() {
  while (UsbSerial.available()) {
    char ch = (char)UsbSerial.read();
    if (ch == '\r') continue;
    if (ch == '\n') {
      g_cmdBuf[g_cmdLen] = '\0';
      if (g_cmdLen > 0) handleCommandLine(std::string(g_cmdBuf), "serial");
      g_cmdLen = 0;
    } else if (g_cmdLen < SERIAL_CMD_MAXLEN - 1) {
      g_cmdBuf[g_cmdLen++] = ch;
    }
  }
}

// ---------------------------------------------------------------------------
// Jiggle task
// ---------------------------------------------------------------------------
static void jiggleTask(void *) {
  for (;;) {
    int dx = 0, dy = 0;
    if (g_jiggle.update(millis(), dx, dy)) {
      if (enqueueHIDEvent(HIDEvent::move(dx, dy), "jiggle")) LOG_JIG("auto dx=%d dy=%d", dx, dy);
    }
    vTaskDelay(pdMS_TO_TICKS(50));
  }
}

// ---------------------------------------------------------------------------
// Boot diagnostics
// ---------------------------------------------------------------------------
static void printBanner() {
  LOG_INFO("=== %s v%s (core USB: CDC + HID mouse+keyboard) ===", FW_NAME, FW_VERSION);
  LOG_INFO("chip=%s rev=%d cores=%d cpu=%dMHz", ESP.getChipModel(),
           ESP.getChipRevision(), ESP.getChipCores(), (int)ESP.getCpuFreqMHz());
  LOG_INFO("flash=%u bytes heap=%u min_heap=%u", (unsigned)ESP.getFlashChipSize(),
           (unsigned)ESP.getFreeHeap(), (unsigned)ESP.getMinFreeHeap());
  LOG_USB("vid=0x%04X pid=0x%04X product=\"%s\"", HID_USB_VID, HID_USB_PID, HID_USB_PRODUCT);
  LOG_INFO("boot-ok");
}

static const char *resetReasonName(esp_reset_reason_t reason) {
  switch (reason) {
    case ESP_RST_POWERON: return "POWERON";
    case ESP_RST_SW: return "SW_RESET";
    case ESP_RST_PANIC: return "PANIC";
    case ESP_RST_INT_WDT: return "INT_WDT";
    case ESP_RST_TASK_WDT: return "TASK_WDT";
    case ESP_RST_WDT: return "WDT";
    case ESP_RST_BROWNOUT: return "BROWNOUT";
    case ESP_RST_DEEPSLEEP: return "DEEPSLEEP";
    case ESP_RST_EXT: return "EXTERNAL";
    default: return "UNKNOWN";
  }
}
const char *deviceResetReason() { return resetReasonName(esp_reset_reason()); }

// ---------------------------------------------------------------------------
void setup() {
  g_hidQueueMutex = xSemaphoreCreateMutex();
  DeviceIdentity::begin();

  // Full USB bring-up, in order, BEFORE the single USB.begin():
  //   1) identity (VID/PID/strings)  2) HID devices  3) CDC  4) USB.begin()
  // ESPUSB::begin() runs tinyusb_init only once, so anything registered after
  // it is ignored. ARDUINO_USB_CDC_ON_BOOT=0 guarantees no boot-time begin().
  USB.VID(HID_USB_VID);
  USB.PID(HID_USB_PID);
  USB.productName(HID_USB_PRODUCT);
  USB.manufacturerName(HID_USB_MANUFACTURER);
  USB.firmwareVersion(FW_VERSION_BCD);

  Mouse.begin();
  Keyboard.begin();
  UsbSerial.begin(SERIAL_BAUD);
  USB.begin();

  uint32_t start = millis();
  while (!UsbSerial && (millis() - start) < 2000) delay(10);
  delay(200);

  LOG_INFO("reset_reason=%s code=%d", resetReasonName(esp_reset_reason()),
           static_cast<int>(esp_reset_reason()));
  printBanner();

  g_statusLed.begin();

#if JIGGLE_ENABLED_DEFAULT
  g_jiggle.setEnabled(true);
#endif

  xTaskCreatePinnedToCore(jiggleTask, "jiggle", 4096, nullptr, 1, nullptr, 0);

  // NVS WiFi creds (seed from compile-time WIFI_SSID on first boot).
  WifiCredentials::begin();

  // Bring up the default radio (compile-time selectable; runtime via `radio`).
  RadioMode initial = RadioMode::None;
  radioModeFromString(RADIO_MODE_DEFAULT_STR, initial);
  g_radio.begin(initial);
  LOG_RADIO("default mode=%s status=%s", radioModeToString(g_radio.mode()),
            g_radio.statusStr());

  LOG_INFO("firmware metadata=%s", inputPilotFirmwareMetadata);
  LOG_INFO("ready: type 'help' for commands");
}

void loop() {
  processHIDQueue(6);
  serviceSerialCommands();
  g_radio.loop();
  processHIDQueue(6);
  g_statusLed.loop();

  const uint32_t now = millis();
  if (now - g_lastHeartbeatMs >= HEARTBEAT_MS) {
    g_lastHeartbeatMs = now;
    LOG_INFO("heartbeat uptime=%lus heap=%u usb=%s jiggle=%s radio=%s",
             (unsigned long)(now / 1000), (unsigned)ESP.getFreeHeap(),
             hidReady() ? "ready" : "not-ready", g_jiggle.isEnabled() ? "on" : "off",
             g_radio.statusStr());
  }
  delay(2);
}
