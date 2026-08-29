#ifndef WIFI_CONFIG_SERVER_H
#define WIFI_CONFIG_SERVER_H

// Discovery-only HTTP endpoint. Sensitive setup, control, diagnostics,
// management and OTA are exclusively carried by Secure Protocol v2 on TCP or
// BLE. Keeping this server deliberately read-only makes plaintext fallback
// impossible.
class WifiConfigServer {
public:
  void begin();
  void stop();
  void loop();
  bool isRunning() const { return running_; }

private:
  void handleRoot();
  void handleStatus();
  bool running_ = false;
};

extern WifiConfigServer g_wifiConfig;

#endif
