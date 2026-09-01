import SwiftUI

enum WiFiReachabilityState: Equatable, Sendable {
    case checking
    case reachable
    case offline
}

/// A user-facing summary derived exclusively from live transport state.
/// Persisted capabilities describe what a device supports, never whether it is online.
enum DevicePresenceStatus: Equatable, Sendable {
    case checking
    case offline
    case setup
    case bluetoothDiscovered
    case connecting
    case reconnecting
    case authenticating
    case authenticationFailed
    case readyBoth
    case readyBluetooth
    case readyWiFi

    var title: String {
        switch self {
        case .checking: "Checking availability…"
        case .offline: "Offline"
        case .setup: "Setup required"
        case .bluetoothDiscovered: "Nearby via Bluetooth"
        case .connecting: "Connecting…"
        case .reconnecting: "Reconnecting…"
        case .authenticating: "Authenticating…"
        case .authenticationFailed: "Authentication failed"
        case .readyBoth, .readyBluetooth, .readyWiFi: "Online"
        }
    }

    var detail: String {
        switch self {
        case .checking: "Checking Bluetooth and Wi-Fi"
        case .offline: "Saved device is currently unavailable"
        case .setup: "Connect the device to Wi-Fi to finish setup"
        case .bluetoothDiscovered: "Discovered, but not connected"
        case .connecting: "Establishing a device connection"
        case .reconnecting: "The previous connection was lost"
        case .authenticating: "Verifying device access"
        case .authenticationFailed: "Pair the device again over USB to rotate its trust credential"
        case .readyBoth: "Online via Wi-Fi and Bluetooth"
        case .readyBluetooth: "Online via Bluetooth only"
        case .readyWiFi: "Online via Wi-Fi only"
        }
    }

    var isUsable: Bool {
        self == .readyBoth || self == .readyBluetooth || self == .readyWiFi
    }

    var color: Color {
        switch self {
        case .readyBoth, .readyBluetooth, .readyWiFi: AppColors.connected
        case .bluetoothDiscovered, .connecting, .reconnecting, .authenticating, .checking: AppColors.available
        case .setup: AppColors.attention
        case .authenticationFailed: AppColors.error
        case .offline: AppColors.offline
        }
    }

    var systemImage: String {
        switch self {
        case .checking: "ellipsis.circle"
        case .offline: "wifi.slash"
        case .setup: "wrench.and.screwdriver"
        case .bluetoothDiscovered: "antenna.radiowaves.left.and.right"
        case .connecting, .reconnecting: "arrow.triangle.2.circlepath"
        case .authenticating: "checkmark.shield"
        case .authenticationFailed: "exclamationmark.shield"
        case .readyBoth: "checkmark.circle.fill"
        case .readyBluetooth: "checkmark.circle.fill"
        case .readyWiFi: "checkmark.circle.fill"
        }
    }

    static func resolve(
        wifi: WiFiReachabilityState,
        bluetooth: TransportConnectionState,
        hasConfiguredWiFi: Bool
    ) -> DevicePresenceStatus {
        if bluetooth == .ready && wifi == .reachable { return .readyBoth }
        // A working transport takes precedence over a failure or reconnect on another.
        if bluetooth == .ready { return .readyBluetooth }
        if wifi == .reachable { return hasConfiguredWiFi ? .readyWiFi : .setup }

        switch bluetooth {
        case .authenticationFailed: return .authenticationFailed
        case .authenticating: return .authenticating
        case .connected, .connecting: return .connecting
        case .reconnecting: return .reconnecting
        case .discovered: return .bluetoothDiscovered
        case .discovering:
            return wifi == .checking ? .checking : .offline
        case .unavailable, .offline:
            return wifi == .checking ? .checking : .offline
        case .ready:
            return .readyBluetooth
        }
    }
}
