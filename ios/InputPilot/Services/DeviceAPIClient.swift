import Foundation

enum DeviceAPIError: Error, Equatable, LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case decodingFailed(String?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Invalid response from InputPilot."
        case let .httpStatus(code): "InputPilot discovery failed (HTTP \(code))."
        case let .decodingFailed(snippet): "Invalid InputPilot discovery response\(snippet.map { ": \($0)" } ?? ".")"
        }
    }
}

// Plain HTTP is intentionally limited to public discovery metadata. Feature
// clients must use the authenticated Secure Protocol v2 transports.
protocol DeviceAPIClientProtocol: Sendable {
    func status(baseURL: URL) async throws -> DeviceStatus
}

struct DeviceAPIClient: DeviceAPIClientProtocol {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func status(baseURL: URL) async throws -> DeviceStatus {
        let (data, response) = try await session.data(from: baseURL.appendingPathComponent("api/status"))
        guard let http = response as? HTTPURLResponse else { throw DeviceAPIError.invalidResponse }
        guard (200 ... 299).contains(http.statusCode) else { throw DeviceAPIError.httpStatus(http.statusCode) }
        do { return try JSONDecoder().decode(DeviceStatus.self, from: data) }
        catch {
            let snippet = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DeviceAPIError.decodingFailed(snippet.map { String($0.prefix(180)) })
        }
    }
}
