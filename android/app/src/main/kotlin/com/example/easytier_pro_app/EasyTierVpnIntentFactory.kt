package com.example.easytier_pro_app

import android.content.Context
import android.content.Intent

object EasyTierVpnIntentFactory {
    fun startIntent(
        context: Context,
        instanceName: String,
        vpnConfig: Map<String, Any?>,
    ): Intent {
        return Intent(context, EasyTierVpnService::class.java).apply {
            action = EasyTierVpnService.actionStart
            putExtra(EasyTierVpnService.extraInstanceName, instanceName)
            putStringArrayListExtra(
                EasyTierVpnService.extraAddresses,
                ArrayList(cidrList(vpnConfig["addresses"] ?: vpnConfig["address"])),
            )
            putStringArrayListExtra(
                EasyTierVpnService.extraRoutes,
                ArrayList(cidrList(vpnConfig["routes"] ?: vpnConfig["route"])),
            )
            putStringArrayListExtra(
                EasyTierVpnService.extraDnsServers,
                ArrayList(
                    stringList(
                        vpnConfig["dns"] ?:
                            vpnConfig["dns_servers"] ?:
                            vpnConfig["dnsServers"],
                    ),
                ),
            )
            putStringArrayListExtra(
                EasyTierVpnService.extraDisallowedApplications,
                ArrayList(
                    stringList(
                        vpnConfig["disallowedApplications"] ?:
                            vpnConfig["disallowed_applications"] ?:
                            vpnConfig["disallowedPackages"] ?:
                            vpnConfig["disallowed_packages"],
                    ),
                ),
            )
            mtu(vpnConfig["mtu"])?.let {
                putExtra(EasyTierVpnService.extraMtu, it)
            }
        }
    }

    fun stringList(value: Any?): List<String> {
        return when (value) {
            is String -> listOf(value)
            is Iterable<*> -> value.mapNotNull { it?.toString()?.trim() }
            else -> emptyList()
        }.map { it.trim() }.filter { it.isNotEmpty() }
    }

    fun cidrList(value: Any?): List<String> {
        return when (value) {
            is String -> listOf(value)
            is Map<*, *> -> listOf(cidrFromMap(value))
            is Iterable<*> -> value.mapNotNull { item ->
                when (item) {
                    is String -> item
                    is Map<*, *> -> cidrFromMap(item)
                    else -> item?.toString()
                }
            }
            else -> emptyList()
        }.map { it.trim() }.filter { it.isNotEmpty() }
    }

    private fun cidrFromMap(value: Map<*, *>): String {
        val address = (value["address"] ?: value["ip"] ?: value["ipv4"])
            ?.toString()
            ?.trim()
            .orEmpty()
        val prefix = (value["prefix"] ?: value["prefixLength"] ?: value["prefix_length"])
            ?.toString()
            ?.trim()
            .orEmpty()
        return if (address.isNotEmpty() && prefix.isNotEmpty()) "$address/$prefix" else address
    }

    private fun mtu(value: Any?): Int? {
        return when (value) {
            is Number -> value.toInt()
            is String -> value.trim().toIntOrNull()
            else -> null
        }
    }
}
