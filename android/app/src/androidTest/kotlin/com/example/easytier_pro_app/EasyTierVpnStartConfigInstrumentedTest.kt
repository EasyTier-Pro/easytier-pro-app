package com.example.easytier_pro_app

import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
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
        assertEquals(
            listOf(context.packageName, "com.example.extra"),
            config.disallowedApplications,
        )
        assertEquals(1280, config.mtu)
    }

    @Test
    fun parsesCidrPrefixAndDefaultsHostRoutesTo32() {
        val subnet = EasyTierVpnStartConfigParser.parseCidr(" 10.10.0.0/24 ")
        val host = EasyTierVpnStartConfigParser.parseCidr("10.10.0.2")
        val mapped = EasyTierVpnStartConfigParser.parseCidr("10.2.0.0/24->192.168.2.0/24")

        assertEquals("10.10.0.0", subnet.address)
        assertEquals(24, subnet.prefixLength)
        assertEquals("10.10.0.2", host.address)
        assertEquals(32, host.prefixLength)
        assertEquals("192.168.2.0", mapped.address)
        assertEquals(24, mapped.prefixLength)
    }

    @Test
    fun parsesRouteCidrToNetworkAddress() {
        val subnet = EasyTierVpnStartConfigParser.parseRouteCidr("10.10.0.42/24")
        val host = EasyTierVpnStartConfigParser.parseRouteCidr("10.10.0.42")
        val defaultRoute = EasyTierVpnStartConfigParser.parseRouteCidr("10.10.0.42/0")
        val mapped = EasyTierVpnStartConfigParser.parseRouteCidr(
            "10.2.0.42/24->192.168.2.45/24",
        )

        assertEquals("10.10.0.0", subnet.address)
        assertEquals(24, subnet.prefixLength)
        assertEquals("10.10.0.42", host.address)
        assertEquals(32, host.prefixLength)
        assertEquals("0.0.0.0", defaultRoute.address)
        assertEquals(0, defaultRoute.prefixLength)
        assertEquals("192.168.2.0", mapped.address)
        assertEquals(24, mapped.prefixLength)
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
    fun diagnosticPayloadDisallowsSelfPackageEvenWhenConfigIsInvalid() {
        val intent = Intent().apply {
            putExtra(EasyTierVpnService.extraInstanceName, "network-a")
            putStringArrayListExtra(
                EasyTierVpnService.extraDisallowedApplications,
                arrayListOf("com.example.extra"),
            )
            putExtra(EasyTierVpnService.extraMtu, 1280)
        }

        val payload = EasyTierVpnStartConfigParser.diagnosticPayload(
            intent,
            context.packageName,
        )

        assertEquals(emptyList<String>(), payload["addresses"])
        assertEquals(emptyList<String>(), payload["routes"])
        assertEquals(emptyList<String>(), payload["dnsServers"])
        assertEquals(
            listOf(context.packageName, "com.example.extra"),
            payload["disallowedApplications"],
        )
        assertEquals(context.packageName, payload["packageName"])
        assertEquals(0, payload["addressCount"])
        assertEquals(0, payload["routeCount"])
        assertEquals(2, payload["disallowedApplicationCount"])
        assertEquals(true, payload["selfDisallowed"])
        assertEquals(1280, payload["mtu"])
    }

    @Test
    fun rejectsInvalidCidrPrefix() {
        assertFailsWithMessage("Invalid CIDR prefix") {
            EasyTierVpnStartConfigParser.parseCidr("10.10.0.0/33")
        }
    }

    @Test
    fun configuresNonBlockingTunRoutesAndDisallowedApplications() {
        val builder = RecordingVpnBuilderOperations()
        val config = AndroidVpnStartConfig(
            instanceName = "network-a",
            addresses = listOf("10.10.0.2/24"),
            routes = listOf(
                "10.10.0.0/24",
                "10.30.0.42/24",
                "10.2.0.0/24->192.168.2.0/24",
            ),
            dnsServers = listOf("10.10.0.53"),
            disallowedApplications = listOf(context.packageName),
            mtu = 1280,
        )

        val appliedConfig = EasyTierVpnBuilderConfigurator.configure(
            builder,
            config,
            sdkInt = Build.VERSION_CODES.Q,
        )

        assertEquals(listOf("10.10.0.2/24"), appliedConfig.addresses)
        assertEquals(
            listOf("10.10.0.0/24", "10.30.0.0/24", "192.168.2.0/24"),
            appliedConfig.routes,
        )
        assertEquals(listOf("10.10.0.53"), appliedConfig.dnsServers)
        assertEquals(listOf(context.packageName), appliedConfig.disallowedApplications)
        assertEquals(emptyList<String>(), appliedConfig.ignoredDisallowedApplications)
        assertEquals(
            listOf(
                "setSession:EasyTier Pro",
                "setBlocking:false",
                "addDisallowedApplication:${context.packageName}",
                "setMtu:1280",
                "addAddress:10.10.0.2/24",
                "addRoute:10.10.0.0/24",
                "addRoute:10.30.0.0/24",
                "addRoute:192.168.2.0/24",
                "addDnsServer:10.10.0.53",
                "setMetered:false",
            ),
            builder.operations,
        )
    }

    @Test
    fun configuresBypassWhenRequestedForDebugging() {
        val builder = RecordingVpnBuilderOperations()

        val appliedConfig = EasyTierVpnBuilderConfigurator.configure(
            builder,
            AndroidVpnStartConfig(
                instanceName = "network-a",
                addresses = listOf("10.10.0.2/24"),
                routes = emptyList(),
                dnsServers = emptyList(),
                disallowedApplications = emptyList(),
                mtu = 0,
            ),
            sdkInt = Build.VERSION_CODES.LOLLIPOP,
            allowBypass = true,
        )

        assertEquals(true, appliedConfig.allowBypass)
        assertEquals(
            listOf(
                "setSession:EasyTier Pro",
                "setBlocking:false",
                "allowBypass",
                "addAddress:10.10.0.2/24",
            ),
            builder.operations,
        )
    }

    @Test
    fun ignoresUnknownDisallowedApplicationsWhenConfiguringBuilder() {
        val builder = RecordingVpnBuilderOperations(
            unknownApplications = setOf("com.example.missing"),
        )
        val ignored = mutableListOf<String>()

        val appliedConfig = EasyTierVpnBuilderConfigurator.configure(
            builder,
            AndroidVpnStartConfig(
                instanceName = "network-a",
                addresses = listOf("10.10.0.2/24"),
                routes = emptyList(),
                dnsServers = emptyList(),
                disallowedApplications = listOf(
                    context.packageName,
                    "com.example.missing",
                ),
                mtu = 0,
            ),
            sdkInt = Build.VERSION_CODES.P,
        ) { application, _ ->
            ignored.add(application)
        }

        assertEquals(listOf("com.example.missing"), ignored)
        assertEquals(listOf(context.packageName), appliedConfig.disallowedApplications)
        assertEquals(
            listOf("com.example.missing"),
            appliedConfig.ignoredDisallowedApplications,
        )
        assertEquals(
            listOf(
                "setSession:EasyTier Pro",
                "setBlocking:false",
                "addDisallowedApplication:${context.packageName}",
                "addDisallowedApplication:com.example.missing",
                "addAddress:10.10.0.2/24",
            ),
            builder.operations,
        )
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

    private class RecordingVpnBuilderOperations(
        private val unknownApplications: Set<String> = emptySet(),
    ) : EasyTierVpnBuilderOperations {
        val operations = mutableListOf<String>()

        override fun setSession(session: String) {
            operations.add("setSession:$session")
        }

        override fun setBlocking(blocking: Boolean) {
            operations.add("setBlocking:$blocking")
        }

        override fun allowBypass() {
            operations.add("allowBypass")
        }

        override fun addDisallowedApplication(packageName: String) {
            operations.add("addDisallowedApplication:$packageName")
            if (packageName in unknownApplications) {
                throw PackageManager.NameNotFoundException(packageName)
            }
        }

        override fun setMtu(mtu: Int) {
            operations.add("setMtu:$mtu")
        }

        override fun addAddress(address: String, prefixLength: Int) {
            operations.add("addAddress:$address/$prefixLength")
        }

        override fun addRoute(address: String, prefixLength: Int) {
            operations.add("addRoute:$address/$prefixLength")
        }

        override fun addDnsServer(server: String) {
            operations.add("addDnsServer:$server")
        }

        override fun setMetered(metered: Boolean) {
            operations.add("setMetered:$metered")
        }
    }
}
