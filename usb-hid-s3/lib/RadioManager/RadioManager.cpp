#include "RadioManager.h"

#include <cstdlib>
#include <vector>
#include <WiFi.h>
#include <WiFiServer.h>
#include <WiFiClient.h>
#include <ESPmDNS.h>

#include <NimBLEDevice.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>

#include "Config.h"
#include "CommandSink.h"
#include "DeviceIdentity.h"
#include "Logging.h"
#include "HIDProtocol.h"
#include "WifiCredentials.h"
#include "WifiConfigServer.h"
#include "BLEOTA.h"
#include "BLEDiagnostics.h"
#include "BLESessionOwnership.h"
#include "OTAEngine.h"
#include "KeyMap.h"
#include "PairingSecretStore.h"
#include "SecureSession.h"
#include "USBIdentityConfig.h"

RadioManager g_radio;

// ---------------------------------------------------------------------------
// Secure Protocol v2 transport state shared by BLE and Wi-Fi/TCP.
// ---------------------------------------------------------------------------
namespace {

NimBLEServer *s_bleServer = nullptr;
NimBLECharacteristic *s_bleTx = nullptr;
// Set while stopBle() is releasing the stack so the disconnect callback does
// NOT restart advertising mid-teardown (which crashes deinit(true)).
volatile bool s_bleTearingDown = false;
bool s_bleReady = false;

bool s_bleAuthed = false;
BLESessionOwnership s_bleOwner(BLE_SECURE_AUTH_TIMEOUT_MS);
bool s_tcpAuthed = false;
WiFiServer s_tcpServer(WIFI_CONTROL_PORT);
WiFiClient s_tcpClient;
std::string s_tcpLineBuf;
SecureSession s_bleSecureSession;
SecureSession s_tcpSecureSession;

struct BLEControlFrame {
  uint16_t length = 0;
  uint8_t bytes[242]{};
};
QueueHandle_t s_bleControlQueue = nullptr;
constexpr size_t BLE_CONTROL_QUEUE_DEPTH = 16;
constexpr size_t BLE_CONTROL_FRAME_MAX = 242;
uint32_t s_managementRebootAtMs = 0;

void sendControlReply(const char *source, const char *reply) {
  if (!reply) return;
  if (strcmp(source, "ble") == 0 && s_bleTx && s_bleOwner.connected()) {
    s_bleTx->setValue(reinterpret_cast<const uint8_t *>(reply), strlen(reply));
    s_bleTx->notify(s_bleOwner.owner());
  } else if (strcmp(source, "wifi") == 0 && s_tcpClient && s_tcpClient.connected()) {
    s_tcpClient.print(reply);
    s_tcpClient.print("\n");
  }
}

void sendSecureReply(const char *source, SecureSession &session,
                     const std::string &plaintext) {
  std::string sealed;
  if (session.encryptText(plaintext, sealed)) sendControlReply(source, sealed.c_str());
}

int hexNibble(char value) {
  if (value >= '0' && value <= '9') return value - '0';
  if (value >= 'a' && value <= 'f') return value - 'a' + 10;
  if (value >= 'A' && value <= 'F') return value - 'A' + 10;
  return -1;
}

bool decodeHex(const std::string &encoded, std::string &decoded) {
  if (encoded.empty() || (encoded.size() & 1)) return false;
  decoded.assign(encoded.size() / 2, '\0');
  for (size_t i = 0; i < decoded.size(); ++i) {
    const int high = hexNibble(encoded[i * 2]);
    const int low = hexNibble(encoded[i * 2 + 1]);
    if (high < 0 || low < 0) return false;
    decoded[i] = static_cast<char>((high << 4) | low);
  }
  return true;
}

std::string jsonEscape(const String &value) {
  std::string escaped;
  escaped.reserve(value.length() + 8);
  for (size_t i = 0; i < value.length(); ++i) {
    const unsigned char c = static_cast<unsigned char>(value[i]);
    switch (c) {
      case '\"': escaped += "\\\""; break;
      case '\\': escaped += "\\\\"; break;
      case '\b': escaped += "\\b"; break;
      case '\f': escaped += "\\f"; break;
      case '\n': escaped += "\\n"; break;
      case '\r': escaped += "\\r"; break;
      case '\t': escaped += "\\t"; break;
      default:
        if (c < 0x20) {
          char unicode[7];
          snprintf(unicode, sizeof(unicode), "\\u%04x", c);
          escaped += unicode;
        } else {
          escaped += static_cast<char>(c);
        }
    }
  }
  return escaped;
}

bool dispatchSecureProtocolMessage(const std::string &message, const char *source,
                                   SecureSession &session) {
  const OTATransportOwner owner = strcmp(source, "ble") == 0
                                      ? OTATransportOwner::BLE
                                      : OTATransportOwner::WiFi;
  if (message == "DIAGNOSTICS INFO") {
    sendSecureReply(source, session, strcmp(source, "ble") == 0
                                         ? g_bleDiagnostics.compactInfoJson()
                                         : g_bleDiagnostics.infoJson());
    return true;
  }
  if (message == "WIFI STATUS") {
    const char *state = "disconnected";
    String ip;
    if (g_radio.isSoftAp()) {
      state = "soft_ap";
    } else if (WiFi.status() == WL_CONNECTED) {
      state = "connected";
      ip = WiFi.localIP().toString();
    } else if (g_radio.wifiEnabled()) {
      state = "connecting";
    }
    const std::string response =
        "{\"state\":\"" + std::string(state) + "\",\"ip\":\"" +
        std::string(ip.c_str()) + "\",\"device_id\":\"" +
        std::string(DeviceIdentity::deviceId()) + "\"}";
    sendSecureReply(source, session, response);
    return true;
  }
  if (message == "WIFI LIST") {
    sendSecureReply(source, session, "{\"count\":" +
                    std::to_string(WifiCredentials::count()) + "}");
    return true;
  }
  if (message.rfind("WIFI GET ", 0) == 0) {
    const std::string indexText = message.substr(9);
    char *end = nullptr;
    const unsigned long index = strtoul(indexText.c_str(), &end, 10);
    if (!end || *end || index >= WifiCredentials::count()) {
      sendSecureReply(source, session, "error invalid_wifi_index");
    } else {
      sendSecureReply(source, session, "{\"ssid\":\"" +
                      jsonEscape(WifiCredentials::get(index).ssid) + "\"}");
    }
    return true;
  }
  if (message.rfind("DIAGNOSTICS NEXT ", 0) == 0) {
    const std::string cursorText = message.substr(17);
    char *end = nullptr;
    uint32_t cursor = strtoul(cursorText.c_str(), &end, 10);
    if (!end || *end) sendSecureReply(source, session, "error invalid_cursor");
    else sendSecureReply(source, session, g_bleDiagnostics.nextLogJson(
        cursor, strcmp(source, "ble") == 0 ? 80 : 159));
    return true;
  }
  if (message == "USB RESET") {
    if (!USBIdentityConfig::reset()) sendSecureReply(source, session, "error invalid_usb_identity");
    else {
      requestReleaseAll("usb-identity-reset");
      sendSecureReply(source, session, "management restarting");
      s_managementRebootAtMs = millis() + 750;
    }
    return true;
  }
  if (message.rfind("USB SET ", 0) == 0) {
    const size_t first = message.find(' ', 8);
    const size_t second = first == std::string::npos ? first : message.find(' ', first + 1);
    const size_t third = second == std::string::npos ? second : message.find(' ', second + 1);
    if (first == std::string::npos || second == std::string::npos || third == std::string::npos) {
      sendSecureReply(source, session, "error invalid_usb_identity"); return true;
    }
    const std::string vidText = message.substr(8, first - 8);
    const std::string pidText = message.substr(first + 1, second - first - 1);
    char *vidEnd = nullptr; char *pidEnd = nullptr;
    const unsigned long vid = strtoul(vidText.c_str(), &vidEnd, 16);
    const unsigned long pid = strtoul(pidText.c_str(), &pidEnd, 16);
    std::string product; std::string serial;
    const bool valid = vidEnd && !*vidEnd && pidEnd && !*pidEnd &&
        decodeHex(message.substr(second + 1, third - second - 1), product) &&
        decodeHex(message.substr(third + 1), serial) &&
        USBIdentityConfig::save(product.c_str(), vid, pid, serial.c_str());
    if (!valid) sendSecureReply(source, session, "error invalid_usb_identity");
    else {
      requestReleaseAll("usb-identity-update");
      sendSecureReply(source, session, "management restarting");
      s_managementRebootAtMs = millis() + 750;
    }
    return true;
  }
  if (message == "REBOOT") {
    requestReleaseAll("secure-reboot");
    sendSecureReply(source, session, "management restarting");
    s_managementRebootAtMs = millis() + 500;
    return true;
  }
  if (message.rfind("START ", 0) == 0) {
    if (g_otaEngine.active()) {
      sendSecureReply(source, session, "error update_in_progress");
      return true;
    }
    OTAStartRequest request;
    std::string error;
    if (!OTAProtocol::parseStart(message, request, error) ||
        !g_otaEngine.start(request, owner)) {
      sendSecureReply(source, session, "error " +
          (error.empty() ? std::string(g_otaEngine.error()) : error));
    } else {
      sendSecureReply(source, session, "ota ready 0");
    }
    return true;
  }
  if (message.rfind("DATA ", 0) == 0) {
    const size_t separator = message.find(' ', 5);
    if (separator == std::string::npos || g_otaEngine.owner() != owner) {
      sendSecureReply(source, session, "error invalid_data");
      return true;
    }
    const std::string offsetText = message.substr(5, separator - 5);
    char *end = nullptr;
    const uint32_t offset = strtoul(offsetText.c_str(), &end, 10);
    const std::string encoded = message.substr(separator + 1);
    if (!end || *end || encoded.empty() || (encoded.size() & 1)) {
      sendSecureReply(source, session, "error invalid_data");
      return true;
    }
    std::string bytes(encoded.size() / 2, '\0');
    for (size_t i = 0; i < bytes.size(); ++i) {
      const int high = hexNibble(encoded[i * 2]);
      const int low = hexNibble(encoded[i * 2 + 1]);
      if (high < 0 || low < 0) {
        sendSecureReply(source, session, "error invalid_data");
        return true;
      }
      bytes[i] = static_cast<char>((high << 4) | low);
    }
    if (!g_otaEngine.write(offset, reinterpret_cast<const uint8_t *>(bytes.data()),
                           bytes.size())) {
      sendSecureReply(source, session, "error " + std::string(g_otaEngine.error()));
    } else {
      sendSecureReply(source, session,
                      "ota ack " + std::to_string(g_otaEngine.received()));
    }
    return true;
  }
  if (message == "FINISH") {
    if (g_otaEngine.owner() != owner || !g_otaEngine.finish()) {
      sendSecureReply(source, session, "error " + std::string(g_otaEngine.error()));
    } else {
      sendSecureReply(source, session, "ota success");
      s_managementRebootAtMs = millis() + 750;
    }
    return true;
  }
  if (message == "ABORT") {
    if (g_otaEngine.owner() == owner && g_otaEngine.active())
      g_otaEngine.abort("user_cancelled", true);
    sendSecureReply(source, session, "ota cancelled");
    return true;
  }
  return false;
}

void dispatchControlLine(const std::string &line, const char *source,
                         bool *authed) {
  SecureSession &session = strcmp(source, "ble") == 0
                               ? s_bleSecureSession : s_tcpSecureSession;
  std::string reply;
  if (line == "secure begin") {
    // A BLE owner gets one authentication window per connection. Repeated
    // begin messages must not extend that window indefinitely.
    if (strcmp(source, "ble") == 0 && s_bleAuthed) {
      LOG_BLE("secure renegotiation rejected; reconnect required");
      return;
    }
    uint8_t secret[PairingSecretStore::SecretSize];
    const bool ok = PairingSecretStore::load(secret) &&
                    session.begin(secret, DeviceIdentity::deviceId(), reply);
    memset(secret, 0, sizeof(secret));
    if (ok) sendControlReply(source, reply.c_str());
    if (authed) *authed = false;
    return;
  }
  if (line.rfind("secure hello ", 0) == 0) {
    const bool ok = session.acceptHello(line, reply);
    if (authed) *authed = ok;
    if (ok && strcmp(source, "ble") == 0)
      s_bleOwner.authenticated(s_bleOwner.owner());
    sendControlReply(source, ok ? reply.c_str() : "secure failed");
    return;
  }
  std::string plaintext;
  if (session.established() && session.decryptText(line, plaintext)) {
    if (authed) *authed = true;
    if (!dispatchSecureProtocolMessage(plaintext, source, session)) {
      handleCommandLine(plaintext, source);
    }
  } else {
    LOG_INFO("unauthenticated or invalid secure record rejected src=%s", source);
  }
}

// Split incoming bytes into lines and dispatch each.
void feedControlLines(std::string &buf, const std::string &incoming,
                      const char *source, bool *authed) {
  buf += incoming;
  size_t nl;
  while ((nl = buf.find('\n')) != std::string::npos) {
    std::string line = buf.substr(0, nl);
    buf.erase(0, nl + 1);
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (!line.empty()) dispatchControlLine(line, source, authed);
  }
}

std::string s_bleLineBuf;

class BinaryCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic *c, NimBLEConnInfo &info) override {
    if (!s_bleOwner.owns(info.getConnHandle())) {
      LOG_BLE("control write rejected from non-owner handle=%u owner=%u",
              info.getConnHandle(), s_bleOwner.owner());
      return;
    }
    const std::string &value = c->getValue();
    if (value.empty()) return;
    if (static_cast<uint8_t>(value[0]) != SecureSession::BinaryVersion) {
      std::string line = value;
      if (!line.empty() && line.back() == '\n') line.pop_back();
      if (!line.empty() && line.back() == '\r') line.pop_back();
      dispatchControlLine(line, "ble", &s_bleAuthed);
      return;
    }
    uint8_t decrypted[BLE_CONTROL_FRAME_MAX];
    const uint8_t *frameBytes = reinterpret_cast<const uint8_t *>(value.data());
    size_t frameLength = value.size();
    size_t decryptedLength = 0;
    if (!s_bleSecureSession.decryptBinary(frameBytes, frameLength, decrypted,
                                          sizeof(decrypted), decryptedLength)) {
      LOG_INFO("encrypted binary control rejected");
      return;
    }
    frameBytes = decrypted;
    frameLength = decryptedLength;
    // Authentication is performed through the text control characteristic
    // before binary event characteristics are accepted.
    if (!s_bleAuthed) {
      LOG_INFO("binary control rejected: BLE session not authenticated");
      return;
    }
    if (!s_bleControlQueue || frameLength > BLE_CONTROL_FRAME_MAX) {
      recordHIDDecodeError("ble-binary", frameLength);
      return;
    }
    BLEControlFrame frame;
    frame.length = static_cast<uint16_t>(frameLength);
    memcpy(frame.bytes, frameBytes, frameLength);
    if (frame.length > 1 && frame.bytes[0] == 0xFE)
      frame.bytes[0] = 0xFD;
    if (xQueueSend(s_bleControlQueue, &frame, 0) != pdTRUE)
      recordHIDDecodeError("ble-binary", frameLength);
  }
};

