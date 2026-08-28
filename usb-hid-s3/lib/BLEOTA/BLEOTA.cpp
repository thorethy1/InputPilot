#include "BLEOTA.h"
#include "PairingSecretStore.h"
#include <cstring>
#include <esp_system.h>
#include "Config.h"
#include "DeviceIdentity.h"
#include "OTAEngine.h"
extern bool deviceBleAuthenticated();
BLEOTA g_bleOta;
class BLEOTA::ControlCallbacks : public NimBLECharacteristicCallbacks { public: explicit ControlCallbacks(BLEOTA &o):o_(o){} void onWrite(NimBLECharacteristic*c,NimBLEConnInfo&)override{o_.control(c->getValue());} private: BLEOTA&o_;};
class BLEOTA::DataCallbacks : public NimBLECharacteristicCallbacks { public: explicit DataCallbacks(BLEOTA &o):o_(o){} void onWrite(NimBLECharacteristic*c,NimBLEConnInfo&)override{o_.data(c->getValue());} private: BLEOTA&o_;};
bool BLEOTA::schemaAvailable(){return OTAEngine::schemaAvailable();}
OTAState BLEOTA::state()const{return g_otaEngine.state();}
bool BLEOTA::active()const{return g_otaEngine.owner()==OTATransportOwner::BLE&&g_otaEngine.active();}
bool BLEOTA::begin(NimBLEServer*server){if(!server)return false;auto*s=server->createService(BLE_OTA_SERVICE_UUID);if(!s)return false;auto*c=s->createCharacteristic(BLE_OTA_CONTROL_UUID,NIMBLE_PROPERTY::WRITE);auto*d=s->createCharacteristic(BLE_OTA_DATA_UUID,NIMBLE_PROPERTY::WRITE_NR);status_=s->createCharacteristic(BLE_OTA_STATUS_UUID,NIMBLE_PROPERTY::READ|NIMBLE_PROPERTY::NOTIFY);if(!c||!d||!status_)return false;c->setCallbacks(new ControlCallbacks(*this));d->setCallbacks(new DataCallbacks(*this));notify("IDLE");return true;}
void BLEOTA::notify(const char*event,const char*error){if(!status_)return;char json[980];if(strcmp(event,"IDLE")==0)snprintf(json,sizeof(json),"{\"product\":\"%s\",\"board\":\"%s\",\"deviceId\":\"%s\",\"deviceName\":\"%s\",\"protocol\":%u,\"otaSchema\":%u,\"firmware\":\"%s\",\"authRequired\":%s,\"capabilities\":[\"ble_control\",\"wifi_control\",\"keep_awake_v2\",\"pairing_input_test\",\"secure_pairing\",\"secure_channel_v1\",\"ble_ota\",\"wifi_ota\",\"ble_diagnostics\",\"wifi_diagnostics\",\"usb_identity\",\"mouse_move\",\"mouse_click\",\"mouse_button_state\",\"mouse_scroll\",\"keyboard_type\",\"keyboard_key\",\"keyboard_layout\",\"release_all\",\"protocol_v1\"],\"state\":\"idle\",\"event\":\"IDLE\",\"offset\":0,\"size\":0,\"maxChunk\":500,\"windowSize\":%lu}",FW_PRODUCT,FW_BOARD,DeviceIdentity::deviceId(),BLE_DEVICE_NAME,OTA_PROTOCOL_VERSION,OTA_SCHEMA_VERSION,FW_VERSION,(PairingSecretStore::hasSecret()||strlen(CONTROL_API_TOKEN))?"true":"false",(unsigned long)BLE_OTA_ACK_BYTES);else snprintf(json,sizeof(json),"{\"protocol\":%u,\"otaSchema\":%u,\"firmware\":\"%s\",\"state\":\"%s\",\"event\":\"%s\",\"offset\":%lu,\"size\":%lu,\"maxChunk\":500,\"windowSize\":%lu%s%s%s}",OTA_PROTOCOL_VERSION,OTA_SCHEMA_VERSION,FW_VERSION,OTAProtocol::stateName(g_otaEngine.state()),event,(unsigned long)g_otaEngine.received(),(unsigned long)g_otaEngine.total(),(unsigned long)BLE_OTA_ACK_BYTES,error?",\"error\":\"":"",error?error:"",error?"\"":"");status_->setValue((const uint8_t*)json,strlen(json));status_->notify();}
void BLEOTA::fail(const char*error){notify("ERROR",error);}
void BLEOTA::control(const std::string &value) {
  if (!deviceBleAuthenticated()) { fail("unauthorized"); return; }
  if (value == "ABORT") {
    if (active()) { g_otaEngine.abort("user_cancelled", true); notify("CANCELLED", "user_cancelled"); }
    return;
  }
  if (value == "FINISH") {
    if (g_otaEngine.owner() != OTATransportOwner::BLE) { fail("not_receiving"); return; }
    notify("VERIFYING");
    if (!g_otaEngine.finish()) { fail(g_otaEngine.error()); return; }
    notify("INSTALLING"); notify("SUCCESS"); notify("REBOOTING");
    rebootAtMs_ = millis() + 750; return;
  }
  OTAStartRequest request; std::string error;
  if (!OTAProtocol::parseStart(value, request, error)) { fail(error.c_str()); return; }
  if (g_otaEngine.active()) { fail("update_in_progress"); return; }
  if (!g_otaEngine.start(request, OTATransportOwner::BLE)) { fail(g_otaEngine.error()); return; }
  lastActivityMs_ = millis(); lastAck_ = 0; notify("READY");
}
void BLEOTA::data(const std::string&v){if(!deviceBleAuthenticated()){fail("unauthorized");return;}if(g_otaEngine.owner()!=OTATransportOwner::BLE||v.size()<=4){fail("not_receiving");return;}const uint8_t*b=(const uint8_t*)v.data();uint32_t o=uint32_t(b[0])|(uint32_t(b[1])<<8)|(uint32_t(b[2])<<16)|(uint32_t(b[3])<<24);if(!g_otaEngine.write(o,b+4,v.size()-4)){fail(g_otaEngine.error());return;}lastActivityMs_=millis();if(g_otaEngine.received()-lastAck_>=BLE_OTA_ACK_BYTES||g_otaEngine.received()==g_otaEngine.total()){lastAck_=g_otaEngine.received();notify("ACK");}}
void BLEOTA::disconnected(){if(active())g_otaEngine.abort("connection_lost");}
void BLEOTA::loop(){if(active()&&millis()-lastActivityMs_>BLE_OTA_TIMEOUT_MS){g_otaEngine.abort("timeout");fail("timeout");}if(rebootAtMs_&&(int32_t)(millis()-rebootAtMs_)>=0)esp_restart();}
