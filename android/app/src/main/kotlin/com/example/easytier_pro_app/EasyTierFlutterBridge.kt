package com.example.easytier_pro_app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale
import java.util.UUID

class EasyTierFlutterBridge(private val activity: MainActivity) :
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    private var eventSink: EventChannel.EventSink? = null
    private var pendingVpnResult: MethodChannel.Result? = null

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
                    EasyTierNative.stopConfigServerClient()
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
            result.error(errorCode(error), error.message ?: error.toString(), null)
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    fun onActivityResult(requestCode: Int, resultCode: Int): Boolean {
        if (requestCode != vpnRequestCode) {
            return false
        }
        val granted = resultCode == Activity.RESULT_OK
        pendingVpnResult?.success(granted)
        pendingVpnResult = null
        emit(
            if (granted) "vpn_permission_granted" else "vpn_permission_denied",
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

        EasyTierNative.startConfigServerClient(url, hostname, machineId, secureMode) { payload ->
            emit(
                "config_server",
                mapOf(
                    "raw" to payload,
                    "payload" to (parseJson(payload) ?: mapOf("raw" to payload)),
                ),
            )
        }
        result.success(null)
    }

    private fun prepareVpn(result: MethodChannel.Result) {
        val intent = VpnService.prepare(activity)
        if (intent == null) {
            emit("vpn_permission_granted", mapOf("granted" to true))
            result.success(true)
            return
        }
        if (pendingVpnResult != null) {
            result.error("VPN_PERMISSION_PENDING", "VPN permission request is already pending", null)
            return
        }
        pendingVpnResult = result
        activity.startActivityForResult(intent, vpnRequestCode)
    }

    private fun startVpn(call: MethodCall, result: MethodChannel.Result) {
        val instanceName = call.argument<String>("instanceName")?.trim().orEmpty()
        require(instanceName.isNotEmpty()) { "instanceName is required" }

        val vpnConfig = call.argument<Map<String, Any?>>("vpnConfig") ?: emptyMap()
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
            (vpnConfig["mtu"] as? Number)?.toInt()?.let {
                putExtra(EasyTierVpnService.extraMtu, it)
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            activity.startForegroundService(intent)
        } else {
            activity.startService(intent)
        }
        result.success(null)
    }

    private fun stopVpn() {
        val intent = Intent(activity, EasyTierVpnService::class.java).apply {
            action = EasyTierVpnService.actionStop
        }
        activity.startService(intent)
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
        activity.runOnUiThread {
            eventSink?.success(mapOf("type" to type, "payload" to payload))
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
        private const val preferencesName = "easytier_core_runtime"
        private const val machineIdKey = "machine_id"
        private const val vpnRequestCode = 42020

        @Volatile
        private var activeBridge: EasyTierFlutterBridge? = null

        fun emitFromService(type: String, payload: Map<String, Any?>) {
            activeBridge?.emit(type, payload)
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

private fun parseJson(text: String): Any? {
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