void processBLEControlFrames(size_t budget = 8) {
  if (!s_bleControlQueue) return;
  BLEControlFrame frame;
  for (size_t processed = 0;
       processed < budget && xQueueReceive(s_bleControlQueue, &frame, 0) == pdTRUE;
       ++processed) {
    // An external 0xFE marker is changed to internal 0xFD only after successful
    // decryption. Type 1 carries length-prefixed raw Wi-Fi credentials, keeping
    // the maximum encrypted record well below a typical iOS ATT write size.
    if (frame.length > 1 && frame.bytes[0] == 0xFD) {
      if (frame.bytes[1] == 2 && frame.length == 2) {
        if (!USBIdentityConfig::reset()) {
          LOG_WARN("secure BLE USB identity reset failed");
          continue;
        }
        requestReleaseAll("usb-identity-reset");
        s_managementRebootAtMs = millis() + 750;
        LOG_USB("secure BLE USB identity defaults restored; reboot scheduled");
        continue;
      }
      if (frame.bytes[1] == 3 && frame.length >= 8) {
        const uint16_t vid = static_cast<uint16_t>(frame.bytes[2]) |
                             (static_cast<uint16_t>(frame.bytes[3]) << 8);
        const uint16_t pid = static_cast<uint16_t>(frame.bytes[4]) |
                             (static_cast<uint16_t>(frame.bytes[5]) << 8);
        const size_t productLength = frame.bytes[6];
        const size_t serialLength = frame.bytes[7];
        if (productLength == 0 || productLength > USB_PRODUCT_NAME_MAX ||
            serialLength == 0 || serialLength > USB_SERIAL_NUMBER_MAX ||
            frame.length != 8 + productLength + serialLength) {
          LOG_WARN("secure BLE USB identity update rejected: invalid lengths");
          continue;
        }
        char product[USB_PRODUCT_NAME_MAX + 1]{};
        char serial[USB_SERIAL_NUMBER_MAX + 1]{};
        memcpy(product, frame.bytes + 8, productLength);
        memcpy(serial, frame.bytes + 8 + productLength, serialLength);
        if (!USBIdentityConfig::save(product, vid, pid, serial)) {
          LOG_WARN("secure BLE USB identity update failed validation");
          continue;
        }
        requestReleaseAll("usb-identity-update");
        s_managementRebootAtMs = millis() + 750;
        LOG_USB("secure BLE USB identity saved; reboot scheduled");
        continue;
      }
      if (frame.length < 4 || frame.bytes[1] != 1) {
        if (frame.length >= 3 && frame.bytes[1] == 4) {
          const size_t ssidLength = frame.bytes[2];
          if (ssidLength == 0 || ssidLength > 32 || frame.length != 3 + ssidLength) {
            LOG_WARN("secure BLE Wi-Fi removal rejected: invalid length");
            continue;
          }
          const String ssid(reinterpret_cast<const char *>(frame.bytes + 3), ssidLength);
          if (!WifiCredentials::remove(ssid)) {
            LOG_WARN("secure BLE Wi-Fi removal failed ssid=\"%s\"", ssid.c_str());
            continue;
          }
          g_radio.applyWifiCredentials();
          continue;
        }
        if (frame.length == 2 && frame.bytes[1] == 5) {
          if (!WifiCredentials::clear()) {
            LOG_WARN("secure BLE Wi-Fi clear failed");
            continue;
          }
          g_radio.applyWifiCredentials();
          continue;
        }
        LOG_WARN("secure BLE management frame rejected: invalid type");
        continue;
      }
      const size_t ssidLength = frame.bytes[2];
      const size_t passwordLength = frame.bytes[3];
      if (ssidLength == 0 || ssidLength > 32 || passwordLength > 63 ||
          frame.length != 4 + ssidLength + passwordLength) {
        LOG_WARN("secure BLE Wi-Fi setup rejected: invalid lengths");
        continue;
      }
      const String ssid(reinterpret_cast<const char *>(frame.bytes + 4), ssidLength);
      const String password(reinterpret_cast<const char *>(frame.bytes + 4 + ssidLength),
                            passwordLength);
      if (!WifiCredentials::save(ssid, password)) {
        LOG_WARN("secure BLE Wi-Fi setup failed");
        continue;
      }
      LOG_WIFI("secure BLE Wi-Fi setup saved ssid=\"%s\"", ssid.c_str());
      g_radio.applyWifiCredentials();
      continue;
    }
    HIDMessage message;
    std::string error;
    if (!HIDProtocol::decode(frame.bytes, frame.length, message, error)) {
      recordHIDDecodeError("ble-binary", frame.length);
      LOG_WARN("binary control rejected: %s", error.c_str());
      continue;
    }
    recordHIDBleFrame(static_cast<uint8_t>(message.type), frame.length);
    HIDEvent event;
    bool isEvent = true;
    switch (message.type) {
      case HIDMessageType::MouseMove: event = HIDEvent::move(message.x, message.y); break;
      case HIDMessageType::MouseScroll: event = HIDEvent::move(0, 0, message.wheel); break;
      case HIDMessageType::MouseButtonDown: event.type = HIDEventType::ButtonDown; event.button = message.button; break;
      case HIDMessageType::MouseButtonUp: event.type = HIDEventType::ButtonUp; event.button = message.button; break;
      case HIDMessageType::MouseClick: event.type = HIDEventType::Click; event.button = message.button; break;
      case HIDMessageType::KeyboardText:
        event.type = HIDEventType::TypeText;
        strncpy(event.text, message.text.c_str(), sizeof(event.text) - 1);
        break;
      case HIDMessageType::KeyboardKey:
      case HIDMessageType::KeyboardCombo: {
        const KeyCode key = KeyMap::lookup(message.text);
        if (!key.found) { LOG_WARN("binary key rejected: unknown key"); return; }
        event.type = HIDEventType::KeyboardReport; event.modifier = key.modifier; event.keycode = key.keycode;
        break;
      }
      case HIDMessageType::KeyboardReport:
        event.type = HIDEventType::KeyboardReport; event.modifier = message.modifier; event.keycode = message.keycode;
        break;
      case HIDMessageType::ReleaseAll: event = HIDEvent::releaseAll(); break;
      case HIDMessageType::Ping: isEvent = false; break;
    }
    if (isEvent) enqueueHIDEvent(event, "ble-binary");
    else if (s_bleTx) {
      const uint8_t pong[] = {HIDProtocol::Version, 0x7f};
      s_bleTx->setValue(pong, sizeof(pong));
      s_bleTx->notify(s_bleOwner.owner());
    }
  }
}

