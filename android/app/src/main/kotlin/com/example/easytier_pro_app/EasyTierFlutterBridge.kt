package com.example.easytier_pro_app

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import org.json.JSONArray
import org.json.JSONObject

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
                "stopRuntime" -> {
                    stopRuntime()
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
                "stopNetworkInstances" -> {
                    EasyTierNative.stopAllInstances()
                    result.success(null)
                }
                "prepareNotifications" -> prepareNotifications(result)
                "prepareVpn" -> prepareVpn(result)
                "startVpn" -> startVpn(call, result)
                "stopVpn" -> {
                    stopVpn()
                    result.success(null)
                }
                "shareFile" -> shareFile(call, result)
                "getLastError" -> result.success(EasyTierNative.getLastError())
                else -> result.notImplemented()
            }
        } catch (error: Throwable) {
            Log.e(logTag, "Method ${call.method} failed", error)
            result.error(
                EasyTierAndroidErrorClassifier.code(error),
                error.message ?: error.toString(),
                null,
            )
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
        val intent = EasyTierVpnIntentFactory.startIntent(activity, instanceName, vpnConfig)
        startRuntimeService(intent)
        result.success(null)
    }

    private fun shareFile(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")?.trim().orEmpty()
        val mimeType = call.argument<String>("mimeType")?.trim()
            ?.takeIf { it.isNotEmpty() } ?: "text/plain"
        val title = call.argument<String>("title")?.trim()
            ?.takeIf { it.isNotEmpty() } ?: "Share EasyTier Pro diagnostics"
        require(path.isNotEmpty()) { "share file path is required" }

        val file = File(path)
        require(file.isFile && file.canRead()) { "share file is not readable: $path" }

        val uri = FileProvider.getUriForFile(
            activity,
            "${activity.packageName}.fileprovider",
            file,
        )
        val sendIntent = Intent(Intent.ACTION_SEND).apply {
            type = mimeType
            putExtra(Intent.EXTRA_STREAM, uri)
            putExtra(Intent.EXTRA_TITLE, title)
            clipData = ClipData.newUri(activity.contentResolver, file.name, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val chooser = Intent.createChooser(sendIntent, title).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            activity.startActivity(chooser)
            result.success(true)
        } catch (error: ActivityNotFoundException) {
            result.error("SHARE_UNAVAILABLE", "No app can share diagnostics file", null)
        }
    }

    private fun stopConfigServerClient() {
        Log.i(logTag, "Stopping config server client service")
        val intent = Intent(activity, EasyTierVpnService::class.java).apply {
            action = EasyTierVpnService.actionStopConfigServer
        }
        activity.startService(intent)
    }

    private fun stopRuntime() {
        Log.i(logTag, "Stopping EasyTier runtime service")
        val intent = Intent(activity, EasyTierVpnService::class.java).apply {
            action = EasyTierVpnService.actionStopRuntime
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
        return EasyTierAndroidIdentity.machineId(activity)
    }

    private fun getHostname(): String {
        return EasyTierAndroidIdentity.hostname()
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

    companion object {
        private const val methodChannelName = "net.easytier.pro/core_runtime"
        private const val eventChannelName = "net.easytier.pro/core_runtime_events"
        private const val logTag = "EasyTierBridge"
        private const val vpnRequestCode = 42020
        private const val notificationRequestCode = 42021
        private const val maxBufferedServiceEvents = 64

        @Volatile
        private var activeBridge: EasyTierFlutterBridge? = null
        private val serviceEventBuffer = EasyTierServiceEventBuffer(maxBufferedServiceEvents)

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
            if (serviceEventBuffer.add(event)) {
                Log.w(logTag, "Dropping oldest buffered native event")
            }
        }

        private fun drainBufferedServiceEvents(): List<Map<String, Any?>> {
            return serviceEventBuffer.drain()
        }
    }
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
