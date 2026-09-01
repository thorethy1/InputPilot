#include "BLEDiagnostics.h"

#include <cstdio>
#include <cstring>
#include <esp_ota_ops.h>

#include "Config.h"
#include "DeviceIdentity.h"
#include "FirmwareLog.h"
#include "CommandSink.h"

BLEDiagnostics g_bleDiagnostics;

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

std::string BLEDiagnostics::compactInfoJson() const {
  // Keep the encrypted text record below the 512-byte GATT value limit.
  char json[224];
  const esp_partition_t *running = esp_ota_get_running_partition();
  snprintf(json, sizeof(json),
           "{\"product\":\"%s\",\"firmware\":\"%s\",\"board\":\"%s\"," 
           "\"protocol\":2,\"otaSchema\":1,\"deviceId\":\"%s\"," 
           "\"resetReason\":\"%s\",\"runningPartition\":\"%s\"}",
           FW_PRODUCT, FW_VERSION, FW_BOARD, DeviceIdentity::deviceId(),
           deviceResetReason(), running ? running->label : "unknown");
  return std::string(json);
}

std::string BLEDiagnostics::nextLogJson(uint32_t &cursor,
                                        size_t maxLineBytes) const {
  FirmwareLogEntry entry;
  if (firmwareLogCopySince(cursor, &entry, 1) == 0) return "{}";
  char prefix[48];
  snprintf(prefix, sizeof(prefix), "{\"sequence\":%lu,\"line\":\"",
           static_cast<unsigned long>(entry.sequence));
  std::string json(prefix);
  size_t consumed = 0;
  for (const char *p = entry.line; *p && consumed < maxLineBytes; ++p, ++consumed) {
    if (*p == '"' || *p == '\\') json += '\\';
    if (*p == '\n') json += "\\n"; else if (*p != '\r') json += *p;
  }
  json += "\"}";
  cursor = entry.sequence;
  return json;
}