class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer *server, NimBLEConnInfo &info) override {
    const uint16_t handle = info.getConnHandle();
    const BLESessionOwnership::ClaimResult claim = s_bleOwner.claim(handle, millis());
    if (claim == BLESessionOwnership::ClaimResult::Rejected) {
      LOG_BLE("additional central rejected handle=%u owner=%u ownerAuthenticated=%s",
              handle, s_bleOwner.owner(), s_bleAuthed ? "yes" : "no");
      server->disconnect(handle);
      return;
    }
    if (claim == BLESessionOwnership::ClaimResult::AlreadyOwner) return;
    s_bleSecureSession.reset();
    s_bleAuthed = false;
    LOG_BLE("central connected handle=%u secure authentication deadline=%lums",
            handle, static_cast<unsigned long>(BLE_SECURE_AUTH_TIMEOUT_MS));
  }
  void onDisconnect(NimBLEServer *, NimBLEConnInfo &info, int reason) override {
    const uint16_t handle = info.getConnHandle();
    if (!s_bleOwner.release(handle)) {
      LOG_BLE("non-owner central disconnected handle=%u reason=%d owner=%u",
              handle, reason, s_bleOwner.owner());
      return;
    }
    s_bleAuthed = false;
    s_bleSecureSession.reset();
    g_bleOta.disconnected();
    if (s_bleControlQueue) xQueueReset(s_bleControlQueue);
    requestReleaseAll("ble-disconnect");
    if (s_bleTearingDown) {
      LOG_BLE("central disconnected reason=%d during teardown", reason);
      return;
    }
    const HIDDiagnosticsSnapshot hid = deviceHidDiagnostics();
    const char *reasonName = "UNKNOWN";
    switch (reason) {
      case 0x08: reasonName = "CONNECTION_TIMEOUT"; break;
      case 0x13: reasonName = "REMOTE_USER_TERMINATED"; break;
      case 0x16: reasonName = "LOCAL_HOST_TERMINATED"; break;
      case 0x3e: reasonName = "CONNECTION_ESTABLISHMENT_FAILED"; break;
    }
    LOG_BLE("central disconnected reason=%d reasonName=%s uptime=%lu heap=%u lastBleRxType=%u lastBleRxLength=%lu lastHidSequence=%lu lastQueuedEvent=%s lastExecutedEvent=%s; re-advertising",
            reason, reasonName, static_cast<unsigned long>(millis()), ESP.getFreeHeap(),
            hid.lastBleRxType, static_cast<unsigned long>(hid.lastBleRxLength),
            static_cast<unsigned long>(hid.lastSequence), hid.lastQueuedEvent, hid.lastExecutedEvent);
    NimBLEAdvertising *adv = NimBLEDevice::getAdvertising();
    if (!s_bleReady || !adv || !adv->start() || !adv->isAdvertising()) {
      g_radio.setBleAdvertisingStatus(false);
      LOG_BLE("advertising restart failed");
      return;
    }
    g_radio.setBleAdvertisingStatus(true);
    LOG_BLE("advertising restarted");
  }
};

