#include "BLEOTA.h"

#include <cstring>
#include <esp_system.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>

#include "Config.h"
#include "DeviceIdentity.h"
#include "OTAEngine.h"
#include "PairingSecretStore.h"
extern bool deviceBleAuthenticated();
extern bool decryptBleSecureRecord(const uint8_t *, size_t, uint8_t *, size_t,
                                   size_t &);
namespace {

constexpr size_t BLE_OTA_MAX_PAYLOAD = 500;
constexpr size_t BLE_OTA_FRAME_BYTES = sizeof(uint32_t) + BLE_OTA_MAX_PAYLOAD;
constexpr size_t BLE_OTA_QUEUE_DEPTH = 12;
constexpr size_t BLE_OTA_CONTROL_BYTES = 160;
constexpr size_t BLE_OTA_CONTROL_DEPTH = 4;

static_assert(BLE_OTA_QUEUE_DEPTH * BLE_OTA_MAX_PAYLOAD >=
                  BLE_OTA_ACK_BYTES + BLE_OTA_MAX_PAYLOAD,
              "BLE OTA queue must cover the advertised acknowledgement window");

struct BLEOTAFrame {
  uint16_t length = 0;
  uint8_t bytes[BLE_OTA_FRAME_BYTES]{};
};

struct BLEOTAControlCommand {
  uint16_t length = 0;
  char bytes[BLE_OTA_CONTROL_BYTES]{};
};

QueueHandle_t s_dataQueue = nullptr;
QueueHandle_t s_controlQueue = nullptr;
volatile bool s_disconnectedPending = false;
enum class PendingAbort : uint8_t { None, InvalidChunk, QueueFull };
volatile PendingAbort s_pendingAbort = PendingAbort::None;

}  // namespace

BLEOTA g_bleOta;

class BLEOTA::ControlCallbacks : public NimBLECharacteristicCallbacks {
 public:
  explicit ControlCallbacks(BLEOTA &owner) : owner_(owner) {}
  void onWrite(NimBLECharacteristic *characteristic, NimBLEConnInfo &) override {
    owner_.enqueueControl(characteristic->getValue());
  }

 private:
  BLEOTA &owner_;
};

class BLEOTA::DataCallbacks : public NimBLECharacteristicCallbacks {
 public:
  explicit DataCallbacks(BLEOTA &owner) : owner_(owner) {}
  void onWrite(NimBLECharacteristic *characteristic, NimBLEConnInfo &) override {
    owner_.enqueueData(characteristic->getValue());
  }

 private:
  BLEOTA &owner_;
};

bool BLEOTA::schemaAvailable() { return OTAEngine::schemaAvailable(); }
OTAState BLEOTA::state() const { return g_otaEngine.state(); }
bool BLEOTA::active() const {
  return g_otaEngine.owner() == OTATransportOwner::BLE && g_otaEngine.active();
}

bool BLEOTA::begin(NimBLEServer *server) {
  if (!server) return false;
  if (!s_dataQueue) s_dataQueue = xQueueCreate(BLE_OTA_QUEUE_DEPTH, sizeof(BLEOTAFrame));
  if (!s_controlQueue)
    s_controlQueue = xQueueCreate(BLE_OTA_CONTROL_DEPTH, sizeof(BLEOTAControlCommand));
  if (!s_dataQueue || !s_controlQueue) return false;
  auto *service = server->createService(BLE_OTA_SERVICE_UUID);
  if (!service) return false;
  auto *control = service->createCharacteristic(
      BLE_OTA_CONTROL_UUID, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_ENC);
  auto *data = service->createCharacteristic(
      BLE_OTA_DATA_UUID, NIMBLE_PROPERTY::WRITE_NR | NIMBLE_PROPERTY::WRITE_ENC);
  status_ = service->createCharacteristic(
      BLE_OTA_STATUS_UUID, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY |
                               NIMBLE_PROPERTY::READ_ENC);
  if (!control || !data || !status_) return false;
  control->setCallbacks(new ControlCallbacks(*this));
  data->setCallbacks(new DataCallbacks(*this));
  notify("IDLE");
  return true;
}

