#ifndef BLE_DIAGNOSTICS_H
#define BLE_DIAGNOSTICS_H

#include <Arduino.h>
#include <string>

class BLEDiagnostics {
 public:
  std::string infoJson() const;
  std::string compactInfoJson() const;
  std::string nextLogJson(uint32_t &cursor, size_t maxLineBytes = 159) const;
};

extern BLEDiagnostics g_bleDiagnostics;

#endif