BinaryCallbacks s_binaryCallbacks;
ServerCallbacks s_serverCallbacks;

}  // namespace

bool deviceBleAuthenticated() { return s_bleOwner.connected() && s_bleAuthed; }

bool deviceBleConnectionOwnsSession(uint16_t connectionHandle) {
  return s_bleOwner.owns(connectionHandle);
}

uint16_t deviceBleSessionHandle() { return s_bleOwner.owner(); }

bool decryptBleSecureRecord(const uint8_t *record, size_t recordLength,
                            uint8_t *plaintext, size_t plaintextCapacity,
                            size_t &plaintextLength) {
  return deviceBleAuthenticated() &&
         s_bleSecureSession.decryptBinary(record, recordLength, plaintext,
                                          plaintextCapacity, plaintextLength);
}

void RadioManager::pairingCredentialRotated() {
  s_bleAuthed = false;
  s_tcpAuthed = false;
  s_bleSecureSession.reset();
  s_tcpSecureSession.reset();
  if (s_tcpClient) s_tcpClient.stop();
  if (s_bleReady) {
    const std::vector<uint16_t> peers = s_bleServer
        ? s_bleServer->getPeerDevices() : std::vector<uint16_t>{};
    for (const uint16_t handle : peers) s_bleServer->disconnect(handle);
    LOG_BLE("connections cleared after USB trust rotation");
  }
  requestReleaseAll("pairing-rotated");
}

