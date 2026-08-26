#ifndef BLE_OTA_H
#define BLE_OTA_H

#include <Arduino.h>
#include <NimBLEDevice.h>
#include <esp_ota_ops.h>
#include <mbedtls/sha256.h>

#include "OTAProtocol.h"

class BLEOTA {
 public:
  void begin(NimBLEServer *server);
  void loop();
  void disconnected();
  bool active() const;
  OTAState state() const { return state_; }
  static bool schemaAvailable();

 private:
  class ControlCallbacks;
  class DataCallbacks;
  friend class ControlCallbacks;
  friend class DataCallbacks;

  void control(const std::string &value);
  void data(const std::string &value);
  void notify(const char *event, const char *error = nullptr);
  void fail(const char *error);
  void abort(OTAState finalState, const char *reason);
  bool start(const OTAStartRequest &request);
  void finish();

  NimBLECharacteristic *status_ = nullptr;
  esp_ota_handle_t handle_ = 0;
  const esp_partition_t *partition_ = nullptr;
  OTAState state_ = OTAState::Idle;
  OTAStartRequest request_;
  uint32_t received_ = 0;
  uint32_t lastActivityMs_ = 0;
  uint32_t lastAck_ = 0;
  mbedtls_sha256_context sha_;
  bool shaInitialized_ = false;
};

extern BLEOTA g_bleOta;

#endif
