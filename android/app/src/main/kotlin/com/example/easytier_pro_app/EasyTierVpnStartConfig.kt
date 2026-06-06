package com.example.easytier_pro_app

import android.content.Intent

data class AndroidVpnStartConfig(
    val instanceName: String,
    val addresses: List<String>,
    val routes: List<String>,
    val dnsServers: List<String>,
    val disallowedApplications: List<String>,
    val mtu: Int,
)

data class AndroidVpnCidr(val address: String, val prefixLength: Int)

object EasyTierVpnStartConfigParser {
    fun fromIntent(intent: Intent, packageName: String): AndroidVpnStartConfig {
        val instanceName = intent.getStringExtra(EasyTierVpnService.extraInstanceName)
            ?.trim()
            .orEmpty()
        require(instanceName.isNotEmpty()) { "VPN instanceName is required" }

        val addresses = stringList(intent, EasyTierVpnService.extraAddresses)
        require(addresses.isNotEmpty()) { "VPN address is required before establishing TUN" }

        return AndroidVpnStartConfig(
            instanceName = instanceName,
            addresses = addresses,
            routes = stringList(intent, EasyTierVpnService.extraRoutes),
            dnsServers = stringList(intent, EasyTierVpnService.extraDnsServers),
            disallowedApplications = disallowedApplications(
                packageName,
                stringList(intent, EasyTierVpnService.extraDisallowedApplications),
            ),
            mtu = intent.getIntExtra(EasyTierVpnService.extraMtu, 0),
        )
    }

    fun disallowedApplications(packageName: String, extraPackages: List<String>): List<String> {
        return (listOf(packageName) + extraPackages)
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .distinct()
    }

    fun parseCidr(value: String): AndroidVpnCidr {
        val parts = value.trim().split("/", limit = 2)
        require(parts.firstOrNull()?.isNotEmpty() == true) { "Invalid CIDR: $value" }
        val prefix = parts.getOrNull(1)?.toIntOrNull() ?: 32
        require(prefix in 0..32) { "Invalid CIDR prefix: $value" }
        return AndroidVpnCidr(parts[0], prefix)
    }

    private fun stringList(intent: Intent, extraName: String): List<String> {
        return intent.getStringArrayListExtra(extraName)
            .orEmpty()
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .distinct()
    }
}