// ---------------------------------------------------------------------------
void RadioManager::begin(RadioMode initial) {
  mode_ = RadioMode::None;
  snprintf(status_, sizeof(status_), "none");
  if (initial != RadioMode::None) setMode(initial);
}

bool RadioManager::setMode(RadioMode m) {
  if (m == mode_) return true;
  if (g_otaEngine.active()) {
    LOG_WARN("radio mode change blocked during OTA");
    return false;
  }
  const bool hadWifi = wifiEnabled();
  const bool hadBle = bleEnabled();
  mode_ = m;
  const bool wantsWifi = wifiEnabled();
  const bool wantsBle = bleEnabled();
  if (hadWifi && !wantsWifi) stopWifi();
  if (hadBle && !wantsBle) stopBle();
  if (!hadWifi && wantsWifi) startWifi();
  if (!hadBle && wantsBle) startBle();
  if (!wantsWifi && !wantsBle) snprintf(status_, sizeof(status_), "none");
  LOG_RADIO("mode=%s status=%s", radioModeToString(mode_), status_);
  return true;
}

// ---------------------------------------------------------------------------
// WiFi (STA with NVS creds, or Soft-AP setup portal)
// ---------------------------------------------------------------------------
void RadioManager::startSoftAp() {
  staConnecting_ = false;
  softAp_ = true;
  DeviceIdentity::begin();
  WiFi.mode(WIFI_AP);
  const char *apSsid = DeviceIdentity::softApSsid();
  const bool openAp = (WIFI_AP_PASS[0] == '\0');
  bool ok = openAp
                ? WiFi.softAP(apSsid, nullptr, WIFI_AP_CHANNEL)
                : WiFi.softAP(apSsid, WIFI_AP_PASS, WIFI_AP_CHANNEL);
  if (!ok) {
    snprintf(status_, sizeof(status_), "wifi:ap-fail");
    LOG_WIFI("Soft-AP start failed");
    return;
  }
  delay(100);
  IPAddress ip = WiFi.softAPIP();
  snprintf(status_, sizeof(status_), "wifi:ap");
  LOG_WIFI("soft-ap ssid=\"%s\" ip=%s discovery=:%d secure=:%d",
           apSsid, ip.toString().c_str(), WIFI_HTTP_PORT, WIFI_CONTROL_PORT);
  g_wifiConfig.begin();
  s_tcpServer.begin();
  s_tcpServer.setNoDelay(true);
}

