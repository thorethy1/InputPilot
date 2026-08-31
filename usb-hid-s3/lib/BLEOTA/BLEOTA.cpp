#include "BLEOTA.h"

#include <cstring>
#include <esp_system.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>

#include "Config.h"
#include "BLEDiscoveryMetadata.h"
#include "DeviceIdentity.h"
#include "OTAEngine.h"
#include "PairingSecretStore.h"
extern bool deviceBleConnectionOwnsSession(uint16_t connectionHandle);
extern uint16_t deviceBleSessionHandle();
extern bool decryptBleSecureRecord(const uint8_t *, size_t, uint8_t *, size_t,
                                   size_t &);
namespace {

constexpr size_t BLE_OTA_MAX_PAYLOAD = 500;
constexpr size_t BLE_OTA_FRAME_BYTES = sizeof(uint32_t) + BLE_OTA_MAX_PAYLOAD;
constexpr size_t BLE_SECURE_RECORD_OVERHEAD = 1 + sizeof(uint64_t) + 16;
constexpr size_t BLE_OTA_ENCRYPTED_FRAME_BYTES =
    BLE_OTA_FRAME_BYTES + BLE_SECURE_RECORD_OVERHEAD;
// iOS may negotiate an ATT payload around 182 bytes, leaving roughly 153
// firmware bytes after the secure-record and offset overhead. Size the queue
// for the advertised window at that conservative packet size, not only for the
// ideal 500-byte payload.
constexpr size_t BLE_OTA_MIN_EXPECTED_PAYLOAD = 128;
constexpr size_t BLE_OTA_QUEUE_DEPTH = 36;
constexpr size_t BLE_OTA_CONTROL_BYTES = 160;
constexpr size_t BLE_OTA_ENCRYPTED_CONTROL_BYTES =
    BLE_OTA_CONTROL_BYTES + BLE_SECURE_RECORD_OVERHEAD;
constexpr size_t BLE_OTA_CONTROL_DEPTH = 4;

static_assert(BLE_OTA_QUEUE_DEPTH * BLE_OTA_MIN_EXPECTED_PAYLOAD >=
                  BLE_OTA_ACK_BYTES + BLE_OTA_MAX_PAYLOAD,
              "BLE OTA queue must cover the advertised acknowledgement window");

struct BLEOTAFrame {
  uint16_t length = 0;
  uint8_t bytes[BLE_OTA_ENCRYPTED_FRAME_BYTES]{};
};

struct BLEOTAControlCommand {
  uint16_t length = 0;
  uint8_t bytes[BLE_OTA_ENCRYPTED_CONTROL_BYTES]{};
};

QueueHandle_t s_dataQueue = nullptr;
QueueHandle_t s_controlQueue = nullptr;
volatile bool s_disconnectedPending = false;
enum class PendingAbort : uint8_t {
  None,
  InvalidChunk,
  QueueFull,
  InvalidControl,
  ControlQueueFull,
};
volatile PendingAbort s_pendingAbort = PendingAbort::None;

}  // namespace

BLEOTA g_bleOta;

class BLEOTA::ControlCallbacks : public NimBLECharacteristicCallbacks {
 public:
  explicit ControlCallbacks(BLEOTA &owner) : owner_(owner) {}
  void onWrite(NimBLECharacteristic *characteristic, NimBLEConnInfo &info) override {
    if (!deviceBleConnectionOwnsSession(info.getConnHandle())) return;
    owner_.enqueueControl(characteristic->getValue());
  }

 private:
  BLEOTA &owner_;
};

class BLEOTA::DataCallbacks : public NimBLECharacteristicCallbacks {
 public:
  explicit DataCallbacks(BLEOTA &owner) : owner_(owner) {}
  void onWrite(NimBLECharacteristic *characteristic, NimBLEConnInfo &info) override {
    if (!deviceBleConnectionOwnsSession(info.getConnHandle())) return;
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
      BLE_OTA_CONTROL_UUID, NIMBLE_PROPERTY::WRITE);
  auto *data = service->createCharacteristic(
      BLE_OTA_DATA_UUID, NIMBLE_PROPERTY::WRITE_NR);
  status_ = service->createCharacteristic(
      BLE_OTA_STATUS_UUID, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);
  if (!control || !data || !status_) return false;
  control->setCallbacks(new ControlCallbacks(*this));
  data->setCallbacks(new DataCallbacks(*this));
  notify("IDLE");
  return true;
}

