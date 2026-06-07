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
            routes = routeList(intent, EasyTierVpnService.extraRoutes),
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

    fun diagnosticPayload(intent: Intent?, packageName: String): Map<String, Any?> {
        val config = try {
            intent?.let { fromIntent(it, packageName) }
        } catch (_: Throwable) {
            null
        }
        val addresses = config?.addresses
            ?: stringList(intent, EasyTierVpnService.extraAddresses)
        val routes = config?.routes
            ?: stringList(intent, EasyTierVpnService.extraRoutes)
        val dnsServers = config?.dnsServers
            ?: stringList(intent, EasyTierVpnService.extraDnsServers)
        val disallowedApplications = config?.disallowedApplications ?: disallowedApplications(
            packageName,
            stringList(intent, EasyTierVpnService.extraDisallowedApplications),
        )
        return mapOf(
            "addresses" to addresses,
            "routes" to routes,
            "dnsServers" to dnsServers,
            "disallowedApplications" to disallowedApplications,
            "packageName" to packageName,
            "addressCount" to addresses.size,
            "routeCount" to routes.size,
            "disallowedApplicationCount" to disallowedApplications.size,
            "selfDisallowed" to disallowedApplications.contains(packageName),
            "mtu" to (
                config?.mtu
                    ?: (intent?.getIntExtra(EasyTierVpnService.extraMtu, 0) ?: 0)
            ),
        )
    }

    fun parseCidr(value: String): AndroidVpnCidr {
        val normalized = routeEndpointCidr(value)
        val parts = normalized.split("/", limit = 2)
        require(parts.firstOrNull()?.isNotEmpty() == true) { "Invalid CIDR: $value" }
        val prefix = parts.getOrNull(1)?.toIntOrNull() ?: 32
        require(prefix in 0..32) { "Invalid CIDR prefix: $value" }
        return AndroidVpnCidr(parts[0], prefix)
    }

    fun parseRouteCidr(value: String): AndroidVpnCidr {
        val cidr = parseCidr(value)
        return AndroidVpnCidr(
            address = ipv4NetworkAddress(cidr.address, cidr.prefixLength) ?: cidr.address,
            prefixLength = cidr.prefixLength,
        )
    }

    private fun routeEndpointCidr(value: String): String {
        val text = value.trim()
        val mappedIndex = text.indexOf("->")
        if (mappedIndex < 0) {
            return text
        }
        val mapped = text.substring(mappedIndex + 2).trim()
        return mapped.ifEmpty { text.substring(0, mappedIndex).trim() }
    }

    private fun routeList(intent: Intent?, extraName: String): List<String> {
        return stringList(intent, extraName)
            .map {
                val cidr = parseRouteCidr(it)
                "${cidr.address}/${cidr.prefixLength}"
            }
            .distinct()
    }

    private fun ipv4NetworkAddress(address: String, prefixLength: Int): String? {
        val value = ipv4ToUInt(address) ?: return null
        val mask = if (prefixLength == 0) {
            0L
        } else {
            (0xffffffffL shl (32 - prefixLength)) and 0xffffffffL
        }
        return ipv4FromUInt(value and mask)
    }

    private fun ipv4ToUInt(address: String): Long? {
        val parts = address.split(".")
        if (parts.size != 4) {
            return null
        }
        var value = 0L
        for (part in parts) {
            val octet = part.toIntOrNull() ?: return null
            if (octet < 0 || octet > 255) {
                return null
            }
            value = (value shl 8) or octet.toLong()
        }
        return value
    }

    private fun ipv4FromUInt(value: Long): String {
        return listOf(
            (value shr 24) and 0xff,
            (value shr 16) and 0xff,
            (value shr 8) and 0xff,
            value and 0xff,
        ).joinToString(".")
    }

    private fun stringList(intent: Intent?, extraName: String): List<String> {
        return intent?.getStringArrayListExtra(extraName)
            .orEmpty()
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .distinct()
    }
}
