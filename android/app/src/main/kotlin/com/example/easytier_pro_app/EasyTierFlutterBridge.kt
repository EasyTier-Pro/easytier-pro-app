package com.example.easytier_pro_app

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.util.ArrayDeque
import java.util.Locale
import java.util.UUID

class EasyTierFlutterBridge(private val activity: MainActivity) :
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    private var eventSink: EventChannel.EventSink? = null
    private var pendingVpnResult: MethodChannel.Result? = null
    private var pendingNotificationResult: MethodChannel.Result? = null

    fun configure(flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            methodChannelName,
        ).setMethodCallHandler(this)
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            eventChannelName,
        ).setStreamHandler(this)
        activeBridge = this
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "getMachineId" -> result.success(getMachineId())
                "getHostname" -> result.success(getHostname())
                "startConfigServerClient" -> startConfigServerClient(call, result)
                "stopConfigServerClient" -> {
                    stopConfigServerClient()
                    result.success(null)
                }
                "isConfigServerClientConnected" -> {
                    result.success(EasyTierNative.isConfigServerClientConnected())
                }
                "collectNetworkInfos" -> {
                    val maxLength = call.argument<Int>("maxLength") ?: 2 * 1024 * 1024
                    result.success(EasyTierNative.collectNetworkInfos(maxLength))
                }
                "retainNetworkInstance" -> {
                    val names = call.argument<List<String>>("instanceNames") ?: emptyList()
                    EasyTierNative.retainNetworkInstance(names)
                    result.success(null)
                }
                "prepareNotifications" -> prepareNotifications(result)
                "prepareVpn" -> prepareVpn(result)
                "startVpn" -> startVpn(call, result)
                "stopVpn" -> {
                    stopVpn()
                    result.success(null)
                }
                "getLastError" -> result.success(EasyTierNative.getLastError())
                else -> result.notImplemented()
            }
        } catch (error: Throwable) {
            Log.e(logTag, "Method ${call.method} failed", error)
            result.error(errorCode(error), error.message ?: error.toString(), null)
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        flushBufferedEvents()
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    fun onActivityResult(requestCode: Int, resultCode: Int): Boolean {
        if (requestCode != vpnRequestCode) {
            return false
        }
        val granted = resultCode == Activity.RESULT_OK
        Log.i(logTag, "VPN permission result granted=$granted")
        pendingVpnResult?.success(granted)
        pendingVpnResult = null
        emit(
            if (granted) "vpn_permission_granted" else "vpn_permission_denied",
            mapOf("granted" to granted),
        )
        return true
    }

    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != notificationRequestCode) {
            return false
        }
        val granted = grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
        Log.i(logTag, "Notification permission result granted=$granted")
        pendingNotificationResult?.success(granted)
        pendingNotificationResult = null
        emit(
            if (granted) "notification_permission_granted" else "notification_permission_denied",
            mapOf("granted" to granted),
        )
        return true
    }

    private fun startConfigServerClient(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")?.trim().orEmpty()
        val hostname = call.argument<String>("hostname")?.trim().orEmpty()
        val machineId = call.argument<String>("machineId")?.trim().orEmpty()
        val secureMode = call.argument<Boolean>("secureMode") ?: true
        require(url.isNotEmpty()) { "config server url is required" }
        require(hostname.isNotEmpty()) { "hostname is required" }
        require(machineId.isNotEmpty()) { "machineId is required" }

        Log.i(logTag, "Starting config server client service for host=$hostname")
        val intent = Intent(activity, EasyTierVpnService::class.java).apply {
            action = EasyTierVpnService.actionStartConfigServer
            putExtra(EasyTierVpnService.extraConfigServerUrl, url)
            putExtra(EasyTierVpnService.extraHostname, hostname)
            putExtra(EasyTierVpnService.extraMachineId, machineId)
            putExtra(EasyTierVpnService.extraSecureMode, secureMode)
        }
        startRuntimeService(intent)
        result.success(null)
    }

    private fun prepareNotifications(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            emit("notification_permission_granted", mapOf("granted" to true))
            result.success(true)
            return
        }
        if (activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            emit("notification_permission_granted", mapOf("granted" to true))
            result.success(true)
            return
        }
        if (pendingNotificationResult != null) {
            result.error(
                "NOTIFICATION_PERMISSION_PENDING",
                "Notification permission request is already pending",
                null,
            )
            return
        }
        pendingNotificationResult = result
        activity.requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            notificationRequestCode,
        )
    }

    private fun prepareVpn(result: MethodChannel.Result) {
        val intent = VpnService.prepare(activity)
        if (intent == null) {
            Log.i(logTag, "VPN permission already granted")
            emit("vpn_permission_granted", mapOf("granted" to true))
            result.success(true)
            return
        }
        if (pendingVpnResult != null) {
            result.error("VPN_PERMISSION_PENDING", "VPN permission request is already pending", null)
            return
        }
        pendingVpnResult = result
        Log.i(logTag, "Requesting VPN permission")
        activity.startActivityForResult(intent, vpnRequestCode)
    }

    private fun startVpn(call: MethodCall, result: MethodChannel.Result) {
        val instanceName = call.argument<String>("instanceName")?.trim().orEmpty()
        require(instanceName.isNotEmpty()) { "instanceName is required" }

        val vpnConfig = call.argument<Map<String, Any?>>("vpnConfig") ?: emptyMap()
        Log.i(logTag, "Starting VPN service for instance=$instanceName")
        val intent = Intent(activity, EasyTierVpnService::class.java).apply {
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
                ArrayList(stringList(vpnConfig["dns"] ?: vpnConfig["dns_servers"])),
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
            (vpnConfig["mtu"] as? Number)?.toInt()?.let {
                putExtra(EasyTierVpnService.extraMtu, it)
            }
        }
        startRuntimeService(intent)
        result.success(null)
    }

    private fun stopConfigServerClient() {
        Log.i(logTag, "Stopping config server client service")
        val intent = Intent(activity, EasyTierVpnService::class.java).apply {
            action = EasyTierVpnService.actionStopConfigServer
        }
        activity.startService(intent)
    }

    private fun stopVpn() {
        Log.i(logTag, "Stopping VPN service")
        val intent = Intent(activity, EasyTierVpnService::class.java).apply {
            action = EasyTierVpnService.actionStop
        }
        activity.startService(intent)
    }

    private fun startRuntimeService(intent: Intent) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            activity.startForegroundService(intent)
        } else {
            activity.startService(intent)
        }
    }

    private fun getMachineId(): String {
        val preferences = activity.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
        val existing = preferences.getString(machineIdKey, null)?.trim()
        if (!existing.isNullOrEmpty()) {
            return existing
        }
        val generated = UUID.randomUUID().toString()
        preferences.edit().putString(machineIdKey, generated).apply()
        return generated
    }

    private fun getHostname(): String {
        val manufacturer = Build.MANUFACTURER?.trim().orEmpty()
        val model = Build.MODEL?.trim().orEmpty()
        val raw = listOf(manufacturer, model)
            .filter { it.isNotEmpty() }
            .joinToString("-")
            .ifEmpty { "android-device" }
        return raw
            .lowercase(Locale.US)
            .replace(Regex("[^a-z0-9-]+"), "-")
            .trim('-')
            .ifEmpty { "android-device" }
    }

    private fun emit(type: String, payload: Map<String, Any?>) {
        deliverEvent(eventOf(type, payload))
    }

    private fun deliverEvent(event: Map<String, Any?>) {
        activity.runOnUiThread {
            val sink = eventSink
            if (sink == null) {
                bufferServiceEvent(event)
                return@runOnUiThread
            }
            for (buffered in drainBufferedServiceEvents()) {
                sink.success(buffered)
            }
            sink.success(event)
        }
    }

    private fun flushBufferedEvents() {
        activity.runOnUiThread {
            val sink = eventSink ?: return@runOnUiThread
            for (event in drainBufferedServiceEvents()) {
                sink.success(event)
            }
        }
    }

    private fun errorCode(error: Throwable): String {
        val message = error.message.orEmpty()
        return if (
            message.contains("JNI", ignoreCase = true) ||
            message.contains("libeasytier_android_jni", ignoreCase = true)
        ) {
            "JNI_UNAVAILABLE"
        } else {
            "ANDROID_RUNTIME_ERROR"
        }
    }

    companion object {
        private const val methodChannelName = "net.easytier.pro/core_runtime"
        private const val eventChannelName = "net.easytier.pro/core_runtime_events"
        private const val logTag = "EasyTierBridge"
        private const val preferencesName = "easytier_core_runtime"
        private const val machineIdKey = "machine_id"
        private const val vpnRequestCode = 42020
        private const val notificationRequestCode = 42021
        private const val maxBufferedServiceEvents = 64

        @Volatile
        private var activeBridge: EasyTierFlutterBridge? = null
        private val bufferedServiceEvents = ArrayDeque<Map<String, Any?>>()

        fun emitFromService(type: String, payload: Map<String, Any?>) {
            val event = eventOf(type, payload)
            val bridge = activeBridge
            if (bridge == null) {
                bufferServiceEvent(event)
                return
            }
            bridge.deliverEvent(event)
        }

        private fun eventOf(type: String, payload: Map<String, Any?>): Map<String, Any?> {
            return mapOf("type" to type, "payload" to payload)
        }

        private fun bufferServiceEvent(event: Map<String, Any?>) {
            synchronized(bufferedServiceEvents) {
                if (bufferedServiceEvents.size >= maxBufferedServiceEvents) {
                    bufferedServiceEvents.removeFirst()
                    Log.w(logTag, "Dropping oldest buffered native event")
                }
                bufferedServiceEvents.addLast(event)
            }
        }

        private fun drainBufferedServiceEvents(): List<Map<String, Any?>> {
            synchronized(bufferedServiceEvents) {
                if (bufferedServiceEvents.isEmpty()) {
                    return emptyList()
                }
                val events = bufferedServiceEvents.toList()
                bufferedServiceEvents.clear()
                return events
            }
        }
    }
}

