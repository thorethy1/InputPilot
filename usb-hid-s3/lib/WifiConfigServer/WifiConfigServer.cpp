#include "WifiConfigServer.h"

#include <cctype>
#include <WebServer.h>
#include <WiFi.h>

#include "CommandSink.h"
#include "Config.h"
#include "ControlAuth.h"
#include "DeviceIdentity.h"
#include "Logging.h"
#include "FirmwareLog.h"
#include "OTAEngine.h"
#include "USBIdentityConfig.h"
#include <esp_ota_ops.h>
#include "WifiCredentials.h"

WifiConfigServer g_wifiConfig;

namespace {

WebServer *s_server = nullptr;

String jsonEscape(const String &in) {
  String out;
  out.reserve(in.length() + 8);
  for (size_t i = 0; i < in.length(); i++) {
    char c = in[i];
    if (c == '"' || c == '\\') {
      out += '\\';
      out += c;
    } else if (c == '\n') {
      out += "\\n";
    } else if (c == '\r') {
      out += "\\r";
    } else {
      out += c;
    }
  }
  return out;
}

bool jsonGetString(const String &body, const char *key, String &out) {
  String needle = String("\"") + key + "\"";
  int k = body.indexOf(needle);
  if (k < 0) return false;
  int colon = body.indexOf(':', k + needle.length());
  if (colon < 0) return false;
  int q1 = body.indexOf('"', colon + 1);
  if (q1 < 0) return false;
  String val;
  for (int i = q1 + 1; i < (int)body.length(); i++) {
    char c = body[i];
    if (c == '\\' && i + 1 < (int)body.length()) {
      val += body[i + 1];
      i++;
      continue;
    }
    if (c == '"') {
      out = val;
      return true;
    }
    val += c;
  }
  return false;
}

bool jsonGetInt(const String &body, const char *key, int &out) {
  String needle = String("\"") + key + "\"";
  int k = body.indexOf(needle);
  if (k < 0) return false;
  int colon = body.indexOf(':', k + needle.length());
  if (colon < 0) return false;
  int i = colon + 1;
  while (i < (int)body.length() && isspace((unsigned char)body[i])) i++;
  if (i >= (int)body.length()) return false;
  bool neg = false;
  if (body[i] == '-') {
    neg = true;
    i++;
  } else if (body[i] == '+') {
    i++;
  }
  if (i >= (int)body.length() || !isdigit((unsigned char)body[i])) return false;
  long v = 0;
  while (i < (int)body.length() && isdigit((unsigned char)body[i])) {
    v = v * 10 + (body[i] - '0');
    i++;
  }
  out = (int)(neg ? -v : v);
  return true;
}

bool jsonGetBool(const String &body, const char *key, bool &out) {
  String needle = String("\"") + key + "\"";
  int k = body.indexOf(needle);
  if (k < 0) return false;
  int colon = body.indexOf(':', k + needle.length());
  if (colon < 0) return false;
  String rest = body.substring(colon + 1);
  rest.trim();
  if (rest.startsWith("true")) {
    out = true;
    return true;
  }
  if (rest.startsWith("false")) {
    out = false;
    return true;
  }
  // Also accept 1/0
  if (rest.length() && (rest[0] == '1' || rest[0] == '0')) {
    out = rest[0] == '1';
    return true;
  }
  return false;
}

String bodyOrEmpty() {
  if (!s_server || !s_server->hasArg("plain")) return String();
  return s_server->arg("plain");
}

}  // namespace

void WifiConfigServer::handleCors() {
  if (!s_server) return;
  s_server->sendHeader("Access-Control-Allow-Origin", "*");
  s_server->sendHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  s_server->sendHeader("Access-Control-Allow-Headers",
                       "Content-Type, X-API-Token, Authorization");
}

bool WifiConfigServer::isSoftApProvisioning() const {
  const bool ap = WiFi.getMode() & WIFI_AP;
  const bool staUp = (WiFi.getMode() & WIFI_STA) && (WiFi.status() == WL_CONNECTED);
  return ap && !staUp;
}

bool WifiConfigServer::requireApiAuth() {
  if (!controlAuthRequired()) return true;
  if (!s_server) return false;

  String token;
  if (s_server->hasHeader("X-API-Token")) {
    token = s_server->header("X-API-Token");
  } else if (s_server->hasHeader("Authorization")) {
    String auth = s_server->header("Authorization");
    if (auth.startsWith("Bearer ") || auth.startsWith("bearer ")) {
      token = auth.substring(7);
      token.trim();
    }
  }
  if (controlTokenMatches(token.c_str())) return true;
  sendErr(401, "unauthorized");
  return false;
}

