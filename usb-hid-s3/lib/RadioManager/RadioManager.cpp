#include "RadioManager.h"

#include <WiFi.h>
#include <WiFiServer.h>
#include <WiFiClient.h>
#include <ESPmDNS.h>

#include <NimBLEDevice.h>

#include "Config.h"
#include "ControlAuth.h"
#include "CommandSink.h"
#include "DeviceIdentity.h"
#include "Logging.h"
#include "HIDProtocol.h"
#include "WifiCredentials.h"
#include "WifiConfigServer.h"
#include "BLEOTA.h"
#include "BLEDiagnostics.h"
#include "OTAEngine.h"

RadioManager g_radio;

// ---------------------------------------------------------------------------
// BLE (Nordic UART Service) control transport
// ---------------------------------------------------------------------------
namespace {

NimBLEServer *s_bleServer = nullptr;
NimBLECharacteristic *s_bleTx = nullptr;
volatile bool s_bleConnected = false;
// Set while stopBle() is releasing the stack so the disconnect callback does
// NOT restart advertising mid-teardown (which crashes deinit(true)).
volatile bool s_bleTearingDown = false;
bool s_bleReady = false;

bool s_bleAuthed = false;
bool s_tcpAuthed = false;
WiFiServer s_tcpServer(WIFI_CONTROL_PORT);
WiFiClient s_tcpClient;
std::string s_tcpLineBuf;

void sendControlReply(const char *source, const char *reply) {
  if (!reply) return;
  if (strcmp(source, "ble") == 0 && s_bleTx && s_bleConnected) {
    s_bleTx->setValue(reinterpret_cast<const uint8_t *>(reply), strlen(reply));
    s_bleTx->notify();
  } else if (strcmp(source, "wifi") == 0 && s_tcpClient && s_tcpClient.connected()) {
    s_tcpClient.print(reply);
    s_tcpClient.print("\n");
  }
}

void dispatchControlLine(const std::string &line, const char *source,
                         bool *authed) {
  const ControlLineGate gate = controlGateLine(line.c_str(), authed);
  if (gate == ControlLineGate::Reject) {
    LOG_INFO("control auth rejected src=%s", source);
    return;
  }
  if (gate == ControlLineGate::Consumed) {
    LOG_INFO("control auth %s src=%s", *authed ? "ok" : "failed", source);
    sendControlReply(source, controlAuthReply(gate, *authed));
    return;
  }
  handleCommandLine(line, source);
}

// Split incoming bytes into lines and dispatch each.
void feedControlLines(std::string &buf, const std::string &incoming,
                      const char *source, bool *authed) {
  buf += incoming;
  size_t nl;
  while ((nl = buf.find('\n')) != std::string::npos) {
    std::string line = buf.substr(0, nl);
    buf.erase(0, nl + 1);
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (!line.empty()) dispatchControlLine(line, source, authed);
  }
}

std::string s_bleLineBuf;

class RxCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic *c, NimBLEConnInfo &) override {
    std::string v = c->getValue();
    if (v.empty()) return;
    // BLE writes may or may not include a trailing newline; treat a write
    // without a newline as a complete line too.
    if (v.find('\n') == std::string::npos) {
      std::string line = v;
      if (!line.empty() && line.back() == '\r') line.pop_back();
      dispatchControlLine(line, "ble", &s_bleAuthed);
    } else {
      feedControlLines(s_bleLineBuf, v, "ble", &s_bleAuthed);
    }
  }
};

class BinaryCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic *c, NimBLEConnInfo &) override {
    const std::string value = c->getValue();
    if (value.empty()) return;
    // Authentication is performed once through the backwards-compatible text
    // control characteristic before binary event characteristics are accepted.
    if (!s_bleAuthed) {
      LOG_INFO("binary control rejected: BLE session not authenticated");
      return;
    }
    HIDMessage message;
    std::string error;
    if (!HIDProtocol::decode(reinterpret_cast<const uint8_t *>(value.data()),
                             value.size(), message, error)) {
      LOG_WARN("binary control rejected: %s", error.c_str());
      return;
    }
    const std::string command = HIDProtocol::command(message);
    if (!command.empty()) handleCommandLine(command, "ble-binary");
    else if (message.type == HIDMessageType::Ping && s_bleTx) {
      const uint8_t pong[] = {HIDProtocol::Version, 0x7f};
      s_bleTx->setValue(pong, sizeof(pong));
      s_bleTx->notify();
    }
  }
};