void RadioManager::startSta(const String &ssid, const String &pass,
                            size_t credentialIndex) {
  softAp_ = false;
  staCredentialIndex_ = credentialIndex;
  WiFi.mode(WIFI_STA);
  WiFi.begin(ssid.c_str(), pass.c_str());
  LOG_WIFI("connecting to %s (candidate %u/%u) ...", ssid.c_str(),
           static_cast<unsigned>(credentialIndex + 1),
           static_cast<unsigned>(WifiCredentials::count()));
  staConnecting_ = true;
  staConnectStartedMs_ = millis();
  snprintf(status_, sizeof(status_), "wifi:connecting");
}

void RadioManager::finishStaConnection() {
  staConnecting_ = false;
  staAttempts_ = 0;
  staDisconnectedSinceMs_ = 0;
  DeviceIdentity::begin();
  s_tcpServer.begin();
  s_tcpServer.setNoDelay(true);
  g_wifiConfig.begin();  // read-only discovery on :80
  const char *mdnsHost = DeviceIdentity::mdnsHostname();
  if (MDNS.begin(mdnsHost)) {
    MDNS.addService("http", "tcp", WIFI_HTTP_PORT);
    MDNS.addServiceTxt("http", "tcp", "path", "/api/status");
    MDNS.addServiceTxt("http", "tcp", "id", DeviceIdentity::deviceId());
    MDNS.addServiceTxt("http", "tcp", "fw", FW_VERSION);
    LOG_WIFI("mDNS started as %s (http :%d)", DeviceIdentity::mdnsFqdn(),
             WIFI_HTTP_PORT);
  } else {
    LOG_WIFI("mDNS start failed");
  }
  snprintf(status_, sizeof(status_), "wifi:%s", WiFi.localIP().toString().c_str());
  LOG_WIFI("connected ip=%s secure-port=%d discovery=:%d mdns=%s",
           WiFi.localIP().toString().c_str(), WIFI_CONTROL_PORT, WIFI_HTTP_PORT,
           DeviceIdentity::mdnsFqdn());
}

void RadioManager::serviceStaConnection() {
  if (!staConnecting_) {
    if (softAp_ || WiFi.status() == WL_CONNECTED) {
      staDisconnectedSinceMs_ = 0;
      return;
    }
    if (staDisconnectedSinceMs_ == 0) {
      staDisconnectedSinceMs_ = millis();
      return;
    }
    // Allow brief station transitions to recover by themselves. A sustained
    // loss starts a fresh pass through every configured network while BLE
    // remains advertising/connected.
    if (millis() - staDisconnectedSinceMs_ < 3000) return;
    const size_t count = WifiCredentials::count();
    if (count == 0) { startSoftAp(); return; }
    LOG_WIFI("station connection lost; trying alternate networks");
    stopWifiServices();
    staAttempts_ = 0;
    const size_t next = (staCredentialIndex_ + 1) % count;
    const WifiCreds candidate = WifiCredentials::get(next);
    staDisconnectedSinceMs_ = 0;
    startSta(candidate.ssid, candidate.pass, next);
    return;
  }
  if (WiFi.status() == WL_CONNECTED) {
    finishStaConnection();
    return;
  }
  if (millis() - staConnectStartedMs_ < WIFI_CONNECT_TIMEOUT_MS) return;
  LOG_WIFI("connect timeout for candidate %u", static_cast<unsigned>(staCredentialIndex_ + 1));
  staConnecting_ = false;
  WiFi.disconnect(false, false);
  const size_t count = WifiCredentials::count();
  ++staAttempts_;
  if (staAttempts_ < count) {
    const size_t next = (staCredentialIndex_ + 1) % count;
    const WifiCreds candidate = WifiCredentials::get(next);
    startSta(candidate.ssid, candidate.pass, next);
    return;
  }
  LOG_WIFI("all configured networks unavailable; returning to Soft-AP discovery");
  startSoftAp();
}

void RadioManager::startWifi() {
  staCredentialIndex_ = 0;
  staAttempts_ = 0;
  staDisconnectedSinceMs_ = 0;
  WifiCreds c = WifiCredentials::get(0);
  if (c.ssid.length() == 0) {
    LOG_WIFI("no STA credentials in NVS; starting Soft-AP setup");
    startSoftAp();
    return;
  }
  startSta(c.ssid, c.pass, 0);
}

void RadioManager::stopWifiServices() {
  MDNS.end();
  g_wifiConfig.stop();
  s_tcpClient.stop();
  s_tcpServer.stop();
  s_tcpLineBuf.clear();
  s_tcpAuthed = false;
  s_tcpSecureSession.reset();
}