void WifiConfigServer::handleOptions() {
  handleCors();
  s_server->send(204);
}

void WifiConfigServer::sendOk(const String &extraJson) {
  handleCors();
  String json = "{\"ok\":true";
  if (extraJson.length()) {
    json += ",";
    json += extraJson;
  }
  json += "}";
  s_server->send(200, "application/json", json);
}

void WifiConfigServer::sendErr(int code, const char *error) {
  handleCors();
  s_server->send(code, "application/json",
                 String("{\"ok\":false,\"error\":\"") + error + "\"}");
}

void WifiConfigServer::handleRoot() {
  handleCors();
  const bool ap = WiFi.getMode() & WIFI_AP;
  if (ap && !(WiFi.getMode() & WIFI_STA && WiFi.status() == WL_CONNECTED)) {
    static const char kPage[] PROGMEM = R"HTML(
<!DOCTYPE html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
<title>InputPilot WiFi setup</title>
<style>
body{font-family:system-ui,sans-serif;max-width:28rem;margin:2rem auto;padding:0 1rem}
label{display:block;margin-top:1rem}input{width:100%;padding:.5rem;box-sizing:border-box}
button{margin-top:1.25rem;padding:.6rem 1rem;width:100%}
#msg{margin-top:1rem;white-space:pre-wrap}
</style></head><body>
<h1>InputPilot</h1><p>Configure WiFi (2.4 GHz).</p>
<label>SSID <input id="ssid" autocomplete="off"></label>
<label>Password <input id="pass" type="password"></label>
<button id="save">Save &amp; connect</button>
<pre id="msg"></pre>
<script>
async function save(){
  const msg=document.getElementById('msg');
  msg.textContent='Saving...';
  try{
    const r=await fetch('/api/wifi',{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({ssid:document.getElementById('ssid').value,
                           password:document.getElementById('pass').value})});
    msg.textContent=(await r.text());
  }catch(e){msg.textContent=String(e)}
}
document.getElementById('save').onclick=save;
</script></body></html>
)HTML";
    s_server->send_P(200, "text/html", kPage);
    return;
  }
  // STA: compact API index
  String json = "{";
  json += "\"name\":\"" + String(FW_NAME) + "\",";
  json += "\"version\":\"" + String(FW_VERSION) + "\",";
  json += "\"endpoints\":[";
  json += "\"GET /api/status\",\"GET /api/diagnostics\",\"GET /api/logs\",\"GET /api/jiggle\",\"POST /api/jiggle\",\"GET /api/keep-awake\",\"POST /api/keep-awake\",";
  json += "\"POST /api/move\",\"POST /api/type\",\"POST /api/key\",\"POST /api/click\",";
  json += "\"GET /api/wifi\",\"POST /api/wifi\",\"GET /api/usb\",\"POST /api/usb\",\"POST /api/ota/start\",\"POST /api/ota/firmware\",\"GET /api/ota/status\",\"POST /api/ota/abort\"";
  json += "]}";
  s_server->send(200, "application/json", json);
}

void WifiConfigServer::handleGetWifi() {
  if (!isSoftApProvisioning() && !requireApiAuth()) return;
  handleCors();
  WifiCreds c = WifiCredentials::get();
  const bool ap = WiFi.getMode() & WIFI_AP;
  const bool sta = WiFi.getMode() & WIFI_STA;
  String json = "{";
  json += "\"mode\":\"";
  if (ap && sta) json += "ap+sta";
  else if (ap) json += "ap";
  else if (sta) json += "sta";
  else json += "off";
  json += "\",";
  json += "\"configured\":";
  json += WifiCredentials::hasSsid() ? "true" : "false";
  json += ",";
  json += "\"ssid\":\"" + jsonEscape(c.ssid) + "\",";
  DeviceIdentity::begin();
  json += "\"ap_ssid\":\"" + jsonEscape(String(DeviceIdentity::softApSsid())) + "\",";
  json += "\"ap_ip\":\"" + WiFi.softAPIP().toString() + "\",";
  json += "\"sta_ip\":\"";
  json += (WiFi.status() == WL_CONNECTED) ? WiFi.localIP().toString() : "";
  json += "\",";
  json += "\"device_id\":\"" + String(DeviceIdentity::deviceId()) + "\",";
  json += "\"http_port\":";
  json += String(WIFI_HTTP_PORT);
  json += ",";
  json += "\"control_port\":";
  json += String(WIFI_CONTROL_PORT);
  json += ",";
  json += "\"auth_required\":";
  json += controlAuthRequired() ? "true" : "false";
  json += ",\"protocol_version\":1,\"ota_schema\":1,";
  json += "\"capabilities\":[\"mouse_move\",\"mouse_click\",\"mouse_button_state\",\"mouse_scroll\",";
  json += "\"keyboard_type\",\"keyboard_key\",\"keyboard_layout\",\"release_all\",\"ble_control\",";
  json += "\"tcp_control\",\"rest_control\",\"wifi_control\",\"ble_ota\",\"wifi_ota\",\"ble_diagnostics\",\"wifi_diagnostics\",\"usb_identity\",\"protocol_v1\"]";
  json += "}";
  s_server->send(200, "application/json", json);
}

