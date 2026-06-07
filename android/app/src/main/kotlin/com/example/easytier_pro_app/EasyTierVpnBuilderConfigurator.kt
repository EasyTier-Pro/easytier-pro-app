package com.example.easytier_pro_app

import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build

interface EasyTierVpnBuilderOperations {
    fun setSession(session: String)
    fun setBlocking(blocking: Boolean)
    fun addDisallowedApplication(packageName: String)
    fun setMtu(mtu: Int)
    fun addAddress(address: String, prefixLength: Int)
    fun addRoute(address: String, prefixLength: Int)
    fun addDnsServer(server: String)
    fun setMetered(metered: Boolean)
}

data class AndroidVpnAppliedConfig(
    val addresses: List<String>,
    val routes: List<String>,
    val dnsServers: List<String>,
    val disallowedApplications: List<String>,
    val ignoredDisallowedApplications: List<String>,
)

class EasyTierVpnServiceBuilderOperations(
    private val builder: VpnService.Builder,
) : EasyTierVpnBuilderOperations {
    override fun setSession(session: String) {
        builder.setSession(session)
    }

    override fun setBlocking(blocking: Boolean) {
        builder.setBlocking(blocking)
    }

    override fun addDisallowedApplication(packageName: String) {
        builder.addDisallowedApplication(packageName)
    }

    override fun setMtu(mtu: Int) {
        builder.setMtu(mtu)
    }

    override fun addAddress(address: String, prefixLength: Int) {
        builder.addAddress(address, prefixLength)
    }

    override fun addRoute(address: String, prefixLength: Int) {
        builder.addRoute(address, prefixLength)
    }

    override fun addDnsServer(server: String) {
        builder.addDnsServer(server)
    }

    override fun setMetered(metered: Boolean) {
        builder.setMetered(metered)
    }
}

object EasyTierVpnBuilderConfigurator {
    fun configure(
        builder: EasyTierVpnBuilderOperations,
        config: AndroidVpnStartConfig,
        sdkInt: Int = Build.VERSION.SDK_INT,
        onUnknownDisallowedApplication: (
            String,
            PackageManager.NameNotFoundException,
        ) -> Unit = { _, _ -> },
    ): AndroidVpnAppliedConfig {
        builder.setSession("EasyTier Pro")
        builder.setBlocking(false)

        val builderAddresses = mutableListOf<String>()
        val builderRoutes = mutableListOf<String>()
        val builderDnsServers = mutableListOf<String>()
        val builderDisallowedApplications = mutableListOf<String>()
        val ignoredDisallowedApplications = mutableListOf<String>()

        for (application in config.disallowedApplications) {
            try {
                builder.addDisallowedApplication(application)
                builderDisallowedApplications.add(application)
            } catch (error: PackageManager.NameNotFoundException) {
                ignoredDisallowedApplications.add(application)
                onUnknownDisallowedApplication(application, error)
            }
        }

        if (config.mtu > 0) {
            builder.setMtu(config.mtu)
        }

        for (address in config.addresses) {
            val cidr = EasyTierVpnStartConfigParser.parseCidr(address)
            builder.addAddress(cidr.address, cidr.prefixLength)
            builderAddresses.add("${cidr.address}/${cidr.prefixLength}")
        }

        for (route in config.routes) {
            val cidr = EasyTierVpnStartConfigParser.parseRouteCidr(route)
            builder.addRoute(cidr.address, cidr.prefixLength)
            builderRoutes.add("${cidr.address}/${cidr.prefixLength}")
        }

        for (server in config.dnsServers) {
            builder.addDnsServer(server)
            builderDnsServers.add(server)
        }

        if (sdkInt >= Build.VERSION_CODES.Q) {
            builder.setMetered(false)
        }

        return AndroidVpnAppliedConfig(
            addresses = builderAddresses,
            routes = builderRoutes,
            dnsServers = builderDnsServers,
            disallowedApplications = builderDisallowedApplications,
            ignoredDisallowedApplications = ignoredDisallowedApplications,
        )
    }
}
