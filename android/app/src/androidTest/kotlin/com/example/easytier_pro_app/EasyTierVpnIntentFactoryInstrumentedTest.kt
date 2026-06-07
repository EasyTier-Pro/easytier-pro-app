package com.example.easytier_pro_app

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class EasyTierVpnIntentFactoryInstrumentedTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    @Test
    fun mapsVpnConfigToStartIntentExtras() {
        val intent = EasyTierVpnIntentFactory.startIntent(
            context,
            "network-a",
            mapOf(
                "addresses" to listOf(
                    mapOf("address" to "10.10.0.2", "prefixLength" to 24),
                    " 10.10.0.3/32 ",
                ),
                "routes" to listOf(
                    mapOf("address" to "10.20.4.3", "prefix" to 16),
                    "192.168.50.0/24",
                ),
                "dnsServers" to listOf(" 10.10.0.53 ", ""),
                "disallowedPackages" to listOf(" com.example.extra "),
                "mtu" to "1280",
            ),
        )

        val config = EasyTierVpnStartConfigParser.fromIntent(intent, context.packageName)

        assertEquals(EasyTierVpnService.actionStart, intent.action)
        assertEquals("network-a", config.instanceName)
        assertEquals(listOf("10.10.0.2/24", "10.10.0.3/32"), config.addresses)
        assertEquals(listOf("10.20.0.0/16", "192.168.50.0/24"), config.routes)
        assertEquals(listOf("10.10.0.53"), config.dnsServers)
        assertEquals(listOf(context.packageName, "com.example.extra"), config.disallowedApplications)
        assertEquals(1280, config.mtu)
    }

    @Test
    fun mapsSnakeCaseVpnConfigAliases() {
        val intent = EasyTierVpnIntentFactory.startIntent(
            context,
            "network-a",
            mapOf(
                "address" to "10.10.0.2/24",
                "route" to "10.20.0.0/16",
                "dns_servers" to listOf("10.10.0.53"),
                "disallowed_packages" to listOf("com.example.extra"),
            ),
        )

        val config = EasyTierVpnStartConfigParser.fromIntent(intent, context.packageName)

        assertEquals(listOf("10.10.0.2/24"), config.addresses)
        assertEquals(listOf("10.20.0.0/16"), config.routes)
        assertEquals(listOf("10.10.0.53"), config.dnsServers)
        assertEquals(listOf(context.packageName, "com.example.extra"), config.disallowedApplications)
        assertEquals(0, config.mtu)
    }
}