void WifiConfigServer::handlePostWifi() {
  if (deviceOtaActive()) { sendErr(409, "firmware update in progress"); return; }
  // Soft-AP setup stays open so a phone can provision WiFi without a token.
  if (!isSoftApProvisioning() && !requireApiAuth()) return;
  const String body = bodyOrEmpty();
  if (!body.length()) {
    sendErr(400, "body required");
    return;
  }
  String ssid, pass;
  if (!jsonGetString(body, "ssid", ssid) || ssid.length() == 0) {
    sendErr(400, "ssid required");
    return;
  }
  if (!jsonGetString(body, "password", pass)) {
    jsonGetString(body, "pass", pass);
  }
  if (!WifiCredentials::save(ssid, pass)) {
    sendErr(500, "nvs save failed");
    return;
  }
  reconnectPending_ = true;
  LOG_WIFI("REST: credentials saved; reconnect pending");
  sendOk("\"reconnecting\":true,\"ssid\":\"" + jsonEscape(ssid) + "\"");
}

void WifiConfigServer::handleClearWifi() {
  if (deviceOtaActive()) { sendErr(409, "firmware update in progress"); return; }
  if (!requireApiAuth()) return;
  WifiCredentials::clear();
  reconnectPending_ = true;
  sendOk("\"cleared\":true,\"reconnecting\":true");
}

void WifiConfigServer::handleGetStatus() {
  if (!requireApiAuth()) return;
  handleCors();
  DeviceIdentity::begin();
  String json = "{";
  json += "\"ok\":true,";
  json += "\"name\":\"" + String(FW_NAME) + "\",";
  json += "\"version\":\"" + String(FW_VERSION) + "\",";
  json += "\"device_id\":\"" + String(DeviceIdentity::deviceId()) + "\",";
  json += "\"uptime_s\":";
  json += String(millis() / 1000);
  json += ",";
  json += "\"heap\":";
  json += String(ESP.getFreeHeap());
  json += ",";
  json += "\"usb\":\"";
  json += deviceHidReady() ? "ready" : "not-ready";
  json += "\",";
  json += "\"jiggle\":";
  json += deviceJiggleEnabled() ? "true" : "false";
  json += ",";
  json += "\"jiggle_interval_ms\":";
  json += String(deviceJiggleIntervalMs());
  json += ",";
  json += "\"click_enabled\":";
  json += deviceAutoClickEnabled() ? "true" : "false";
  json += ",\"click_interval_ms\":";
  json += String(deviceAutoClickIntervalMs());
  json += ",";
  json += "\"sta_ip\":\"";
  json += (WiFi.status() == WL_CONNECTED) ? WiFi.localIP().toString() : "";
  json += "\",";
  json += "\"mdns\":\"";
  json += String(DeviceIdentity::mdnsFqdn());
  json += "\",";
  json += "\"auth_required\":";
  json += controlAuthRequired() ? "true" : "false";
  json += ",\"protocol_version\":1,\"ota_schema\":1,";
  json += "\"capabilities\":[\"mouse_move\",\"mouse_click\",\"mouse_button_state\",\"mouse_scroll\",";
  json += "\"keyboard_type\",\"keyboard_key\",\"keyboard_layout\",\"release_all\",\"ble_control\",";
  json += "\"tcp_control\",\"rest_control\",\"wifi_control\",\"keep_awake_v2\",\"pairing_input_test\",\"ble_ota\",\"wifi_ota\",\"ble_diagnostics\",\"wifi_diagnostics\",\"usb_identity\",\"protocol_v1\"]";
  json += "}";
  s_server->send(200, "application/json", json);
}

