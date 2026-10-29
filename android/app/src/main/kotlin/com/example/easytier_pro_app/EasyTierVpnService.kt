package com.example.easytier_pro_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.util.Log
import java.io.IOException
import org.json.JSONObject

class EasyTierVpnService : VpnService() {
    private var tunFd: Int? = null
    private var pendingTunFd: Int? = null
    private var activeTunConfig: EasyTierMobileTunConfig? = null
    private var activeBuilderConfig: AndroidVpnAppliedConfig? = null
    private var activeConfigServerConfig: ConfigServerConfig? = null
    private var membershipChanged = true
    private val startingInstances = mutableMapOf<String, Long>()
    @Volatile private var explicitStopSelfRequested = false
    @Volatile private var destroyed = false
    private var lastRefreshError: String? = null

    override fun onCreate() {
        super.onCreate()
        activeService = this
    }

    private val refresh = object : Runnable {
        override fun run() {
            if (destroyed || activeConfigServerConfig == null) return
            try {
                refreshVpn()
                updateStartingInstances()
                lastRefreshError = null
            } catch (error: Throwable) {
                val message = error.message ?: error.toString()
                if (message != lastRefreshError) {
                    Log.e(logTag, "Shared VPN update failed", error)
                    EasyTierFlutterBridge.emitFromService("vpn_config_error", mapOf("error" to message))
                }
                lastRefreshError = message
                vpnState = vpnState + mapOf("error" to message)
            } finally {
                if (!destroyed && activeConfigServerConfig != null) {
                    val now = SystemClock.elapsedRealtime()
                    startingInstances.entries.removeAll { it.value <= now }
                    worker.postDelayed(this, if (startingInstances.isEmpty()) 3000 else 200)
                }
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action ?: return START_NOT_STICKY
        if (action == actionStartConfigServer || action == actionStart) {
            startForeground(notificationId, notification("Connecting to EasyTier networks"))
        }
        worker.post {
            if (destroyed) return@post
            try {
                when (action) {
                    actionStartConfigServer -> startConfigServerClient(intent)
                    actionStopConfigServer, actionStopRuntime -> stopRuntime(
                        reason = intent.getStringExtra(extraStopReason),
                    )
                    actionStop -> stopVpn()
                    actionStart -> scheduleRefresh()
                }
            } catch (error: Throwable) {
                Log.e(logTag, "VPN service command failed", error)
                EasyTierFlutterBridge.emitFromService(
                    "error", mapOf("error" to (error.message ?: error.toString()), "action" to action),
                )
            }
        }
        return if (action == actionStartConfigServer) START_REDELIVER_INTENT else START_NOT_STICKY
    }

    override fun onDestroy() {
        destroyed = true
        if (activeService === this) activeService = null
        worker.removeCallbacks(refresh)
        if (!explicitStopSelfRequested) {
            worker.post { stopRuntime(stopReasonServiceDestroyed, stopService = false) }
        }
        super.onDestroy()
    }

    override fun onRevoke() {
        worker.post { stopRuntime("revoked") }
        super.onRevoke()
    }

    private fun scheduleRefresh() {
        worker.removeCallbacks(refresh)
        if (!destroyed && activeConfigServerConfig != null) worker.post(refresh)
    }

    private fun startConfigServerClient(intent: Intent) {
        explicitStopSelfRequested = false
        val url = intent.getStringExtra(extraConfigServerUrl)?.trim().orEmpty()
        val hostname = intent.getStringExtra(extraHostname)?.trim().orEmpty()
        val machineId = intent.getStringExtra(extraMachineId)?.trim().orEmpty()
        val secureMode = intent.getBooleanExtra(extraSecureMode, true)
        require(url.isNotEmpty()) { "config server url is required" }
        require(hostname.isNotEmpty()) { "hostname is required" }
        require(machineId.isNotEmpty()) { "machineId is required" }
        val config = ConfigServerConfig(url, hostname, machineId, secureMode)
        val alreadyStarted = activeConfigServerConfig == config
        if (!alreadyStarted) {
            if (activeConfigServerConfig != null) stopRuntime(stopService = false)
            EasyTierNative.startConfigServerClient(url, hostname, machineId, secureMode) { payload ->
                // The service owns membership even when Flutter is suspended or detached.
                worker.post {
                    if (destroyed || activeConfigServerConfig != config) return@post
                    val event = parseJson(payload) as? Map<*, *>
                    val instanceId = event?.get("instance_id") as? String
                    if (!instanceId.isNullOrEmpty()) {
                        when (event["event"]) {
                            "run_network_instance" -> if (event["success"] != false) {
                                startingInstances[instanceId] = SystemClock.elapsedRealtime() + 60_000
                            }
                            "delete_network_instance" -> startingInstances.remove(instanceId)
                        }
                    }
                    EasyTierFlutterBridge.emitFromService(
                        "config_server",
                        mapOf("raw" to payload, "payload" to (event ?: mapOf("raw" to payload))),
                    )
                    // A replacement may reuse the UUID and addresses with a new runtime host.
                    membershipChanged = true
                    scheduleRefresh()
                }
            }
            activeConfigServerConfig = config
        }
        EasyTierFlutterBridge.emitFromService(
            "config_server_started", mapOf("hostname" to hostname, "alreadyStarted" to alreadyStarted),
        )
        scheduleRefresh()
    }

    private fun updateStartingInstances() {
        val state = vpnState
        val attached = (state["instance_ids"] as? List<*>)?.toSet().orEmpty()
        val rejected = (state["rejected"] as? List<*>)
            ?.mapNotNull { (it as? Map<*, *>)?.get("instance_id") as? String }
            ?.toSet().orEmpty()
        startingInstances.keys.toList().forEach { id ->
            if (id in rejected) {
                startingInstances.remove(id)
            } else if (id in attached) {
                val config = EasyTierMobileTunConfig.parse(EasyTierNative.getMobileTunConfig(listOf(id)))
                val installed = activeTunConfig
                if (id in config.instanceIds && config.addresses.isNotEmpty() &&
                    installed != null &&
                    config.addresses.all { it in installed.addresses } &&
                    config.routes.all { it in installed.routes } &&
                    config.searchDomains.all { it in installed.searchDomains } &&
                    (config.dns == null || config.dns == installed.dns)) {
                    startingInstances.remove(id)
                }
            }
        }
    }

    private fun refreshVpn() {
        if (pendingTunFd != null) stopVpn()
        if (prepare(this) != null) return
        val instances = JSONObject(EasyTierNative.listInstances(4096))
        val ids = instances.keys().asSequence().map { instances.getString(it) }.distinct().toList()
        val config = EasyTierMobileTunConfig.parse(EasyTierNative.getMobileTunConfig(ids))
        if (config.instanceIds.isEmpty() || config.addresses.isEmpty()) {
            if (tunFd != null) stopVpn()
            publishState(config.copy(instanceIds = emptyList()))
            return
        }
        val previous = activeTunConfig
        if (!membershipChanged && tunFd != null && previous?.instanceIds == config.instanceIds && previous.sameInterface(config)) {
            publishState(config)
            return
        }

        val oldFd = tunFd
        val replaceInterface = oldFd == null || previous?.sameInterface(config) != true
        var builderConfig = activeBuilderConfig
        val builder = if (replaceInterface) {
            val builder = Builder()
            builderConfig = EasyTierVpnBuilderConfigurator.configure(
                EasyTierVpnServiceBuilderOperations(builder),
                config.toVpnStartConfig(packageName),
                sdkInt = Build.VERSION.SDK_INT,
                allowBypass = (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0,
            ) { application, error -> Log.w(logTag, "Unknown disallowed application=$application", error) }
            builder
        } else {
            null
        }
        val newFd = if (builder != null) {
            (builder.establish() ?: error("VpnService establish returned null")).detachFd()
        } else {
            checkNotNull(oldFd)
        }
        if (newFd != oldFd) pendingTunFd = newFd
        try {
            // Selection runs before old members are detached, preserving their priority.
            // Successful attach also waits for the old borrowed fd to be released.
            val attached = EasyTierMobileTunConfig.parse(
                EasyTierNative.attachMobileTunFd(newFd, ids),
            )
            tunFd = newFd
            pendingTunFd = null
            if (oldFd != null && oldFd != newFd) closeDetachedTunFd(oldFd)
            if (attached.instanceIds.isEmpty()) {
                stopVpn()
                publishState(attached)
                return
            }
            // Remember installed OS settings, not a newer config observed during attach.
            activeTunConfig = config.copy(instanceIds = attached.instanceIds)
            activeBuilderConfig = builderConfig
            membershipChanged = false
            publishState(if (config.sameInterface(attached)) attached else attached.copy(instanceIds = emptyList()))
            startForeground(notificationId, notification("Connected to ${attached.instanceIds.size} networks"))
            EasyTierFlutterBridge.emitFromService(
                if (replaceInterface) "vpn_started" else "vpn_config_refreshed",
                attached.toMap() + mapOf(
                    "fd" to newFd,
                    "disallowedApplications" to listOf(packageName),
                    "selfDisallowed" to true,
                    "packageName" to packageName,
                    "builderAddresses" to builderConfig?.addresses,
                    "builderRoutes" to builderConfig?.routes,
                    "builderDnsServers" to builderConfig?.dnsServers,
                    "builderSearchDomains" to builderConfig?.searchDomains,
                    "builderDisallowedApplications" to builderConfig?.disallowedApplications,
                    "builderSelfDisallowed" to builderConfig?.disallowedApplications?.contains(packageName),
                    "ignoredDisallowedApplications" to builderConfig?.ignoredDisallowedApplications,
                    "allowBypass" to builderConfig?.allowBypass,
                    "builderAllowBypass" to builderConfig?.allowBypass,
                    "mtu" to 1280,
                ),
            )
        } catch (error: Throwable) {
            // A failed attach must release borrowed descriptors before closing them.
            activeTunConfig = null
            vpnState = mapOf("instance_ids" to emptyList<String>())
            try {
                stopVpn()
            } catch (detachError: Throwable) {
                // Both descriptors remain owned until a later detach succeeds.
                error.addSuppressed(detachError)
            }
            throw error
        }
    }

    private fun publishState(config: EasyTierMobileTunConfig) {
        vpnState = config.toMap()
    }

    private fun stopRuntime(reason: String? = null, stopService: Boolean = true) {
        worker.removeCallbacks(refresh)
        activeConfigServerConfig = null
        startingInstances.clear()
        stopVpn(reason)
        EasyTierNative.stopConfigServerClient()
        EasyTierNative.stopAllInstances()
        EasyTierFlutterBridge.emitFromService("config_server_stopped", mapOf("reason" to reason))
        if (stopService) {
            stopForegroundCompat()
            explicitStopSelfRequested = true
            stopSelf()
        }
    }

    private fun stopVpn(reason: String? = null) {
        val fd = tunFd
        val descriptors = listOfNotNull(fd, pendingTunFd).distinct()
        if (descriptors.isNotEmpty()) {
            EasyTierNative.attachMobileTunFd(0, null)
            descriptors.forEach(::closeDetachedTunFd)
        }
        tunFd = null
        pendingTunFd = null
        activeTunConfig = null
        activeBuilderConfig = null
        membershipChanged = true
        vpnState = mapOf("instance_ids" to emptyList<String>(), "rejected" to emptyList<Any>())
        if (fd != null || reason != null) {
            EasyTierFlutterBridge.emitFromService("vpn_stopped", mapOf("reason" to reason))
        }
        if (!destroyed && activeConfigServerConfig != null) {
            startForeground(notificationId, notification("Waiting for network config"))
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
        private val workerThread = HandlerThread("EasyTierVpn").apply { start() }
        private val worker = Handler(workerThread.looper)
        @Volatile private var activeService: EasyTierVpnService? = null
        @Volatile private var vpnState: Map<String, Any?> = mapOf("instance_ids" to emptyList<String>())
        fun state(): Map<String, Any?> = vpnState
        fun requestRefresh() {
            worker.post { activeService?.scheduleRefresh() }
        }

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
        const val stopReasonServiceDestroyed = "service_destroyed"

        private const val logTag = "EasyTierVpnService"
        private const val notificationId = 22020
        private const val notificationChannelId = "easytier_vpn"
        private const val pendingIntentOpenAppRequestCode = 22021
        private const val pendingIntentStopRequestCode = 22022
        private val pendingIntentFlags =
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    }
}
