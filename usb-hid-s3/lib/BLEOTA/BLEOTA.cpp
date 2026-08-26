#include "BLEOTA.h"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <esp_partition.h>
#include <esp_system.h>

#include "CommandSink.h"
#include "Config.h"
#include "DeviceIdentity.h"
#include "FirmwareMetadata.h"
#include "Logging.h"

extern bool deviceBleAuthenticated();

BLEOTA g_bleOta;

class BLEOTA::ControlCallbacks : public NimBLECharacteristicCallbacks {
 public:
  explicit ControlCallbacks(BLEOTA &owner) : owner_(owner) {}
  void onWrite(NimBLECharacteristic *c, NimBLEConnInfo &) override { owner_.control(c->getValue()); }
 private: BLEOTA &owner_;
};

class BLEOTA::DataCallbacks : public NimBLECharacteristicCallbacks {
 public:
  explicit DataCallbacks(BLEOTA &owner) : owner_(owner) {}
  void onWrite(NimBLECharacteristic *c, NimBLEConnInfo &) override { owner_.data(c->getValue()); }
 private: BLEOTA &owner_;
};

bool BLEOTA::schemaAvailable() {
  const esp_partition_t *running = esp_ota_get_running_partition();
  const esp_partition_t *next = esp_ota_get_next_update_partition(nullptr);
  return running && next && running->type == ESP_PARTITION_TYPE_APP &&
         running->subtype >= ESP_PARTITION_SUBTYPE_APP_OTA_0 &&
         running->subtype < ESP_PARTITION_SUBTYPE_APP_OTA_MAX &&
         next->size > 0;
}

void BLEOTA::begin(NimBLEServer *server) {
  NimBLEService *service = server->createService(BLE_OTA_SERVICE_UUID);
  auto *controlCharacteristic = service->createCharacteristic(
      BLE_OTA_CONTROL_UUID, NIMBLE_PROPERTY::WRITE);
  auto *dataCharacteristic = service->createCharacteristic(
      BLE_OTA_DATA_UUID, NIMBLE_PROPERTY::WRITE_NR);
  status_ = service->createCharacteristic(
      BLE_OTA_STATUS_UUID, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);
  controlCharacteristic->setCallbacks(new ControlCallbacks(*this));
  dataCharacteristic->setCallbacks(new DataCallbacks(*this));
  notify("IDLE");
}

bool BLEOTA::active() const {
  return state_ == OTAState::Preparing || state_ == OTAState::Receiving ||
         state_ == OTAState::Verifying || state_ == OTAState::Installing;
}

void BLEOTA::notify(const char *event, const char *error) {
  if (!status_) return;
  char json[640];
  if (strcmp(event, "IDLE") == 0) {
    // The complete identity is read during onboarding/connection. Active OTA
    // notifications stay below a typical iOS ATT MTU and remain deterministic.
    snprintf(json, sizeof(json),
             "{\"product\":\"%s\",\"board\":\"%s\",\"deviceId\":\"%s\",\"deviceName\":\"%s\",\"protocol\":%u,\"otaSchema\":%u,\"firmware\":\"%s\",\"authRequired\":%s,\"capabilities\":[\"ble_control\",\"ble_ota\",\"mouse_move\",\"mouse_click\",\"mouse_button_state\",\"mouse_scroll\",\"keyboard_type\",\"keyboard_key\",\"keyboard_layout\",\"release_all\",\"protocol_v1\"],\"state\":\"idle\",\"event\":\"IDLE\",\"offset\":0,\"size\":0,\"maxChunk\":500,\"windowSize\":%lu}",
             FW_PRODUCT, FW_BOARD, DeviceIdentity::deviceId(), BLE_DEVICE_NAME,
             OTA_PROTOCOL_VERSION, OTA_SCHEMA_VERSION, FW_VERSION,
             strlen(CONTROL_API_TOKEN) ? "true" : "false", (unsigned long)BLE_OTA_ACK_BYTES);
  } else {
    snprintf(json, sizeof(json),
             "{\"protocol\":%u,\"otaSchema\":%u,\"firmware\":\"%s\",\"state\":\"%s\",\"event\":\"%s\",\"offset\":%lu,\"size\":%lu,\"maxChunk\":%u,\"windowSize\":%lu%s%s%s}",
             OTA_PROTOCOL_VERSION, OTA_SCHEMA_VERSION, FW_VERSION, OTAProtocol::stateName(state_), event,
             (unsigned long)received_, (unsigned long)request_.size, 500,
             (unsigned long)BLE_OTA_ACK_BYTES, error ? ",\"error\":\"" : "",
             error ? error : "", error ? "\"" : "");
  }
  status_->setValue(reinterpret_cast<const uint8_t *>(json), strlen(json));
  status_->notify();
}

void BLEOTA::abort(OTAState finalState, const char *reason) {
  if (handle_) esp_ota_abort(handle_);
  handle_ = 0; partition_ = nullptr;
  if (shaInitialized_) { mbedtls_sha256_free(&sha_); shaInitialized_ = false; }
  state_ = finalState;
  notify(finalState == OTAState::Cancelled ? "CANCELLED" : "ERROR", reason);
  deviceReleaseAll();
}

void BLEOTA::fail(const char *error) { LOG_WARN("OTA failed: %s", error); abort(OTAState::Failed, error); }