void BLEOTA::notify(const char *event, const char *error) {
  if (!status_) return;
  if (strcmp(event, "IDLE") == 0) {
    const std::string metadata = BLEDiscoveryMetadata::build(
        DeviceIdentity::deviceId(), DeviceIdentity::deviceName());
    if (!metadata.empty()) {
      status_->setValue(reinterpret_cast<const uint8_t *>(metadata.data()),
                        metadata.size());
    } else {
      static constexpr char fallback[] = "{\"error\":\"metadata_too_large\"}";
      status_->setValue(reinterpret_cast<const uint8_t *>(fallback),
                        sizeof(fallback) - 1);
    }
    const uint16_t handle = deviceBleSessionHandle();
    if (handle != UINT16_MAX) status_->notify(handle);
    return;
  }
  char json[512];
  const int written = snprintf(
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
  if (written < 0 || static_cast<size_t>(written) >= sizeof(json)) {
    static constexpr char fallback[] = "{\"error\":\"status_too_large\"}";
    status_->setValue(reinterpret_cast<const uint8_t *>(fallback),
                      sizeof(fallback) - 1);
    const uint16_t handle = deviceBleSessionHandle();
    if (handle != UINT16_MAX) status_->notify(handle);
    return;
  }
  status_->setValue(reinterpret_cast<const uint8_t *>(json),
                    static_cast<size_t>(written));
  const uint16_t handle = deviceBleSessionHandle();
  if (handle != UINT16_MAX) status_->notify(handle);
}

void BLEOTA::fail(const char *error) { notify("ERROR", error); }

void BLEOTA::enqueueControl(const std::string &value) {
  // NimBLE invokes this on its host task. Keep the callback bounded to a copy;
  // AES-GCM and OTA processing run later from the Arduino loop task.
  if (!s_controlQueue || value.empty() ||
      value.size() > BLE_OTA_ENCRYPTED_CONTROL_BYTES) {
    s_pendingAbort = PendingAbort::InvalidControl;
    return;
  }
  BLEOTAControlCommand command;
  command.length = static_cast<uint16_t>(value.size());
  memcpy(command.bytes, value.data(), value.size());
  if (xQueueSend(s_controlQueue, &command, 0) != pdTRUE)
    s_pendingAbort = PendingAbort::ControlQueueFull;
}

void BLEOTA::processControl(size_t budget) {
  if (!s_controlQueue) return;
  BLEOTAControlCommand command;
  for (size_t processed = 0;
       processed < budget && xQueueReceive(s_controlQueue, &command, 0) == pdTRUE;
       ++processed) {
    uint8_t plaintext[BLE_OTA_CONTROL_BYTES];
    size_t plaintextLength = 0;
    if (!decryptBleSecureRecord(command.bytes, command.length, plaintext,
                                sizeof(plaintext), plaintextLength) ||
        plaintextLength == 0 || plaintextLength >= sizeof(plaintext)) {
      fail("invalid_control");
      continue;
    }
    const std::string value(reinterpret_cast<const char *>(plaintext),
                            plaintextLength);
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
  // See enqueueControl(): decryption here starves NimBLE and can overflow the
  // host task under a sustained write-without-response burst.
  if (!s_dataQueue || value.empty() ||
      value.size() > BLE_OTA_ENCRYPTED_FRAME_BYTES) {
    s_pendingAbort = PendingAbort::InvalidChunk;
    return;
  }
  BLEOTAFrame frame;
  frame.length = static_cast<uint16_t>(value.size());
  memcpy(frame.bytes, value.data(), value.size());
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
    uint8_t plaintext[BLE_OTA_FRAME_BYTES];
    size_t plaintextLength = 0;
    if (!decryptBleSecureRecord(frame.bytes, frame.length, plaintext,
                                sizeof(plaintext), plaintextLength) ||
        plaintextLength <= sizeof(uint32_t) ||
        g_otaEngine.owner() != OTATransportOwner::BLE) {
      xQueueReset(s_dataQueue);
      if (active()) g_otaEngine.abort("invalid_chunk");
      fail("invalid_chunk");
      return;
    }
    const uint8_t *bytes = plaintext;
    const uint32_t offset = static_cast<uint32_t>(bytes[0]) |
                            (static_cast<uint32_t>(bytes[1]) << 8) |
                            (static_cast<uint32_t>(bytes[2]) << 16) |
                            (static_cast<uint32_t>(bytes[3]) << 24);
    if (!g_otaEngine.write(offset, bytes + 4, plaintextLength - 4)) {
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
    const char *error = "invalid_chunk";
    if (pendingAbort == PendingAbort::QueueFull) error = "ble_queue_full";
    else if (pendingAbort == PendingAbort::InvalidControl)
      error = "invalid_control";
    else if (pendingAbort == PendingAbort::ControlQueueFull)
      error = "control_queue_full";
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
