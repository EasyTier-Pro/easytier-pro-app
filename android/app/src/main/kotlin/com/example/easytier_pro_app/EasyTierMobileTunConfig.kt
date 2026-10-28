package com.example.easytier_pro_app

import org.json.JSONObject

data class EasyTierMobileTunConfig(
    val instanceIds: List<String>,
    val addresses: List<String>,
    val routes: List<String>,
    val dns: String?,
    val searchDomains: List<String>,
    val rejected: List<Map<String, String>>,
) {
    fun sameInterface(other: EasyTierMobileTunConfig): Boolean =
        addresses == other.addresses && routes == other.routes && dns == other.dns &&
            searchDomains == other.searchDomains

    fun toVpnStartConfig(packageName: String) = AndroidVpnStartConfig(
        instanceName = "EasyTier Pro",
        addresses = addresses,
        routes = routes,
        dnsServers = listOfNotNull(dns),
        searchDomains = searchDomains,
        disallowedApplications = listOf(packageName),
        mtu = 1280,
    )

    fun toMap(): Map<String, Any?> = mapOf(
        "instance_ids" to instanceIds,
        "addresses" to addresses,
        "routes" to routes,
        "dns" to dns,
        "search_domains" to searchDomains,
        "rejected" to rejected,
    )

    companion object {
        fun parse(text: String): EasyTierMobileTunConfig {
            val value = JSONObject(text)
            fun strings(key: String): List<String> {
                val items = value.getJSONArray(key)
                return (0 until items.length()).map { items.getString(it) }.distinct().sorted()
            }
            val rejected = value.getJSONArray("rejected")
            return EasyTierMobileTunConfig(
                instanceIds = strings("instance_ids"),
                addresses = strings("addresses"),
                routes = strings("routes"),
                dns = if (value.isNull("dns")) null else value.getString("dns"),
                searchDomains = strings("search_domains"),
                rejected = (0 until rejected.length()).map {
                    val member = rejected.getJSONObject(it)
                    mapOf("instance_id" to member.getString("instance_id"), "error" to member.getString("error"))
                },
            )
        }
    }
}
