import Foundation

enum DeviceEndpointResolver {
    /// ESP32 Arduino's default Soft-AP gateway. It is probed only as a final
    /// candidate and accepted only after the expected device identity matches.
    static let softAPHost = "192.168.4.1"

    /// Strips IPv4/IPv6 zone/interface suffixes (e.g. `192.168.2.161%en0` → `192.168.2.161`).
    static func sanitizeHost(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let percent = trimmed.firstIndex(of: "%") else { return trimmed }
        return String(trimmed[..<percent])
    }

    /// Candidate base URLs in preference order: direct/routable address first,
    /// then the Bonjour hostname as a discovery fallback.
    static func endpointURLs(mdnsHost: String, staIP: String?) -> [URL] {
        var urls: [URL] = []
        if let staIP, let ipURL = baseURL(from: staIP), !urls.contains(ipURL) {
            urls.append(ipURL)
        }
        if let mdnsURL = baseURL(from: mdnsHost), !urls.contains(mdnsURL) {
            urls.append(mdnsURL)
        }
        return urls
    }

    static func probeURLs(mdnsHost: String, staIP: String?) -> [URL] {
        var urls = endpointURLs(mdnsHost: mdnsHost, staIP: staIP)
        if let fallback = baseURL(from: softAPHost), !urls.contains(fallback) {
            urls.append(fallback)
        }
        return urls
    }

    /// Returns a canonical IPv4 address only when Bonjour resolved to a direct
    /// address. Hostnames are deliberately excluded from the last-known IP
    /// cache so that the cache remains useful when mDNS is unavailable.
    static func directIPv4Address(from host: String) -> String? {
        let parts = sanitizeHost(host).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { UInt8($0) }
        guard octets.count == 4 else { return nil }
        return octets.map(String.init).joined(separator: ".")
    }

    /// Keeps the address that actually answered a manual/direct probe. The
    /// device-reported STA address may be unreachable across a VPN.
    static func directAddress(reportedSTAIP: String?, fallbackHost: String) -> String? {
        let fallback = sanitizeHost(fallbackHost)
        if !fallback.isEmpty, !fallback.lowercased().hasSuffix(".local") {
            return fallback
        }
        guard let reportedSTAIP else { return nil }
        let reported = sanitizeHost(reportedSTAIP)
        return reported.isEmpty ? nil : reported
    }

    static func baseURL(from host: String) -> URL? {
        let trimmed = sanitizeHost(host)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            var urlString = trimmed
            if !urlString.hasSuffix("/") {
                urlString += "/"
            }
            return URL(string: urlString)
        }

        // Bracket IPv6 literals when building a URL.
        let hostPart: String
        if trimmed.contains(":"), !trimmed.hasPrefix("["), !trimmed.lowercased().hasSuffix(".local") {
            hostPart = "[\(trimmed)]"
        } else {
            hostPart = trimmed
        }

        return URL(string: "http://\(hostPart)/")
    }

    static func baseURL(host: String, port: Int) -> URL? {
        let trimmed = sanitizeHost(host)
        guard !trimmed.isEmpty else { return nil }
        if port == 80 {
            return baseURL(from: trimmed)
        }
        let hostPart: String
        if trimmed.contains(":"), !trimmed.hasPrefix("["), !trimmed.lowercased().hasSuffix(".local") {
            hostPart = "[\(trimmed)]"
        } else {
            hostPart = trimmed
        }
        return URL(string: "http://\(hostPart):\(port)/")
    }
}
