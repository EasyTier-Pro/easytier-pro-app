package com.example.easytier_pro_app

import android.content.Intent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class EasyTierVpnStartConfigInstrumentedTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    @Test
    fun parsesVpnStartIntentAndDisallowsSelfPackage() {
        val intent = Intent().apply {
            putExtra(EasyTierVpnService.extraInstanceName, " network-a ")
            putStringArrayListExtra(
                EasyTierVpnService.extraAddresses,
                arrayListOf(" 10.10.0.2/24 ", "", "10.10.0.2/24"),
            )
            putStringArrayListExtra(
                EasyTierVpnService.extraRoutes,
                arrayListOf("10.10.0.0/24", " 192.168.50.0/24 ", "10.10.0.0/24"),
            )
            putStringArrayListExtra(
                EasyTierVpnService.extraDnsServers,
                arrayListOf(" 10.10.0.53 ", ""),
            )
            putStringArrayListExtra(
                EasyTierVpnService.extraDisallowedApplications,
                arrayListOf("", context.packageName, "com.example.extra"),
            )
            putExtra(EasyTierVpnService.extraMtu, 1280)
        }

        val config = EasyTierVpnStartConfigParser.fromIntent(intent, context.packageName)

        assertEquals("network-a", config.instanceName)
        assertEquals(listOf("10.10.0.2/24"), config.addresses)
        assertEquals(listOf("10.10.0.0/24", "192.168.50.0/24"), config.routes)
        assertEquals(listOf("10.10.0.53"), config.dnsServers)
        assertEquals(listOf(context.packageName, "com.example.extra"), config.disallowedApplications)
        assertEquals(1280, config.mtu)
    }

    @Test
    fun parsesCidrPrefixAndDefaultsHostRoutesTo32() {
        val subnet = EasyTierVpnStartConfigParser.parseCidr(" 10.10.0.0/24 ")
        val host = EasyTierVpnStartConfigParser.parseCidr("10.10.0.2")

        assertEquals("10.10.0.0", subnet.address)
        assertEquals(24, subnet.prefixLength)
        assertEquals("10.10.0.2", host.address)
        assertEquals(32, host.prefixLength)
    }

    @Test
    fun rejectsVpnStartIntentWithoutAddress() {
        val intent = Intent().apply {
            putExtra(EasyTierVpnService.extraInstanceName, "network-a")
        }

        assertFailsWithMessage("VPN address is required") {
            EasyTierVpnStartConfigParser.fromIntent(intent, context.packageName)
        }
    }

    @Test
    fun rejectsInvalidCidrPrefix() {
        assertFailsWithMessage("Invalid CIDR prefix") {
            EasyTierVpnStartConfigParser.parseCidr("10.10.0.0/33")
        }
    }

    private fun assertFailsWithMessage(
        expectedMessage: String,
        action: () -> Unit,
    ) {
        try {
            action()
        } catch (error: IllegalArgumentException) {
            assertTrue(error.message.orEmpty().contains(expectedMessage))
            return
        }
        throw AssertionError("Expected IllegalArgumentException containing $expectedMessage")
    }
}