void WifiConfigServer::handleGetUsb() {
  if (!requireApiAuth()) return;
  handleCors();
  const USBIdentityValues &identity = USBIdentityConfig::get();
  char vid[7], pid[7];
  snprintf(vid, sizeof(vid), "0x%04X", identity.vid);
  snprintf(pid, sizeof(pid), "0x%04X", identity.pid);
  String json = "{\"product_name\":\"" + jsonEscape(identity.productName) +
                "\",\"vid\":" + String(identity.vid) +
                ",\"pid\":" + String(identity.pid) +
                ",\"vid_hex\":\"" + String(vid) +
                "\",\"pid_hex\":\"" + String(pid) +
                "\",\"serial_number\":\"" + jsonEscape(identity.serialNumber) +
                "\",\"requires_restart\":true}";
  s_server->send(200, "application/json", json);
}

void WifiConfigServer::handlePostUsb() {
  if (deviceOtaActive()) { sendErr(409, "firmware update in progress"); return; }
  if (!requireApiAuth()) return;
  const String body = bodyOrEmpty();
  bool reset = false;
  if (jsonGetBool(body, "reset", reset) && reset) {
    if (!USBIdentityConfig::reset()) { sendErr(500, "nvs save failed"); return; }
    sendOk("\"rebooting\":true,\"defaults_restored\":true");
    configRebootAtMs_ = millis() + 1200;
    return;
  }
  String product, serial;
  int vid = 0, pid = 0;
  if (!jsonGetString(body, "product_name", product) ||
      !jsonGetString(body, "serial_number", serial) ||
      !jsonGetInt(body, "vid", vid) || !jsonGetInt(body, "pid", pid)) {
    sendErr(400, "product_name, vid, pid and serial_number required");
    return;
  }
  if (!USBIdentityConfig::save(product.c_str(), static_cast<uint32_t>(vid),
                               static_cast<uint32_t>(pid), serial.c_str())) {
    sendErr(400, "invalid usb identity");
    return;
  }
  sendOk("\"rebooting\":true");
  configRebootAtMs_ = millis() + 1200;
}

void WifiConfigServer::handleGetLogs() {
  if (!requireApiAuth()) return;
  handleCors();
  String json = "{\"entries\":[";
  bool first = true;
  uint32_t cursor = 0;
  FirmwareLogEntry entries[4];
  while (true) {
    const size_t count = firmwareLogCopySince(cursor, entries, 4);
    if (!count) break;
    for (size_t i = 0; i < count; ++i) {
      if (!first) json += ',';
      first = false;
      json += "{\"sequence\":";
      json += String(entries[i].sequence);
      json += ",\"line\":\"";
      json += jsonEscape(String(entries[i].line));
      json += "\"}";
      cursor = entries[i].sequence;
    }
  }
  json += "],\"latestSequence\":";
  json += String(firmwareLogLatestSequence());
  json += '}';
  s_server->send(200, "application/json", json);
}

