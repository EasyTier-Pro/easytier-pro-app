package com.example.easytier_pro_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import java.io.IOException

class EasyTierVpnService : VpnService() {
    private var tunFd: Int? = null
    private var tunDescriptor: ParcelFileDescriptor? = null
    private var activeInstanceName: String? = null

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
            Log.e(logTag, "VPN service command failed", error)
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

        stopVpn(stopService = false)
        Log.i(logTag, "Establishing VPN for instance=$instanceName addresses=${addresses.size}")

        startForeground(notificationId, notification(instanceName))

        val builder = Builder()
            .setSession("EasyTier Pro")
            .addDisallowedApplication(packageName)

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
        tunDescriptor = null
        tunFd = fd
        activeInstanceName = instanceName
        EasyTierNative.setTunFd(instanceName, fd)
        Log.i(logTag, "Injected TUN fd for instance=$instanceName")
        EasyTierFlutterBridge.emitFromService(
            "vpn_started",
            mapOf("instanceName" to instanceName),
        )
    }

    private fun stopVpn(stopService: Boolean = true) {
        val fd = tunFd
        val instanceName = activeInstanceName
        tunFd = null
        activeInstanceName = null
        tunDescriptor?.close()
        tunDescriptor = null
        if (fd != null) {
            closeDetachedTunFd(fd)
            Log.i(logTag, "Stopped VPN fd=$fd instance=$instanceName")
            EasyTierFlutterBridge.emitFromService(
                "vpn_stopped",
                mapOf("fd" to fd, "instanceName" to instanceName),
            )
        }
        stopForegroundCompat()
        if (stopService) {
            stopSelf()
        }
    }

    private fun closeDetachedTunFd(fd: Int) {
        try {
            ParcelFileDescriptor.adoptFd(fd).close()
        } catch (error: IOException) {
            Log.w(logTag, "Failed to close detached TUN fd=$fd", error)
        }
    }

    private fun notification(instanceName: String): Notification {
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
            .setContentText("Connected to $instanceName")
            .setContentIntent(openAppPendingIntent())
            .addAction(
                applicationInfo.icon,
                "Disconnect",
                stopVpnPendingIntent(),
            )
            .setOngoing(true)
            .build()
    }

    private fun openAppPendingIntent(): PendingIntent {
        val intent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        intent.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        return PendingIntent.getActivity(
            this,
            pendingIntentOpenAppRequestCode,
            intent,
            pendingIntentFlags,
        )
    }

    private fun stopVpnPendingIntent(): PendingIntent {
        val intent = Intent(this, EasyTierVpnService::class.java).apply {
            action = actionStop
        }
        return PendingIntent.getService(
            this,
            pendingIntentStopRequestCode,
            intent,
            pendingIntentFlags,
        )
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

        private const val logTag = "EasyTierVpnService"
        private const val notificationId = 22020
        private const val notificationChannelId = "easytier_vpn"
        private const val pendingIntentOpenAppRequestCode = 22021
        private const val pendingIntentStopRequestCode = 22022
        private val pendingIntentFlags =
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    }
}
