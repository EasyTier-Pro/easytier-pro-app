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
    ) {
        builder.setSession("EasyTier Pro")
        builder.setBlocking(false)

        for (application in config.disallowedApplications) {
            try {
                builder.addDisallowedApplication(application)
            } catch (error: PackageManager.NameNotFoundException) {
                onUnknownDisallowedApplication(application, error)
            }
        }

        if (config.mtu > 0) {
            builder.setMtu(config.mtu)
        }

        for (address in config.addresses) {
            val cidr = EasyTierVpnStartConfigParser.parseCidr(address)
            builder.addAddress(cidr.address, cidr.prefixLength)
        }

        for (route in config.routes) {
            val cidr = EasyTierVpnStartConfigParser.parseRouteCidr(route)
            builder.addRoute(cidr.address, cidr.prefixLength)
        }

        for (server in config.dnsServers) {
            builder.addDnsServer(server)
        }

        if (sdkInt >= Build.VERSION_CODES.Q) {
            builder.setMetered(false)
        }
    }
}
