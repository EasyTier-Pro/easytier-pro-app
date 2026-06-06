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
    private var activeConfigServerConfig: ConfigServerConfig? = null
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
                    stopRuntime(
                        runtimeStopReason = intent
                            .getStringExtra(extraStopReason)
                            ?.trim()
                            ?.takeIf { it.isNotEmpty() },
                    )
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
            val action = intent?.action.orEmpty()
            val instanceName = intent
                ?.getStringExtra(extraInstanceName)
                ?.trim()
                .orEmpty()
            val payload = mutableMapOf<String, Any?>(
                "error" to (error.message ?: error.toString()),
                "action" to action,
            )
            if (instanceName.isNotEmpty()) {
                payload["instanceName"] = instanceName
            }
            if (action == actionStart) {
                payload.putAll(
                    EasyTierVpnStartConfigParser.diagnosticPayload(
                        intent,
                        packageName,
                    ),
                )
            }
            EasyTierFlutterBridge.emitFromService(
                "error",
                payload,
            )
            if (action == actionStart) {
                stopVpn(
                    stopService = !configServerClientStarted,
                    reason = "start_failed",
                    fallbackInstanceName = instanceName,
                )
            } else {
                stopVpn()
            }
            START_NOT_STICKY
        }
    }

    override fun onDestroy() {
        stopConfigServerClient(stopServiceIfIdle = false)
        stopNetworkInstances()
        stopVpn(stopService = false)
        super.onDestroy()
    }

    override fun onRevoke() {
        Log.i(logTag, "VPN revoked by system")
        stopRuntime(runtimeStopReason = "revoked")
        super.onRevoke()
    }

    private fun startConfigServerClient(intent: Intent) {
        val url = intent.getStringExtra(extraConfigServerUrl)?.trim().orEmpty()
        val hostname = intent.getStringExtra(extraHostname)?.trim().orEmpty()
        val machineId = intent.getStringExtra(extraMachineId)?.trim().orEmpty()
        val secureMode = intent.getBooleanExtra(extraSecureMode, true)
        require(url.isNotEmpty()) { "config server url is required" }
        require(hostname.isNotEmpty()) { "hostname is required" }
        require(machineId.isNotEmpty()) { "machineId is required" }

        val config = ConfigServerConfig(url, hostname, machineId, secureMode)
        if (configServerClientStarted) {
            if (activeConfigServerConfig == config) {
                startForeground(notificationId, notification("Connecting to EasyTier network"))
                Log.i(logTag, "Config server client already started for host=$hostname")
                emitConfigServerStarted(hostname, alreadyStarted = true)
                return
            }
            stopConfigServerClient(stopServiceIfIdle = false, emitEvent = false)
        }

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
        activeConfigServerConfig = config
        emitConfigServerStarted(hostname, alreadyStarted = false)
    }

    private fun emitConfigServerStarted(hostname: String, alreadyStarted: Boolean) {
        EasyTierFlutterBridge.emitFromService(
            "config_server_started",
            mapOf(
                "hostname" to hostname,
                "alreadyStarted" to alreadyStarted,
            ),
        )
    }

    private fun stopConfigServerClient(
        stopServiceIfIdle: Boolean = true,
        emitEvent: Boolean = true,
        stopReason: String? = null,
    ) {
        if (!configServerClientStarted) {
            return
        }
        configServerClientStarted = false
        activeConfigServerConfig = null
        try {
            EasyTierNative.stopConfigServerClient()
            Log.i(logTag, "Stopped config server client")
        } catch (error: Throwable) {
            Log.w(logTag, "Failed to stop config server client", error)
        }
        if (emitEvent) {
            val payload = if (stopReason == null) {
                emptyMap()
            } else {
                mapOf("reason" to stopReason)
            }
            EasyTierFlutterBridge.emitFromService("config_server_stopped", payload)
        }
        if (stopServiceIfIdle && activeInstanceName == null) {
            stopForegroundCompat()
            stopSelf()
        }
    }

    private fun stopRuntime(runtimeStopReason: String? = null) {
        stopConfigServerClient(
            stopServiceIfIdle = false,
            stopReason = runtimeStopReason,
        )
        stopNetworkInstances()
        stopVpn(reason = runtimeStopReason)
    }

    private fun stopNetworkInstances() {
        try {
            EasyTierNative.stopAllInstances()
            Log.i(logTag, "Stopped all EasyTier network instances")
        } catch (error: Throwable) {
            Log.w(logTag, "Failed to stop EasyTier network instances", error)
        }
    }

    private fun startVpn(intent: Intent) {
        val config = EasyTierVpnStartConfigParser.fromIntent(intent, packageName)

        stopVpn(stopService = false)
        Log.i(
            logTag,
            "Establishing VPN for instance=${config.instanceName} addresses=${config.addresses} routes=${config.routes} dns=${config.dnsServers} mtu=${config.mtu} disallowed=${config.disallowedApplications}",
        )

        startForeground(notificationId, notification("Connected to ${config.instanceName}"))

        val builder = Builder()
        EasyTierVpnBuilderConfigurator.configure(
            EasyTierVpnServiceBuilderOperations(builder),
            config,
            sdkInt = Build.VERSION.SDK_INT,
        ) { application, error ->
            Log.w(logTag, "Ignoring unknown disallowed application=$application", error)
        }

        val descriptor = builder.establish() ?: throw IllegalStateException("VpnService establish returned null")
        tunDescriptor = descriptor
        val fd = descriptor.detachFd()
        tunDescriptor = null
        tunFd = fd
        activeInstanceName = config.instanceName
        EasyTierNative.setTunFd(config.instanceName, fd)
        Log.i(logTag, "Injected TUN fd for instance=${config.instanceName}")
        EasyTierFlutterBridge.emitFromService(
            "vpn_started",
            mapOf(
                "instanceName" to config.instanceName,
                "fd" to fd,
                "addresses" to config.addresses,
                "routes" to config.routes,
                "dnsServers" to config.dnsServers,
                "mtu" to config.mtu,
                "disallowedApplications" to config.disallowedApplications,
                "packageName" to packageName,
                "addressCount" to config.addresses.size,
                "routeCount" to config.routes.size,
                "disallowedApplicationCount" to config.disallowedApplications.size,
                "selfDisallowed" to config.disallowedApplications.contains(packageName),
            ),
        )
    }

    private fun stopVpn(
        stopService: Boolean = true,
        reason: String? = null,
        fallbackInstanceName: String? = null,
    ) {
        val fd = tunFd
        val instanceName = activeInstanceName
            ?: fallbackInstanceName?.takeIf { it.isNotEmpty() }
        tunFd = null
        activeInstanceName = null
        tunDescriptor?.close()
        tunDescriptor = null
        if (fd != null) {
            closeDetachedTunFd(fd)
            Log.i(logTag, "Stopped VPN fd=$fd instance=$instanceName")
        }
        if (fd != null || reason != null) {
            val payload = mutableMapOf<String, Any?>("instanceName" to instanceName)
            if (fd != null) {
                payload["fd"] = fd
            }
            if (reason != null) {
                payload["reason"] = reason
            }
            EasyTierFlutterBridge.emitFromService(
                "vpn_stopped",
                payload,
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

    private fun intentStringList(intent: Intent?, extraName: String): List<String> {
        return intent
            ?.getStringArrayListExtra(extraName)
            .orEmpty()
            .map { it.trim() }
            .filter { it.isNotEmpty() }
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
            putExtra(extraStopReason, "user_disconnect")
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

    private data class ConfigServerConfig(
        val url: String,
        val hostname: String,
        val machineId: String,
        val secureMode: Boolean,
    )

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
        const val extraDisallowedApplications = "disallowedApplications"
        const val extraMtu = "mtu"
        const val extraStopReason = "stopReason"

        private const val logTag = "EasyTierVpnService"
        private const val notificationId = 22020
        private const val notificationChannelId = "easytier_vpn"
        private const val pendingIntentOpenAppRequestCode = 22021
        private const val pendingIntentStopRequestCode = 22022
        private val pendingIntentFlags =
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    }
}
