#ifndef USB_IDENTITY_CONFIG_H
#define USB_IDENTITY_CONFIG_H

#include <stddef.h>
#include <stdint.h>

constexpr size_t USB_PRODUCT_NAME_MAX = 31;
constexpr size_t USB_SERIAL_NUMBER_MAX = 31;

bool usbProductNameValid(const char *value);
bool usbSerialNumberValid(const char *value);
bool usbVidPidValid(uint32_t value);

#ifndef UNIT_TEST
struct USBIdentityValues {
  uint16_t vid;
  uint16_t pid;
  char productName[USB_PRODUCT_NAME_MAX + 1];
  char serialNumber[USB_SERIAL_NUMBER_MAX + 1];
};

class USBIdentityConfig {
public:
  static void begin(const char *defaultSerialNumber);
  static const USBIdentityValues &get();
  static bool save(const char *productName, uint32_t vid, uint32_t pid,
                   const char *serialNumber);
  static bool reset();
};
#endif

#endif
