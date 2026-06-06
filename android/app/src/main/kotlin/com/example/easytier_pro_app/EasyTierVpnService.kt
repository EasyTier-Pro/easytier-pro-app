package com.example.easytier_pro_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor

class EasyTierVpnService : VpnService() {
    private var tunFd: Int? = null
    private var tunDescriptor: ParcelFileDescriptor? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return try {
            when (intent?.action) {
                actionStop -> {
                    stopVpn()
                    START_NOT_STICKY
                }
                actionStart -> {
                    startVpn(intent)
                    START_STICKY
                }
                else -> START_NOT_STICKY
            }
        } catch (error: Throwable) {
            EasyTierFlutterBridge.emitFromService(
                "error",
                mapOf("error" to (error.message ?: error.toString())),
            )
            stopVpn()
            START_NOT_STICKY
        }
    }

    override fun onDestroy() {
        stopVpn()
        super.onDestroy()
    }

    private fun startVpn(intent: Intent) {
        val instanceName = intent.getStringExtra(extraInstanceName)?.trim().orEmpty()
        require(instanceName.isNotEmpty()) { "VPN instanceName is required" }

        val addresses = intent.getStringArrayListExtra(extraAddresses) ?: arrayListOf()
        require(addresses.isNotEmpty()) { "VPN address is required before establishing TUN" }

        startForeground(notificationId, notification())

        val builder = Builder()
            .setSession("EasyTier Pro")

        val mtu = intent.getIntExtra(extraMtu, 0)
        if (mtu > 0) {
            builder.setMtu(mtu)
        }

        for (address in addresses) {
            val cidr = parseCidr(address)
            builder.addAddress(cidr.address, cidr.prefixLength)
        }

        val routes = intent.getStringArrayListExtra(extraRoutes) ?: arrayListOf()
        for (route in routes) {
            val cidr = parseCidr(route)
            builder.addRoute(cidr.address, cidr.prefixLength)
        }

        val dnsServers = intent.getStringArrayListExtra(extraDnsServers) ?: arrayListOf()
        for (server in dnsServers) {
            builder.addDnsServer(server)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false)
        }

        val descriptor = builder.establish() ?: throw IllegalStateException("VpnService establish returned null")
        tunDescriptor = descriptor
        val fd = descriptor.detachFd()
        tunFd = fd
        EasyTierNative.setTunFd(instanceName, fd)
        EasyTierFlutterBridge.emitFromService(
            "vpn_started",
            mapOf("instanceName" to instanceName),
        )
    }

    private fun stopVpn() {
        val fd = tunFd
        tunFd = null
        tunDescriptor?.close()
        tunDescriptor = null
        if (fd != null) {
            EasyTierFlutterBridge.emitFromService("vpn_stopped", mapOf("fd" to fd))
        }
        stopForegroundCompat()
        stopSelf()
    }

    private fun notification(): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            val channel = NotificationChannel(
                notificationChannelId,
                "EasyTier VPN",
                NotificationManager.IMPORTANCE_LOW,
            )
            manager.createNotificationChannel(channel)
        }

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, notificationChannelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle("EasyTier Pro")
            .setContentText("VPN connection is active")
            .setOngoing(true)
            .build()
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    private fun parseCidr(value: String): Cidr {
        val parts = value.trim().split("/", limit = 2)
        require(parts.firstOrNull()?.isNotEmpty() == true) { "Invalid CIDR: $value" }
        val prefix = parts.getOrNull(1)?.toIntOrNull() ?: 32
        return Cidr(parts[0], prefix)
    }

    private data class Cidr(val address: String, val prefixLength: Int)

    companion object {
        const val actionStart = "com.example.easytier_pro_app.action.START_VPN"
        const val actionStop = "com.example.easytier_pro_app.action.STOP_VPN"
        const val extraInstanceName = "instanceName"
        const val extraAddresses = "addresses"
        const val extraRoutes = "routes"
        const val extraDnsServers = "dnsServers"
        const val extraMtu = "mtu"

        private const val notificationId = 22020
        private const val notificationChannelId = "easytier_vpn"
    }
}
