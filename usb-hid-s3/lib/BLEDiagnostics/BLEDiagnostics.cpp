#include "BLEDiagnostics.h"

#include <cstdio>
#include <cstring>
#include <esp_ota_ops.h>

#include "Config.h"
#include "DeviceIdentity.h"
#include "FirmwareLog.h"
#include "CommandSink.h"
extern bool deviceBleAuthenticated();

BLEDiagnostics g_bleDiagnostics;

class BLEDiagnostics::InfoCallbacks : public NimBLECharacteristicCallbacks {
 public:
  explicit InfoCallbacks(BLEDiagnostics &owner) : owner_(owner) {}
  void onRead(NimBLECharacteristic *characteristic, NimBLEConnInfo &) override {
    if (deviceBleAuthenticated()) owner_.refreshInfo();
    else characteristic->setValue("authentication required");
  }
 private:
  BLEDiagnostics &owner_;
};

class BLEDiagnostics::LogCallbacks : public NimBLECharacteristicCallbacks {
 public:
  explicit LogCallbacks(BLEDiagnostics &owner) : owner_(owner) {}
  void onSubscribe(NimBLECharacteristic *, NimBLEConnInfo &, uint16_t value) override {
    owner_.subscribed_ = deviceBleAuthenticated() && (value & 0x0001) != 0;
    if (owner_.subscribed_) owner_.cursor_ = 0;
  }
 private:
  BLEDiagnostics &owner_;
};

bool BLEDiagnostics::begin(NimBLEServer *server) {
  if (!server) return false;
  NimBLEService *service = server->createService(BLE_DIAGNOSTICS_SERVICE_UUID);
  if (!service) return false;
  info_ = service->createCharacteristic(
      BLE_DIAGNOSTICS_INFO_UUID, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::READ_ENC);
  log_ = service->createCharacteristic(
      BLE_DIAGNOSTICS_LOG_UUID, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY |
                                    NIMBLE_PROPERTY::READ_ENC);
  if (!info_ || !log_) return false;

  infoCallbacks_ = new InfoCallbacks(*this);
  info_->setCallbacks(infoCallbacks_);
  refreshInfo();
  log_->setValue("Subscribe for recent and live logs");
  callbacks_ = new LogCallbacks(*this);
  log_->setCallbacks(callbacks_);
  return true;
}

std::string BLEDiagnostics::infoJson() const {
  char json[1024];
  const esp_partition_t *running = esp_ota_get_running_partition();
  const esp_partition_t *boot = esp_ota_get_boot_partition();
  const HIDDiagnosticsSnapshot hid = deviceHidDiagnostics();
  snprintf(json, sizeof(json),
           "{\"product\":\"%s\",\"firmware\":\"%s\",\"board\":\"%s\","
           "\"protocol\":2,\"otaSchema\":1,\"deviceId\":\"%s\","
           "\"firmwareCommit\":\"%s\",\"resetReason\":\"%s\","
           "\"runningPartition\":\"%s\",\"bootPartition\":\"%s\",\"uptime\":%lu,\"heap\":%u,"
           "\"hid\":{\"rxBle\":%lu,\"rxTcp\":%lu,\"rxSerial\":%lu,"
           "\"decoded\":%lu,\"decodeErrors\":%lu,\"queued\":%lu,\"queueRejected\":%lu,"
           "\"executed\":%lu,\"failed\":%lu,\"mouseExecuted\":%lu,\"keyboardExecuted\":%lu,"
           "\"usbReportsAttempted\":%lu,\"usbReportsSucceeded\":%lu,\"usbReportsFailed\":%lu,"
           "\"lastSource\":\"%s\",\"lastType\":\"%s\",\"lastSequence\":%lu,\"lastPhase\":\"%s\","
           "\"previousBreadcrumbValid\":%s,\"previousSequence\":%lu,\"previousSource\":\"%s\","
           "\"previousEventType\":%u,\"previousPhase\":%u,\"previousBleRxType\":%u,"
           "\"previousBleRxLength\":%lu,\"previousQueueDepth\":%lu}}",
           FW_PRODUCT, FW_VERSION, FW_BOARD, DeviceIdentity::deviceId(),
           FW_GIT_COMMIT, deviceResetReason(),
           running ? running->label : "unknown", boot ? boot->label : "unknown",
           static_cast<unsigned long>(millis()), ESP.getFreeHeap(),
           (unsigned long)hid.rxBle, (unsigned long)hid.rxTcp, (unsigned long)hid.rxSerial,
           (unsigned long)hid.decoded, (unsigned long)hid.decodeErrors, (unsigned long)hid.queued, (unsigned long)hid.queueRejected,
           (unsigned long)hid.executed, (unsigned long)hid.executeFailed, (unsigned long)hid.mouseExecuted, (unsigned long)hid.keyboardExecuted,
           (unsigned long)hid.usbReportsAttempted, (unsigned long)hid.usbReportsSucceeded, (unsigned long)hid.usbReportsFailed,
           hid.lastSource, hid.lastType, (unsigned long)hid.lastSequence, hid.lastPhaseName,
           hid.previousBreadcrumbValid ? "true" : "false", (unsigned long)hid.previousSequence,
           hid.previousSource, hid.previousEventType, hid.previousPhase, hid.previousBleRxType,
           (unsigned long)hid.previousBleRxLength, (unsigned long)hid.previousQueueDepth);
  return std::string(json);
}

std::string BLEDiagnostics::nextLogJson(uint32_t &cursor) const {
  FirmwareLogEntry entry;
  if (firmwareLogCopySince(cursor, &entry, 1) == 0) return "{}";
  char prefix[48];
  snprintf(prefix, sizeof(prefix), "{\"sequence\":%lu,\"line\":\"",
           static_cast<unsigned long>(entry.sequence));
  std::string json(prefix);
  for (const char *p = entry.line; *p; ++p) {
    if (*p == '"' || *p == '\\') json += '\\';
    if (*p == '\n') json += "\\n"; else if (*p != '\r') json += *p;
  }
  json += "\"}";
  cursor = entry.sequence;
  return json;
}

void BLEDiagnostics::refreshInfo() {
  if (!info_) return;
  const std::string json = infoJson();
  info_->setValue(reinterpret_cast<const uint8_t *>(json.data()), json.size());
}

void BLEDiagnostics::loop(bool otaActive) {
  if (!subscribed_ || !deviceBleAuthenticated() || !log_ || otaActive ||
      millis() - lastNotifyMs_ < 100) return;
  FirmwareLogEntry entries[3];
  const size_t count = firmwareLogCopySince(cursor_, entries, 3);
  if (!count) return;
  lastNotifyMs_ = millis();
  for (size_t i = 0; i < count; ++i) {
    char frame[224];
    snprintf(frame, sizeof(frame), "{\"sequence\":%lu,\"line\":\"",
             static_cast<unsigned long>(entries[i].sequence));
    std::string json(frame);
    for (const char *p = entries[i].line; *p; ++p) {
      if (*p == '"' || *p == '\\') json += '\\';
      if (*p == '\n') json += "\\n"; else if (*p != '\r') json += *p;
    }
    json += "\"}";
    log_->setValue(reinterpret_cast<const uint8_t *>(json.data()), json.size());
    if (!log_->notify()) break;
    cursor_ = entries[i].sequence;
  }
}

void BLEDiagnostics::disconnected() {
  subscribed_ = false;
  cursor_ = 0;
}