class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer *, NimBLEConnInfo &) override {
    s_bleConnected = true;
    s_bleAuthed = !controlAuthRequired();
    LOG_BLE("central connected");
  }
  void onDisconnect(NimBLEServer *, NimBLEConnInfo &, int reason) override {
    s_bleConnected = false;
    s_bleAuthed = false;
    g_bleOta.disconnected();
    g_bleDiagnostics.disconnected();
    deviceReleaseAll();
    if (s_bleTearingDown) {
      LOG_BLE("central disconnected reason=%d during teardown", reason);
      return;
    }
    LOG_BLE("central disconnected reason=%d; re-advertising", reason);
    NimBLEAdvertising *adv = NimBLEDevice::getAdvertising();
    if (!s_bleReady || !adv || !adv->start() || !adv->isAdvertising()) {
      g_radio.setBleAdvertisingStatus(false);
      LOG_BLE("advertising restart failed");
      return;
    }
    g_radio.setBleAdvertisingStatus(true);
    LOG_BLE("advertising restarted");
  }
};

RxCallbacks s_rxCallbacks;
BinaryCallbacks s_binaryCallbacks;
ServerCallbacks s_serverCallbacks;

}  // namespace

bool deviceBleAuthenticated() { return s_bleConnected && s_bleAuthed; }

// ---------------------------------------------------------------------------
void RadioManager::begin(RadioMode initial) {
  mode_ = RadioMode::None;
  snprintf(status_, sizeof(status_), "none");
  if (initial != RadioMode::None) setMode(initial);
}

bool RadioManager::setMode(RadioMode m) {
  if (m == mode_) return true;
  if (g_otaEngine.active()) {
    LOG_WARN("radio mode change blocked during OTA");
    return false;
  }
  const bool hadWifi = wifiEnabled();
  const bool hadBle = bleEnabled();
  mode_ = m;
  const bool wantsWifi = wifiEnabled();
  const bool wantsBle = bleEnabled();
  if (hadWifi && !wantsWifi) stopWifi();
  if (hadBle && !wantsBle) stopBle();
  if (!hadWifi && wantsWifi) startWifi();
  if (!hadBle && wantsBle) startBle();
  if (!wantsWifi && !wantsBle) snprintf(status_, sizeof(status_), "none");
  LOG_RADIO("mode=%s status=%s", radioModeToString(mode_), status_);
  return true;
}

// ---------------------------------------------------------------------------
// WiFi (STA with NVS creds, or Soft-AP setup portal)
// ---------------------------------------------------------------------------
void RadioManager::startSoftAp() {
  softAp_ = true;
  DeviceIdentity::begin();
  WiFi.mode(WIFI_AP);
  const char *apSsid = DeviceIdentity::softApSsid();
  const bool openAp = (WIFI_AP_PASS[0] == '\0');
  bool ok = openAp
                ? WiFi.softAP(apSsid, nullptr, WIFI_AP_CHANNEL)
                : WiFi.softAP(apSsid, WIFI_AP_PASS, WIFI_AP_CHANNEL);
  if (!ok) {
    snprintf(status_, sizeof(status_), "wifi:ap-fail");
    LOG_WIFI("Soft-AP start failed");
    return;
  }
  delay(100);
  IPAddress ip = WiFi.softAPIP();
  snprintf(status_, sizeof(status_), "wifi:ap");
  LOG_WIFI("soft-ap ssid=\"%s\" ip=%s http=:%d (configure via REST /api/wifi)",
           apSsid, ip.toString().c_str(), WIFI_HTTP_PORT);
  g_wifiConfig.begin();
}

