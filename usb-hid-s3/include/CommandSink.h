#ifndef COMMAND_SINK_H
#define COMMAND_SINK_H

#include <stdint.h>
#include <string>
#include "../lib/HIDExecutor/HIDEventQueue.h"

// Single entry point for a command line, regardless of transport
// (USB-CDC serial, BLE NUS, WiFi TCP, or HTTP REST). Defined in main.cpp.
// `source` is a short tag for logs, e.g. "serial", "ble", "wifi", "http".
void handleCommandLine(const std::string &line, const char *source);
bool enqueueHIDEvent(const HIDEvent &event, const char *source);
void requestReleaseAll(const char *source);
bool requestReleaseAllAndWait(const char *source, uint32_t timeoutMs);

// Status hooks for HTTP GET endpoints (implemented in main.cpp).
bool deviceJiggleEnabled();
uint32_t deviceJiggleIntervalMs();
bool deviceHidReady();
bool deviceOtaActive();
HIDDiagnosticsSnapshot deviceHidDiagnostics();
void recordHIDDecodeError(const char *source, size_t length);
void recordHIDInput(const char *source, uint8_t type, size_t length);
void recordHIDBleFrame(uint8_t type, size_t length);
const char *deviceResetReason();

#endif // COMMAND_SINK_H