void BLEOTA::notify(const char *event, const char *error) {
  if (!status_) return;
  char json[1080];
  if (strcmp(event, "IDLE") == 0) {
    snprintf(
        json, sizeof(json),
        "{\"product\":\"%s\",\"board\":\"%s\",\"deviceId\":\"%s\",\"deviceName\":\"%s\","
        "\"protocol\":%u,\"otaSchema\":%u,\"firmware\":\"%s\",\"trustRequired\":%s,"
        "\"capabilities\":[\"secure_protocol_v2\",\"ble_transport\",\"wifi_transport\","
        "\"secure_wifi_setup\",\"secure_usb_identity\",\"secure_ota\","
        "\"secure_diagnostics\",\"mouse_move\","
        "\"mouse_click\",\"mouse_button_state\",\"mouse_scroll\",\"keyboard_type\","
        "\"keyboard_key\",\"keyboard_layout\",\"release_all\",\"protocol_v2\"],"
        "\"state\":\"idle\",\"event\":\"IDLE\",\"offset\":0,\"size\":0,"
        "\"maxChunk\":%u,\"windowSize\":%lu}",
        FW_PRODUCT, FW_BOARD, DeviceIdentity::deviceId(), DeviceIdentity::deviceName(),
        OTA_PROTOCOL_VERSION, OTA_SCHEMA_VERSION, FW_VERSION,
        "true",
        static_cast<unsigned>(BLE_OTA_MAX_PAYLOAD),
        static_cast<unsigned long>(BLE_OTA_ACK_BYTES));
  } else {
    snprintf(
        json, sizeof(json),
        "{\"protocol\":%u,\"otaSchema\":%u,\"firmware\":\"%s\",\"state\":\"%s\","
        "\"event\":\"%s\",\"offset\":%lu,\"size\":%lu,\"maxChunk\":%u,"
        "\"windowSize\":%lu%s%s%s}",
        OTA_PROTOCOL_VERSION, OTA_SCHEMA_VERSION, FW_VERSION,
        OTAProtocol::stateName(g_otaEngine.state()), event,
        static_cast<unsigned long>(g_otaEngine.received()),
        static_cast<unsigned long>(g_otaEngine.total()),
        static_cast<unsigned>(BLE_OTA_MAX_PAYLOAD),
        static_cast<unsigned long>(BLE_OTA_ACK_BYTES),
        error ? ",\"error\":\"" : "", error ? error : "", error ? "\"" : "");
  }
  status_->setValue(reinterpret_cast<const uint8_t *>(json), strlen(json));
  status_->notify();
}

void BLEOTA::fail(const char *error) { notify("ERROR", error); }

void BLEOTA::enqueueControl(const std::string &value) {
  uint8_t plaintext[BLE_OTA_CONTROL_BYTES];
  size_t plaintextLength = 0;
  if (!s_controlQueue || value.empty() ||
      !decryptBleSecureRecord(reinterpret_cast<const uint8_t *>(value.data()),
                              value.size(), plaintext, sizeof(plaintext),
                              plaintextLength) || plaintextLength == 0 ||
      plaintextLength >= BLE_OTA_CONTROL_BYTES) {
    fail("invalid_control");
    return;
  }
  BLEOTAControlCommand command;
  command.length = static_cast<uint16_t>(plaintextLength);
  memcpy(command.bytes, plaintext, plaintextLength);
  if (xQueueSend(s_controlQueue, &command, 0) != pdTRUE) fail("control_queue_full");
}

void BLEOTA::processControl(size_t budget) {
  if (!s_controlQueue) return;
  BLEOTAControlCommand command;
  for (size_t processed = 0;
       processed < budget && xQueueReceive(s_controlQueue, &command, 0) == pdTRUE;
       ++processed) {
    const std::string value(command.bytes, command.length);
    if (!deviceBleAuthenticated()) {
      fail("unauthorized");
      continue;
    }
    if (value == "ABORT") {
      if (active()) {
        g_otaEngine.abort("user_cancelled", true);
        if (s_dataQueue) xQueueReset(s_dataQueue);
        notify("CANCELLED", "user_cancelled");
      }
      continue;
    }
    if (value == "FINISH") {
      if (g_otaEngine.owner() != OTATransportOwner::BLE ||
          (s_dataQueue && uxQueueMessagesWaiting(s_dataQueue) != 0)) {
        fail("not_receiving");
        continue;
      }
      notify("VERIFYING");
      if (!g_otaEngine.finish()) {
        fail(g_otaEngine.error());
        continue;
      }
      notify("INSTALLING");
      notify("SUCCESS");
      notify("REBOOTING");
      rebootAtMs_ = millis() + 750;
      continue;
    }
    OTAStartRequest request;
    std::string error;
    if (!OTAProtocol::parseStart(value, request, error)) {
      fail(error.c_str());
      continue;
    }
    if (g_otaEngine.active()) {
      fail("update_in_progress");
      continue;
    }
    if (s_dataQueue) xQueueReset(s_dataQueue);
    if (!g_otaEngine.start(request, OTATransportOwner::BLE)) {
      fail(g_otaEngine.error());
      continue;
    }
    lastActivityMs_ = millis();
    lastAck_ = 0;
    notify("READY");
  }
}