void WifiConfigServer::handleGetDiagnostics() {
  if (!requireApiAuth()) return;
  const esp_partition_t *running = esp_ota_get_running_partition();
  const esp_partition_t *boot = esp_ota_get_boot_partition();
  DeviceIdentity::begin(); handleCors();
  const HIDDiagnosticsSnapshot hid = deviceHidDiagnostics();
  String json = "{\"product\":\"" + String(FW_PRODUCT) + "\",\"board\":\"" + String(FW_BOARD) +
                "\",\"deviceId\":\"" + String(DeviceIdentity::deviceId()) + "\",\"firmware\":\"" + String(FW_VERSION) +
                "\",\"protocol\":" + String(OTA_PROTOCOL_VERSION) + ",\"otaSchema\":" + String(OTA_SCHEMA_VERSION) +
                ",\"runningPartition\":\"" + String(running ? running->label : "unknown") +
                "\",\"bootPartition\":\"" + String(boot ? boot->label : "unknown") +
                "\",\"firmwareCommit\":\"" + String(FW_GIT_COMMIT) + "\",\"resetReason\":\"" + String(deviceResetReason()) +
                "\",\"uptime\":" + String(millis()) + ",\"heap\":" + String(ESP.getFreeHeap()) +
                ",\"usbReady\":" + String(deviceHidReady() ? "true" : "false") +
                ",\"otaState\":\"" + String(OTAProtocol::stateName(g_otaEngine.state())) + "\",\"hid\":{" +
                "\"rxBle\":" + String(hid.rxBle) + ",\"rxTcp\":" + String(hid.rxTcp) + ",\"rxRest\":" + String(hid.rxRest) +
                ",\"rxSerial\":" + String(hid.rxSerial) + ",\"decoded\":" + String(hid.decoded) +
                ",\"decodeErrors\":" + String(hid.decodeErrors) + ",\"queued\":" + String(hid.queued) +
                ",\"queueRejected\":" + String(hid.queueRejected) + ",\"executed\":" + String(hid.executed) +
                ",\"failed\":" + String(hid.executeFailed) + ",\"mouseExecuted\":" + String(hid.mouseExecuted) +
                ",\"keyboardExecuted\":" + String(hid.keyboardExecuted) +
                ",\"usbReportsAttempted\":" + String(hid.usbReportsAttempted) +
                ",\"usbReportsSucceeded\":" + String(hid.usbReportsSucceeded) +
                ",\"usbReportsFailed\":" + String(hid.usbReportsFailed) +
                ",\"lastSource\":\"" + String(hid.lastSource) +
                "\",\"lastType\":\"" + String(hid.lastType) + "\",\"lastSequence\":" + String(hid.lastSequence) +
                ",\"lastPhase\":\"" + String(hid.lastPhaseName) +
                "\",\"previousBreadcrumbValid\":" + String(hid.previousBreadcrumbValid ? "true" : "false") +
                ",\"previousSequence\":" + String(hid.previousSequence) +
                ",\"previousSource\":\"" + String(hid.previousSource) +
                "\",\"previousEventType\":" + String(hid.previousEventType) +
                ",\"previousPhase\":" + String(hid.previousPhase) +
                ",\"previousBleRxType\":" + String(hid.previousBleRxType) +
                ",\"previousBleRxLength\":" + String(hid.previousBleRxLength) +
                ",\"previousQueueDepth\":" + String(hid.previousQueueDepth) + "}}";
  s_server->send(200, "application/json", json);
}

void WifiConfigServer::handleOtaStart() {
  if (!requireApiAuth()) return;
  const String body = bodyOrEmpty(); int protocol = 0, size = 0; String version, sha;
  if (!jsonGetInt(body, "protocol", protocol) || !jsonGetInt(body, "size", size) ||
      !jsonGetString(body, "version", version) || !jsonGetString(body, "sha256", sha)) {
    sendErr(400, "invalid_metadata"); return;
  }
  OTAStartRequest request{static_cast<uint32_t>(protocol), static_cast<uint32_t>(size), version.c_str(), sha.c_str()};
  if (g_otaEngine.active()) { sendErr(409, "update_in_progress"); return; }
  if (!g_otaEngine.start(request, OTATransportOwner::WiFi)) {
    sendErr(strcmp(g_otaEngine.error(), "update_in_progress") == 0 ? 409 : 400, g_otaEngine.error()); return;
  }
  otaUploadComplete_ = false;
  otaLastActivityMs_ = millis();
  sendOk("\"state\":\"receiving\",\"offset\":0");
}

void WifiConfigServer::handleOtaStatus() {
  if (!requireApiAuth()) return;
  handleCors();
  const uint32_t total = g_otaEngine.total(), offset = g_otaEngine.received();
  String json = "{\"state\":\"" + String(OTAProtocol::stateName(g_otaEngine.state())) +
                "\",\"offset\":" + String(offset) + ",\"size\":" + String(total) +
                ",\"progress\":" + String(total ? (offset * 100ULL / total) : 0) +
                ",\"firmware\":\"" + String(FW_VERSION) + "\"";
  if (strlen(g_otaEngine.error())) json += ",\"error\":\"" + String(g_otaEngine.error()) + "\"";
  json += "}"; s_server->send(200, "application/json", json);
}

void WifiConfigServer::handleOtaAbort() {
  if (!requireApiAuth()) return;
  if (g_otaEngine.owner() != OTATransportOwner::WiFi || !g_otaEngine.active()) { sendErr(409, "not_receiving"); return; }
  g_otaEngine.abort("user_cancelled", true); sendOk("\"state\":\"cancelled\"");
}

