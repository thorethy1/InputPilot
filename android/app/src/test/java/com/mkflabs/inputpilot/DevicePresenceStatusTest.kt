package com.mkflabs.inputpilot

import com.mkflabs.inputpilot.network.DevicePresenceStatus
import org.junit.Assert.assertEquals
import org.junit.Test

class DevicePresenceStatusTest {
    @Test
    fun offlineWhenUnreachable() {
        assertEquals(
            DevicePresenceStatus.OFFLINE,
            DevicePresenceStatus.resolve(false, true),
        )
    }

    @Test
    fun checkingBeforeFirstProbe() {
        assertEquals(
            DevicePresenceStatus.CHECKING,
            DevicePresenceStatus.resolve(null, true),
        )
    }

    @Test
    fun onlineWhenReachable() {
        assertEquals(
            DevicePresenceStatus.ONLINE,
            DevicePresenceStatus.resolve(true, true),
        )
    }

    @Test
    fun setupWhenNoNetworkEndpoint() {
        assertEquals(
            DevicePresenceStatus.SETUP,
            DevicePresenceStatus.resolve(true, false),
        )
    }
}
