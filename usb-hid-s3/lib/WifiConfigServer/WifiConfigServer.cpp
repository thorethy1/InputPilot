#include "WifiConfigServer.h"

#include <WebServer.h>

#include "Config.h"
#include "DeviceIdentity.h"
#include "Logging.h"

WifiConfigServer g_wifiConfig;

namespace {
WebServer *s_server = nullptr;

String statusJson() {
  DeviceIdentity::begin();
  String json = "{\"product\":\"InputPilot\",\"board\":\"" +
                String(FW_BOARD) + "\",\"name\":\"" +
                String(DeviceIdentity::deviceName()) + "\",\"version\":\"" +
                String(FW_VERSION) + "\",\"device_id\":\"" +
                String(DeviceIdentity::deviceId()) + "\",\"protocol_version\":2,";
  json += "\"ota_schema\":" + String(OTA_SCHEMA_VERSION) + ",";
  json += "\"secure_port\":" + String(WIFI_CONTROL_PORT) + ",";
  json += "\"trust_required\":";
  json += "true";
  json += ",\"capabilities\":[\"secure_protocol_v2\",\"ble_transport\",";
  json += "\"wifi_transport\",\"secure_wifi_setup\",\"multiple_wifi\",\"secure_usb_identity\",";
  json += "\"secure_ota\",\"secure_diagnostics\",\"mouse_move\",";
  json += "\"mouse_click\",\"mouse_button_state\",\"mouse_scroll\",";
  json += "\"keyboard_type\",\"keyboard_key\",\"keyboard_layout\",\"release_all\"]}";
  return json;
}
}

void WifiConfigServer::handleRoot() {
  s_server->send(200, "application/json", statusJson());
}

void WifiConfigServer::handleStatus() {
  s_server->send(200, "application/json", statusJson());
}

void WifiConfigServer::begin() {
  if (running_) return;
  if (!s_server) s_server = new WebServer(WIFI_HTTP_PORT);
  s_server->on("/", HTTP_GET, [this]() { handleRoot(); });
  s_server->on("/api/status", HTTP_GET, [this]() { handleStatus(); });
  s_server->onNotFound([]() {
    s_server->send(404, "application/json",
                   "{\"error\":\"discovery_only\",\"secure_port\":3333}");
  });
  s_server->begin();
  running_ = true;
  LOG_WIFI("discovery HTTP listening on :%d; secure protocol on :%d",
           WIFI_HTTP_PORT, WIFI_CONTROL_PORT);
}

void WifiConfigServer::stop() {
  if (!running_) return;
  if (s_server) s_server->stop();
  running_ = false;
}

void WifiConfigServer::loop() {
  if (running_ && s_server) s_server->handleClient();
}
