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
    private var configServerClientStarted = false

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return try {
            when (intent?.action) {
                actionStartConfigServer -> {
                    startConfigServerClient(intent)
                    START_REDELIVER_INTENT
                }
                actionStopConfigServer -> {
                    stopConfigServerClient()
                    START_NOT_STICKY
                }
                actionStopRuntime -> {
                    stopRuntime()
                    START_NOT_STICKY
                }
                actionStop -> {
                    stopVpn(stopService = !configServerClientStarted)
                    START_NOT_STICKY
                }
                actionStart -> {
                    startVpn(intent)
                    START_REDELIVER_INTENT
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
        stopConfigServerClient(stopServiceIfIdle = false)
        stopVpn(stopService = false)
        super.onDestroy()
    }

    private fun startConfigServerClient(intent: Intent) {
        val url = intent.getStringExtra(extraConfigServerUrl)?.trim().orEmpty()
        val hostname = intent.getStringExtra(extraHostname)?.trim().orEmpty()
        val machineId = intent.getStringExtra(extraMachineId)?.trim().orEmpty()
        val secureMode = intent.getBooleanExtra(extraSecureMode, true)
        require(url.isNotEmpty()) { "config server url is required" }
        require(hostname.isNotEmpty()) { "hostname is required" }
        require(machineId.isNotEmpty()) { "machineId is required" }

        startForeground(notificationId, notification("Connecting to EasyTier network"))
        Log.i(logTag, "Starting config server client in foreground service host=$hostname")
        EasyTierNative.startConfigServerClient(url, hostname, machineId, secureMode) { payload ->
            Log.d(logTag, "Received config server event")
            EasyTierFlutterBridge.emitFromService(
                "config_server",
                mapOf(
                    "raw" to payload,
                    "payload" to (parseJson(payload) ?: mapOf("raw" to payload)),
                ),
            )
        }
        configServerClientStarted = true
        EasyTierFlutterBridge.emitFromService(
            "config_server_started",
            mapOf("hostname" to hostname),
        )
    }

    private fun stopConfigServerClient(stopServiceIfIdle: Boolean = true) {
        if (!configServerClientStarted) {
            return
        }
        configServerClientStarted = false
        try {
            EasyTierNative.stopConfigServerClient()
            Log.i(logTag, "Stopped config server client")
        } catch (error: Throwable) {
            Log.w(logTag, "Failed to stop config server client", error)
        }
        EasyTierFlutterBridge.emitFromService("config_server_stopped", emptyMap())
        if (stopServiceIfIdle && activeInstanceName == null) {
            stopForegroundCompat()
            stopSelf()
        }
    }

    private fun stopRuntime() {
        stopConfigServerClient(stopServiceIfIdle = false)
        stopVpn()
    }

    private fun startVpn(intent: Intent) {
        val instanceName = intent.getStringExtra(extraInstanceName)?.trim().orEmpty()
        require(instanceName.isNotEmpty()) { "VPN instanceName is required" }

        val addresses = intent.getStringArrayListExtra(extraAddresses) ?: arrayListOf()
        require(addresses.isNotEmpty()) { "VPN address is required before establishing TUN" }

        stopVpn(stopService = false)
        Log.i(logTag, "Establishing VPN for instance=$instanceName addresses=${addresses.size}")

        startForeground(notificationId, notification("Connected to $instanceName"))

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
        if (configServerClientStarted && !stopService) {
            startForeground(notificationId, notification("Waiting for network config"))
        } else {
            stopForegroundCompat()
        }
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

    private fun notification(contentText: String): Notification {
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
            .setContentText(contentText)
            .setContentIntent(openAppPendingIntent())
            .addAction(
                applicationInfo.icon,
                "Disconnect",
                stopRuntimePendingIntent(),
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

    private fun stopRuntimePendingIntent(): PendingIntent {
        val intent = Intent(this, EasyTierVpnService::class.java).apply {
            action = actionStopRuntime
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
        const val actionStartConfigServer = "net.easytier.pro.action.START_CONFIG_SERVER"
        const val actionStopConfigServer = "net.easytier.pro.action.STOP_CONFIG_SERVER"
        const val actionStopRuntime = "net.easytier.pro.action.STOP_RUNTIME"
        const val actionStart = "net.easytier.pro.action.START_VPN"
        const val actionStop = "net.easytier.pro.action.STOP_VPN"
        const val extraConfigServerUrl = "configServerUrl"
        const val extraHostname = "hostname"
        const val extraMachineId = "machineId"
        const val extraSecureMode = "secureMode"
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
