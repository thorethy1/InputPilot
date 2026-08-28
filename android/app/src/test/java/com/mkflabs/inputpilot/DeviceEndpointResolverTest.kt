package com.mkflabs.inputpilot

import com.mkflabs.inputpilot.network.DeviceEndpointResolver
import org.junit.Assert.assertEquals
import org.junit.Test

class DeviceEndpointResolverTest {
    @Test
    fun prefersDirectAddressThenMdns() {
        val urls =
            DeviceEndpointResolver.endpointUrls(
                mdnsHost = "hid-helper-a1b2.local",
                staIp = "192.168.2.161",
            )
        assertEquals(2, urls.size)
        assertEquals("http://192.168.2.161/", urls[0])
        assertEquals("http://hid-helper-a1b2.local/", urls[1])
    }

    @Test
    fun sanitizesInterfaceZone() {
        assertEquals(
            "192.168.2.161",
            DeviceEndpointResolver.sanitizeHost("192.168.2.161%en0"),
        )
        assertEquals(
            "http://192.168.2.161/",
            DeviceEndpointResolver.baseUrl("192.168.2.161%en0"),
        )
    }

    @Test
    fun deduplicatesSameHost() {
        val urls =
            DeviceEndpointResolver.endpointUrls(
                mdnsHost = "192.168.2.161",
                staIp = "192.168.2.161",
            )
        assertEquals(1, urls.size)
    }

    @Test
    fun directProbeAddressWinsOverReportedLanAddress() {
        assertEquals(
            "100.64.0.12",
            DeviceEndpointResolver.directAddress("192.168.2.161", "100.64.0.12"),
        )
    }

    @Test
    fun bonjourProbeUsesReportedDirectAddress() {
        assertEquals(
            "192.168.2.161",
            DeviceEndpointResolver.directAddress("192.168.2.161", "hid-helper-a1b2.local"),
        )
    }
}