private fun stringList(value: Any?): List<String> {
    return when (value) {
        is String -> listOf(value)
        is Iterable<*> -> value.mapNotNull { it?.toString()?.trim() }
        else -> emptyList()
    }.map { it.trim() }.filter { it.isNotEmpty() }
}

private fun cidrList(value: Any?): List<String> {
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
    val address = (value["address"] ?: value["ip"] ?: value["ipv4"])?.toString()?.trim().orEmpty()
    val prefix = (value["prefix"] ?: value["prefixLength"] ?: value["prefix_length"])
        ?.toString()
        ?.trim()
        .orEmpty()
    return if (address.isNotEmpty() && prefix.isNotEmpty()) "$address/$prefix" else address
}

fun parseJson(text: String): Any? {
    return try {
        val trimmed = text.trim()
        when {
            trimmed.startsWith("{") -> jsonObjectToMap(JSONObject(trimmed))
            trimmed.startsWith("[") -> jsonArrayToList(JSONArray(trimmed))
            else -> null
        }
    } catch (_: Throwable) {
        null
    }
}

private fun jsonObjectToMap(value: JSONObject): Map<String, Any?> {
    val out = linkedMapOf<String, Any?>()
    val keys = value.keys()
    while (keys.hasNext()) {
        val key = keys.next()
        out[key] = jsonValue(value.get(key))
    }
    return out
}

private fun jsonArrayToList(value: JSONArray): List<Any?> {
    val out = mutableListOf<Any?>()
    for (index in 0 until value.length()) {
        out.add(jsonValue(value.get(index)))
    }
    return out
}

private fun jsonValue(value: Any?): Any? {
    return when (value) {
        JSONObject.NULL -> null
        is JSONObject -> jsonObjectToMap(value)
        is JSONArray -> jsonArrayToList(value)
        else -> value
    }
}