void WifiConfigServer::handleOtaUpload() {
  HTTPUpload &upload = s_server->upload();
  if (upload.status == UPLOAD_FILE_START) {
    const bool authOk = requireApiAuth();
    otaUploadAuthorized_ = authOk && g_otaEngine.owner() == OTATransportOwner::WiFi && g_otaEngine.active() && upload.filename == "firmware.bin";
    otaUploadComplete_ = false;
    if (authOk && !otaUploadAuthorized_ && g_otaEngine.owner() == OTATransportOwner::WiFi) g_otaEngine.abort("invalid_upload");
  } else if (upload.status == UPLOAD_FILE_WRITE && otaUploadAuthorized_) {
    otaLastActivityMs_ = millis();
    if (!g_otaEngine.write(g_otaEngine.received(), upload.buf, upload.currentSize)) otaUploadAuthorized_ = false;
  } else if (upload.status == UPLOAD_FILE_END && otaUploadAuthorized_) {
    otaUploadComplete_ = g_otaEngine.finish();
    otaUploadAuthorized_ = false;
  } else if (upload.status == UPLOAD_FILE_ABORTED && g_otaEngine.owner() == OTATransportOwner::WiFi) {
    g_otaEngine.abort("upload_aborted"); otaUploadAuthorized_ = false;
  }
}

void WifiConfigServer::handleOtaUploadComplete() {
  if (!requireApiAuth()) return;
  if (!otaUploadComplete_) { sendErr(400, strlen(g_otaEngine.error()) ? g_otaEngine.error() : "upload_failed"); return; }
  sendOk("\"state\":\"rebooting\""); otaRebootAtMs_ = millis() + 1200;
}

void WifiConfigServer::handleGetJiggle() {
  if (!requireApiAuth()) return;
  handleCors();
  String json = "{";
  json += "\"ok\":true,";
  json += "\"enabled\":";
  json += deviceJiggleEnabled() ? "true" : "false";
  json += ",";
  json += "\"interval_ms\":";
  json += String(deviceJiggleIntervalMs());
  json += "}";
  s_server->send(200, "application/json", json);
}

void WifiConfigServer::handlePostJiggle() {
  if (!requireApiAuth()) return;
  const String body = bodyOrEmpty();
  bool enabled = false;
  bool have = jsonGetBool(body, "enabled", enabled);
  if (!have) {
    String onOff;
    if (jsonGetString(body, "state", onOff) || jsonGetString(body, "jiggle", onOff)) {
      onOff.toLowerCase();
      if (onOff == "on" || onOff == "true" || onOff == "1") {
        enabled = true;
        have = true;
      } else if (onOff == "off" || onOff == "false" || onOff == "0") {
        enabled = false;
        have = true;
      }
    }
  }
  if (!have) {
    sendErr(400, "enabled bool required");
    return;
  }
  handleCommandLine(enabled ? "jiggle on" : "jiggle off", "http");
  sendOk(String("\"enabled\":") + (enabled ? "true" : "false"));
}

void WifiConfigServer::handlePostMove() {
  if (!requireApiAuth()) return;
  const String body = bodyOrEmpty();
  int dx = 0, dy = 0, wheel = 0;
  if (!jsonGetInt(body, "dx", dx) || !jsonGetInt(body, "dy", dy)) {
    sendErr(400, "dx and dy required");
    return;
  }
  jsonGetInt(body, "wheel", wheel);
  String cmd = "move " + String(dx) + " " + String(dy);
  if (wheel != 0) cmd += " " + String(wheel);
  handleCommandLine(cmd.c_str(), "http");
  sendOk("\"dx\":" + String(dx) + ",\"dy\":" + String(dy) + ",\"wheel\":" + String(wheel));
}

void WifiConfigServer::handlePostType() {
  if (!requireApiAuth()) return;
  const String body = bodyOrEmpty();
  String text;
  if (!jsonGetString(body, "text", text) || text.length() == 0) {
    sendErr(400, "text required");
    return;
  }
  // Command line: "type <text>" — text may contain spaces.
  String cmd = "type " + text;
  handleCommandLine(cmd.c_str(), "http");
  sendOk("\"len\":" + String(text.length()));
}

void WifiConfigServer::handlePostKey() {
  if (!requireApiAuth()) return;
  const String body = bodyOrEmpty();
  String key;
  if (!jsonGetString(body, "key", key)) jsonGetString(body, "name", key);
  if (!key.length()) {
    sendErr(400, "key required");
    return;
  }
  handleCommandLine(("key " + key).c_str(), "http");
  sendOk("\"key\":\"" + jsonEscape(key) + "\"");
}

void WifiConfigServer::handlePostClick() {
  if (!requireApiAuth()) return;
  const String body = bodyOrEmpty();
  String button = "left";
  jsonGetString(body, "button", button);
  if (!button.length()) button = "left";
  handleCommandLine(("click " + button).c_str(), "http");
  sendOk("\"button\":\"" + jsonEscape(button) + "\"");
}

