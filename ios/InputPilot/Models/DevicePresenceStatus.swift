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
        case .readyBluetooth: "Ready"
        case .readyWiFi: "Online"
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
        case .readyBluetooth: "Connected securely over Bluetooth and ready for control"
        case .readyWiFi: "Reachable on the local Wi-Fi network"
        }
    }

    var isUsable: Bool { self == .readyBluetooth || self == .readyWiFi }

    var color: Color {
        switch self {
        case .readyBluetooth, .readyWiFi: AppColors.success
        case .bluetoothDiscovered, .connecting, .reconnecting, .authenticating, .checking: AppColors.info
        case .setup: AppColors.warning
        case .authenticationFailed, .offline: AppColors.error
        }
    }

    static func resolve(
        wifi: WiFiReachabilityState,
        bluetooth: TransportConnectionState,
        hasConfiguredWiFi: Bool
    ) -> DevicePresenceStatus {
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