void RadioManager::startSta(const String &ssid, const String &pass) {
  softAp_ = false;
  WiFi.mode(WIFI_STA);
  WiFi.begin(ssid.c_str(), pass.c_str());
  LOG_WIFI("connecting to %s ...", ssid.c_str());
  uint32_t start = millis();
  while (WiFi.status() != WL_CONNECTED &&
         (millis() - start) < WIFI_CONNECT_TIMEOUT_MS) {
    delay(200);
  }
  if (WiFi.status() == WL_CONNECTED) {
    DeviceIdentity::begin();
    s_tcpServer.begin();
    s_tcpServer.setNoDelay(true);
    g_wifiConfig.begin();  // STA REST control API on :80
    const char *mdnsHost = DeviceIdentity::mdnsHostname();
    if (MDNS.begin(mdnsHost)) {
      MDNS.addService("http", "tcp", WIFI_HTTP_PORT);
      MDNS.addServiceTxt("http", "tcp", "path", "/api/status");
      MDNS.addServiceTxt("http", "tcp", "id", DeviceIdentity::deviceId());
      MDNS.addServiceTxt("http", "tcp", "fw", FW_VERSION);
      LOG_WIFI("mDNS started as %s (http :%d)", DeviceIdentity::mdnsFqdn(),
               WIFI_HTTP_PORT);
    } else {
      LOG_WIFI("mDNS start failed");
    }
    snprintf(status_, sizeof(status_), "wifi:%s", WiFi.localIP().toString().c_str());
    LOG_WIFI("connected ip=%s control-port=%d http=:%d mdns=%s",
             WiFi.localIP().toString().c_str(), WIFI_CONTROL_PORT, WIFI_HTTP_PORT,
             DeviceIdentity::mdnsFqdn());
  } else {
    LOG_WIFI("connect timeout; falling back to Soft-AP setup");
    WiFi.disconnect(true);
    startSoftAp();
  }
}

void RadioManager::startWifi() {
  WifiCreds c = WifiCredentials::get();
  if (c.ssid.length() == 0) {
    LOG_WIFI("no STA credentials in NVS; starting Soft-AP setup");
    startSoftAp();
    return;
  }
  startSta(c.ssid, c.pass);
}

void RadioManager::stopWifi() {
  MDNS.end();
  g_wifiConfig.stop();
  softAp_ = false;
  s_tcpClient.stop();
  s_tcpServer.stop();
  s_tcpLineBuf.clear();
  WiFi.softAPdisconnect(true);
  WiFi.disconnect(true);
  WiFi.mode(WIFI_OFF);
  LOG_WIFI("stopped");
}

void RadioManager::applyWifiCredentials() {
  if (!wifiEnabled()) {
    LOG_WIFI("credentials updated (will apply on next radio wifi)");
    return;
  }
  LOG_WIFI("applying credentials; restarting WiFi");
  stopWifi();
  startWifi();
  LOG_RADIO("mode=%s status=%s", radioModeToString(mode_), status_);
}

