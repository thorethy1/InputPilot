#include "StatusLed.h"

#include <WiFi.h>
#include "esp32-hal-rgb-led.h"

#include "CommandSink.h"
#include "Config.h"
#include "RadioManager.h"
#include "StatusLedPolicy.h"

StatusLed g_statusLed;

void StatusLed::begin() {
  off();
}

void StatusLed::off() { show(0, 0, 0); }

void StatusLed::show(uint8_t r, uint8_t g, uint8_t b) {
  if (r == lastR_ && g == lastG_ && b == lastB_) return;
  lastR_ = r;
  lastG_ = g;
  lastB_ = b;
  // Waveshare ESP32-S3-Zero/Mini onboard WS2812 uses GRB channel order.
  // Keep logical r/g/b values here and let the driver reorder them for the LED.
  rgbLedWriteOrdered(STATUS_LED_PIN, LED_COLOR_ORDER_GRB, r, g, b);
}

void StatusLed::loop() {
  const uint8_t peak = STATUS_LED_BRIGHTNESS;
  const uint32_t now = millis();
  const bool stationReady = g_radio.wifiEnabled() && !g_radio.isSoftAp() &&
                            WiFi.status() == WL_CONNECTED;
  const bool bluetoothReady = g_radio.bleEnabled() &&
                              (g_radio.isBleAdvertising() ||
                               g_radio.isBleConnected());
  const StatusLedPolicy::State state = StatusLedPolicy::resolve({
      deviceOtaActive(),
      g_radio.wifiEnabled() && g_radio.isSoftAp(),
      deviceJiggleEnabled() || deviceAutoClickEnabled(),
      g_radio.isControlSessionConnected(),
      stationReady || bluetoothReady,
  });

  switch (state) {
    case StatusLedPolicy::State::Ota: {
      const bool on = ((now / 180) % 2) == 0;
      if (on) show(peak, peak / 3, 0);
      else off();
      return;
    }
    case StatusLedPolicy::State::FallbackAp: {
      const bool on = ((now / 500) % 2) == 0;
      if (on) show(peak, 0, peak);
      else off();
      return;
    }
    case StatusLedPolicy::State::KeepAwake: {
      // Quantize to 40 frames/s. This remains visually smooth while avoiding
      // needless WS2812 writes in the radio/HID loop.
      const uint32_t period = 1200;
      const uint32_t t = ((now / 25) * 25) % period;
      const uint32_t half = period / 2;
      const uint8_t floor = peak / 8;
      const uint8_t span = peak - floor;
      const uint8_t level = t < half
          ? static_cast<uint8_t>(floor + (t * span) / half)
          : static_cast<uint8_t>(floor + ((period - t) * span) / half);
      show(0, level, level);
      return;
    }
    case StatusLedPolicy::State::ControllerConnected:
      show(0, peak / 3, peak);
      return;
    case StatusLedPolicy::State::Ready: {
      const uint8_t dim = peak / 3;
      show(0, dim > 0 ? dim : 1, 0);
      return;
    }
    case StatusLedPolicy::State::Unavailable: {
      const bool on = ((now / 750) % 2) == 0;
      if (on) show(peak, 0, 0);
      else off();
      return;
    }
  }
}
