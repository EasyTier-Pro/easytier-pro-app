package com.example.easytier_pro_app

import androidx.test.ext.junit.runners.AndroidJUnit4
import android.os.ParcelFileDescriptor
import android.system.Os
import android.system.OsConstants
import android.system.StructPollfd
import android.util.Base64
import com.easytier.jni.EasyTierJNI
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class EasyTierMobileTunConfigInstrumentedTest {
    @Test
    fun aggregatesTwoStartingInstancesAndRemovesOnlyTheSelectedMember() {
        val first = UUID.randomUUID().toString()
        val second = UUID.randomUUID().toString()
        try {
            start(first, "10.253.91.2/24")
            awaitMembers(listOf(first))
            start(second, "10.253.92.2/24")
            val both = awaitMembers(listOf(first, second))
            assertEquals(listOf("10.253.91.2/24", "10.253.92.2/24"), both.addresses)
            EasyTierNative.retainNetworkInstance(listOf(second))
            val remaining = awaitMembers(listOf(second))
            assertEquals(listOf("10.253.92.2/24"), remaining.addresses)
        } finally {
            EasyTierNative.stopAllInstances()
        }
    }

    @Test
    fun nativeDnsConfigIncludesEnabledZonesAndClearsOnMemberRemoval() {
        val first = UUID.randomUUID().toString()
        val second = UUID.randomUUID().toString()
        val disabled = UUID.randomUUID().toString()
        try {
            start(first, "10.253.91.2/24", "accept_dns = true")
            start(second, "10.253.92.2/24", """
                accept_dns = true
                tld_dns_zone = "nas.internal."
            """.trimIndent())
            start(disabled, "10.253.93.2/24", """
                accept_dns = false
                tld_dns_zone = "disabled.internal."
            """.trimIndent())
            val config = awaitMembers(listOf(first, second, disabled))
            assertEquals("100.100.100.101", config.dns)
            assertTrue(config.routes.contains("100.100.100.101/32"))
            assertEquals(listOf("et.net", "nas.internal"), config.searchDomains)

            EasyTierNative.retainNetworkInstance(listOf(disabled))
            val remaining = awaitMembers(listOf(disabled))
            assertNull(remaining.dns)
            assertTrue(remaining.searchDomains.isEmpty())
            assertFalse(remaining.routes.contains("100.100.100.101/32"))
        } finally {
            EasyTierNative.stopAllInstances()
        }
    }

    @Test
    fun reusedBorrowedFdKeepsForwardingWithEitherUserspaceStackSetting() {
        for (userspace in listOf(false, true)) {
            val id = UUID.randomUUID().toString()
            var pair: Array<ParcelFileDescriptor>? = null
            try {
                start(id, "10.239.88.1/24", "use_smoltcp = $userspace")
                awaitMembers(listOf(id))
                repeat(10) {
                    val previous = pair
                    // Exercise both the service handoff and the old close/reopen order.
                    val closeBeforeAttach = it % 2 == 0
                    if (closeBeforeAttach) previous?.forEach { it.close() }
                    pair = ParcelFileDescriptor.createSocketPair()
                    val current = checkNotNull(pair)
                    Os.fcntlInt(current[0].fileDescriptor, OsConstants.F_SETFL, OsConstants.O_NONBLOCK)
                    val attached = EasyTierMobileTunConfig.parse(
                        EasyTierNative.attachMobileTunFd(current[0].fd, listOf(id)),
                    )
                    assertEquals(listOf(id), attached.instanceIds)
                    if (!closeBeforeAttach) {
                        previous?.forEach {
                            Os.fcntlInt(it.fileDescriptor, OsConstants.F_GETFL, 0)
                            it.close()
                        }
                    }
                    Thread.sleep(50)
                    assertPacketRoundTrip(current)
                }
                EasyTierNative.attachMobileTunFd(0, null)
                // Native code borrows the descriptor; only its Android owner closes it.
                Os.fcntlInt(checkNotNull(pair)[0].fileDescriptor, OsConstants.F_GETFL, 0)
            } finally {
                EasyTierNative.attachMobileTunFd(0, null)
                pair?.forEach { it.close() }
                EasyTierNative.stopAllInstances()
            }
        }
    }

    @Test
    fun mapsAllAcceptedMembersAndPreservesRejectedReason() {
        val config = EasyTierMobileTunConfig.parse("""{
            "instance_ids":["b","a"],
            "addresses":["10.2.0.2/24","10.1.0.2/24","fd00::2/64"],
            "routes":["10.2.0.0/24","10.1.0.0/24","fd00::/64"],
            "dns":"100.100.100.101",
            "search_domains":["nas.internal","et.net","et.net"],
            "rejected":[{"instance_id":"c","error":"overlapping route"}]
        }""")
        assertEquals(listOf("a", "b"), config.instanceIds)
        assertEquals(listOf("et.net", "nas.internal"), config.searchDomains)
        assertEquals(config.searchDomains, config.toMap()["search_domains"])
        assertEquals(config.searchDomains, config.toVpnStartConfig("net.easytier.pro").searchDomains)
        assertFalse(config.sameInterface(config.copy(searchDomains = listOf("et.net"))))
        assertEquals(3, config.toVpnStartConfig("net.easytier.pro").addresses.size)
        assertEquals("overlapping route", config.rejected.single()["error"])
        assertEquals(listOf("net.easytier.pro"), config.toVpnStartConfig("net.easytier.pro").disallowedApplications)
        assertEquals(AndroidVpnCidr("fd00::2", 64), EasyTierVpnStartConfigParser.parseCidr("fd00::2/64"))
        assertEquals(AndroidVpnCidr("fd00::", 64), EasyTierVpnStartConfigParser.parseRouteCidr("fd00::/64"))
    }

    @Test
    fun sharedTunJniSupportsEmptyMembershipAndDetach() {
        val empty = EasyTierMobileTunConfig.parse(EasyTierNative.getMobileTunConfig(emptyList()))
        assertTrue(empty.instanceIds.isEmpty())
        assertTrue(empty.addresses.isEmpty())
        assertNull(empty.dns)
        assertTrue(empty.searchDomains.isEmpty())
        val detached = EasyTierMobileTunConfig.parse(EasyTierNative.attachMobileTunFd(0, null))
        assertTrue(detached.instanceIds.isEmpty())
    }

    @Test
    fun sharedTunJniRejectsMalformedInstanceIdentity() {
        try {
            EasyTierNative.getMobileTunConfig(listOf("invalid-uuid"))
            fail("Expected invalid instance identity to be rejected")
        } catch (error: RuntimeException) {
            assertFalse(error.message.isNullOrBlank())
        }
    }

    private fun start(id: String, address: String, flags: String = "") {
        assertEquals(0, EasyTierJNI.runNetworkInstance("""
            instance_id = "$id"
            instance_name = "$id"
            ipv4 = "$address"
            dhcp = false
            listeners = []
            [network_identity]
            network_name = "$id"
            network_secret = "instrumentation"
            [flags]
            no_tun = false
            enable_ipv6 = false
            $flags
        """.trimIndent()))
    }

    private fun awaitMembers(ids: List<String>): EasyTierMobileTunConfig {
        val deadline = System.nanoTime() + 10_000_000_000L
        while (true) {
            val config = EasyTierMobileTunConfig.parse(EasyTierNative.getMobileTunConfig(ids))
            assertTrue("Startup must remain pending: ${config.rejected}", config.rejected.isEmpty())
            if (config.instanceIds == ids.sorted()) return config
            assertTrue("Members did not start before timeout", System.nanoTime() < deadline)
            Thread.sleep(20)
        }
    }

    private fun assertPacketRoundTrip(pair: Array<ParcelFileDescriptor>) {
        // IPv4 TCP SYN to the instance's own virtual IP exercises both TUN directions.
        val packet = Base64.decode(
            "RQAAKAABAABABrTvCu9YAQrvWAGhQwjrAAAACgAAAABQAiAAH8oAAA==",
            Base64.DEFAULT,
        )
        Os.write(pair[1].fileDescriptor, packet, 0, packet.size)
        val poll = StructPollfd().apply {
            fd = pair[1].fileDescriptor
            events = OsConstants.POLLIN.toShort()
        }
        assertTrue("TUN stopped forwarding after fd replacement", Os.poll(arrayOf(poll), 2000) > 0)
        val response = ByteArray(2048)
        val size = Os.read(pair[1].fileDescriptor, response, 0, response.size)
        assertArrayEquals(packet, response.copyOf(size))
    }
}