// ---------------------------------------------------------------------------
// BLE
// ---------------------------------------------------------------------------
void RadioManager::startBle() {
  // Build the GATT server exactly once and keep it for the whole session.
  // We never NimBLEDevice::deinit() (see stopBle), so on a re-select the stack
  // is already initialized and we only need to re-advertise.
  if (!NimBLEDevice::isInitialized()) {
    LOG_BLE("init start");
    if (!NimBLEDevice::init(BLE_DEVICE_NAME)) {
      snprintf(status_, sizeof(status_), "ble:init-failed");
      LOG_BLE("init failed");
      return;
    }
    LOG_BLE("initialized");
    s_bleServer = NimBLEDevice::createServer();
    if (!s_bleServer) {
      snprintf(status_, sizeof(status_), "ble:server-fail");
      LOG_BLE("server creation failed");
      return;
    }
    s_bleServer->setCallbacks(&s_serverCallbacks);
    LOG_BLE("server created");

    NimBLEService *svc = s_bleServer->createService(BLE_NUS_SERVICE_UUID);
    if (!svc) {
      snprintf(status_, sizeof(status_), "ble:service-fail");
      LOG_BLE("NUS service creation failed");
      return;
    }
    NimBLECharacteristic *rx = svc->createCharacteristic(
        BLE_NUS_RX_UUID, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
    s_bleTx = svc->createCharacteristic(BLE_NUS_TX_UUID, NIMBLE_PROPERTY::NOTIFY);
    if (!rx || !s_bleTx) {
      snprintf(status_, sizeof(status_), "ble:service-fail");
      LOG_BLE("NUS characteristic creation failed");
      return;
    }
    rx->setCallbacks(&s_rxCallbacks);
    LOG_BLE("NUS service created");

    NimBLEService *hidSvc = s_bleServer->createService(BLE_HID_SERVICE_UUID);
    if (!hidSvc) {
      snprintf(status_, sizeof(status_), "ble:service-fail");
      LOG_BLE("HID service creation failed");
      return;
    }
    for (const char *uuid : {BLE_HID_CONTROL_UUID, BLE_HID_MOUSE_UUID,
                             BLE_HID_KEYBOARD_UUID}) {
      NimBLECharacteristic *characteristic = hidSvc->createCharacteristic(
          uuid, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
      if (!characteristic) {
        snprintf(status_, sizeof(status_), "ble:service-fail");
        LOG_BLE("HID characteristic creation failed uuid=%s", uuid);
        return;
      }
      characteristic->setCallbacks(&s_binaryCallbacks);
    }
    NimBLECharacteristic *status = hidSvc->createCharacteristic(
        BLE_HID_STATUS_UUID, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);
    if (!status) {
      snprintf(status_, sizeof(status_), "ble:service-fail");
      LOG_BLE("HID status characteristic creation failed");
      return;
    }
    const uint8_t statusValue[] = {HIDProtocol::Version, 0x00};
    status->setValue(statusValue, sizeof(statusValue));

    LOG_BLE("HID service created");
    if (!g_bleOta.begin(s_bleServer)) {
      snprintf(status_, sizeof(status_), "ble:service-fail");
      LOG_BLE("OTA service creation failed");
      return;
    }
    LOG_BLE("OTA service created");
    if (!g_bleDiagnostics.begin(s_bleServer)) {
      snprintf(status_, sizeof(status_), "ble:service-fail");
      LOG_BLE("diagnostics service creation failed");
      return;
    }
    LOG_BLE("diagnostics service created");

    // NimBLE-Arduino 2.x registers all services together when the server is
    // started. NimBLEService::start() is a deprecated no-op in this version.
    if (!s_bleServer->start()) {
      snprintf(status_, sizeof(status_), "ble:service-fail");
      LOG_BLE("GATT server/service start failed");
      return;
    }
    LOG_BLE("GATT services started (NUS, HID, OTA, Diagnostics)");

    NimBLEAdvertising *adv = NimBLEDevice::getAdvertising();
    if (!adv) {
      snprintf(status_, sizeof(status_), "ble:adv-fail");
      LOG_BLE("advertising object unavailable");
      return;
    }
    const std::string identity = std::string("IP") + DeviceIdentity::deviceId();
    NimBLEAdvertisementData advData;
    NimBLEAdvertisementData scanData;
    const bool identityOk = advData.setFlags(BLE_HS_ADV_F_DISC_GEN |
                                              BLE_HS_ADV_F_BREDR_UNSUP) &&
                            advData.setManufacturerData(identity);
    const bool nameOk = scanData.setName(BLE_DEVICE_NAME);
    const bool payloadOk = identityOk && nameOk &&
                           adv->setAdvertisementData(advData) &&
                           adv->setScanResponseData(scanData);
    adv->enableScanResponse(true);
    LOG_BLE("advertising payload bytes=%u scan-response bytes=%u",
            static_cast<unsigned>(advData.getPayload().size()),
            static_cast<unsigned>(scanData.getPayload().size()));
    if (!payloadOk || advData.getDataLocation(BLE_HS_ADV_TYPE_MFG_DATA) < 0) {
      snprintf(status_, sizeof(status_), "ble:adv-fail");
      LOG_BLE("advertising configuration failed; manufacturer data missing");
      return;
    }
    LOG_BLE("manufacturer identity configured id=%s", DeviceIdentity::deviceId());
    s_bleReady = true;
  }
  s_bleTearingDown = false;
  NimBLEAdvertising *adv = NimBLEDevice::getAdvertising();
  if (!s_bleReady || !adv || !adv->start() || !adv->isAdvertising()) {
    snprintf(status_, sizeof(status_), "ble:adv-fail");
    LOG_BLE("advertising start failed");
    return;
  }

  snprintf(status_, sizeof(status_), "ble:adv");
  LOG_BLE("advertising started as '%s'", BLE_DEVICE_NAME);
}

void RadioManager::setBleAdvertisingStatus(bool active) {
  snprintf(status_, sizeof(status_), active ? "ble:adv" : "ble:adv-fail");
}

void RadioManager::stopBle() {
  // IMPORTANT: we do NOT call NimBLEDevice::deinit() here. On arduino-esp32
  // 3.2.1 / IDF 5.4, esp_bt_controller_deinit (reached via nimble_port_deinit)
  // crashes and reboots the S3 even after stopAdvertising with no clients
  // connected (NimBLE-Arduino #1008 - an upstream controller-deinit bug). So we
  // just quiesce the stack: stop advertising and drop any client, leaving the
  // controller initialized but idle. Re-selecting BLE re-advertises instantly.
  // Trade-off: once BLE has been used, its controller stays powered until
  // reboot (coexists fine with WiFi); the *control transport* is still
  // exclusive because advertising is off and clients are dropped.
  if (NimBLEDevice::isInitialized()) {
    s_bleTearingDown = true;  // stop onDisconnect from re-advertising
    NimBLEDevice::stopAdvertising();
    if (s_bleServer && s_bleServer->getConnectedCount() > 0) {
      for (uint16_t handle : s_bleServer->getPeerDevices()) {
        s_bleServer->disconnect(handle);
      }
      uint32_t start = millis();
      while (s_bleConnected && (millis() - start) < 1000) delay(10);
    }
  }
  s_bleConnected = false;
  s_bleAuthed = false;
  s_bleLineBuf.clear();
  LOG_BLE("stopped (advertising off; stack idle)");
}

// ---------------------------------------------------------------------------
void RadioManager::loop() {
  g_bleOta.loop();
  g_bleDiagnostics.loop(g_otaEngine.active());
  if (!wifiEnabled()) return;

  // Soft-AP HTTP portal / REST (also handles reconnect requests from POST).
  g_wifiConfig.loop();
  if (g_wifiConfig.takeReconnectRequest()) {
    // Defer slightly so the HTTP response can finish flushing.
    delay(200);
    applyWifiCredentials();
    return;
  }

  if (softAp_ || WiFi.status() != WL_CONNECTED) return;

  const bool hadTcpClient = s_tcpClient && s_tcpClient.connected();
  if (!hadTcpClient) {
    WiFiClient nc = s_tcpServer.accept();
    if (nc) {
      s_tcpClient = nc;
      s_tcpLineBuf.clear();
      s_tcpAuthed = !controlAuthRequired();
      LOG_WIFI("control client connected");
    }
  }
  if (s_tcpClient && s_tcpClient.connected()) {
    while (s_tcpClient.available()) {
      char ch = (char)s_tcpClient.read();
      if (ch == '\r') continue;
      if (ch == '\n') {
        if (!s_tcpLineBuf.empty()) {
          dispatchControlLine(s_tcpLineBuf, "wifi", &s_tcpAuthed);
        }
        s_tcpLineBuf.clear();
      } else if (s_tcpLineBuf.size() < 256) {
        s_tcpLineBuf.push_back(ch);
      }
    }
  } else {
    if (s_tcpAuthed) deviceReleaseAll();
    s_tcpAuthed = false;
  }
}

const char *RadioManager::statusStr() {
  if (mode_ == RadioMode::WifiBle) {
    if (softAp_) snprintf(status_, sizeof(status_), "wifi:ap+ble:%s", s_bleConnected ? "conn" : "adv");
    else if (WiFi.status() == WL_CONNECTED)
      snprintf(status_, sizeof(status_), "wifi:%s+ble:%s", WiFi.localIP().toString().c_str(),
               s_bleConnected ? "conn" : "adv");
  } else if (mode_ == RadioMode::Ble) {
    snprintf(status_, sizeof(status_), "ble:%s", s_bleConnected ? "conn" : "adv");
  } else if (mode_ == RadioMode::Wifi) {
    if (softAp_) {
      snprintf(status_, sizeof(status_), "wifi:ap");
    } else if (WiFi.status() == WL_CONNECTED) {
      snprintf(status_, sizeof(status_), "wifi:%s", WiFi.localIP().toString().c_str());
    }
  }
  return status_;
}

void RadioManager::sendToControl(const char *line) {
  if (bleEnabled() && s_bleTx && s_bleConnected) {
    s_bleTx->setValue((const uint8_t *)line, strlen(line));
    s_bleTx->notify();
  } else if (wifiEnabled() && s_tcpClient && s_tcpClient.connected()) {
    s_tcpClient.print(line);
    s_tcpClient.print("\n");
  }
}