void WifiConfigServer::handleGetKeepAwake() {
  if (!requireApiAuth()) return;
  handleCors();
  String json = "{\"ok\":true,\"move_enabled\":";
  json += deviceJiggleEnabled() ? "true" : "false";
  json += ",\"move_interval_ms\":" + String(deviceJiggleIntervalMs());
  json += ",\"click_enabled\":";
  json += deviceAutoClickEnabled() ? "true" : "false";
  json += ",\"click_interval_ms\":" + String(deviceAutoClickIntervalMs()) + "}";
  s_server->send(200, "application/json", json);
}

void WifiConfigServer::handlePostKeepAwake() {
  if (!requireApiAuth()) return;
  const String body = bodyOrEmpty();
  bool moveEnabled = false, clickEnabled = false;
  int moveInterval = 0, clickInterval = 0;
  if (!jsonGetBool(body, "move_enabled", moveEnabled) ||
      !jsonGetBool(body, "click_enabled", clickEnabled) ||
      !jsonGetInt(body, "move_interval_ms", moveInterval) ||
      !jsonGetInt(body, "click_interval_ms", clickInterval) ||
      moveInterval < (int)KEEP_AWAKE_MIN_INTERVAL_MS ||
      moveInterval > (int)KEEP_AWAKE_MAX_INTERVAL_MS ||
      clickInterval < (int)KEEP_AWAKE_MIN_INTERVAL_MS ||
      clickInterval > (int)KEEP_AWAKE_MAX_INTERVAL_MS) {
    sendErr(400, "valid move/click settings required");
    return;
  }
  handleCommandLine(("jiggle interval " + String(moveInterval)).c_str(), "http");
  handleCommandLine(moveEnabled ? "jiggle on" : "jiggle off", "http");
  handleCommandLine(("autoclick interval " + String(clickInterval)).c_str(), "http");
  handleCommandLine(clickEnabled ? "autoclick on" : "autoclick off", "http");
  handleGetKeepAwake();
}

void WifiConfigServer::handlePostReport() {
  if (!requireApiAuth()) return;
  const String body = bodyOrEmpty();
  int modifier = 0, usage = 0;
  if (!jsonGetInt(body, "modifiers", modifier) || !jsonGetInt(body, "usage", usage) ||
      modifier < 0 || modifier > 255 || usage < 0 || usage > 255) {
    sendErr(400, "modifiers and usage bytes required");
    return;
  }
  handleCommandLine(("report " + String(modifier) + " " + String(usage)).c_str(), "http");
  sendOk("\"modifiers\":" + String(modifier) + ",\"usage\":" + String(usage));
}

void WifiConfigServer::handlePostButton() {
  if (!requireApiAuth()) return;
  const String body = bodyOrEmpty();
  String button, state;
  if (!jsonGetString(body, "button", button) ||
      !jsonGetString(body, "state", state)) {
    sendErr(400, "button and state required"); return;
  }
  button.toLowerCase(); state.toLowerCase();
  if ((button != "left" && button != "right" && button != "middle") ||
      (state != "down" && state != "up")) {
    sendErr(400, "invalid button or state"); return;
  }
  handleCommandLine(("button " + button + " " + state).c_str(), "http");
  sendOk("\"button\":\"" + jsonEscape(button) + "\",\"state\":\"" + state + "\"");
}

void WifiConfigServer::handlePostReleaseAll() {
  if (!requireApiAuth()) return;
  handleCommandLine("release all", "http");
  sendOk("\"released\":true");
}

