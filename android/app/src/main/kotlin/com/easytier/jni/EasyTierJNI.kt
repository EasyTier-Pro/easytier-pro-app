package com.easytier.jni

fun interface ConfigServerEventCallback {
    fun onEvent(eventJson: String)
}

object EasyTierJNI {
    init {
        System.loadLibrary("easytier_android_jni")
    }

    @JvmStatic external fun setTunFd(instanceName: String, fd: Int): Int

    @JvmStatic external fun parseConfig(config: String): Int

    @JvmStatic external fun runNetworkInstance(config: String): Int

    @JvmStatic
    external fun startConfigServerClient(
        url: String,
        hostname: String?,
        machineId: String,
        secureMode: Boolean,
        callback: ConfigServerEventCallback?,
    ): Int

    @JvmStatic external fun stopConfigServerClient(): Int

    @JvmStatic external fun isConfigServerClientConnected(): Boolean

    @JvmStatic external fun retainNetworkInstance(instanceNames: Array<String>?): Int

    @JvmStatic external fun collectNetworkInfos(maxLength: Int): String?

    @JvmStatic external fun getLastError(): String?

    @JvmStatic
    fun stopAllInstances(): Int {
        return retainNetworkInstance(null)
    }

    @JvmStatic
    fun retainSingleInstance(instanceName: String): Int {
        return retainNetworkInstance(arrayOf(instanceName))
    }
}
