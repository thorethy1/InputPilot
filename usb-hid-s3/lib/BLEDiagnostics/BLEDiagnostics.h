#ifndef BLE_DIAGNOSTICS_H
#define BLE_DIAGNOSTICS_H

#include <Arduino.h>
#include <NimBLEDevice.h>

class BLEDiagnostics {
 public:
  bool begin(NimBLEServer *server);
  void loop(bool otaActive);
  void disconnected();

 private:
  class InfoCallbacks;
  class LogCallbacks;
  void refreshInfo();
  NimBLECharacteristic *info_ = nullptr;
  NimBLECharacteristic *log_ = nullptr;
  InfoCallbacks *infoCallbacks_ = nullptr;
  LogCallbacks *callbacks_ = nullptr;
  uint32_t cursor_ = 0;
  uint32_t lastNotifyMs_ = 0;
  bool subscribed_ = false;
};

extern BLEDiagnostics g_bleDiagnostics;

#endif
