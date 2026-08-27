#ifndef OTA_ENGINE_H
#define OTA_ENGINE_H

#include <Arduino.h>
#include <esp_ota_ops.h>
#include <mbedtls/sha256.h>
#include <string>

#include "OTAProtocol.h"

enum class OTATransportOwner { None, BLE, WiFi };

class OTAEngine {
 public:
  bool start(const OTAStartRequest &request, OTATransportOwner owner);
  bool write(uint32_t offset, const uint8_t *data, size_t size);
  bool finish();
  void abort(const char *reason, bool cancelled = false);
  void reset();

  bool active() const;
  OTAState state() const { return state_; }
  OTATransportOwner owner() const { return owner_; }
  uint32_t received() const { return received_; }
  uint32_t total() const { return request_.size; }
  const OTAStartRequest &request() const { return request_; }
  const char *error() const { return error_.c_str(); }
  const char *targetPartition() const { return partition_ ? partition_->label : ""; }
  static bool schemaAvailable();

 private:
  bool fail(const char *error);
  bool validateWrittenImage();
  void releaseResources();

  esp_ota_handle_t handle_ = 0;
  const esp_partition_t *partition_ = nullptr;
  OTAState state_ = OTAState::Idle;
  OTATransportOwner owner_ = OTATransportOwner::None;
  OTAStartRequest request_;
  uint32_t received_ = 0;
  mbedtls_sha256_context sha_{};
  bool shaInitialized_ = false;
  std::string error_;
};

extern OTAEngine g_otaEngine;

#endif
