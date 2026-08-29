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
  void enqueueControl(const std::string &value);
  void enqueueData(const std::string &value);
  void processControl(size_t budget = 2);
  void processData(size_t budget = 4);
  void notify(const char *event, const char *error = nullptr); void fail(const char *error);
  NimBLECharacteristic *status_ = nullptr;
  uint32_t lastActivityMs_ = 0, lastAck_ = 0, rebootAtMs_ = 0;
};
extern BLEOTA g_bleOta;
#endif
