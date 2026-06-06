package com.example.easytier_pro_app

import com.easytier.jni.ConfigServerEventCallback
import java.lang.IllegalStateException
import java.lang.reflect.Method
import java.lang.reflect.Modifier

object EasyTierNative {
    private const val libraryName = "easytier_android_jni"
    private const val jniClassName = "com.easytier.jni.EasyTierJNI"

    @Volatile
    private var loaded = false
    private var jniClass: Class<*>? = null
    private var jniReceiver: Any? = null
    private var loadError: Throwable? = null

    fun startConfigServerClient(
        url: String,
        hostname: String,
        machineId: String,
        secureMode: Boolean,
        callback: (String) -> Unit,
    ) {
        val function = ConfigServerEventCallback { payload ->
            callback(payload)
        }
        invokeStatus("startConfigServerClient", url, hostname, machineId, secureMode, function)
    }

    fun stopConfigServerClient() {
        invokeStatus("stopConfigServerClient")
    }

    fun isConfigServerClientConnected(): Boolean {
        return invoke("isConfigServerClientConnected") as? Boolean ?: false
    }

    fun collectNetworkInfos(maxLength: Int): String {
        val method = findMethod("collectNetworkInfos", 1)
        val arg = when (method.parameterTypes.firstOrNull()) {
            Long::class.javaPrimitiveType,
            Long::class.javaObjectType -> maxLength.toLong()
            else -> maxLength
        }
        return invoke(method, arg)?.toString() ?: "{}"
    }

    fun retainNetworkInstance(instanceNames: List<String>) {
        val method = findMethod("retainNetworkInstance", 1)
        val parameter = method.parameterTypes.firstOrNull()
        val arg: Any = if (parameter?.isArray == true) {
            instanceNames.toTypedArray()
        } else {
            instanceNames
        }
        invokeStatus(method, arg)
    }

    fun setTunFd(instanceName: String, fd: Int) {
        invokeStatus("setTunFd", instanceName, fd)
    }

    fun getLastError(): String {
        return try {
            invoke("getLastError")?.toString() ?: ""
        } catch (error: Throwable) {
            error.message ?: error.toString()
        }
    }

    private fun invoke(name: String, vararg args: Any?): Any? {
        return invoke(findMethod(name, args.size), *args)
    }

    private fun invokeStatus(name: String, vararg args: Any?) {
        invokeStatus(findMethod(name, args.size), *args)
    }

    private fun invokeStatus(method: Method, vararg args: Any?) {
        val result = invoke(method, *args)
        val code = when (result) {
            null -> 0
            is Number -> result.toInt()
            else -> throw IllegalStateException(
                "EasyTier JNI ${method.name} returned unsupported status type: ${result::class.java.name}",
            )
        }
        if (code != 0) {
            val lastError = getLastError().ifBlank { "native status $code" }
            throw IllegalStateException("EasyTier JNI ${method.name} failed: $lastError")
        }
    }

    private fun invoke(method: Method, vararg args: Any?): Any? {
        val receiver = if (Modifier.isStatic(method.modifiers)) null else receiver()
        return method.invoke(receiver, *args)
    }

    private fun findMethod(name: String, parameterCount: Int): Method {
        val clazz = ensureLoaded()
        return clazz.methods.firstOrNull { method ->
            method.name == name && method.parameterTypes.size == parameterCount
        } ?: throw IllegalStateException("EasyTier JNI method not found: $name/$parameterCount")
    }

    private fun receiver(): Any {
        return jniReceiver
            ?: throw IllegalStateException("EasyTier JNI receiver is unavailable")
    }

    private fun ensureLoaded(): Class<*> {
        if (loaded) {
            return jniClass ?: throw IllegalStateException("EasyTier JNI class is unavailable")
        }

        synchronized(this) {
            if (loaded) {
                return jniClass ?: throw IllegalStateException("EasyTier JNI class is unavailable")
            }
            try {
                System.loadLibrary(libraryName)
                val clazz = Class.forName(jniClassName)
                jniClass = clazz
                jniReceiver = clazz.fields.firstOrNull { field ->
                    field.name == "INSTANCE"
                }?.get(null)
                loaded = true
                return clazz
            } catch (error: Throwable) {
                loadError = error
                throw IllegalStateException(
                    "EasyTier Android JNI is unavailable. Build lib$libraryName.so into jniLibs first.",
                    error,
                )
            }
        }
    }

    fun unavailableReason(): String {
        return loadError?.message ?: ""
    }
}
