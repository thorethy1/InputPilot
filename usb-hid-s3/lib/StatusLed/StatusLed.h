#ifndef STATUS_LED_H
#define STATUS_LED_H

#include <Arduino.h>

/**
 * Onboard WS2812 status LED (Waveshare ESP32-S3 Mini/Zero, GPIO21).
 *
 * Transport-neutral priority (highest first):
 *   1) OTA active             → amber, fast blink
 *   2) Fallback AP active     → magenta, slow blink
 *   3) Keep Awake active      → cyan, breathing pulse
 *   4) Secure controller      → blue, solid
 *   5) BLE/Wi-Fi ready        → green, dim solid
 *   6) No control radio ready → red, slow blink
 */

class StatusLed {
public:
  void begin();
  // Call from loop(); reads radio/jiggle state and drives the LED.
  void loop();

private:
  void show(uint8_t r, uint8_t g, uint8_t b);
  void off();

  uint8_t lastR_ = 255, lastG_ = 255, lastB_ = 255;
};

extern StatusLed g_statusLed;

#endif  // STATUS_LED_H