void WifiConfigServer::begin() {
  if (running_) return;
  if (!s_server) s_server = new WebServer(WIFI_HTTP_PORT);

  static const char *kCollectHeaders[] = {"X-API-Token", "Authorization"};
  s_server->collectHeaders(kCollectHeaders, 2);

  s_server->on("/", HTTP_GET, [this]() { handleRoot(); });

  s_server->on("/api/wifi", HTTP_GET, [this]() { handleGetWifi(); });
  s_server->on("/api/wifi", HTTP_POST, [this]() { handlePostWifi(); });
  s_server->on("/api/wifi", HTTP_OPTIONS, [this]() { handleOptions(); });
  s_server->on("/api/wifi/clear", HTTP_POST, [this]() { handleClearWifi(); });
  s_server->on("/api/wifi/clear", HTTP_OPTIONS, [this]() { handleOptions(); });

  s_server->on("/api/usb", HTTP_GET, [this]() { handleGetUsb(); });
  s_server->on("/api/usb", HTTP_POST, [this]() { handlePostUsb(); });
  s_server->on("/api/usb", HTTP_OPTIONS, [this]() { handleOptions(); });

  s_server->on("/api/status", HTTP_GET, [this]() { handleGetStatus(); });
  s_server->on("/api/status", HTTP_OPTIONS, [this]() { handleOptions(); });
  s_server->on("/api/logs", HTTP_GET, [this]() { handleGetLogs(); });
  s_server->on("/api/logs", HTTP_OPTIONS, [this]() { handleOptions(); });
  s_server->on("/api/diagnostics", HTTP_GET, [this]() { handleGetDiagnostics(); });
  s_server->on("/api/diagnostics", HTTP_OPTIONS, [this]() { handleOptions(); });
  s_server->on("/api/ota/start", HTTP_POST, [this]() { handleOtaStart(); });
  s_server->on("/api/ota/status", HTTP_GET, [this]() { handleOtaStatus(); });
  s_server->on("/api/ota/abort", HTTP_POST, [this]() { handleOtaAbort(); });
  s_server->on("/api/ota/firmware", HTTP_POST, [this]() { handleOtaUploadComplete(); }, [this]() { handleOtaUpload(); });

  s_server->on("/api/jiggle", HTTP_GET, [this]() { handleGetJiggle(); });
  s_server->on("/api/jiggle", HTTP_POST, [this]() { handlePostJiggle(); });
  s_server->on("/api/jiggle", HTTP_OPTIONS, [this]() { handleOptions(); });
  s_server->on("/api/keep-awake", HTTP_GET, [this]() { handleGetKeepAwake(); });
  s_server->on("/api/keep-awake", HTTP_POST, [this]() { handlePostKeepAwake(); });
  s_server->on("/api/keep-awake", HTTP_OPTIONS, [this]() { handleOptions(); });

  s_server->on("/api/move", HTTP_POST, [this]() { handlePostMove(); });
  s_server->on("/api/move", HTTP_OPTIONS, [this]() { handleOptions(); });

  s_server->on("/api/type", HTTP_POST, [this]() { handlePostType(); });
  s_server->on("/api/type", HTTP_OPTIONS, [this]() { handleOptions(); });

  s_server->on("/api/key", HTTP_POST, [this]() { handlePostKey(); });
  s_server->on("/api/key", HTTP_OPTIONS, [this]() { handleOptions(); });
  s_server->on("/api/report", HTTP_POST, [this]() { handlePostReport(); });
  s_server->on("/api/report", HTTP_OPTIONS, [this]() { handleOptions(); });

  s_server->on("/api/click", HTTP_POST, [this]() { handlePostClick(); });
  s_server->on("/api/click", HTTP_OPTIONS, [this]() { handleOptions(); });
  s_server->on("/api/button", HTTP_POST, [this]() { handlePostButton(); });
  s_server->on("/api/button", HTTP_OPTIONS, [this]() { handleOptions(); });
  s_server->on("/api/release-all", HTTP_POST, [this]() { handlePostReleaseAll(); });
  s_server->on("/api/release-all", HTTP_OPTIONS, [this]() { handleOptions(); });

  s_server->onNotFound([this]() {
    handleCors();
    s_server->send(404, "application/json", "{\"ok\":false,\"error\":\"not found\"}");
  });
  s_server->begin();
  running_ = true;
  LOG_WIFI("HTTP REST listening on :%d (wifi + control)", WIFI_HTTP_PORT);
}

void WifiConfigServer::stop() {
  if (!running_) return;
  if (s_server) s_server->stop();
  running_ = false;
  LOG_WIFI("HTTP REST stopped");
}

void WifiConfigServer::loop() {
  if (running_ && s_server) s_server->handleClient();
  if (g_otaEngine.owner() == OTATransportOwner::WiFi && g_otaEngine.active() &&
      millis() - otaLastActivityMs_ > 30000) g_otaEngine.abort("timeout");
  if (otaRebootAtMs_ && static_cast<int32_t>(millis() - otaRebootAtMs_) >= 0) ESP.restart();
  if (configRebootAtMs_ && static_cast<int32_t>(millis() - configRebootAtMs_) >= 0) ESP.restart();
}

bool WifiConfigServer::takeReconnectRequest() {
  if (!reconnectPending_) return false;
  reconnectPending_ = false;
  return true;
}

void WifiConfigServer::requestReconnect() {
  reconnectPending_ = true;
}
