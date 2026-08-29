import Foundation
@testable import InputPilot

final class MockAPIClient: DeviceAPIClientProtocol, @unchecked Sendable {
    var statusResults: [URL: Result<DeviceStatus, Error>] = [:]
    private(set) var statusCalls: [URL] = []

    func status(baseURL: URL) async throws -> DeviceStatus {
        statusCalls.append(baseURL)
        guard let result = statusResults[baseURL] else { throw DeviceAPIError.invalidResponse }
        return try result.get()
    }
}
