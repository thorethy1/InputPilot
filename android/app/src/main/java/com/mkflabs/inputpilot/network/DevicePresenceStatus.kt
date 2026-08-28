package com.mkflabs.inputpilot.network

enum class DevicePresenceStatus(val title: String, val ledArgb: Long) {
    CHECKING("Checking availability…", 0xFF1976D2),
    OFFLINE("Offline", 0xFFF2261F),
    SETUP("Setup required", 0xFFF226D9),
    ONLINE("Online via Wi-Fi", 0xFF1EB847),
    ;

    companion object {
        fun resolve(isReachable: Boolean?, hasNetworkEndpoint: Boolean): DevicePresenceStatus {
            if (isReachable == null) return CHECKING
            if (!isReachable) return OFFLINE
            return if (hasNetworkEndpoint) ONLINE else SETUP
        }
    }
}
