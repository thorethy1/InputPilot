#ifndef BLE_OTA_H
#define BLE_OTA_H
#include <Arduino.h>
#include <NimBLEDevice.h>
#include "OTAProtocol.h"
class BLEOTA {
 public:
  bool begin(NimBLEServer *server); void loop(); void disconnected();
  bool active() const; OTAState state() const; static bool schemaAvailable();
 private:
  class ControlCallbacks; class DataCallbacks;
  friend class ControlCallbacks; friend class DataCallbacks;
  void control(const std::string &value); void data(const std::string &value);
  void notify(const char *event, const char *error = nullptr); void fail(const char *error);
  NimBLECharacteristic *status_ = nullptr;
  uint32_t lastActivityMs_ = 0, lastAck_ = 0, rebootAtMs_ = 0;
};
extern BLEOTA g_bleOta;
#endif
