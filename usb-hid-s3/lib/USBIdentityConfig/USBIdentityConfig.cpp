#include "USBIdentityConfig.h"

#include <ctype.h>
#include <string.h>

namespace {

bool printableAscii(const char *value, size_t maximum) {
  if (!value) return false;
  const size_t length = strlen(value);
  if (length == 0 || length > maximum) return false;
  for (size_t i = 0; i < length; ++i) {
    const unsigned char c = static_cast<unsigned char>(value[i]);
    if (c < 0x20 || c > 0x7e) return false;
  }
  return true;
}

}  // namespace

bool usbProductNameValid(const char *value) {
  return printableAscii(value, USB_PRODUCT_NAME_MAX);
}

bool usbSerialNumberValid(const char *value) {
  if (!printableAscii(value, USB_SERIAL_NUMBER_MAX)) return false;
  for (const char *p = value; *p; ++p) {
    const unsigned char c = static_cast<unsigned char>(*p);
    if (!isalnum(c) && c != '-' && c != '_' && c != '.') return false;
  }
  return true;
}

bool usbVidPidValid(uint32_t value) {
  return value > 0 && value <= 0xffff;
}

#ifndef UNIT_TEST
#include <Preferences.h>
#include <stdio.h>

#include "Config.h"
#include "Logging.h"

namespace {

constexpr const char *kNamespace = "usb_identity";
constexpr const char *kProductKey = "product";
constexpr const char *kVidKey = "vid";
constexpr const char *kPidKey = "pid";
constexpr const char *kSerialKey = "serial";

USBIdentityValues s_values{};
char s_defaultSerial[USB_SERIAL_NUMBER_MAX + 1]{};
bool s_ready = false;

void loadDefaults() {
  s_values.vid = HID_USB_VID;
  s_values.pid = HID_USB_PID;
  snprintf(s_values.productName, sizeof(s_values.productName), "%s",
           HID_USB_PRODUCT);
  snprintf(s_values.serialNumber, sizeof(s_values.serialNumber), "%s",
           s_defaultSerial);
}

}  // namespace

void USBIdentityConfig::begin(const char *defaultSerialNumber) {
  snprintf(s_defaultSerial, sizeof(s_defaultSerial), "%s",
           defaultSerialNumber ? defaultSerialNumber : "InputPilot");
  if (!usbSerialNumberValid(s_defaultSerial)) {
    snprintf(s_defaultSerial, sizeof(s_defaultSerial), "InputPilot");
  }
  loadDefaults();

  Preferences preferences;
  if (preferences.begin(kNamespace, true)) {
    const String product = preferences.getString(kProductKey, HID_USB_PRODUCT);
    const uint32_t vid = preferences.getUInt(kVidKey, HID_USB_VID);
    const uint32_t pid = preferences.getUInt(kPidKey, HID_USB_PID);
    const String serial = preferences.getString(kSerialKey, s_defaultSerial);
    preferences.end();
    if (usbProductNameValid(product.c_str()))
      snprintf(s_values.productName, sizeof(s_values.productName), "%s", product.c_str());
    if (usbVidPidValid(vid)) s_values.vid = static_cast<uint16_t>(vid);
    if (usbVidPidValid(pid)) s_values.pid = static_cast<uint16_t>(pid);
    if (usbSerialNumberValid(serial.c_str()))
      snprintf(s_values.serialNumber, sizeof(s_values.serialNumber), "%s", serial.c_str());
  }
  s_ready = true;
  LOG_USB("identity loaded vid=0x%04X pid=0x%04X product=\"%s\" serial=\"%s\"",
          s_values.vid, s_values.pid, s_values.productName, s_values.serialNumber);
}

const USBIdentityValues &USBIdentityConfig::get() {
  if (!s_ready) begin("InputPilot");
  return s_values;
}

bool USBIdentityConfig::save(const char *productName, uint32_t vid, uint32_t pid,
                             const char *serialNumber) {
  if (!usbProductNameValid(productName) || !usbVidPidValid(vid) ||
      !usbVidPidValid(pid) || !usbSerialNumberValid(serialNumber)) return false;
  Preferences preferences;
  if (!preferences.begin(kNamespace, false)) return false;
  const bool ok = preferences.putString(kProductKey, productName) > 0 &&
                  preferences.putUInt(kVidKey, vid) == sizeof(uint32_t) &&
                  preferences.putUInt(kPidKey, pid) == sizeof(uint32_t) &&
                  preferences.putString(kSerialKey, serialNumber) > 0;
  preferences.end();
  if (!ok) return false;
  s_values.vid = static_cast<uint16_t>(vid);
  s_values.pid = static_cast<uint16_t>(pid);
  snprintf(s_values.productName, sizeof(s_values.productName), "%s", productName);
  snprintf(s_values.serialNumber, sizeof(s_values.serialNumber), "%s", serialNumber);
  return true;
}

bool USBIdentityConfig::reset() {
  Preferences preferences;
  if (!preferences.begin(kNamespace, false)) return false;
  const bool ok = preferences.clear();
  preferences.end();
  if (ok) loadDefaults();
  return ok;
}
#endif