void RadioManager::stopWifi() {
  stopWifiServices();
  staConnecting_ = false;
  softAp_ = false;
  WiFi.softAPdisconnect(true);
  WiFi.disconnect(true);
  WiFi.mode(WIFI_OFF);
  LOG_WIFI("stopped");
}

void RadioManager::applyWifiCredentials() {
  if (!wifiEnabled()) {
    LOG_WIFI("credentials updated (will apply on next radio wifi)");
    return;
  }
  // Provisioning arrives through the live BLE Secure Session. Do not turn the
  // shared Wi-Fi/BLE controller fully off or block the main loop while joining
  // the home network. Keep BLE responsive and advance STA setup from loop().
  LOG_WIFI("applying credentials; transitioning to STA asynchronously");
  stopWifiServices();
  WiFi.disconnect(false, false);
  startWifi();
  LOG_RADIO("mode=%s status=%s", radioModeToString(mode_), status_);
}

// ---------------------------------------------------------------------------
// BLE
// ---------------------------------------------------------------------------
void RadioManager::startBle() {
  // Build the GATT server exactly once and keep it for the whole session.
  // We never NimBLEDevice::deinit() (see stopBle), so on a re-select the stack
  // is already initialized and we only need to re-advertise.
  if (!NimBLEDevice::isInitialized()) {
    if (!s_bleControlQueue)
      s_bleControlQueue = xQueueCreate(BLE_CONTROL_QUEUE_DEPTH,
                                      sizeof(BLEControlFrame));
    if (!s_bleControlQueue) {
      snprintf(status_, sizeof(status_), "ble:queue-fail");
      LOG_BLE("control queue creation failed");
      return;
    }
    LOG_BLE("init start");
    if (!NimBLEDevice::init(DeviceIdentity::deviceName())) {
      snprintf(status_, sizeof(status_), "ble:init-failed");
      LOG_BLE("init failed");
      return;
    }
    LOG_BLE("initialized");
    s_bleServer = NimBLEDevice::createServer();
    if (!s_bleServer) {
      snprintf(status_, sizeof(status_), "ble:server-fail");
      LOG_BLE("server creation failed");
      return;
    }
    s_bleServer->setCallbacks(&s_serverCallbacks);
    LOG_BLE("server created");

    NimBLEService *hidSvc = s_bleServer->createService(BLE_HID_SERVICE_UUID);
    if (!hidSvc) {
      snprintf(status_, sizeof(status_), "ble:service-fail");
      LOG_BLE("HID service creation failed");
      return;
    }
    NimBLECharacteristic *control = hidSvc->createCharacteristic(
        BLE_HID_CONTROL_UUID, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
    s_bleTx = hidSvc->createCharacteristic(
        BLE_HID_STATUS_UUID, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);
    if (!control || !s_bleTx) {
      snprintf(status_, sizeof(status_), "ble:service-fail");
      LOG_BLE("HID status characteristic creation failed");
      return;
    }
    control->setCallbacks(&s_binaryCallbacks);
    const uint8_t statusValue[] = {HIDProtocol::Version, 0x00};
    s_bleTx->setValue(statusValue, sizeof(statusValue));

    LOG_BLE("HID service created");
    if (!g_bleOta.begin(s_bleServer)) {
      snprintf(status_, sizeof(status_), "ble:service-fail");
      LOG_BLE("OTA service creation failed");
      return;
    }
    LOG_BLE("OTA service created");
    // NimBLE-Arduino 2.x registers all services together when the server is
    // started. NimBLEService::start() is a deprecated no-op in this version.
    if (!s_bleServer->start()) {
      snprintf(status_, sizeof(status_), "ble:service-fail");
      LOG_BLE("GATT server/service start failed");
      return;
    }
    LOG_BLE("GATT services started (Secure Protocol, OTA)");

    NimBLEAdvertising *adv = NimBLEDevice::getAdvertising();
    if (!adv) {
      snprintf(status_, sizeof(status_), "ble:adv-fail");
      LOG_BLE("advertising object unavailable");
      return;
    }
    const std::string identity = std::string("IP") + DeviceIdentity::deviceId();
    NimBLEAdvertisementData advData;
    NimBLEAdvertisementData scanData;
    const bool identityOk = advData.setFlags(BLE_HS_ADV_F_DISC_GEN |
                                              BLE_HS_ADV_F_BREDR_UNSUP) &&
                            advData.setManufacturerData(identity);
    const bool nameOk = scanData.setName(DeviceIdentity::deviceName());
    const bool payloadOk = identityOk && nameOk &&
                           adv->setAdvertisementData(advData) &&
                           adv->setScanResponseData(scanData);
    adv->enableScanResponse(true);
    LOG_BLE("advertising payload bytes=%u scan-response bytes=%u",
            static_cast<unsigned>(advData.getPayload().size()),
            static_cast<unsigned>(scanData.getPayload().size()));
    if (!payloadOk || advData.getDataLocation(BLE_HS_ADV_TYPE_MFG_DATA) < 0) {
      snprintf(status_, sizeof(status_), "ble:adv-fail");
      LOG_BLE("advertising configuration failed; manufacturer data missing");
      return;
    }
    LOG_BLE("manufacturer identity configured id=%s", DeviceIdentity::deviceId());
    s_bleReady = true;
  }
  s_bleTearingDown = false;
  NimBLEAdvertising *adv = NimBLEDevice::getAdvertising();
  if (!s_bleReady || !adv || !adv->start() || !adv->isAdvertising()) {
    snprintf(status_, sizeof(status_), "ble:adv-fail");
    LOG_BLE("advertising start failed");
    return;
  }

  snprintf(status_, sizeof(status_), "ble:adv");
  LOG_BLE("advertising started as '%s'", DeviceIdentity::deviceName());
}

void RadioManager::setBleAdvertisingStatus(bool active) {
  snprintf(status_, sizeof(status_), active ? "ble:adv" : "ble:adv-fail");
}

void RadioManager::stopBle() {
  // IMPORTANT: we do NOT call NimBLEDevice::deinit() here. On arduino-esp32
  // 3.2.1 / IDF 5.4, esp_bt_controller_deinit (reached via nimble_port_deinit)
  // crashes and reboots the S3 even after stopAdvertising with no clients
  // connected (NimBLE-Arduino #1008 - an upstream controller-deinit bug). So we
  // just quiesce the stack: stop advertising and drop any client, leaving the
  // controller initialized but idle. Re-selecting BLE re-advertises instantly.
  // Trade-off: once BLE has been used, its controller stays powered until
  // reboot (coexists fine with WiFi); the *control transport* is still
  // exclusive because advertising is off and clients are dropped.
  if (NimBLEDevice::isInitialized()) {
    s_bleTearingDown = true;  // stop onDisconnect from re-advertising
    NimBLEDevice::stopAdvertising();
    if (s_bleServer && s_bleServer->getConnectedCount() > 0) {
      for (uint16_t handle : s_bleServer->getPeerDevices()) {
        s_bleServer->disconnect(handle);
      }
      uint32_t start = millis();
      while (s_bleOwner.connected() && (millis() - start) < 1000) delay(10);
    }
  }
  s_bleOwner.clear();
  s_bleAuthed = false;
  s_bleLineBuf.clear();
  LOG_BLE("stopped (advertising off; stack idle)");
}

// ---------------------------------------------------------------------------
void RadioManager::loop() {
  if (s_bleOwner.authenticationExpired(millis(), s_bleAuthed)) {
    const uint16_t handle = s_bleOwner.owner();
    LOG_BLE("secure authentication timed out handle=%u; disconnecting", handle);
    // Clear the deadline before requesting disconnect so this is issued once.
    s_bleOwner.pauseAuthenticationTimeout(handle);
    if (!s_bleServer || !s_bleServer->disconnect(handle)) {
      LOG_BLE("timed-out central disconnect request failed handle=%u; retrying", handle);
      s_bleOwner.restartAuthentication(handle, millis());
    }
  }
  // Decode binary writes outside NimBLE's host callback. This keeps STL,
  // KeyMap, logging and HID queue work off the 4 KiB BLE host stack.
  processBLEControlFrames();
  g_bleOta.loop();
  if (s_managementRebootAtMs &&
      static_cast<int32_t>(millis() - s_managementRebootAtMs) >= 0) {
    esp_restart();
  }
  if (!wifiEnabled()) return;

  serviceStaConnection();
  if (staConnecting_) return;

  // Plain HTTP is discovery-only. Setup and management use the secure TCP port.
  g_wifiConfig.loop();
  if (!softAp_ && WiFi.status() != WL_CONNECTED) return;

  const bool hadTcpClient = s_tcpClient && s_tcpClient.connected();
  if (!hadTcpClient) {
    WiFiClient nc = s_tcpServer.accept();
    if (nc) {
      s_tcpClient = nc;
      s_tcpLineBuf.clear();
      s_tcpSecureSession.reset();
      s_tcpAuthed = false;
      LOG_WIFI("control client connected");
    }
  }
  if (s_tcpClient && s_tcpClient.connected()) {
    while (s_tcpClient.available()) {
      char ch = (char)s_tcpClient.read();
      if (ch == '\r') continue;
      if (ch == '\n') {
        if (!s_tcpLineBuf.empty()) {
          dispatchControlLine(s_tcpLineBuf, "wifi", &s_tcpAuthed);
        }
        s_tcpLineBuf.clear();
      } else if (s_tcpLineBuf.size() < 768) {
        s_tcpLineBuf.push_back(ch);
      }
    }
  } else {
    if (s_tcpAuthed) requestReleaseAll("tcp-disconnect");
    s_tcpAuthed = false;
    s_tcpSecureSession.reset();
  }
}

const char *RadioManager::statusStr() {
  if (mode_ == RadioMode::WifiBle) {
    if (softAp_) snprintf(status_, sizeof(status_), "wifi:ap+ble:%s", s_bleOwner.connected() ? "conn" : "adv");
    else if (WiFi.status() == WL_CONNECTED)
      snprintf(status_, sizeof(status_), "wifi:%s+ble:%s", WiFi.localIP().toString().c_str(),
               s_bleOwner.connected() ? "conn" : "adv");
  } else if (mode_ == RadioMode::Ble) {
    snprintf(status_, sizeof(status_), "ble:%s", s_bleOwner.connected() ? "conn" : "adv");
  } else if (mode_ == RadioMode::Wifi) {
    if (softAp_) {
      snprintf(status_, sizeof(status_), "wifi:ap");
    } else if (WiFi.status() == WL_CONNECTED) {
      snprintf(status_, sizeof(status_), "wifi:%s", WiFi.localIP().toString().c_str());
    }
  }
  return status_;
}

void RadioManager::sendToControl(const char *line) {
  if (bleEnabled() && s_bleTx && s_bleOwner.connected()) {
    s_bleTx->setValue((const uint8_t *)line, strlen(line));
    s_bleTx->notify(s_bleOwner.owner());
  } else if (wifiEnabled() && s_tcpClient && s_tcpClient.connected()) {
    s_tcpClient.print(line);
    s_tcpClient.print("\n");
  }
}
