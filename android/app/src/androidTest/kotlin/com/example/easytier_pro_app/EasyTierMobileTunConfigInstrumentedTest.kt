package com.example.easytier_pro_app

import androidx.test.ext.junit.runners.AndroidJUnit4
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
        fun start(id: String, address: String) {
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
            """.trimIndent()))
        }
        fun awaitMembers(ids: List<String>): EasyTierMobileTunConfig {
            val deadline = System.nanoTime() + 10_000_000_000L
            while (true) {
                val config = EasyTierMobileTunConfig.parse(EasyTierNative.getMobileTunConfig(ids))
                assertTrue("Startup must remain pending: ${config.rejected}", config.rejected.isEmpty())
                if (config.instanceIds == ids.sorted()) return config
                assertTrue("Members did not start before timeout", System.nanoTime() < deadline)
                Thread.sleep(20)
            }
        }
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
    fun mapsAllAcceptedMembersAndPreservesRejectedReason() {
        val config = EasyTierMobileTunConfig.parse("""{
            "instance_ids":["b","a"],
            "addresses":["10.2.0.2/24","10.1.0.2/24","fd00::2/64"],
            "routes":["10.2.0.0/24","10.1.0.0/24","fd00::/64"],
            "dns":"100.100.100.101",
            "rejected":[{"instance_id":"c","error":"overlapping route"}]
        }""")
        assertEquals(listOf("a", "b"), config.instanceIds)
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
}
