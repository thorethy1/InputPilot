#ifndef UNIT_TEST
#include "OTAEngine.h"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <esp_partition.h>

#include "CommandSink.h"
#include "Config.h"
#include "FirmwareMetadata.h"
#include "Logging.h"
#include "OTAEngineValidation.h"

OTAEngine g_otaEngine;

bool OTAEngine::schemaAvailable() {
  const esp_partition_t *running = esp_ota_get_running_partition();
  const esp_partition_t *next = esp_ota_get_next_update_partition(nullptr);
  return running && next && running->type == ESP_PARTITION_TYPE_APP &&
         running->subtype >= ESP_PARTITION_SUBTYPE_APP_OTA_0 &&
         running->subtype < ESP_PARTITION_SUBTYPE_APP_OTA_MAX && next->size > 0;
}

bool OTAEngine::active() const {
  return state_ == OTAState::Preparing || state_ == OTAState::Receiving ||
         state_ == OTAState::Verifying || state_ == OTAState::Installing;
}

bool OTAEngine::start(const OTAStartRequest &request, OTATransportOwner owner) {
  if (active()) return false;
  if (owner_ != OTATransportOwner::None) reset();
  if (owner == OTATransportOwner::None) return fail("invalid_transport");
  if (!schemaAvailable()) return fail("migration_required");
  partition_ = esp_ota_get_next_update_partition(nullptr);
  if (!partition_) return fail("migration_required");
  std::string validationError;
  if (!OTAEngineValidation::start(false, request, partition_->size, validationError)) return fail(validationError.c_str());

  request_ = request; received_ = 0; error_.clear(); owner_ = owner;
  state_ = OTAState::Preparing;
  // Queue a priority release. USB reports are deliberately emitted only from
  // Arduino loop(), never from a BLE/HTTP OTA callback.
  requestReleaseAll("ota-start");
  if (esp_ota_begin(partition_, request.size, &handle_) != ESP_OK) {
    handle_ = 0; return fail("begin_failed");
  }
  mbedtls_sha256_init(&sha_);
  if (mbedtls_sha256_starts(&sha_, 0) != 0) return fail("hash_init_failed");
  shaInitialized_ = true; state_ = OTAState::Receiving;
  LOG_OTA("start transport=%s version=%s size=%lu target=%s",
          owner == OTATransportOwner::BLE ? "ble" : "wifi", request.version.c_str(),
          static_cast<unsigned long>(request.size), partition_->label);
  return true;
}

bool OTAEngine::write(uint32_t offset, const uint8_t *data, size_t size) {
  if (state_ != OTAState::Receiving) return fail("not_receiving");
  std::string validationError;
  if (!data || !OTAEngineValidation::write(received_, offset, size, request_.size, validationError)) return fail("invalid_offset");
  if (esp_ota_write(handle_, data, size) != ESP_OK) return fail("write_failed");
  if (mbedtls_sha256_update(&sha_, data, size) != 0) return fail("hash_failed");
  received_ += size;
  return true;
}

bool OTAEngine::validateWrittenImage() {
  uint8_t digest[32];
  if (mbedtls_sha256_finish(&sha_, digest) != 0) return fail("hash_failed");
  mbedtls_sha256_free(&sha_); shaInitialized_ = false;
  char calculated[65]{};
  for (size_t i = 0; i < sizeof(digest); ++i) snprintf(calculated + i * 2, 3, "%02x", digest[i]);
  FirmwareMetadataValue metadata; std::string metadataError;
  constexpr size_t kChunk = 4096, kOverlap = 256;
  uint8_t *image = static_cast<uint8_t *>(malloc(kChunk + kOverlap));
  if (!image) return fail("metadata_read_failed");
  size_t carried = 0; bool parsed = false;
  for (uint32_t offset = 0; offset < request_.size && !parsed;) {
    const size_t count = std::min<size_t>(kChunk, request_.size - offset);
    if (esp_partition_read(partition_, offset, image + carried, count) != ESP_OK) break;
    parsed = FirmwareMetadata::parse(image, carried + count, metadata);
    const size_t available = carried + count;
    carried = std::min(kOverlap, available);
    memmove(image, image + available - carried, carried); offset += count;
  }
  free(image);
  if (!parsed) return fail("invalid_metadata");
  if (!OTAEngineValidation::completion(received_, request_, calculated, metadata, metadataError)) return fail(metadataError.c_str());
  return true;
}

bool OTAEngine::finish() {
  if (state_ != OTAState::Receiving) return fail("not_receiving");
  if (received_ != request_.size) return fail("incomplete_firmware");
  state_ = OTAState::Verifying; LOG_OTA("verifying");
  if (!validateWrittenImage()) return false;
  if (esp_ota_end(handle_) != ESP_OK) { handle_ = 0; return fail("image_invalid"); }
  handle_ = 0; state_ = OTAState::Installing;
  if (esp_ota_set_boot_partition(partition_) != ESP_OK) return fail("boot_partition_failed");
  state_ = OTAState::Complete; LOG_OTA("boot partition set target=%s", partition_->label);
  requestReleaseAll("ota-finish");
  return true;
}

bool OTAEngine::fail(const char *error) {
  error_ = error ? error : "ota_failed";
  LOG_OTA_WARN("failed: %s", error_.c_str());
  releaseResources(); state_ = OTAState::Failed; requestReleaseAll("ota-failure");
  return false;
}

void OTAEngine::abort(const char *reason, bool cancelled) {
  error_ = reason ? reason : "cancelled";
  releaseResources(); state_ = cancelled ? OTAState::Cancelled : OTAState::Failed;
  requestReleaseAll("ota-abort"); LOG_OTA_WARN("%s", error_.c_str());
}

void OTAEngine::releaseResources() {
  if (handle_) esp_ota_abort(handle_);
  handle_ = 0;
  if (shaInitialized_) { mbedtls_sha256_free(&sha_); shaInitialized_ = false; }
}

void OTAEngine::reset() {
  if (active()) return;
  releaseResources(); partition_ = nullptr; request_ = {}; received_ = 0;
  error_.clear(); state_ = OTAState::Idle; owner_ = OTATransportOwner::None;
}
#endif