void BLEOTA::enqueueData(const std::string &value) {
  uint8_t plaintext[BLE_OTA_FRAME_BYTES];
  size_t plaintextLength = 0;
  if (!decryptBleSecureRecord(reinterpret_cast<const uint8_t *>(value.data()),
                              value.size(), plaintext, sizeof(plaintext),
                              plaintextLength)) {
    fail("unauthorized");
    return;
  }
  if (g_otaEngine.owner() != OTATransportOwner::BLE || plaintextLength <= 4) {
    fail("not_receiving");
    return;
  }
  if (!s_dataQueue || plaintextLength > BLE_OTA_FRAME_BYTES) {
    s_pendingAbort = PendingAbort::InvalidChunk;
    return;
  }
  BLEOTAFrame frame;
  frame.length = static_cast<uint16_t>(plaintextLength);
  memcpy(frame.bytes, plaintext, plaintextLength);
  if (xQueueSend(s_dataQueue, &frame, 0) != pdTRUE) {
    s_pendingAbort = PendingAbort::QueueFull;
    return;
  }
  lastActivityMs_ = millis();
}

void BLEOTA::processData(size_t budget) {
  if (!s_dataQueue) return;
  BLEOTAFrame frame;
  for (size_t processed = 0;
       processed < budget && xQueueReceive(s_dataQueue, &frame, 0) == pdTRUE;
       ++processed) {
    const uint8_t *bytes = frame.bytes;
    const uint32_t offset = static_cast<uint32_t>(bytes[0]) |
                            (static_cast<uint32_t>(bytes[1]) << 8) |
                            (static_cast<uint32_t>(bytes[2]) << 16) |
                            (static_cast<uint32_t>(bytes[3]) << 24);
    if (!g_otaEngine.write(offset, bytes + 4, frame.length - 4)) {
      xQueueReset(s_dataQueue);
      fail(g_otaEngine.error());
      return;
    }
    lastActivityMs_ = millis();
    if (g_otaEngine.received() - lastAck_ >= BLE_OTA_ACK_BYTES ||
        g_otaEngine.received() == g_otaEngine.total()) {
      lastAck_ = g_otaEngine.received();
      notify("ACK");
    }
  }
}

void BLEOTA::disconnected() {
  s_disconnectedPending = true;
}

void BLEOTA::loop() {
  if (s_disconnectedPending) {
    s_disconnectedPending = false;
    if (s_controlQueue) xQueueReset(s_controlQueue);
    if (s_dataQueue) xQueueReset(s_dataQueue);
    if (active()) g_otaEngine.abort("connection_lost");
  }
  const PendingAbort pendingAbort = s_pendingAbort;
  if (pendingAbort != PendingAbort::None) {
    s_pendingAbort = PendingAbort::None;
    const char *error = pendingAbort == PendingAbort::InvalidChunk
                            ? "invalid_chunk" : "ble_queue_full";
    if (active()) g_otaEngine.abort(error);
    if (s_dataQueue) xQueueReset(s_dataQueue);
    fail(error);
  }
  processControl();
  processData();
  if (active() && millis() - lastActivityMs_ > BLE_OTA_TIMEOUT_MS) {
    g_otaEngine.abort("timeout");
    if (s_dataQueue) xQueueReset(s_dataQueue);
    fail("timeout");
  }
  if (rebootAtMs_ && static_cast<int32_t>(millis() - rebootAtMs_) >= 0) esp_restart();
}