bool BLEOTA::start(const OTAStartRequest &request) {
  if (!deviceBleAuthenticated()) { fail("unauthorized"); return false; }
  if (active()) { fail("update_in_progress"); return false; }
  if (!schemaAvailable()) { fail("migration_required"); return false; }
  if (request.protocol != OTA_PROTOCOL_VERSION) { fail("unsupported_protocol"); return false; }
  partition_ = esp_ota_get_next_update_partition(nullptr);
  if (!partition_ || request.size > partition_->size) { fail("firmware_too_large"); return false; }
  state_ = OTAState::Preparing; request_ = request; received_ = 0; lastAck_ = 0;
  deviceReleaseAll();
  esp_err_t result = esp_ota_begin(partition_, request.size, &handle_);
  if (result != ESP_OK) { handle_ = 0; fail("begin_failed"); return false; }
  mbedtls_sha256_init(&sha_);
  if (mbedtls_sha256_starts(&sha_, 0) != 0) { fail("hash_init_failed"); return false; }
  shaInitialized_ = true; state_ = OTAState::Receiving; lastActivityMs_ = millis();
  LOG_INFO("OTA start version=%s size=%lu", request.version.c_str(), (unsigned long)request.size);
  LOG_INFO("OTA target partition=%s", partition_->label);
  notify("READY");
  return true;
}

void BLEOTA::control(const std::string &value) {
  if (!deviceBleAuthenticated()) { fail("unauthorized"); return; }
  if (value == "ABORT") { if (active()) abort(OTAState::Cancelled, "user_cancelled"); return; }
  if (value == "FINISH") { finish(); return; }
  OTAStartRequest request; std::string error;
  if (!OTAProtocol::parseStart(value, request, error)) { fail(error.c_str()); return; }
  start(request);
}

void BLEOTA::data(const std::string &value) {
  if (!deviceBleAuthenticated()) { fail("unauthorized"); return; }
  if (state_ != OTAState::Receiving || value.size() <= 4) { fail("not_receiving"); return; }
  const uint8_t *bytes = reinterpret_cast<const uint8_t *>(value.data());
  const uint32_t offset = uint32_t(bytes[0]) | (uint32_t(bytes[1]) << 8) |
                          (uint32_t(bytes[2]) << 16) | (uint32_t(bytes[3]) << 24);
  const size_t payload = value.size() - 4;
  if (!OTAProtocol::acceptsOffset(received_, offset, payload, request_.size)) { fail("invalid_offset"); return; }
  if (esp_ota_write(handle_, bytes + 4, payload) != ESP_OK) { fail("write_failed"); return; }
  if (mbedtls_sha256_update(&sha_, bytes + 4, payload) != 0) { fail("hash_failed"); return; }
  received_ += payload; lastActivityMs_ = millis();
  if (received_ - lastAck_ >= BLE_OTA_ACK_BYTES || received_ == request_.size) {
    lastAck_ = received_; notify("ACK");
    const unsigned progress = request_.size ? (received_ * 100ULL / request_.size) : 0;
    if (progress == 25 || progress == 50 || progress == 75 || progress == 100)
      LOG_INFO("OTA progress=%u%%", progress);
  }
}

void BLEOTA::finish() {
  if (state_ != OTAState::Receiving) { fail("not_receiving"); return; }
  if (received_ != request_.size) { fail("incomplete_firmware"); return; }
  state_ = OTAState::Verifying; notify("VERIFYING"); LOG_INFO("OTA verifying");
  uint8_t digest[32];
  if (mbedtls_sha256_finish(&sha_, digest) != 0) { fail("hash_failed"); return; }
  mbedtls_sha256_free(&sha_); shaInitialized_ = false;
  char calculated[65];
  for (size_t i = 0; i < sizeof(digest); ++i) snprintf(calculated + i * 2, 3, "%02x", digest[i]);
  if (request_.sha256 != calculated) { fail("checksum_mismatch"); return; }
  LOG_INFO("OTA checksum ok");
  FirmwareMetadataValue metadata;
  std::string metadataError;
  // Scan in bounded chunks; allocating an entire OTA slot would exhaust SRAM.
  constexpr size_t kChunk = 4096;
  constexpr size_t kOverlap = 256;
  uint8_t *image = static_cast<uint8_t *>(malloc(kChunk + kOverlap));
  if (!image) { fail("metadata_read_failed"); return; }
  size_t carried = 0;
  bool parsed = false;
  for (uint32_t offset = 0; offset < request_.size && !parsed;) {
    const size_t count = std::min<size_t>(kChunk, request_.size - offset);
    if (esp_partition_read(partition_, offset, image + carried, count) != ESP_OK) break;
    parsed = FirmwareMetadata::parse(image, carried + count, metadata);
    const size_t available = carried + count;
    carried = std::min(kOverlap, available);
    memmove(image, image + available - carried, carried);
    offset += count;
  }
  free(image);
  if (!parsed) { fail("invalid_metadata"); return; }
  if (!FirmwareMetadata::compatible(metadata, metadataError)) { fail(metadataError.c_str()); return; }
  if (metadata.version != request_.version) { fail("version_mismatch"); return; }
  if (esp_ota_end(handle_) != ESP_OK) { handle_ = 0; fail("image_invalid"); return; }
  handle_ = 0; state_ = OTAState::Installing; notify("INSTALLING");
  if (esp_ota_set_boot_partition(partition_) != ESP_OK) { fail("boot_partition_failed"); return; }
  LOG_INFO("OTA setting boot partition"); state_ = OTAState::Complete; notify("SUCCESS");
  state_ = OTAState::Rebooting; notify("REBOOTING"); LOG_INFO("OTA reboot");
  delay(750); esp_restart();
}

void BLEOTA::disconnected() { if (active()) abort(OTAState::Cancelled, "connection_lost"); }

void BLEOTA::loop() {
  if (active() && millis() - lastActivityMs_ > BLE_OTA_TIMEOUT_MS) fail("timeout");
}
