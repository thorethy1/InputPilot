import Foundation
@testable import InputPilot

final class MockAPIClient: DeviceAPIClientProtocol, @unchecked Sendable {
    var statusResults: [URL: Result<DeviceStatus, Error>] = [:]
    var setJiggleResults: [URL: Result<Void, Error>] = [:]
    var keepAwakeResults: [URL: Result<KeepAwakeSettings, Error>] = [:]
    var setKeepAwakeResults: [URL: Result<Void, Error>] = [:]
    var getWifiResults: [URL: Result<WifiStatus, Error>] = [:]
    var provisionWifiResults: [URL: Result<Void, Error>] = [:]
    var usbIdentityResults: [URL: Result<USBIdentity, Error>] = [:]
    private(set) var setJiggleCalls: [(URL, Bool, String?)] = []
    private(set) var setKeepAwakeCalls: [(URL, KeepAwakeSettings, String?)] = []
    private(set) var provisionWifiCalls: [(URL, String, String, String?)] = []

    func status(baseURL: URL, token: String?) async throws -> DeviceStatus {
        if let result = statusResults[baseURL] {
            return try result.get()
        }
        throw DeviceAPIError.invalidResponse
    }

    func setJiggle(baseURL: URL, enabled: Bool, token: String?) async throws {
        setJiggleCalls.append((baseURL, enabled, token))
        if let result = setJiggleResults[baseURL] {
            try result.get()
            return
        }
        throw DeviceAPIError.invalidResponse
    }

    func getWifi(baseURL: URL, token: String?) async throws -> WifiStatus {
        if let result = getWifiResults[baseURL] {
            return try result.get()
        }
        throw DeviceAPIError.invalidResponse
    }

    func provisionWifi(baseURL: URL, ssid: String, password: String, token: String?) async throws {
        provisionWifiCalls.append((baseURL, ssid, password, token))
        if let result = provisionWifiResults[baseURL] {
            try result.get()
            return
        }
    }

    func keepAwake(baseURL: URL, token: String?) async throws -> KeepAwakeSettings {
        if let result = keepAwakeResults[baseURL] { return try result.get() }
        throw DeviceAPIError.invalidResponse
    }

    func setKeepAwake(baseURL: URL, settings: KeepAwakeSettings, token: String?) async throws {
        setKeepAwakeCalls.append((baseURL, settings, token))
        if let result = setKeepAwakeResults[baseURL] { try result.get(); return }
        throw DeviceAPIError.invalidResponse
    }

    func usbIdentity(baseURL: URL, token: String?) async throws -> USBIdentity {
        if let result = usbIdentityResults[baseURL] { return try result.get() }
        throw DeviceAPIError.invalidResponse
    }

    func setUSBIdentity(baseURL: URL, identity: USBIdentityUpdate, token: String?) async throws {}

    func resetUSBIdentity(baseURL: URL, token: String?) async throws {}
}
